import Foundation

/// Tunables for automatic route grouping.
///
/// All thresholds live here so matching, persistence, and UI never scatter
/// magic numbers. Two stages share one policy:
///
/// 1. **Stage 1 (cheap facts filter)** — bounding-box overlap, endpoint
///    proximity, and total-distance ratio over `RouteGroupingRouteFacts`
///    computed from stored route points.
/// 2. **Stage 2 (shape confirmation)** — the existing constrained-DTW path
///    solver (the Route-Aware comparison boundary) over compact alignment
///    samples, scored in Swift from the returned path.
///
/// The distance-ratio bound is the subset guard: because grouping evaluates
/// only coverage *of the shorter route*, a short route wholly contained in a
/// much longer one would otherwise score perfectly. A ratio outside
/// `distanceRatioBounds` is rejected before any solve.
public struct RouteGroupingPolicy: Hashable, Sendable {
    /// DTW policy variant used for grouping solves. Unlike comparison
    /// alignment, grouping must admit loop-plus-spur supersets: the
    /// consecutive-warp cap is lifted so a strict superset can still produce
    /// a path that traverses the extra distance. Match quality is then
    /// decided by the grouping thresholds below, never by path existence.
    public var alignment: RouteAlignmentPolicy

    /// Minimum coverage of the shorter route required to group.
    ///
    /// Coverage is the discriminating axis — separation is dominated by GPS
    /// quality — so it is deliberately stricter than the comparison
    /// acceptance floor while separation stays at the comparison "good" band.
    public var minimumShorterRouteCoverageFraction: Double

    /// Distance-weighted median matched separation ceiling (metres).
    public var maximumMedianSeparationMeters: Double

    /// Distance-weighted 90th-percentile matched separation ceiling (metres).
    public var maximumP90SeparationMeters: Double

    /// Minimum route distance before a workout can participate in grouping.
    public var minimumRouteDistanceMeters: Double

    /// Minimum valid route points before a workout can participate.
    public var minimumRoutePointCount: Int

    /// Total-distance ratio bounds (shorter / longer) for a candidate pair.
    /// Roughly [0.8, 1.25]: admits a loop plus a spur, excludes a strict
    /// subset of a substantially longer route.
    public var distanceRatioBounds: ClosedRange<Double>

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
        minimumShorterRouteCoverageFraction: Double = 0.85,
        maximumMedianSeparationMeters: Double = 35,
        maximumP90SeparationMeters: Double = 100,
        minimumRouteDistanceMeters: Double = 500,
        minimumRoutePointCount: Int = 20,
        distanceRatioBounds: ClosedRange<Double> = 0.8...1.25,
        boundingBoxOverlapMarginMeters: Double = 150,
        endpointProximityMeters: Double = 300,
        matchesOppositeDirection: Bool = true,
        algorithmVersion: Int = 1
    ) {
        self.alignment = alignment
        self.minimumShorterRouteCoverageFraction = minimumShorterRouteCoverageFraction
        self.maximumMedianSeparationMeters = maximumMedianSeparationMeters
        self.maximumP90SeparationMeters = maximumP90SeparationMeters
        self.minimumRouteDistanceMeters = minimumRouteDistanceMeters
        self.minimumRoutePointCount = minimumRoutePointCount
        self.distanceRatioBounds = distanceRatioBounds
        self.boundingBoxOverlapMarginMeters = boundingBoxOverlapMarginMeters
        self.endpointProximityMeters = endpointProximityMeters
        self.matchesOppositeDirection = matchesOppositeDirection
        self.algorithmVersion = algorithmVersion
    }

    /// Product defaults for route grouping.
    public static let `default` = RouteGroupingPolicy()

    /// DTW policy variant for grouping solves: same solver, cost model, and
    /// unmatched prefix/suffix budget as Route-Aware comparison, with only
    /// the consecutive-warp cap lifted so a loop-plus-spur superset can be
    /// traversed (the spur is consumed by warp steps, not left unmatched, so
    /// the standard budget still applies). Widening the unmatched budget
    /// instead would let a zero-cost identical-route path stop early and
    /// under-report coverage. The 4,000,000 band-cell ceiling is preserved.
    public static let groupingAlignment = RouteAlignmentPolicy(
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
        let shape = closesLoop
            ? String(localized: "route_group.shape.loop", defaultValue: "Loop")
            : String(localized: "route_group.shape.route", defaultValue: "Route")
        return String(
            format: String(localized: "route_group.default_name", defaultValue: "%.1f km %@"),
            kilometres,
            shape
        )
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
    /// Coverage of the shorter route (matched distance / shorter total).
    public let coverageOfShorterRoute: Double
    /// Distance-weighted median matched separation (metres).
    public let medianSeparationMeters: Double
    /// Distance-weighted 90th-percentile matched separation (metres).
    public let p90SeparationMeters: Double
    /// Whether the run traverses the representative's route in the opposite
    /// direction (detected, not user-set).
    public let isReversed: Bool
    /// Normalized similarity score in 0...1 for ranking candidate groups.
    /// Coverage scaled by how far separation sits under its ceilings; the
    /// grouping decision itself uses the explicit thresholds, never this
    /// score.
    public let similarityScore: Double
    public let noMatchReason: NoMatchReason?

    static func unmatched(_ reason: NoMatchReason) -> RouteGroupingMatchOutcome {
        RouteGroupingMatchOutcome(
            matches: false,
            coverageOfShorterRoute: 0,
            medianSeparationMeters: .infinity,
            p90SeparationMeters: .infinity,
            isReversed: false,
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
