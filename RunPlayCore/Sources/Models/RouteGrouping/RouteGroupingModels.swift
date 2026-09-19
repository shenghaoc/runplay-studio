import Foundation

/// Tunables for automatic route grouping.
///
/// All thresholds live here so matching, persistence, and UI never scatter
/// magic numbers. Two stages share one policy:
///
/// 1. **Stage 1 (cheap facts filter)** — bounding-box overlap and endpoint
///    proximity over `RouteGroupingRouteFacts` computed from stored route
///    points.
/// 2. **Stage 2 (shape confirmation)** — the existing constrained-DTW path
///    solver (the Route-Aware comparison boundary) over compact alignment
///    samples, scored in Swift from the returned path.
///
/// Matching requires coverage of **both** routes (mutual coverage): matched
/// distance on each side divided by that side's total distance, both taken
/// from the single existing solve. This deliberately reverses the original
/// plan's superset rule: a run that covers a route plus extra distance — a
/// spur, a warm-up, or a longer finish — is NOT the same route, and the
/// manual merge action is the recovery path.
public struct RouteGroupingPolicy: Hashable, Sendable {
    /// DTW policy variant used for grouping solves. The consecutive-warp
    /// cap is lifted relative to comparison alignment so long warp runs
    /// stay legal; match quality is decided by the grouping thresholds
    /// below, never by path existence. The unmatched budget exposed by
    /// `unmatchedBudgetMeters` is the live grouping parameter — see its
    /// documentation for the interaction with the coverage threshold.
    public var alignment: RouteAlignmentPolicy

    /// Minimum mutual coverage — matched distance ÷ total distance on BOTH
    /// routes — required to group.
    ///
    /// This is the containment guard: a 5 km prefix of a 6 km route covers
    /// at most 5/6 ≈ 0.83 of the longer route, and a loop plus a spur covers
    /// at most loop/(loop+spur) of the superset, so both fall below the
    /// threshold no matter how cleanly the shared section aligns. Coverage
    /// remains the discriminating axis — separation is dominated by GPS
    /// quality — so it is deliberately stricter than the comparison
    /// acceptance floor while separation stays at the comparison "good"
    /// band.
    public var minimumMutualCoverageFraction: Double

    /// Distance-weighted median matched separation ceiling (metres).
    public var maximumMedianSeparationMeters: Double

    /// Distance-weighted 90th-percentile matched separation ceiling (metres).
    public var maximumP90SeparationMeters: Double

    /// Minimum route distance before a workout can participate in grouping.
    public var minimumRouteDistanceMeters: Double

    /// Minimum valid route points before a workout can participate.
    public var minimumRoutePointCount: Int

    /// Total-distance ratio bounds are deliberately absent: mutual coverage
    /// subsumes the ratio as a correctness rule (mutual ≥ threshold forces
    /// shorter/longer ≥ threshold − sampling slack), and the measured
    /// solve-count difference with and without the historical bound on the
    /// 2,000-workout benchmark library was 1,760 vs 1,761 solves — the
    /// bounding-box and endpoint tests do the filtering. Removing it is the
    /// measured decision, recorded here so the idea is not re-added on
    /// intuition; see the containment section of docs/architecture.md.

    /// Unmatched prefix/suffix budget for grouping solves, in metres. This
    /// is the live grouping parameter behind
    /// `alignment.maximumUnmatchedPrefixSuffixMeters`: it bounds how much of
    /// either route the solve may leave unmatched, which is exactly what
    /// mutual coverage measures.
    ///
    /// Interaction — read before choosing a pair with the coverage
    /// threshold: the engine truncates within the budget for free, so a
    /// route's own coverage cannot exceed 1 − budget/route-length
    /// (whenever the fraction cap does not bite first). At a 500 m budget a
    /// 3 km route tops out near 0.83, which a fixed 0.85 threshold would
    /// reject even against itself. The chosen pair keeps identical short
    /// routes above the threshold with margin; the measured grid is in
    /// `RouteGroupingMeasurementTests`.
    public var unmatchedBudgetMeters: Double {
        get { alignment.maximumUnmatchedPrefixSuffixMeters }
        set { alignment.maximumUnmatchedPrefixSuffixMeters = newValue }
    }

    /// Margin added to each bounding box before the overlap test (metres).
    public var boundingBoxOverlapMarginMeters: Double

    /// Maximum distance from the new run's start to either end of the other
    /// route for a candidate pair (metres). Comparing against both ends
    /// admits reversed-direction runs of the same route.
    public var endpointProximityMeters: Double

    /// Whether runs recorded in the opposite direction may group. On by
    /// default — a reversed loop is the same route — with no user toggle.
    public var matchesOppositeDirection: Bool

