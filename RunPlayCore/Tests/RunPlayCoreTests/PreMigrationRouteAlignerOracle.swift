import Foundation
@testable import RunPlayCore

/// Complete pre-migration `ConstrainedDynamicTimeWarpingAligner`, transcribed
/// into the test target so end-to-end `RouteAlignmentSnapshot` parity can be
/// proven against the migrated production aligner.
///
/// Everything outside the dynamic-programming solve — the direction probe,
/// block construction, monotonic enforcement, diagnostics, quality
/// classification, warnings, and the `align` entry point with its error
/// mapping — is a faithful copy of the pre-migration source. It uses the real
/// `RouteAlignmentSampleBuilder`, exactly as the original did.
///
/// Two deliberate substitutions, and nothing else:
///
/// 1. The inline band packing, DP sweep, endpoint selection, and path
///    reconstruction are delegated to `SwiftConstrainedDtwPathOracle`, which is
///    itself a verbatim transcription of that same pre-migration code. Its
///    `.resourceLimit` and `.noPath` outcomes map onto the two snapshots the
///    original produced at those exact return points.
/// 2. `SwiftConstrainedDtwPathCell` values are converted into the local
///    `PathCell` shape that the transcribed `buildBlocks` and `makeDiagnostics`
///    consume.
///
/// This type never calls `ConstrainedDynamicTimeWarpingAligner` or
/// `RunPlayRouteAlignmentDtwBridge`, so a shared-helper regression cannot hide
/// a snapshot mismatch.
///
/// The pre-migration cancellation checks that lived *inside* the DP sweep and
/// the reconstruction loop are not reproduced, because the delegated solver has
/// no cancellation hook. Every cancellation check outside the solve is kept, so
/// an always-cancelled run still matches production. Parity fixtures therefore
/// use a non-cancelling closure or one that cancels before the solve.
///
/// The pre-migration `pointCost` and `maxPrefixSuffixSamples` helpers are not
/// duplicated here: they were used only by the delegated DP, and
/// `SwiftConstrainedDtwPathOracle` carries its own verbatim copies.
struct PreMigrationRouteAlignerOracle: RouteComparisonAligning, Sendable {
    private let sampleBuilder: RouteAlignmentSampleBuilder

    init(sampleBuilder: RouteAlignmentSampleBuilder = RouteAlignmentSampleBuilder()) {
        self.sampleBuilder = sampleBuilder
    }

