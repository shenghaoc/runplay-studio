import Foundation

/// Stage-1 candidate filter: cheap geometric admission over route facts.
///
/// Pure arithmetic on `RouteGroupingRouteFacts` — no route-point scans, no
/// native calls. A pair must pass the distance-ratio bound (the subset
/// guard), bounding-box overlap with margin, and start-to-either-endpoint
/// proximity (which admits reversed-direction runs).
public enum RouteGroupCandidateFilter {
    /// Degrees of latitude per metre (equatorial approximation; the filter
    /// deliberately stays coarse).
    private static let metersPerDegreeLatitude = 111_000.0

    public static func isCandidate(
        _ a: RouteGroupingRouteFacts,
        _ b: RouteGroupingRouteFacts,
        policy: RouteGroupingPolicy
    ) -> Bool {
        guard a.canParticipate(policy: policy), b.canParticipate(policy: policy) else {
            return false
        }

        // Distance ratio: shorter / longer must sit inside the bounds. This
        // is what excludes a short route wholly contained in a much longer
        // one, which coverage alone would admit.
        let longer = max(a.totalDistanceMeters, b.totalDistanceMeters)
        let shorter = min(a.totalDistanceMeters, b.totalDistanceMeters)
        guard longer > 0, shorter / longer >= policy.distanceRatioBounds.lowerBound else {
            return false
        }

        // Bounding-box overlap with a margin. Using the latitude scale for
        // both axes keeps the test conservative at high latitudes.
        let marginDegrees = policy.boundingBoxOverlapMarginMeters / metersPerDegreeLatitude
        let latitudeOverlap = min(a.maxLatitude, b.maxLatitude) - max(a.minLatitude, b.minLatitude)
        let longitudeOverlap = min(a.maxLongitude, b.maxLongitude) - max(a.minLongitude, b.minLongitude)
        if latitudeOverlap < -marginDegrees || longitudeOverlap < -marginDegrees {
            return false
        }

        // The new run's start must sit near either end of the other route,
        // so reversed traversals of the same route stay candidates.
        let toStart = GeoDistance.distanceMeters(
            fromLat: a.startLatitude,
            lon: a.startLongitude,
            toLat: b.startLatitude,
            lon: b.startLongitude
        )
        let toFinish = GeoDistance.distanceMeters(
            fromLat: a.startLatitude,
            lon: a.startLongitude,
            toLat: b.finishLatitude,
            lon: b.finishLongitude
        )
        return min(toStart, toFinish) <= policy.endpointProximityMeters
    }
}

/// Stage-2 shape confirmation for one workout/representative pair.
///
/// Reuses the Route-Aware comparison machinery end to end: the compact
/// alignment samples come from `RouteAlignmentSampleBuilder`, the path from
/// the existing one-bulk-call `RunPlayRouteAlignmentDtwBridge` solve, and the
/// direction probe from the aligner. No second DTW exists here — the only
/// geometry work beyond the reuse is a scoring walk over the returned path
/// cells, mirroring how the aligner derives its diagnostics.
public struct RouteGroupingMatcher: Sendable {
    private let sampleBuilder: RouteAlignmentSampleBuilder
    private let aligner: ConstrainedDynamicTimeWarpingAligner

    public init(
        sampleBuilder: RouteAlignmentSampleBuilder = RouteAlignmentSampleBuilder(),
        aligner: ConstrainedDynamicTimeWarpingAligner = ConstrainedDynamicTimeWarpingAligner()
    ) {
        self.sampleBuilder = sampleBuilder
        self.aligner = aligner
    }