    /// Grouping algorithm version. Bump when matching behaviour changes;
    /// stored on assignment records so a later pass can re-evaluate work
    /// produced by an older algorithm.
    public var algorithmVersion: Int

    public init(
        alignment: RouteAlignmentPolicy = RouteGroupingPolicy.groupingAlignment,
        minimumMutualCoverageFraction: Double = 0.9,
        maximumMedianSeparationMeters: Double = 35,
        maximumP90SeparationMeters: Double = 100,
        minimumRouteDistanceMeters: Double = 500,
        minimumRoutePointCount: Int = 20,
        boundingBoxOverlapMarginMeters: Double = 150,
        endpointProximityMeters: Double = 300,
        matchesOppositeDirection: Bool = true,
        algorithmVersion: Int = 1
    ) {
        self.alignment = alignment
        self.minimumMutualCoverageFraction = minimumMutualCoverageFraction
        self.maximumMedianSeparationMeters = maximumMedianSeparationMeters
        self.maximumP90SeparationMeters = maximumP90SeparationMeters
        self.minimumRouteDistanceMeters = minimumRouteDistanceMeters
        self.minimumRoutePointCount = minimumRoutePointCount
        self.boundingBoxOverlapMarginMeters = boundingBoxOverlapMarginMeters
        self.endpointProximityMeters = endpointProximityMeters
        self.matchesOppositeDirection = matchesOppositeDirection
        self.algorithmVersion = algorithmVersion
    }

    /// Product defaults for route grouping.
    ///
    /// The (budget, coverage) pair is measured, not guessed — the grid in
    /// `RouteGroupingMeasurementTests` chose **100 m / 0.90**: at that
    /// budget the identical/reversed class measures 0.950–0.980 mutual
    /// coverage (the short 2 km pair is the floor at 0.950), while the
    /// clean-shared-section containment classes are pinned at their
    /// geometric ceiling 1/ratio at every budget — loop-plus-spur 0.862 and
    /// the 5-of-6 prefix 0.833. Margins: 0.038 below the line
    /// (loop-plus-spur, the closest reject fixture) and 0.050 above
    /// (identical-short, the closest accept fixture). The 5-of-10 prefix
    /// solves with separation blown out (p90 ≈ 4.5 km) and coverage 0.500;
    /// 40 %-shared loops are rejected by separation (median 400–520 m) at
    /// every budget. The chosen values and their evidence live one file
    /// apart so neither drifts silently.
    public static let `default` = RouteGroupingPolicy()

    /// DTW policy variant for grouping solves: same solver and cost model
    /// as Route-Aware comparison, with the consecutive-warp cap lifted so
    /// long warp runs stay legal, and the unmatched prefix/suffix budget
    /// set to the measured grouping parameter (`unmatchedBudgetMeters`,
    /// 100 m). The 4,000,000 band-cell ceiling is preserved.
    public static let groupingAlignment = RouteAlignmentPolicy(
        maximumUnmatchedPrefixSuffixMeters: 100,
        maximumConsecutiveWarpSteps: 4_000
    )
}

/// Cheap geometric facts used by the stage-1 candidate filter, computed in
/// one pass over stored route points. Persisted inside
/// `WorkoutRouteGroupSummary`, so it is `Codable` even though stage 1 always
/// recomputes facts for the workout being matched.
public struct RouteGroupingRouteFacts: Codable, Hashable, Sendable {
    public var minLatitude: Double
    public var maxLatitude: Double
    public var minLongitude: Double
    public var maxLongitude: Double
    public var startLatitude: Double
    public var startLongitude: Double
    public var finishLatitude: Double
    public var finishLongitude: Double
    public var totalDistanceMeters: Double
    public var routePointCount: Int
    public var discardedCoordinatePointCount: Int

