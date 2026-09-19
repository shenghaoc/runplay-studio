import Foundation

/// Stage-1 candidate filter: cheap geometric admission over route facts.
///
/// Pure arithmetic on `RouteGroupingRouteFacts` — no route-point scans, no
/// native calls. A pair must pass bounding-box overlap with margin and
/// start-to-either-endpoint proximity (which admits reversed-direction
/// runs). A historical distance-ratio bound was removed after measurement:
/// mutual coverage subsumes it for correctness and it saved 1 solve in
/// 1,760 on the benchmark library (see `RouteGroupingPolicy`).
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

    /// Scores one solved path: accumulates **diagonally matched** distance
    /// per side, collects advance-weighted separations over the same
    /// diagonal steps, and applies the grouping thresholds against mutual
    /// coverage — the smaller of the two per-side coverages.
    ///
    /// Only diagonal (simultaneously matched) advances count toward a
    /// side's matched distance. Warp-only steps advance one side past the
    /// other, which is exactly the geometry mutual coverage must price: a
    /// spur, warm-up, or longer finish traverses alone, so its distance
    /// never enters that side's numerator. Both sides are read from the
    /// single existing solve — no second solve, no engine change, no new
    /// bridge call.
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

            if cell.step == .diagonal {
                // Diagonal advance: both sides move together, so both
                // numerators grow. Separation statistics weigh by the same
                // advance so GPS-dominated axes keep their distance
                // weighting.
                primaryMatched += primaryDelta
                comparisonMatched += comparisonDelta
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

        // Unmatched prefix + suffix on the longer route, read straight off
        // the solved path's first and last matched indices. No engine call:
        // the path already carries this. Reported as a diagnostic only —
        // measured (RouteGroupingMeasurementTests), the open-suffix endpoint
        // truncates every low-cost path at the unmatched budget regardless
        // of whether the pair is a genuine repeat or a containment, so this
        // figure reads the budget, not the route class. Mutual coverage —
        // which prices warp-only travel — is the operative discriminator.
        // See the containment section of docs/architecture.md.
        let longerIsPrimary = primaryRouteDistanceMeters >= comparisonRouteDistanceMeters
        let longerTotal = longerIsPrimary
            ? primaryRouteDistanceMeters
            : comparisonRouteDistanceMeters
        let longerPrefix = longerIsPrimary
            ? primary[first.primaryIndex].distanceFromStartMeters
            : comparison[first.comparisonIndex].distanceFromStartMeters
        let longerSuffixStart = longerIsPrimary
            ? primary[path[path.count - 1].primaryIndex].distanceFromStartMeters
            : comparison[path[path.count - 1].comparisonIndex].distanceFromStartMeters
        let unmatchedLongerMeters = max(0, longerPrefix) + max(0, longerTotal - longerSuffixStart)
        let unmatchedLongerFraction = longerTotal > 0 ? unmatchedLongerMeters / longerTotal : 0
        let primaryCoverage = min(1, primaryMatched / primaryRouteDistanceMeters)
        let comparisonCoverage = min(1, comparisonMatched / comparisonRouteDistanceMeters)
        // Mutual coverage: the match rule evaluates the smaller of the two
        // per-side coverages, so a route wholly containing another — spur,
        // warm-up, or longer finish — cannot group however cleanly the
        // shared section aligns. This deliberately reverses the original
        // plan's superset rule; the manual merge action is the recovery
        // path for genuine containment pairs.
        let mutualCoverage = min(primaryCoverage, comparisonCoverage)

        guard !weighted.isEmpty else {
            return .unmatched(.belowThresholds)
        }
        let median = DistanceWeightedStatistics.weightedMedian(weighted) ?? .infinity
        let p90 = DistanceWeightedStatistics.weightedQuantile(weighted, quantile: 0.9) ?? .infinity

        let medianQuality = max(0, 1 - median / max(1, policy.maximumMedianSeparationMeters))
        let p90Quality = max(0, 1 - p90 / max(1, policy.maximumP90SeparationMeters))
        let score = max(0, min(1, mutualCoverage * (medianQuality + p90Quality) / 2))

        let thresholdsPass =
            mutualCoverage >= policy.minimumMutualCoverageFraction
            && median <= policy.maximumMedianSeparationMeters
            && p90 <= policy.maximumP90SeparationMeters

        return RouteGroupingMatchOutcome(
            matches: thresholdsPass,
            primaryCoverage: primaryCoverage,
            comparisonCoverage: comparisonCoverage,
            mutualCoverage: mutualCoverage,
            medianSeparationMeters: median,
            p90SeparationMeters: p90,
            isReversed: comparisonReversed,
            unmatchedLongerRouteMeters: unmatchedLongerMeters,
            unmatchedLongerRouteFraction: unmatchedLongerFraction,
            similarityScore: score,
            noMatchReason: thresholdsPass ? nil : .belowThresholds
        )
    }
}