    func align(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        policy: RouteAlignmentPolicy = .default,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteAlignmentSnapshot {
        // Contexts are accepted for API stability / future matched metrics
        // construction at the call site; DTW cost remains geometry-only.
        _ = primaryContext
        _ = comparisonContext

        let samplePair: RouteAlignmentSamplePair
        do {
            samplePair = try sampleBuilder.build(
                primary: primary,
                comparison: comparison,
                policy: policy,
                isCancelled: isCancelled
            )
        } catch RouteAlignmentSampleError.cancelled {
            return .unavailable(reason: .cancelled, policyVersion: policy.algorithmVersion)
        } catch RouteAlignmentSampleError.insufficientRouteData {
            return .unavailable(
                reason: .insufficientRouteData,
                diagnostics: baseDiagnostics(policy: policy),
                policyVersion: policy.algorithmVersion
            )
        } catch RouteAlignmentSampleError.unsupportedGeographicExtent {
            return .unavailable(
                reason: .unsupportedGeographicExtent,
                diagnostics: baseDiagnostics(policy: policy),
                policyVersion: policy.algorithmVersion
            )
        } catch RouteAlignmentSampleError.resourceLimit {
            return .unavailable(
                reason: .resourceLimit,
                diagnostics: baseDiagnostics(policy: policy),
                policyVersion: policy.algorithmVersion
            )
        }

        if isCancelled() {
            return .unavailable(reason: .cancelled, policyVersion: policy.algorithmVersion)
        }

        let direction = detectDirection(
            primary: samplePair.primary,
            comparison: samplePair.comparison,
            policy: policy,
            isCancelled: isCancelled
        )
        if isCancelled() {
            return .unavailable(reason: .cancelled, policyVersion: policy.algorithmVersion)
        }
        if direction == .opposite {
            return .unavailable(
                reason: .oppositeDirection,
                diagnostics: RouteAlignmentDiagnostics(
                    primaryRouteDistanceMeters: samplePair.primaryRouteDistanceMeters,
                    comparisonRouteDistanceMeters: samplePair.comparisonRouteDistanceMeters,
                    primarySampleCount: samplePair.primary.count,
                    comparisonSampleCount: samplePair.comparison.count,
                    effectiveSampleIntervalMeters: samplePair.effectiveSampleIntervalMeters,
                    detectedDirection: .opposite,
                    algorithmVersion: policy.algorithmVersion,
                    warnings: ["Opposite direction detected; cumulative-time alignment is unavailable."]
                ),
                policyVersion: policy.algorithmVersion
            )
        }

        do {
            return try runDTW(
                samples: samplePair,
                direction: direction,
                policy: policy,
                isCancelled: isCancelled
            )
        } catch is RouteAlignmentCancellation {
            return .unavailable(reason: .cancelled, policyVersion: policy.algorithmVersion)
        } catch {
            return .unavailable(
                reason: .algorithmFailure,
                diagnostics: RouteAlignmentDiagnostics(
                    primaryRouteDistanceMeters: samplePair.primaryRouteDistanceMeters,
                    comparisonRouteDistanceMeters: samplePair.comparisonRouteDistanceMeters,
                    primarySampleCount: samplePair.primary.count,
                    comparisonSampleCount: samplePair.comparison.count,
                    effectiveSampleIntervalMeters: samplePair.effectiveSampleIntervalMeters,
                    detectedDirection: direction,
                    algorithmVersion: policy.algorithmVersion,
                    warnings: ["Alignment algorithm failed."]
                ),
                policyVersion: policy.algorithmVersion
            )
        }
    }

    // MARK: - Direction probe

    private func detectDirection(
        primary: [RouteAlignmentSample],
        comparison: [RouteAlignmentSample],
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool
    ) -> RouteAlignmentDirection {
        let probeCount = max(4, policy.directionProbeSampleCount)
        let primaryProbe = coarseSamples(primary, count: probeCount)
        let comparisonProbe = coarseSamples(comparison, count: probeCount)
        guard primaryProbe.count >= 4, comparisonProbe.count >= 4 else { return .unknown }
        if isCancelled() { return .unknown }

        // Ordered sequential cost (not bag-of-points nearest neighbour) so a
        // reversed straight route is distinguishable from the forward sequence.
        let forward = orderedSequenceCost(primaryProbe, comparisonProbe)
        let reversed = orderedSequenceCost(primaryProbe, Array(comparisonProbe.reversed()))
        guard forward.isFinite, reversed.isFinite else { return .unknown }

        // Heading agreement on long edges as a secondary signal.
        let headingAgreement = meanHeadingAgreement(primaryProbe, comparisonProbe)

        if reversed + 1e-6 < forward * policy.oppositeDirectionCostRatio {
            return .opposite
        }
        if headingAgreement < -0.25, reversed <= forward {
            return .opposite
        }
        if forward + 1e-6 < reversed * policy.oppositeDirectionCostRatio {
            return .same
        }
        if headingAgreement > 0.35, forward <= reversed {
            return .same
        }
        return .ambiguous
    }

    private func coarseSamples(_ samples: [RouteAlignmentSample], count: Int) -> [RouteAlignmentSample] {
        guard samples.count > count else { return samples }
        var result: [RouteAlignmentSample] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let sourceIndex = Int(Double(index) * Double(samples.count - 1) / Double(count - 1))
            result.append(samples[sourceIndex])
        }
        return result
    }

