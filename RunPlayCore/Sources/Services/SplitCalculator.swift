import Foundation

/// Calculates kilometer splits from a running workout.
public struct SplitCalculator {

    /// Calculate 1km splits for a workout.
    public static func calculateSplits(from workout: RunWorkout) -> [RunSplit] {
        let points = workout.routePoints
        guard points.count >= 2 else { return [] }

        var splits: [RunSplit] = []
        let splitDistance: Double = 1000.0 // 1 km
        var currentSplitStart: Double = 0
        var splitIndex = 1
        let totalDistance = points.last?.distanceFromStartMeters ?? 0

        while currentSplitStart < totalDistance {
            let splitEnd = min(currentSplitStart + splitDistance, totalDistance)

            guard
                let firstPoint = RoutePointInterpolator.point(at: currentSplitStart, in: points),
                let lastPoint = RoutePointInterpolator.point(at: splitEnd, in: points)
            else {
                break
            }

            let actualDistance = splitEnd - currentSplitStart
            let elapsed = lastPoint.elapsedSeconds - firstPoint.elapsedSeconds

            guard actualDistance > 0, elapsed > 0, elapsed.isFinite else { break }

            let pace = (elapsed / actualDistance) * 1000.0

            let avgHR = RoutePointInterpolator.averageHeartRate(
                in: points,
                from: currentSplitStart,
                to: splitEnd
            )
            let elevGain = RoutePointInterpolator.elevationGain(
                in: points,
                from: currentSplitStart,
                to: splitEnd
            )

            let split = RunSplit(
                splitIndex: splitIndex,
                distanceMeters: actualDistance,
                elapsedSeconds: elapsed,
                paceSecondsPerKilometer: pace,
                averageHeartRateBPM: avgHR,
                elevationGainMeters: elevGain,
                startDistanceMeters: currentSplitStart,
                endDistanceMeters: currentSplitStart + actualDistance
            )
            splits.append(split)

            currentSplitStart = splitEnd
            splitIndex += 1
        }

        return splits
    }
}