    public init(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double,
        startLatitude: Double,
        startLongitude: Double,
        finishLatitude: Double,
        finishLongitude: Double,
        totalDistanceMeters: Double,
        routePointCount: Int,
        discardedCoordinatePointCount: Int
    ) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.finishLatitude = finishLatitude
        self.finishLongitude = finishLongitude
        self.totalDistanceMeters = totalDistanceMeters
        self.routePointCount = routePointCount
        self.discardedCoordinatePointCount = discardedCoordinatePointCount
    }

    /// Facts for one stored workout. Scans valid coordinates in source order;
    /// invalid coordinates contribute to neither bounds nor endpoints.
    public init(workout: RunWorkout) {
        var minLat = Double.infinity
        var maxLat = -Double.infinity
        var minLon = Double.infinity
        var maxLon = -Double.infinity
        var startLat = 0.0
        var startLon = 0.0
        var finishLat = 0.0
        var finishLon = 0.0
        var count = 0

        for point in workout.routePoints {
            guard GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude) else {
                continue
            }
            if count == 0 {
                startLat = point.latitude
                startLon = point.longitude
                minLat = point.latitude
                maxLat = point.latitude
                minLon = point.longitude
                maxLon = point.longitude
            } else {
                minLat = min(minLat, point.latitude)
                maxLat = max(maxLat, point.latitude)
                minLon = min(minLon, point.longitude)
                maxLon = max(maxLon, point.longitude)
            }
            finishLat = point.latitude
            finishLon = point.longitude
            count += 1
        }

        if count == 0 {
            minLat = 0
            maxLat = 0
            minLon = 0
            maxLon = 0
        }

        self.init(
            minLatitude: minLat,
            maxLatitude: maxLat,
            minLongitude: minLon,
            maxLongitude: maxLon,
            startLatitude: startLat,
            startLongitude: startLon,
            finishLatitude: finishLat,
            finishLongitude: finishLon,
            totalDistanceMeters: workout.summary.totalDistanceMeters,
            routePointCount: count,
            discardedCoordinatePointCount: workout.qualityDiagnostics.discardedCoordinatePointCount
        )
    }

    /// Whether a route with these facts can participate in grouping at all.
    public func canParticipate(policy: RouteGroupingPolicy) -> Bool {
        totalDistanceMeters.isFinite
            && totalDistanceMeters >= policy.minimumRouteDistanceMeters
            && routePointCount >= policy.minimumRoutePointCount
    }

    /// Representative-quality ranking: cleanest GPS first (fewest discarded
    /// coordinate points), then densest sampling — the representative is what
    /// gets drawn on the map. Earlier canonical start date and a stable UUID
    /// keep the order total.
    public func ranksAbove(_ other: RouteGroupingRouteFacts, earlierDate: Date?, otherEarlierDate: Date?) -> Bool {
        if discardedCoordinatePointCount != other.discardedCoordinatePointCount {
            return discardedCoordinatePointCount < other.discardedCoordinatePointCount
        }
        if routePointCount != other.routePointCount {
            return routePointCount > other.routePointCount
        }
        if let earlierDate, let otherEarlierDate, earlierDate != otherEarlierDate {
            return earlierDate < otherEarlierDate
        }
        return false
    }
}

/// Cached identity + facts of a group's effective representative, persisted
/// with the group and refreshed whenever membership changes. Incremental
/// assignment matches against these summaries so a new import never loads or
/// scans the whole library; drift is repaired by a full re-cluster.
public struct WorkoutRouteGroupSummary: Codable, Hashable, Sendable {
    /// The effective (derived, unless pinned) representative workout.
    public var workoutID: UUID
    /// Canonical start date used as the representative tiebreak.
    public var startDate: Date?
    public var facts: RouteGroupingRouteFacts

    public init(workoutID: UUID, startDate: Date?, facts: RouteGroupingRouteFacts) {
        self.workoutID = workoutID
        self.startDate = startDate
        self.facts = facts
    }

    public func ranksAbove(_ other: WorkoutRouteGroupSummary) -> Bool {
        facts.ranksAbove(other.facts, earlierDate: startDate, otherEarlierDate: other.startDate)
    }
}

/// One automatic route group persisted in the library manifest (schema v4).
///
/// Membership is derived from `WorkoutRouteGroupAssignment` records — the
/// assignments are the single source of truth, so a group never stores a
/// member list that can drift.
public struct WorkoutRouteGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID

    /// User-assigned name. `nil` means the UI derives a descriptive default
    /// from the representative's own geometry (for example "5.2 km Loop").
    public var name: String?

    /// User-pinned representative. When set (and still a member) it overrides
    /// the derived representative. A full re-cluster clears stale pins but
    /// preserves one whose workout still clusters into the same group.
    public var pinnedRepresentativeWorkoutID: UUID?

    /// Cached effective representative identity + stage-1 facts. `nil` only
    /// for a group whose representative snapshot could not be loaded; the
    /// next membership change or re-cluster repairs it.
    public var representativeSummary: WorkoutRouteGroupSummary?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        pinnedRepresentativeWorkoutID: UUID? = nil,
        representativeSummary: WorkoutRouteGroupSummary? = nil
    ) {
        self.id = id
        self.name = name
        self.pinnedRepresentativeWorkoutID = pinnedRepresentativeWorkoutID
        self.representativeSummary = representativeSummary
    }

    /// Descriptive default name derived from the representative's own
    /// geometry — no geocoding, no network. Examples: "5.2 km Loop",
    /// "10.1 km Route". Used whenever the user has not renamed the group.
    public static func defaultDisplayName(
        distanceMeters: Double,
        closesLoop: Bool
    ) -> String {
        let kilometres = max(0, distanceMeters) / 1_000
        // `String(localized:defaultValue:)` takes literal-only
        // String.LocalizationValue arguments, so the platform split happens
        // here rather than in a helper: Swift Foundation on Linux does not
        // expose the initializer at all (same limitation the
        // `routeMetricLocalized` adapter handles), and the English default
        // is the Linux fallback.
        #if canImport(Darwin)
        let shape = closesLoop
            ? String(localized: "route_group.shape.loop", defaultValue: "Loop")
            : String(localized: "route_group.shape.route", defaultValue: "Route")
        let format = String(localized: "route_group.default_name", defaultValue: "%.1f km %@")
        #else
        let shape = closesLoop ? "Loop" : "Route"
        let format = "%.1f km %@"
        #endif
        return String(format: format, kilometres, shape)
    }
}