    /// Mean Euclidean distance between co-indexed coarse samples.
    private func orderedSequenceCost(
        _ primary: [RouteAlignmentSample],
        _ comparison: [RouteAlignmentSample]
    ) -> Double {
        let count = min(primary.count, comparison.count)
        guard count > 0 else { return .infinity }
        var total = 0.0
        for index in 0..<count {
            let dx = primary[index].xMeters - comparison[index].xMeters
            let dz = primary[index].zMeters - comparison[index].zMeters
            total += (dx * dx + dz * dz).squareRoot()
        }
        return total / Double(count)
    }

    /// Mean cosine of heading difference in [-1, 1]; positive means same-ish.
    private func meanHeadingAgreement(
        _ primary: [RouteAlignmentSample],
        _ comparison: [RouteAlignmentSample]
    ) -> Double {
        let count = min(primary.count, comparison.count)
        guard count > 0 else { return 0 }
        var sum = 0.0
        var used = 0
        for index in 0..<count {
            guard let h1 = primary[index].headingRadians,
                  let h2 = comparison[index].headingRadians else { continue }
            var delta = abs(h1 - h2)
            if delta > .pi { delta = 2 * .pi - delta }
            sum += cos(delta)
            used += 1
        }
        guard used > 0 else { return 0 }
        return sum / Double(used)
    }

    // MARK: - DTW

    private enum StepKind: UInt8 {
        case diagonal = 0
        case primaryOnly = 1
        case comparisonOnly = 2
    }

    private struct PathCell {
        let i: Int
        let j: Int
        let step: StepKind
    }

