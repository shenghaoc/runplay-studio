import Foundation

/// Immutable shared inputs for all derived workout analysis.
public struct WorkoutAnalysisContext: Sendable {
    public let timeline: WorkoutTimeline
    public let elevationProfile: ElevationProfile

    public init(
        workout: RunWorkout,
        policy: RouteQualityPolicy = .runningDefault
    ) {
        let profile = ElevationProfile(routePoints: workout.routePoints, policy: policy)
        self.init(routePoints: workout.routePoints, elevationProfile: profile)
    }

    public init(routePoints: [RoutePoint], elevationProfile: ElevationProfile) {
        self.elevationProfile = elevationProfile
        self.timeline = WorkoutTimeline(
            routePoints: routePoints,
            elevationProfile: elevationProfile
        )
    }

    public init(timeline: WorkoutTimeline, elevationProfile: ElevationProfile) {
        self.timeline = timeline
        self.elevationProfile = elevationProfile
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
