import Foundation

/// Constrained dynamic time warping over route geometry only.
///
/// Swift builds the compact alignment samples, detects route direction, and
/// turns the matched index path into blocks, diagnostics, and quality. The
/// band-packed dynamic-programming solve itself runs in the C++23 engine
/// through `RunPlayRouteAlignmentDtwBridge`: one native call per alignment
/// attempt, never one per row, cell, or sample.
///
/// Complexity: O(samples × bandWidth) time and memory for active DP rows /
/// backpointers. Does not allocate an unrestricted full n×m matrix.
///
/// Alignment cost uses horizontal separation, optional heading disagreement,
/// normalized progress difference, and non-diagonal transition penalties.
/// Elapsed time, pace, HR, elevation, and cadence are never cost inputs.
public struct ConstrainedDynamicTimeWarpingAligner: RouteComparisonAligning, Sendable {
    private let sampleBuilder: RouteAlignmentSampleBuilder

    public init(sampleBuilder: RouteAlignmentSampleBuilder = RouteAlignmentSampleBuilder()) {
        self.sampleBuilder = sampleBuilder
    }

    public func align(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        policy: RouteAlignmentPolicy = .default,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteAlignmentSnapshot {
        var profile: RouteAlignmentPhaseProfile? = nil
        return try align(
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            policy: policy,
            isCancelled: isCancelled,
            profile: &profile
        )
    }

    /// Test-only profiled path. Shares the production implementation.
    func alignCollectingProfile(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        policy: RouteAlignmentPolicy = .default,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> (snapshot: RouteAlignmentSnapshot, profile: RouteAlignmentPhaseProfile) {
        var profile: RouteAlignmentPhaseProfile? = RouteAlignmentPhaseProfile()
        let wallStart = ContinuousClock.now
        let snapshot = try align(
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            policy: policy,
            isCancelled: isCancelled,
            profile: &profile
        )
        var result = profile ?? RouteAlignmentPhaseProfile()
        result.wallNanoseconds = HotspotProfileClock.nanoseconds(
            from: wallStart,
            to: ContinuousClock.now
        )
        return (snapshot, result)
    }

    private func align(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool,
        profile: inout RouteAlignmentPhaseProfile?
    ) throws -> RouteAlignmentSnapshot {
        // Contexts are accepted for API stability / future matched metrics
        // construction at the call site; DTW cost remains geometry-only.
        _ = primaryContext
        _ = comparisonContext

        let samplePair: RouteAlignmentSamplePair
        if profile != nil {
            let built = sampleBuilder.buildCollectingProfileResult(
                primary: primary,
                comparison: comparison,
                policy: policy,
                isCancelled: isCancelled
            )
            profile?.sampleBuilderDetail = built.profile
            profile?.sampleBuilderNanoseconds = built.profile.wallNanoseconds
            switch built.pair {
            case .success(let pair):
                samplePair = pair
            case .failure(let error):
                switch error as? RouteAlignmentSampleError {
                case .cancelled:
                    return .unavailable(reason: .cancelled, policyVersion: policy.algorithmVersion)
                case .insufficientRouteData:
                    return .unavailable(
                        reason: .insufficientRouteData,
                        diagnostics: baseDiagnostics(policy: policy),
                        policyVersion: policy.algorithmVersion
                    )
                case .unsupportedGeographicExtent:
                    return .unavailable(
                        reason: .unsupportedGeographicExtent,
                        diagnostics: baseDiagnostics(policy: policy),
                        policyVersion: policy.algorithmVersion
                    )
                case .resourceLimit:
                    return .unavailable(
                        reason: .resourceLimit,
                        diagnostics: baseDiagnostics(policy: policy),
                        policyVersion: policy.algorithmVersion
                    )
                case .none:
                    return .unavailable(
                        reason: .algorithmFailure,
                        diagnostics: baseDiagnostics(policy: policy),
                        policyVersion: policy.algorithmVersion
                    )
                }
            }
        } else {
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
            } catch {
                return .unavailable(
                    reason: .algorithmFailure,
                    diagnostics: baseDiagnostics(policy: policy),
                    policyVersion: policy.algorithmVersion
                )
            }
        }

        if isCancelled() {
            return .unavailable(reason: .cancelled, policyVersion: policy.algorithmVersion)
        }

        let direction: RouteAlignmentDirection
        if profile != nil {
            let start = ContinuousClock.now
            direction = detectDirection(
                primary: samplePair.primary,
                comparison: samplePair.comparison,
                policy: policy,
                isCancelled: isCancelled
            )
            profile?.directionDetectionNanoseconds = HotspotProfileClock.nanoseconds(
                from: start,
                to: ContinuousClock.now
            )
        } else {
            direction = detectDirection(
                primary: samplePair.primary,
                comparison: samplePair.comparison,
                policy: policy,
                isCancelled: isCancelled
            )
        }
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
                isCancelled: isCancelled,
                profile: &profile
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

    private func runDTW(
        samples: RouteAlignmentSamplePair,
        direction: RouteAlignmentDirection,
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool,
        profile: inout RouteAlignmentPhaseProfile?
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

        if isCancelled() {
            return .unavailable(reason: .cancelled, policyVersion: policy.algorithmVersion)
        }

        // Band packing, the dynamic-programming sweep, endpoint selection, and
        // path reconstruction happen in one bounded C++23 call. There is no
        // native call per row, cell, or sample, and no callback into Swift.
        let solved: RunPlayRouteAlignmentDtwResult
        do {
            if profile != nil {
                let start = ContinuousClock.now
                solved = try RunPlayRouteAlignmentDtwBridge.solve(
                    primary: primary,
                    comparison: comparison,
                    primaryRouteDistanceMeters: samples.primaryRouteDistanceMeters,
                    comparisonRouteDistanceMeters: samples.comparisonRouteDistanceMeters,
                    effectiveSampleIntervalMeters: samples.effectiveSampleIntervalMeters,
                    policy: policy,
                    isCancelled: isCancelled
                )
                profile?.nativeDTWNanoseconds = HotspotProfileClock.nanoseconds(
                    from: start,
                    to: ContinuousClock.now
                )
            } else {
                solved = try RunPlayRouteAlignmentDtwBridge.solve(
                    primary: primary,
                    comparison: comparison,
                    primaryRouteDistanceMeters: samples.primaryRouteDistanceMeters,
                    comparisonRouteDistanceMeters: samples.comparisonRouteDistanceMeters,
                    effectiveSampleIntervalMeters: samples.effectiveSampleIntervalMeters,
                    policy: policy,
                    isCancelled: isCancelled
                )
            }
        } catch is CancellationError {
            throw RouteAlignmentCancellation()
        }

        if isCancelled() {
            return .unavailable(reason: .cancelled, policyVersion: policy.algorithmVersion)
        }

        let path: [RunPlayRouteAlignmentDtwPathCell]
        switch solved {
        case .resourceLimit:
            return .unavailable(
                reason: .resourceLimit,
                diagnostics: diagnostics(samples: samples, direction: direction, policy: policy),
                policyVersion: policy.algorithmVersion
            )
        case .noPath:
            return .unavailable(
                reason: .routesTooFarApart,
                diagnostics: diagnostics(samples: samples, direction: direction, policy: policy),
                policyVersion: policy.algorithmVersion
            )
        case .success(let matched, _, _, _):
            path = matched
        }

        // Drop free prefix/suffix warp-only edges that do not contribute geometry.
        // Build anchors and blocks; split when either sample crosses a segment gap.
        let built: BuiltBlocks
        if profile != nil {
            let start = ContinuousClock.now
            built = buildBlocks(
                path: path,
                primary: primary,
                comparison: comparison,
                policy: policy
            )
            profile?.blockConstructionNanoseconds = HotspotProfileClock.nanoseconds(
                from: start,
                to: ContinuousClock.now
            )
        } else {
            built = buildBlocks(
                path: path,
                primary: primary,
                comparison: comparison,
                policy: policy
            )
        }

        let finishDiagnostics: () -> (
            diagnostics: RouteAlignmentDiagnostics,
            availability: RouteAlignmentAvailability
        ) = {
            var diagnostics = self.makeDiagnostics(
                samples: samples,
                direction: direction,
                policy: policy,
                path: path,
                blocks: built.blocks,
                primaryMatchedDistance: built.primaryMatchedDistance,
                comparisonMatchedDistance: built.comparisonMatchedDistance,
                primaryUnmatchedPrefix: primary[path.first?.primaryIndex ?? 0].distanceFromStartMeters,
                comparisonUnmatchedPrefix: comparison[path.first?.comparisonIndex ?? 0].distanceFromStartMeters,
                primaryUnmatchedSuffix: samples.primaryRouteDistanceMeters - primary[path.last?.primaryIndex ?? (n - 1)].distanceFromStartMeters,
                comparisonUnmatchedSuffix: samples.comparisonRouteDistanceMeters - comparison[path.last?.comparisonIndex ?? (m - 1)].distanceFromStartMeters
            )
            let availability = self.classify(
                diagnostics: diagnostics,
                policy: policy,
                direction: direction
            )
            if case .unavailable = availability {
                return (diagnostics, availability)
            }
            if direction == .ambiguous {
                diagnostics = self.withWarning(
                    diagnostics,
                    "Route geometry is somewhat ambiguous; treat local deltas cautiously."
                )
            }
            return (diagnostics, availability)
        }

        let diagnostics: RouteAlignmentDiagnostics
        let availability: RouteAlignmentAvailability
        if profile != nil {
            let start = ContinuousClock.now
            let finished = finishDiagnostics()
            diagnostics = finished.diagnostics
            availability = finished.availability
            profile?.diagnosticsNanoseconds = HotspotProfileClock.nanoseconds(
                from: start,
                to: ContinuousClock.now
            )
        } else {
            let finished = finishDiagnostics()
            diagnostics = finished.diagnostics
            availability = finished.availability
        }

        if case .unavailable(let reason) = availability {
            return .unavailable(
                reason: reason,
                diagnostics: diagnostics,
                policyVersion: policy.algorithmVersion
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
        path: [RunPlayRouteAlignmentDtwPathCell],
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
        var lastPrimaryDistance = primary[path[0].primaryIndex].distanceFromStartMeters
        var lastComparisonDistance = comparison[path[0].comparisonIndex].distanceFromStartMeters
        var lastPrimarySegment = primary[path[0].primaryIndex].routeSegmentIndex
        var lastComparisonSegment = comparison[path[0].comparisonIndex].routeSegmentIndex
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
            let pSample = primary[cell.primaryIndex]
            let cSample = comparison[cell.comparisonIndex]
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
        path: [RunPlayRouteAlignmentDtwPathCell],
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
