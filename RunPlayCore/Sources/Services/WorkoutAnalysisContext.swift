import Foundation

/// Immutable shared inputs for all derived workout analysis.
public struct WorkoutAnalysisContext: Sendable {
    public let timeline: WorkoutTimeline
    public let elevationProfile: ElevationProfile
    public let movementProfile: MovementProfile?

    public init(
        workout: RunWorkout,
        policy: RouteQualityPolicy = .runningDefault
    ) {
        let profile = ElevationProfile(routePoints: workout.routePoints, policy: policy)
        let timeline = WorkoutTimeline(
            routePoints: workout.routePoints,
            elevationProfile: profile
        )
        let movementProfile = try? MovementProfile(
            routePoints: workout.routePoints,
            timeline: timeline
        )
        self.timeline = timeline
        self.elevationProfile = profile
        self.movementProfile = movementProfile
    }

    public init(routePoints: [RoutePoint], elevationProfile: ElevationProfile) {
        self.init(routePoints: routePoints, elevationProfile: elevationProfile, movementProfile: nil)
    }

    public init(routePoints: [RoutePoint], elevationProfile: ElevationProfile, movementProfile: MovementProfile?) {
        self.elevationProfile = elevationProfile
        self.movementProfile = movementProfile
        self.timeline = WorkoutTimeline(
            routePoints: routePoints,
            elevationProfile: elevationProfile
        )
    }

    public init(timeline: WorkoutTimeline, elevationProfile: ElevationProfile) {
        self.timeline = timeline
        self.elevationProfile = elevationProfile
        self.movementProfile = nil
    }

    /// Assemble a context from already-built components without re-deriving them.
    ///
    /// Used by the production-equivalent profiling path so measured elevation /
    /// timeline / movement phases are not silently repeated when forming the
    /// context value. Ordinary production call sites continue to use the
    /// deriving initializers above.
    init(
        prebuiltTimeline timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        movementProfile: MovementProfile?
    ) {
        self.timeline = timeline
        self.elevationProfile = elevationProfile
        self.movementProfile = movementProfile
    }
}

/// Fixed defensive work bounds for distance-stepped derived consumers. These
/// are safety ceilings, not route-quality decisions or user-visible tuning.
enum RouteAnalysisBudget {
    static let absoluteMaximumEvaluations = 100_000
    static let minimumEvaluations = 1_000
    static let evaluationsPerRoutePoint = 8

    static func maximumEvaluations(forRoutePointCount count: Int) -> Int {
        let scaled: Int
        if count > Int.max / evaluationsPerRoutePoint {
            scaled = absoluteMaximumEvaluations
        } else {
            scaled = count * evaluationsPerRoutePoint
        }
        return min(absoluteMaximumEvaluations, max(minimumEvaluations, scaled))
    }

    static func boundedStep(
        preferredStep: Double,
        distanceSpan: Double,
        routePointCount: Int
    ) -> Double {
        let maximum = maximumEvaluations(forRoutePointCount: routePointCount)
        let coveringStep = distanceSpan.isFinite && distanceSpan > 0
            ? distanceSpan / Double(max(1, maximum - 1))
            : 0
        return max(preferredStep, max(coveringStep, Double.leastNonzeroMagnitude))
    }
}
