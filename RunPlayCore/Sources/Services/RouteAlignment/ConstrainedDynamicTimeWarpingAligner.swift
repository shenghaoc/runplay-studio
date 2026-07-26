import Foundation

/// Constrained dynamic time warping over route geometry only.
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

        let bandRadius = max(
            1,
            Int(ceil(Double(max(n, m)) * policy.bandWidthFraction)),
            maxPrefixSuffixSamples(primaryDistance: samples.primaryRouteDistanceMeters, comparisonDistance: samples.comparisonRouteDistanceMeters, interval: samples.effectiveSampleIntervalMeters, policy: policy)
        )

        // Estimated cells inside the band.
        let estimatedCells = n * (2 * bandRadius + 1)
        if estimatedCells > policy.maximumBandCells {
            return .unavailable(
                reason: .resourceLimit,
                diagnostics: diagnostics(samples: samples, direction: direction, policy: policy),
                policyVersion: policy.algorithmVersion
            )
        }

        let infinity = Double.greatestFiniteMagnitude / 4
        // Rolling cost rows + compact backpointers (step kind only) inside band.
        // Store full rows of width m for simplicity but only write active band cells.
        // Memory is O(n * m) for backpointers only when band is full; to honor
        // the band budget we store backpointers as a flat array of optional UInt8
        // sized n*m only when estimatedCells is bounded — for large routes we
        // store a band-packed structure.

        // Band-packed storage: for each i, columns [jStart...jEnd].
        var rowStarts = [Int](repeating: 0, count: n)
        var rowEnds = [Int](repeating: -1, count: n)
        var offsets = [Int](repeating: 0, count: n)
        var totalCells = 0
        for i in 0..<n {
            let center = Int((Double(i) / Double(max(n - 1, 1))) * Double(max(m - 1, 1)))
            let jStart = max(0, center - bandRadius)
            let jEnd = min(m - 1, center + bandRadius)
            // Also expand near ends for open begin/end.
            let open = maxPrefixSuffixSamples(
                primaryDistance: samples.primaryRouteDistanceMeters,
                comparisonDistance: samples.comparisonRouteDistanceMeters,
                interval: samples.effectiveSampleIntervalMeters,
                policy: policy
            )
            let expandedStart = i < open ? 0 : jStart
            let expandedEnd = i >= n - open ? m - 1 : jEnd
            let start = min(expandedStart, jStart)
            let end = max(expandedEnd, jEnd)
            rowStarts[i] = start
            rowEnds[i] = end
            offsets[i] = totalCells
            totalCells += max(0, end - start + 1)
        }
        if totalCells > policy.maximumBandCells {
            return .unavailable(
                reason: .resourceLimit,
                diagnostics: diagnostics(samples: samples, direction: direction, policy: policy),
                policyVersion: policy.algorithmVersion
            )
        }

        var costs = [Double](repeating: infinity, count: totalCells)
        var steps = [UInt8](repeating: 255, count: totalCells)
        var warpRuns = [UInt8](repeating: 0, count: totalCells)

        func index(_ i: Int, _ j: Int) -> Int? {
            guard i >= 0, i < n, j >= rowStarts[i], j <= rowEnds[i] else { return nil }
            return offsets[i] + (j - rowStarts[i])
        }

        func pointCost(i: Int, j: Int) -> Double {
            Self.pointCost(primary: primary[i], comparison: comparison[j], policy: policy)
        }

        // Seed (0, j) open beginning for comparison prefix.
        let openPrimary = maxPrefixSuffixSamples(
            primaryDistance: samples.primaryRouteDistanceMeters,
            comparisonDistance: samples.comparisonRouteDistanceMeters,
            interval: samples.effectiveSampleIntervalMeters,
            policy: policy
        )
        var cellsVisited = 0
        for j in rowStarts[0]...rowEnds[0] {
            guard let idx = index(0, j) else { continue }
            if j == 0 {
                costs[idx] = pointCost(i: 0, j: 0)
                steps[idx] = StepKind.diagonal.rawValue
                warpRuns[idx] = 0
            } else if j <= openPrimary {
                // Allow free-ish prefix on comparison.
                let prev = index(0, j - 1).map { costs[$0] } ?? infinity
                costs[idx] = prev + pointCost(i: 0, j: j) + policy.nonDiagonalStepPenalty * 0.25
                steps[idx] = StepKind.comparisonOnly.rawValue
                warpRuns[idx] = UInt8(min(255, Int(warpRuns[index(0, j - 1) ?? idx]) + 1))
            }
            cellsVisited += 1
        }
        // Seed (i, 0) open beginning for primary prefix.
        for i in 1..<n where rowStarts[i] == 0 {
            guard let idx = index(i, 0), let prevIdx = index(i - 1, 0) else { continue }
            if i <= openPrimary {
                costs[idx] = costs[prevIdx] + pointCost(i: i, j: 0) + policy.nonDiagonalStepPenalty * 0.25
                steps[idx] = StepKind.primaryOnly.rawValue
                warpRuns[idx] = UInt8(min(255, Int(warpRuns[prevIdx]) + 1))
            }
            cellsVisited += 1
        }

        for i in 1..<n {
            if isCancelled() { throw RouteAlignmentCancellation() }
            let jLo = rowStarts[i]
            let jHi = rowEnds[i]
            guard jLo <= jHi else { continue }
            for j in jLo...jHi {
                if j == 0 { continue }
                cellsVisited += 1
                if cellsVisited % policy.cancellationStride == 0, isCancelled() {
                    throw RouteAlignmentCancellation()
                }
                guard let idx = index(i, j) else { continue }
                let pc = pointCost(i: i, j: j)
                var best = infinity
                var bestStep = StepKind.diagonal
                var bestWarp: UInt8 = 0

                // Diagonal
                if let dIdx = index(i - 1, j - 1), costs[dIdx] < infinity {
                    let candidate = costs[dIdx] + pc
                    if candidate < best {
                        best = candidate
                        bestStep = .diagonal
                        bestWarp = 0
                    }
                }
                // Primary only (vertical in matrix if i is rows)
                if let pIdx = index(i - 1, j), costs[pIdx] < infinity {
                    let run = Int(warpRuns[pIdx]) + 1
                    if run <= policy.maximumConsecutiveWarpSteps {
                        let candidate = costs[pIdx] + pc + policy.nonDiagonalStepPenalty
                        if candidate < best {
                            best = candidate
                            bestStep = .primaryOnly
                            bestWarp = UInt8(min(255, run))
                        }
                    }
                }
                // Comparison only
                if let cIdx = index(i, j - 1), costs[cIdx] < infinity {
                    let run = Int(warpRuns[cIdx]) + 1
                    if run <= policy.maximumConsecutiveWarpSteps {
                        let candidate = costs[cIdx] + pc + policy.nonDiagonalStepPenalty
                        if candidate < best {
                            best = candidate
                            bestStep = .comparisonOnly
                            bestWarp = UInt8(min(255, run))
                        }
                    }
                }
                costs[idx] = best
                steps[idx] = bestStep.rawValue
                warpRuns[idx] = bestWarp
            }
        }

        // Choose best endpoint allowing open suffix.
        var bestEndI = n - 1
        var bestEndJ = m - 1
        var bestEndCost = infinity
        let openSuffix = openPrimary
        for i in max(0, n - 1 - openSuffix)..<n {
            for j in max(0, m - 1 - openSuffix)..<m {
                guard let idx = index(i, j), costs[idx] < bestEndCost else { continue }
                bestEndCost = costs[idx]
                bestEndI = i
                bestEndJ = j
            }
        }
        guard bestEndCost < infinity, let endIdx = index(bestEndI, bestEndJ) else {
            return .unavailable(
                reason: .routesTooFarApart,
                diagnostics: diagnostics(samples: samples, direction: direction, policy: policy),
                policyVersion: policy.algorithmVersion
            )
        }
        _ = endIdx

        // Reconstruct path.
        var path: [PathCell] = []
        path.reserveCapacity(n + m)
        var ci = bestEndI
        var cj = bestEndJ
        var guardCounter = 0
        while true {
            guardCounter += 1
            if guardCounter > n + m + 8 { break }
            if isCancelled() { throw RouteAlignmentCancellation() }
            guard let idx = index(ci, cj), steps[idx] != 255 else { break }
            let step = StepKind(rawValue: steps[idx]) ?? .diagonal
            path.append(PathCell(i: ci, j: cj, step: step))
            if ci == 0 && cj == 0 { break }
            switch step {
            case .diagonal:
                if ci == 0 && cj == 0 { break }
                ci = max(0, ci - 1)
                cj = max(0, cj - 1)
            case .primaryOnly:
                if ci == 0 { break }
                ci -= 1
            case .comparisonOnly:
                if cj == 0 { break }
                cj -= 1
            }
            if ci == 0 && cj == 0 {
                path.append(PathCell(i: 0, j: 0, step: .diagonal))
                break
            }
        }
        path.reverse()

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

    // MARK: - Point cost

    static func pointCost(
        primary: RouteAlignmentSample,
        comparison: RouteAlignmentSample,
        policy: RouteAlignmentPolicy
    ) -> Double {
        let dx = primary.xMeters - comparison.xMeters
        let dz = primary.zMeters - comparison.zMeters
        let separation = (dx * dx + dz * dz).squareRoot()
        let scale = max(policy.spatialDistanceCostScaleMeters, 1)
        // Bounded spatial cost dominates.
        let spatial = min(policy.maximumSpatialCost, separation / scale)

        var headingTerm = 0.0
        if let h1 = primary.headingRadians, let h2 = comparison.headingRadians {
            var delta = abs(h1 - h2)
            if delta > .pi { delta = 2 * .pi - delta }
            // 0...π → 0...1
            headingTerm = (delta / .pi) * policy.headingPenaltyWeight
        }

        let progressDelta = abs(primary.normalizedProgress - comparison.normalizedProgress)
        let progressTerm = progressDelta * policy.progressPenaltyWeight

        let total = spatial + headingTerm + progressTerm
        return total.isFinite ? total : policy.maximumSpatialCost
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

    private func maxPrefixSuffixSamples(
        primaryDistance: Double,
        comparisonDistance: Double,
        interval: Double,
        policy: RouteAlignmentPolicy
    ) -> Int {
        let maxMeters = max(
            policy.maximumUnmatchedDistance(forRouteDistance: primaryDistance),
            policy.maximumUnmatchedDistance(forRouteDistance: comparisonDistance)
        )
        let step = max(interval, 1)
        // Floor so the sample window cannot exceed the metre-based policy once
        // multiplied back by the effective interval (ceil would overshoot).
        return max(1, Int(floor(maxMeters / step)))
    }

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