    /// Evaluates whether `workout` follows the route of `representative`.
    ///
    /// Throws `CancellationError` when `isCancelled` fires; every other
    /// condition is an ordinary outcome.
    public func match(
        workout: RunWorkout,
        workoutFacts: RouteGroupingRouteFacts,
        representative: RunWorkout,
        representativeFacts: RouteGroupingRouteFacts,
        policy: RouteGroupingPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteGroupingMatchOutcome {
        guard RouteGroupCandidateFilter.isCandidate(workoutFacts, representativeFacts, policy: policy) else {
            return .unmatched(.filteredOut)
        }

        let pair: RouteAlignmentSamplePair
        do {
            pair = try sampleBuilder.build(
                primary: representative,
                comparison: workout,
                policy: policy.alignment,
                isCancelled: isCancelled
            )
        } catch RouteAlignmentSampleError.cancelled {
            throw CancellationError()
        } catch RouteAlignmentSampleError.insufficientRouteData {
            return .unmatched(.insufficientRouteData)
        } catch RouteAlignmentSampleError.unsupportedGeographicExtent {
            return .unmatched(.unsupportedGeographicExtent)
        } catch RouteAlignmentSampleError.resourceLimit {
            return .unmatched(.resourceLimit)
        }

        if isCancelled() {
            throw CancellationError()
        }

        let direction = aligner.detectDirection(
            primary: pair.primary,
            comparison: pair.comparison,
            policy: policy.alignment,
            isCancelled: isCancelled
        )

        if direction == .opposite, !policy.matchesOppositeDirection {
            return .unmatched(.oppositeDirectionExcluded)
        }

        // Forward orientation first. When the probe cannot commit (or, for
        // reversed-agnostic safety, when the probe said opposite), also try
        // the reversed orientation and keep the better outcome.
        let forward = try score(
            pair: pair,
            comparisonReversed: false,
            policy: policy,
            isCancelled: isCancelled
        )
        if forward.matches {
            return forward
        }

        guard policy.matchesOppositeDirection, direction != .same else {
            return forward
        }

        let reversed = try score(
            pair: pair,
            comparisonReversed: true,
            policy: policy,
            isCancelled: isCancelled
        )
        return reversed.similarityScore > forward.similarityScore ? reversed : forward
    }

    /// Direction probe for member marking in the Routes detail list: whether
    /// `member` traverses `representative`'s route in the opposite direction.
    ///
    /// Uses the same coarse ordered-sequence probe as matching (no native
    /// call, no DTW solve), so a reversed closed loop — whose start and
    /// finish coincide — is still detected. The endpoint heuristic is
    /// deliberately not used: it cannot distinguish direction on a loop.
    public static func memberRunsOppositeDirection(
        member: RunWorkout,
        representative: RunWorkout,
        policy: RouteGroupingPolicy = .default
    ) -> Bool {
        guard let pair = try? RouteAlignmentSampleBuilder().build(
            primary: representative,
            comparison: member,
            policy: policy.alignment,
            isCancelled: { false }
        ) else {
            return false
        }
        return ConstrainedDynamicTimeWarpingAligner().detectDirection(
            primary: pair.primary,
            comparison: pair.comparison,
            policy: policy.alignment,
            isCancelled: { false }
        ) == .opposite
    }

    // MARK: - Solve + score

    private func score(
        pair: RouteAlignmentSamplePair,
        comparisonReversed: Bool,
        policy: RouteGroupingPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteGroupingMatchOutcome {
        let comparison = comparisonReversed
            ? RouteGroupingMatcher.reversedSamples(
                pair.comparison,
                totalDistanceMeters: pair.comparisonRouteDistanceMeters
            )
            : pair.comparison

        let solved: RunPlayRouteAlignmentDtwResult
        do {
            solved = try RunPlayRouteAlignmentDtwBridge.solve(
                primary: pair.primary,
                comparison: comparison,
                primaryRouteDistanceMeters: pair.primaryRouteDistanceMeters,
                comparisonRouteDistanceMeters: pair.comparisonRouteDistanceMeters,
                effectiveSampleIntervalMeters: pair.effectiveSampleIntervalMeters,
                policy: policy.alignment,
                isCancelled: isCancelled
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Contract violations surface as ordinary non-matches; grouping
            // never escalates a pair failure to a pass failure.
            return .unmatched(.noPath)
        }

        let path: [RunPlayRouteAlignmentDtwPathCell]
        switch solved {
        case .success(let matched, _, _, _):
            path = matched
        case .resourceLimit:
            return .unmatched(.resourceLimit)
        case .noPath:
            return .unmatched(.noPath)
        }

        return RouteGroupingMatcher.scorePath(
            path: path,
            primary: pair.primary,
            comparison: comparison,
            primaryRouteDistanceMeters: pair.primaryRouteDistanceMeters,
            comparisonRouteDistanceMeters: pair.comparisonRouteDistanceMeters,
            comparisonReversed: comparisonReversed,
            policy: policy
        )
    }

    /// Reverses one comparison sample sequence for opposite-direction
    /// matching. Distances, progress, elapsed time, and headings are mirrored
    /// so the walked path still advances monotonically and headings stay
    /// geometrically truthful for the reversed traversal.
    static func reversedSamples(
        _ samples: [RouteAlignmentSample],
        totalDistanceMeters: Double
    ) -> [RouteAlignmentSample] {
        let totalElapsed = samples.last?.elapsedSeconds
        return samples.reversed().map { sample in
            let flippedHeading: Double?
            if let heading = sample.headingRadians {
                flippedHeading = heading > 0 ? heading - .pi : heading + .pi
            } else {
                flippedHeading = nil
            }
            let mirroredElapsed: Double?
            if let elapsed = sample.elapsedSeconds, let total = totalElapsed {
                mirroredElapsed = max(0, total - elapsed)
            } else {
                mirroredElapsed = nil
            }
            return RouteAlignmentSample(
                xMeters: sample.xMeters,
                zMeters: sample.zMeters,
                distanceFromStartMeters: totalDistanceMeters - sample.distanceFromStartMeters,
                routeSegmentIndex: sample.routeSegmentIndex,
                elapsedSeconds: mirroredElapsed,
                headingRadians: flippedHeading,
                normalizedProgress: 1 - sample.normalizedProgress
            )
        }
    }

    /// Scores one solved path: accumulates matched distance per side (the
    /// aligner's block-construction recipe), collects advance-weighted
    /// separations over diagonal steps, and applies the grouping thresholds
    /// against coverage of the shorter route only.
    static func scorePath(
        path: [RunPlayRouteAlignmentDtwPathCell],
        primary: [RouteAlignmentSample],
        comparison: [RouteAlignmentSample],
        primaryRouteDistanceMeters: Double,
        comparisonRouteDistanceMeters: Double,
        comparisonReversed: Bool,
        policy: RouteGroupingPolicy
    ) -> RouteGroupingMatchOutcome {
        guard let first = path.first else {
            return .unmatched(.noPath)
        }

        var lastPrimaryDistance = primary[first.primaryIndex].distanceFromStartMeters
        var lastComparisonDistance = comparison[first.comparisonIndex].distanceFromStartMeters
        var primaryMatched = 0.0
        var comparisonMatched = 0.0
        var weighted: [DistanceWeightedStatistics.WeightedSample] = []

        for cell in path.dropFirst() {
            let primarySample = primary[cell.primaryIndex]
            let comparisonSample = comparison[cell.comparisonIndex]
            let primaryDelta = max(0, primarySample.distanceFromStartMeters - lastPrimaryDistance)
            let comparisonDelta = max(0, comparisonSample.distanceFromStartMeters - lastComparisonDistance)
            primaryMatched += primaryDelta
            comparisonMatched += comparisonDelta

            if cell.step == .diagonal {
                let advance = max(primaryDelta, comparisonDelta)
                if advance > 0 {
                    let dx = primarySample.xMeters - comparisonSample.xMeters
                    let dz = primarySample.zMeters - comparisonSample.zMeters
                    let separation = (dx * dx + dz * dz).squareRoot()
                    if separation.isFinite {
                        weighted.append(.init(value: separation, weight: advance))
                    }
                }
            }

            lastPrimaryDistance = primarySample.distanceFromStartMeters
            lastComparisonDistance = comparisonSample.distanceFromStartMeters
        }

        guard primaryRouteDistanceMeters > 0, comparisonRouteDistanceMeters > 0 else {
            return .unmatched(.belowThresholds)
        }
        let primaryCoverage = min(1, primaryMatched / primaryRouteDistanceMeters)
        let comparisonCoverage = min(1, comparisonMatched / comparisonRouteDistanceMeters)
        // The superset rule: only coverage of the shorter route is evaluated,
        // so a loop plus an extra spur groups with the loop while the spur
        // stays unmatched on the longer side.
        let shorterRouteCoverage = min(primaryCoverage, comparisonCoverage)

        guard !weighted.isEmpty else {
            return .unmatched(.belowThresholds)
        }
        let median = DistanceWeightedStatistics.weightedMedian(weighted) ?? .infinity
        let p90 = DistanceWeightedStatistics.weightedQuantile(weighted, quantile: 0.9) ?? .infinity

        let medianQuality = max(0, 1 - median / max(1, policy.maximumMedianSeparationMeters))
        let p90Quality = max(0, 1 - p90 / max(1, policy.maximumP90SeparationMeters))
        let score = max(0, min(1, shorterRouteCoverage * (medianQuality + p90Quality) / 2))

        let thresholdsPass =
            shorterRouteCoverage >= policy.minimumShorterRouteCoverageFraction
            && median <= policy.maximumMedianSeparationMeters
            && p90 <= policy.maximumP90SeparationMeters

        guard thresholdsPass else {
            return RouteGroupingMatchOutcome(
                matches: false,
                coverageOfShorterRoute: shorterRouteCoverage,
                medianSeparationMeters: median,
                p90SeparationMeters: p90,
                isReversed: comparisonReversed,
                similarityScore: score,
                noMatchReason: .belowThresholds
            )
        }

        return RouteGroupingMatchOutcome(
            matches: true,
            coverageOfShorterRoute: shorterRouteCoverage,
            medianSeparationMeters: median,
            p90SeparationMeters: p90,
            isReversed: comparisonReversed,
            similarityScore: score,
            noMatchReason: nil
        )
    }
}