/// One workout's route-group assignment record persisted in the manifest.
///
/// The record's *absence* is the nil marker — the assignment has not run for
/// that workout and a later pass picks it up (the records-backfill
/// idempotence argument). A present record with a `nil` group ID means the
/// workout was evaluated and deliberately belongs to no group: it is below
/// the participation minimums or the user removed it from its route.
public struct WorkoutRouteGroupAssignment: Codable, Hashable, Sendable {
    public let workoutID: UUID

    /// The group this workout belongs to, or `nil` when evaluated and
    /// deliberately ungrouped.
    public let groupID: UUID?

    /// Algorithm version that produced this record. A pass recomputes records
    /// carrying an older version.
    public let algorithmVersion: Int

    public init(workoutID: UUID, groupID: UUID?, algorithmVersion: Int) {
        self.workoutID = workoutID
        self.groupID = groupID
        self.algorithmVersion = algorithmVersion
    }
}

/// Outcome of one stage-2 pair evaluation.
public struct RouteGroupingMatchOutcome: Hashable, Sendable {
    public enum NoMatchReason: Hashable, Sendable {
        case filteredOut
        case insufficientRouteData
        case unsupportedGeographicExtent
        case resourceLimit
        case noPath
        case oppositeDirectionExcluded
        case belowThresholds
    }

    /// Whether the pair groups.
    public let matches: Bool
    /// Matched distance ÷ total distance on the primary (representative)
    /// side, counting only simultaneously matched (diagonal) path steps.
    public let primaryCoverage: Double
    /// Matched distance ÷ total distance on the comparison (workout) side,
    /// counting only simultaneously matched (diagonal) path steps.
    public let comparisonCoverage: Double
    /// The smaller of `primaryCoverage` and `comparisonCoverage` — the
    /// mutual coverage the threshold evaluates.
    public let mutualCoverage: Double
    /// Distance-weighted median matched separation (metres).
    public let medianSeparationMeters: Double
    /// Distance-weighted 90th-percentile matched separation (metres).
    public let p90SeparationMeters: Double
    /// Whether the run traverses the representative's route in the opposite
    /// direction (detected, not user-set).
    public let isReversed: Bool
    /// Unmatched prefix + suffix distance on the longer of the two routes,
    /// taken from the solved path's first and last matched indices.
    /// Reported as a diagnostic only: the endpoint truncation is free
    /// within the unmatched budget, so this figure reads the budget, not
    /// the route class (measured; see the containment section of
    /// docs/architecture.md). `.infinity` when no path was solved.
    public let unmatchedLongerRouteMeters: Double
    /// `unmatchedLongerRouteMeters` as a fraction of the longer route's
    /// total distance.
    public let unmatchedLongerRouteFraction: Double
    /// Normalized similarity score in 0...1 for ranking candidate groups.
    /// Coverage scaled by how far separation sits under its ceilings; the
    /// grouping decision itself uses the explicit thresholds, never this
    /// score.
    public let similarityScore: Double
    public let noMatchReason: NoMatchReason?

    static func unmatched(_ reason: NoMatchReason) -> RouteGroupingMatchOutcome {
        RouteGroupingMatchOutcome(
            matches: false,
            primaryCoverage: 0,
            comparisonCoverage: 0,
            mutualCoverage: 0,
            medianSeparationMeters: .infinity,
            p90SeparationMeters: .infinity,
            isReversed: false,
            unmatchedLongerRouteMeters: .infinity,
            unmatchedLongerRouteFraction: .infinity,
            similarityScore: 0,
            noMatchReason: reason
        )
    }
}

/// Per-item progress for one grouping pass. Belongs to the feature's own
/// published state, never to library-wide invalidation tokens.
public struct RouteGroupingPassProgress: Hashable, Sendable {
    public let completedCount: Int
    public let totalCount: Int
    public let currentWorkoutName: String

    public init(completedCount: Int, totalCount: Int, currentWorkoutName: String) {
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.currentWorkoutName = currentWorkoutName
    }
}