    private func runDTW(
        samples: RouteAlignmentSamplePair,
        direction: RouteAlignmentDirection,
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteAlignmentSnapshot {
        let primary = samples.primary
        let comparison = samples.comparison
        let n = primary.count
        let m = comparison.count
        guard n >= policy.minimumSamplesPerRoute, m >= policy.minimumSamplesPerRoute else {
            return .unavailable(
                reason: .insufficientRouteData,
                diagnostics: diagnostics(
                    samples: samples,
                    direction: direction,
                    policy: policy
                ),
                policyVersion: policy.algorithmVersion
            )
        }

        // Substituted solve: identical band packing, DP sweep, endpoint choice,
        // and reconstruction, transcribed into the independent path oracle.
        let solved = SwiftConstrainedDtwPathOracle.solve(
            primary: primary,
            comparison: comparison,
            primaryRouteDistanceMeters: samples.primaryRouteDistanceMeters,
            comparisonRouteDistanceMeters: samples.comparisonRouteDistanceMeters,
            effectiveSampleIntervalMeters: samples.effectiveSampleIntervalMeters,
            policy: policy
        )

        let path: [PathCell]
        switch solved {
        case .resourceLimit:
            // Pre-migration returned this snapshot at both band-budget checks.
            return .unavailable(
                reason: .resourceLimit,
                diagnostics: diagnostics(samples: samples, direction: direction, policy: policy),
                policyVersion: policy.algorithmVersion
            )
        case .noPath:
            // Pre-migration returned this snapshot when no finite endpoint existed.
            return .unavailable(
                reason: .routesTooFarApart,
                diagnostics: diagnostics(samples: samples, direction: direction, policy: policy),
                policyVersion: policy.algorithmVersion
            )
        case .success(let cells, _, _, _):
            path = cells.map { cell in
                PathCell(
                    i: cell.primaryIndex,
                    j: cell.comparisonIndex,
                    step: StepKind(rawValue: cell.step.rawValue) ?? .diagonal
                )
            }
        }

        // Drop free prefix/suffix warp-only edges that do not contribute geometry.
        // Build anchors and blocks; split when either sample crosses a segment gap.
        let built = buildBlocks(
            path: path,
            primary: primary,
            comparison: comparison,
            policy: policy
        )

        var diagnostics = makeDiagnostics(
            samples: samples,
            direction: direction,
            policy: policy,
            path: path,
            blocks: built.blocks,
            primaryMatchedDistance: built.primaryMatchedDistance,
            comparisonMatchedDistance: built.comparisonMatchedDistance,
            primaryUnmatchedPrefix: primary[path.first?.i ?? 0].distanceFromStartMeters,
            comparisonUnmatchedPrefix: comparison[path.first?.j ?? 0].distanceFromStartMeters,
            primaryUnmatchedSuffix: samples.primaryRouteDistanceMeters - primary[path.last?.i ?? (n - 1)].distanceFromStartMeters,
            comparisonUnmatchedSuffix: samples.comparisonRouteDistanceMeters - comparison[path.last?.j ?? (m - 1)].distanceFromStartMeters
        )

        let availability = classify(
            diagnostics: diagnostics,
            policy: policy,
            direction: direction
        )
        if case .unavailable(let reason) = availability {
            return .unavailable(
                reason: reason,
                diagnostics: diagnostics,
                policyVersion: policy.algorithmVersion
            )
        }

        if direction == .ambiguous {
            diagnostics = withWarning(
                diagnostics,
                "Route geometry is somewhat ambiguous; treat local deltas cautiously."
            )
        }

        return RouteAlignmentSnapshot(
            blocks: built.blocks,
            diagnostics: diagnostics,
            availability: availability,
            policyVersion: policy.algorithmVersion
        )
    }

    // MARK: - Blocks

    private struct BuiltBlocks {
        let blocks: [RouteAlignmentBlock]
        let primaryMatchedDistance: Double
        let comparisonMatchedDistance: Double
    }

    private func buildBlocks(
        path: [PathCell],
        primary: [RouteAlignmentSample],
        comparison: [RouteAlignmentSample],
        policy: RouteAlignmentPolicy
    ) -> BuiltBlocks {
        guard !path.isEmpty else {
            return BuiltBlocks(blocks: [], primaryMatchedDistance: 0, comparisonMatchedDistance: 0)
        }

        var blocks: [RouteAlignmentBlock] = []
        var currentAnchors: [RouteAlignmentAnchor] = []
        var alignedProgress = 0.0
        var lastPrimaryDistance = primary[path[0].i].distanceFromStartMeters
        var lastComparisonDistance = comparison[path[0].j].distanceFromStartMeters
        var lastPrimarySegment = primary[path[0].i].routeSegmentIndex
        var lastComparisonSegment = comparison[path[0].j].routeSegmentIndex
        var primaryMatched = 0.0
        var comparisonMatched = 0.0

        func flushBlock() {
            guard currentAnchors.count >= 2 else {
                currentAnchors.removeAll(keepingCapacity: true)
                return
            }
            // Ensure monotonic aligned progress within block.
            blocks.append(RouteAlignmentBlock(id: blocks.count, anchors: currentAnchors))
            currentAnchors.removeAll(keepingCapacity: true)
        }

        for (index, cell) in path.enumerated() {
            let pSample = primary[cell.i]
            let cSample = comparison[cell.j]
            let segmentBreak = pSample.routeSegmentIndex != lastPrimarySegment
                || cSample.routeSegmentIndex != lastComparisonSegment

            if segmentBreak && !currentAnchors.isEmpty {
                flushBlock()
                // Restart aligned progress continuity but keep cumulative domain increasing.
                // Aligned progress continues across blocks without filling the gap.
                lastPrimaryDistance = pSample.distanceFromStartMeters
                lastComparisonDistance = cSample.distanceFromStartMeters
            }

            let primaryDelta = max(0, pSample.distanceFromStartMeters - lastPrimaryDistance)
            let comparisonDelta = max(0, cSample.distanceFromStartMeters - lastComparisonDistance)
            // Aligned progress advances by the larger matched travel when both move,
            // or by the moving side alone on warp steps.
            let advance: Double
            switch cell.step {
            case .diagonal:
                advance = max(primaryDelta, comparisonDelta)
            case .primaryOnly:
                advance = primaryDelta
            case .comparisonOnly:
                advance = comparisonDelta
            }
            if index > 0, advance > 0 {
                alignedProgress += advance
            }

            let separation = hypot(pSample.xMeters - cSample.xMeters, pSample.zMeters - cSample.zMeters)
            // Avoid duplicate anchors with identical aligned progress and distances.
            if let last = currentAnchors.last,
               abs(last.primaryDistanceMeters - pSample.distanceFromStartMeters) < 1e-6,
               abs(last.comparisonDistanceMeters - cSample.distanceFromStartMeters) < 1e-6 {
                lastPrimaryDistance = pSample.distanceFromStartMeters
                lastComparisonDistance = cSample.distanceFromStartMeters
                lastPrimarySegment = pSample.routeSegmentIndex
                lastComparisonSegment = cSample.routeSegmentIndex
                continue
            }

            // If aligned progress did not move and we already have an anchor, skip.
            if let last = currentAnchors.last, abs(last.alignedProgressMeters - alignedProgress) < 1e-9 {
                // Prefer updating to the later pair only when progress truly stalled.
                if pSample.distanceFromStartMeters >= last.primaryDistanceMeters
                    && cSample.distanceFromStartMeters >= last.comparisonDistanceMeters {
                    // Replace last for monotonic endpoint capture.
                    currentAnchors[currentAnchors.count - 1] = RouteAlignmentAnchor(
                        alignedProgressMeters: alignedProgress,
                        primaryDistanceMeters: pSample.distanceFromStartMeters,
                        comparisonDistanceMeters: cSample.distanceFromStartMeters,
                        spatialSeparationMeters: separation,
                        primarySegmentIndex: pSample.routeSegmentIndex,
                        comparisonSegmentIndex: cSample.routeSegmentIndex
                    )
                }
            } else {
                if currentAnchors.isEmpty && blocks.isEmpty {
                    alignedProgress = 0
                } else if currentAnchors.isEmpty && !blocks.isEmpty {
                    // Continue after gap without inserting gap distance.
                    alignedProgress = blocks[blocks.count - 1].alignedEndMeters
                }
                currentAnchors.append(
                    RouteAlignmentAnchor(
                        alignedProgressMeters: alignedProgress,
                        primaryDistanceMeters: pSample.distanceFromStartMeters,
                        comparisonDistanceMeters: cSample.distanceFromStartMeters,
                        spatialSeparationMeters: separation,
                        primarySegmentIndex: pSample.routeSegmentIndex,
                        comparisonSegmentIndex: cSample.routeSegmentIndex
                    )
                )
            }

            if primaryDelta > 0 { primaryMatched += primaryDelta }
            if comparisonDelta > 0 { comparisonMatched += comparisonDelta }
            lastPrimaryDistance = pSample.distanceFromStartMeters
            lastComparisonDistance = cSample.distanceFromStartMeters
            lastPrimarySegment = pSample.routeSegmentIndex
            lastComparisonSegment = cSample.routeSegmentIndex
        }
        flushBlock()

        // Re-normalize aligned progress to be continuous 0...total across blocks.
        var normalized: [RouteAlignmentBlock] = []
        var cursor = 0.0
        for block in blocks {
            guard let first = block.anchors.first, let last = block.anchors.last else { continue }
            let span = max(0, last.alignedProgressMeters - first.alignedProgressMeters)
            var newAnchors: [RouteAlignmentAnchor] = []
            newAnchors.reserveCapacity(block.anchors.count)
            for anchor in block.anchors {
                let local = anchor.alignedProgressMeters - first.alignedProgressMeters
                newAnchors.append(
                    RouteAlignmentAnchor(
                        alignedProgressMeters: cursor + local,
                        primaryDistanceMeters: anchor.primaryDistanceMeters,
                        comparisonDistanceMeters: anchor.comparisonDistanceMeters,
                        spatialSeparationMeters: anchor.spatialSeparationMeters,
                        primarySegmentIndex: anchor.primarySegmentIndex,
                        comparisonSegmentIndex: anchor.comparisonSegmentIndex
                    )
                )
            }
            // Enforce strict monotonic primary/comparison distances inside block.
            newAnchors = enforceMonotonic(newAnchors)
            guard newAnchors.count >= 2 else { continue }
            normalized.append(RouteAlignmentBlock(id: normalized.count, anchors: newAnchors))
            cursor += span
        }

        return BuiltBlocks(
            blocks: normalized,
            primaryMatchedDistance: primaryMatched,
            comparisonMatchedDistance: comparisonMatched
        )
    }

    private func enforceMonotonic(_ anchors: [RouteAlignmentAnchor]) -> [RouteAlignmentAnchor] {
        guard !anchors.isEmpty else { return anchors }
        var result: [RouteAlignmentAnchor] = []
        result.reserveCapacity(anchors.count)
        var lastP = -Double.infinity
        var lastC = -Double.infinity
        var lastA = -Double.infinity
        for anchor in anchors {
            let p = max(anchor.primaryDistanceMeters, lastP)
            let c = max(anchor.comparisonDistanceMeters, lastC)
            let a = max(anchor.alignedProgressMeters, lastA)
            result.append(
                RouteAlignmentAnchor(
                    alignedProgressMeters: a,
                    primaryDistanceMeters: p,
                    comparisonDistanceMeters: c,
                    spatialSeparationMeters: anchor.spatialSeparationMeters,
                    primarySegmentIndex: anchor.primarySegmentIndex,
                    comparisonSegmentIndex: anchor.comparisonSegmentIndex
                )
            )
            lastP = p
            lastC = c
            lastA = a
        }
        return result
    }

    // MARK: - Quality

    private func classify(
        diagnostics: RouteAlignmentDiagnostics,
        policy: RouteAlignmentPolicy,
        direction: RouteAlignmentDirection
    ) -> RouteAlignmentAvailability {
        if diagnostics.alignedDistanceMeters < policy.minimumAlignedDistanceMeters {
            return .unavailable(.insufficientMatchedDistance)
        }
        if diagnostics.primaryCoverageFraction < policy.minimumCoverageFraction
            || diagnostics.comparisonCoverageFraction < policy.minimumCoverageFraction {
            return .unavailable(.insufficientCoverage)
        }
        if diagnostics.medianSpatialSeparationMeters > policy.acceptableMedianSeparationMeters
            || diagnostics.p90SpatialSeparationMeters > policy.maximumAcceptedP90SeparationMeters {
            return .unavailable(.routesTooFarApart)
        }

        let totalSteps = max(
            1,
            diagnostics.diagonalStepCount
                + diagnostics.primaryOnlyWarpStepCount
                + diagnostics.comparisonOnlyWarpStepCount
        )
        let warpFraction = Double(
            diagnostics.primaryOnlyWarpStepCount + diagnostics.comparisonOnlyWarpStepCount
        ) / Double(totalSteps)
        if warpFraction > policy.maximumAcceptedWarpFraction
            || diagnostics.maximumConsecutiveWarpRun > policy.maximumConsecutiveWarpSteps {
            return .unavailable(.excessiveWarping)
        }

        let maxUnmatchedPrimary = policy.maximumUnmatchedDistance(forRouteDistance: diagnostics.primaryRouteDistanceMeters)
        let maxUnmatchedComparison = policy.maximumUnmatchedDistance(forRouteDistance: diagnostics.comparisonRouteDistanceMeters)
        // Allow one sample interval of quantisation slack on unmatched ends.
        let slack = max(diagnostics.effectiveSampleIntervalMeters, 1)
        if diagnostics.primaryUnmatchedPrefixMeters > maxUnmatchedPrimary + slack
            || diagnostics.primaryUnmatchedSuffixMeters > maxUnmatchedPrimary + slack
            || diagnostics.comparisonUnmatchedPrefixMeters > maxUnmatchedComparison + slack
            || diagnostics.comparisonUnmatchedSuffixMeters > maxUnmatchedComparison + slack {
            // Large start rotation on loops often lands here.
            if direction == .ambiguous {
                return .unavailable(.ambiguousGeometry)
            }
            return .unavailable(.insufficientCoverage)
        }

        let minCoverage = min(diagnostics.primaryCoverageFraction, diagnostics.comparisonCoverageFraction)
        if minCoverage >= policy.excellentCoverageFraction
            && diagnostics.medianSpatialSeparationMeters <= policy.excellentMedianSeparationMeters
            && diagnostics.p90SpatialSeparationMeters <= policy.excellentP90SeparationMeters
            && warpFraction <= policy.excellentMaximumWarpFraction {
            return .available(.excellent)
        }
        if minCoverage >= policy.goodCoverageFraction
            && diagnostics.medianSpatialSeparationMeters <= policy.goodMedianSeparationMeters
            && diagnostics.p90SpatialSeparationMeters <= policy.goodP90SeparationMeters
            && warpFraction <= policy.goodMaximumWarpFraction {
            return .available(.good)
        }
        return .available(.limited)
    }

    // MARK: - Diagnostics helpers

    private func baseDiagnostics(policy: RouteAlignmentPolicy) -> RouteAlignmentDiagnostics {
        RouteAlignmentDiagnostics(algorithmVersion: policy.algorithmVersion)
    }

    private func diagnostics(
        samples: RouteAlignmentSamplePair,
        direction: RouteAlignmentDirection,
        policy: RouteAlignmentPolicy
    ) -> RouteAlignmentDiagnostics {
        RouteAlignmentDiagnostics(
            primaryRouteDistanceMeters: samples.primaryRouteDistanceMeters,
            comparisonRouteDistanceMeters: samples.comparisonRouteDistanceMeters,
            primarySampleCount: samples.primary.count,
            comparisonSampleCount: samples.comparison.count,
            effectiveSampleIntervalMeters: samples.effectiveSampleIntervalMeters,
            detectedDirection: direction,
            algorithmVersion: policy.algorithmVersion
        )
    }

    private func makeDiagnostics(
        samples: RouteAlignmentSamplePair,
        direction: RouteAlignmentDirection,
        policy: RouteAlignmentPolicy,
        path: [PathCell],
        blocks: [RouteAlignmentBlock],
        primaryMatchedDistance: Double,
        comparisonMatchedDistance: Double,
        primaryUnmatchedPrefix: Double,
        comparisonUnmatchedPrefix: Double,
        primaryUnmatchedSuffix: Double,
        comparisonUnmatchedSuffix: Double
    ) -> RouteAlignmentDiagnostics {
        var diagonal = 0
        var primaryWarp = 0
        var comparisonWarp = 0
        var maxWarpRun = 0
        var currentWarpRun = 0
        for cell in path {
            switch cell.step {
            case .diagonal:
                diagonal += 1
                currentWarpRun = 0
            case .primaryOnly:
                primaryWarp += 1
                currentWarpRun += 1
                maxWarpRun = max(maxWarpRun, currentWarpRun)
            case .comparisonOnly:
                comparisonWarp += 1
                currentWarpRun += 1
                maxWarpRun = max(maxWarpRun, currentWarpRun)
            }
        }

        var weighted: [DistanceWeightedStatistics.WeightedSample] = []
        var maxSep = 0.0
        var sumSep = 0.0
        var sepCount = 0
        for block in blocks {
            let anchors = block.anchors
            guard anchors.count >= 2 else { continue }
            for index in 1..<anchors.count {
                let prev = anchors[index - 1]
                let curr = anchors[index]
                let weight = max(0, curr.alignedProgressMeters - prev.alignedProgressMeters)
                let value = curr.spatialSeparationMeters
                if value.isFinite {
                    maxSep = max(maxSep, value)
                    sumSep += value
                    sepCount += 1
                    if weight > 0 {
                        weighted.append(.init(value: value, weight: weight))
                    }
                }
            }
        }

        let mean = sepCount > 0 ? sumSep / Double(sepCount) : 0
        let median = DistanceWeightedStatistics.weightedMedian(weighted) ?? mean
        let p90 = DistanceWeightedStatistics.weightedQuantile(weighted, quantile: 0.9) ?? maxSep
        let aligned = blocks.last?.alignedEndMeters ?? 0
        let primaryCoverage = samples.primaryRouteDistanceMeters > 0
            ? min(1, primaryMatchedDistance / samples.primaryRouteDistanceMeters) : 0
        let comparisonCoverage = samples.comparisonRouteDistanceMeters > 0
            ? min(1, comparisonMatchedDistance / samples.comparisonRouteDistanceMeters) : 0

        return RouteAlignmentDiagnostics(
            primaryRouteDistanceMeters: samples.primaryRouteDistanceMeters,
            comparisonRouteDistanceMeters: samples.comparisonRouteDistanceMeters,
            primarySampleCount: samples.primary.count,
            comparisonSampleCount: samples.comparison.count,
            effectiveSampleIntervalMeters: samples.effectiveSampleIntervalMeters,
            matchedBlockCount: blocks.count,
            alignedDistanceMeters: aligned,
            primaryCoverageFraction: primaryCoverage,
            comparisonCoverageFraction: comparisonCoverage,
            meanSpatialSeparationMeters: mean,
            medianSpatialSeparationMeters: median,
            p90SpatialSeparationMeters: p90,
            maximumSpatialSeparationMeters: maxSep,
            diagonalStepCount: diagonal,
            primaryOnlyWarpStepCount: primaryWarp,
            comparisonOnlyWarpStepCount: comparisonWarp,
            maximumConsecutiveWarpRun: maxWarpRun,
            primaryUnmatchedPrefixMeters: max(0, primaryUnmatchedPrefix),
            primaryUnmatchedSuffixMeters: max(0, primaryUnmatchedSuffix),
            comparisonUnmatchedPrefixMeters: max(0, comparisonUnmatchedPrefix),
            comparisonUnmatchedSuffixMeters: max(0, comparisonUnmatchedSuffix),
            detectedDirection: direction,
            algorithmVersion: policy.algorithmVersion,
            warnings: []
        )
    }

    private func withWarning(
        _ diagnostics: RouteAlignmentDiagnostics,
        _ warning: String
    ) -> RouteAlignmentDiagnostics {
        var warnings = diagnostics.warnings
        warnings.append(warning)
        return RouteAlignmentDiagnostics(
            primaryRouteDistanceMeters: diagnostics.primaryRouteDistanceMeters,
            comparisonRouteDistanceMeters: diagnostics.comparisonRouteDistanceMeters,
            primarySampleCount: diagnostics.primarySampleCount,
            comparisonSampleCount: diagnostics.comparisonSampleCount,
            effectiveSampleIntervalMeters: diagnostics.effectiveSampleIntervalMeters,
            matchedBlockCount: diagnostics.matchedBlockCount,
            alignedDistanceMeters: diagnostics.alignedDistanceMeters,
            primaryCoverageFraction: diagnostics.primaryCoverageFraction,
            comparisonCoverageFraction: diagnostics.comparisonCoverageFraction,
            meanSpatialSeparationMeters: diagnostics.meanSpatialSeparationMeters,
            medianSpatialSeparationMeters: diagnostics.medianSpatialSeparationMeters,
            p90SpatialSeparationMeters: diagnostics.p90SpatialSeparationMeters,
            maximumSpatialSeparationMeters: diagnostics.maximumSpatialSeparationMeters,
            diagonalStepCount: diagnostics.diagonalStepCount,
            primaryOnlyWarpStepCount: diagnostics.primaryOnlyWarpStepCount,
            comparisonOnlyWarpStepCount: diagnostics.comparisonOnlyWarpStepCount,
            maximumConsecutiveWarpRun: diagnostics.maximumConsecutiveWarpRun,
            primaryUnmatchedPrefixMeters: diagnostics.primaryUnmatchedPrefixMeters,
            primaryUnmatchedSuffixMeters: diagnostics.primaryUnmatchedSuffixMeters,
            comparisonUnmatchedPrefixMeters: diagnostics.comparisonUnmatchedPrefixMeters,
            comparisonUnmatchedSuffixMeters: diagnostics.comparisonUnmatchedSuffixMeters,
            detectedDirection: diagnostics.detectedDirection,
            algorithmVersion: diagnostics.algorithmVersion,
            warnings: warnings
        )
    }
}
