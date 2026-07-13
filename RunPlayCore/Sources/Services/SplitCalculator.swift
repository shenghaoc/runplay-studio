import Foundation

/// Calculates global kilometer splits from a running workout.
public struct SplitCalculator {

    public static func calculateSplits(from workout: RunWorkout) -> [RunSplit] {
        calculateSplits(from: workout, timeline: WorkoutTimeline(workout: workout))
    }

    /// Route-segment boundaries do not reset cumulative split distance. A pause
    /// exactly on a split boundary is excluded from both neighboring splits by
    /// the timeline's explicit range-start/range-end rule.
    public static func calculateSplits(
        from workout: RunWorkout,
        timeline: WorkoutTimeline
    ) -> [RunSplit] {
        guard workout.routePoints.count >= 2,
              timeline.totalDistanceMeters > timeline.startDistanceMeters
        else {
            return []
        }

        let splitDistance = 1000.0
        var splits: [RunSplit] = []
        var splitIndex = 1
        var splitStart = timeline.startDistanceMeters

        while splitStart < timeline.totalDistanceMeters {
            let splitEnd = min(splitStart + splitDistance, timeline.totalDistanceMeters)
            let distance = splitEnd - splitStart
            guard distance > 0,
                  let range = timeline.distanceRange(from: splitStart, to: splitEnd)
            else {
                break
            }

            let activePace = pace(seconds: range.activeSeconds, distanceMeters: distance)
            let elapsedPace = pace(seconds: range.elapsedSeconds, distanceMeters: distance)

            splits.append(RunSplit(
                splitIndex: splitIndex,
                distanceMeters: distance,
                elapsedSeconds: range.elapsedSeconds,
                activeSeconds: range.activeSeconds,
                paceSecondsPerKilometer: activePace,
                elapsedPaceSecondsPerKilometer: elapsedPace,
                averageHeartRateBPM: timeline.averageHeartRate(from: splitStart, to: splitEnd),
                elevationGainMeters: timeline.elevationGain(from: splitStart, to: splitEnd),
                startDistanceMeters: splitStart,
                endDistanceMeters: splitEnd
            ))

            splitIndex += 1
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
