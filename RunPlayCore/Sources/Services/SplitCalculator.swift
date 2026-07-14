import Foundation

/// Calculates global kilometer splits from a running workout.
public struct SplitCalculator {

    public static func calculateSplits(from workout: RunWorkout) -> [RunSplit] {
        calculateSplits(from: workout, context: WorkoutAnalysisContext(workout: workout))
    }

    /// Route-segment boundaries do not reset cumulative split distance. A pause
    /// exactly on a split boundary is excluded from both neighboring splits by
    /// the timeline's explicit range-start/range-end rule.
    public static func calculateSplits(
        from workout: RunWorkout,
        timeline: WorkoutTimeline
    ) -> [RunSplit] {
        calculateSplits(
            from: workout,
            context: WorkoutAnalysisContext(
                timeline: timeline,
                elevationProfile: ElevationProfile(routePoints: workout.routePoints)
            )
        )
    }

    public static func calculateSplits(
        from workout: RunWorkout,
        context: WorkoutAnalysisContext
    ) -> [RunSplit] {
        (try? calculateSplits(
            from: workout,
            context: context,
            policy: .runningDefault,
            isCancelled: { false }
        )) ?? []
    }

    static func calculateSplits(
        from workout: RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> [RunSplit] {
        let timeline = context.timeline
        guard workout.routePoints.count >= 2,
              timeline.totalDistanceMeters > timeline.startDistanceMeters
        else {
            return []
        }

        let splitDistance = 1000.0
        var splits: [RunSplit] = []
        var splitIndex = 1
        var splitStart = timeline.startDistanceMeters
        let maximumSplitCount = RouteAnalysisBudget.maximumEvaluations(
            forRoutePointCount: workout.routePoints.count
        )
        let distanceSpan = timeline.totalDistanceMeters - timeline.startDistanceMeters
        let requiredSplitCount = ceil(distanceSpan / splitDistance)
        guard requiredSplitCount.isFinite,
              requiredSplitCount <= Double(maximumSplitCount)
        else {
            return []
        }

        while splitStart < timeline.totalDistanceMeters,
              splits.count < maximumSplitCount {
            if isCancelled() { throw CancellationError() }
            let splitEnd = min(splitStart + splitDistance, timeline.totalDistanceMeters)
            let distance = splitEnd - splitStart
            guard distance > 0,
                  let range = timeline.distanceRange(from: splitStart, to: splitEnd)
            else {
                break
            }

            let activePace = pace(seconds: range.activeSeconds, distanceMeters: distance)
            let elapsedPace = pace(seconds: range.elapsedSeconds, distanceMeters: distance)

            let movingSec = context.movementProfile?.movingSeconds(
                from: splitStart, to: splitEnd, timeline: timeline
            )
            let stoppedSec = context.movementProfile?.stoppedSeconds(
                from: splitStart, to: splitEnd, timeline: timeline
            )

            splits.append(RunSplit(
                splitIndex: splitIndex,
                distanceMeters: distance,
                elapsedSeconds: range.elapsedSeconds,
                activeSeconds: range.activeSeconds,
                movingSeconds: movingSec,
                stoppedSeconds: stoppedSec,
                paceSecondsPerKilometer: activePace,
                elapsedPaceSecondsPerKilometer: elapsedPace,
                averageHeartRateBPM: timeline.averageHeartRate(from: splitStart, to: splitEnd),
                elevationGainMeters: context.elevationProfile.ascent(from: splitStart, to: splitEnd),
                startDistanceMeters: splitStart,
                endDistanceMeters: splitEnd
            ))

            splitIndex += 1
            guard splitEnd > splitStart else { break }
            splitStart = splitEnd
        }

        return splits
    }

    private static func pace(seconds: Double, distanceMeters: Double) -> Double {
        guard seconds.isFinite,
              seconds > 0,
              distanceMeters.isFinite,
              distanceMeters > 0
        else {
            return 0
        }
        return (seconds / distanceMeters) * 1000
    }
}
