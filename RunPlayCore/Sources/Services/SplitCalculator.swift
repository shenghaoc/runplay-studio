import Foundation

/// Calculates kilometer splits from a running workout.
public struct SplitCalculator {

    /// Calculate 1km splits for a workout without crossing route-segment gaps.
    public static func calculateSplits(from workout: RunWorkout) -> [RunSplit] {
        let points = workout.routePoints
        guard points.count >= 2 else { return [] }

        var splits: [RunSplit] = []
        let splitDistance: Double = 1000.0 // 1 km
        var splitIndex = 1

        for segmentPoints in contiguousSegments(in: points) {
            guard let first = segmentPoints.first,
                  let last = segmentPoints.last,
                  first.distanceFromStartMeters.isFinite,
                  last.distanceFromStartMeters.isFinite,
                  last.distanceFromStartMeters > first.distanceFromStartMeters
            else {
                continue
            }

            var currentSplitStart = first.distanceFromStartMeters
            let segmentEnd = last.distanceFromStartMeters

            while currentSplitStart < segmentEnd {
                let splitEnd = min(currentSplitStart + splitDistance, segmentEnd)

                guard
                    let firstPoint = RoutePointInterpolator.point(at: currentSplitStart, in: segmentPoints),
                    let lastPoint = RoutePointInterpolator.point(at: splitEnd, in: segmentPoints)
                else {
                    currentSplitStart = splitEnd
                    continue
                }

                let actualDistance = splitEnd - currentSplitStart
                let elapsed = lastPoint.elapsedSeconds - firstPoint.elapsedSeconds

                guard actualDistance > 0, elapsed > 0, elapsed.isFinite else {
                    currentSplitStart = splitEnd
                    continue
                }

                let pace = (elapsed / actualDistance) * 1000.0

                let avgHR = RoutePointInterpolator.averageHeartRate(
                    in: segmentPoints,
                    from: currentSplitStart,
                    to: splitEnd
                )
                let elevGain = RoutePointInterpolator.elevationGain(
                    in: segmentPoints,
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
                splitIndex += 1

                currentSplitStart = splitEnd
            }
        }

        return splits
    }

    private static func contiguousSegments(in points: [RoutePoint]) -> [[RoutePoint]] {
        guard let first = points.first else { return [] }

        var segments: [[RoutePoint]] = []
        var currentSegmentIndex = first.routeSegmentIndex
        var currentPoints: [RoutePoint] = []

        for point in points {
            if point.routeSegmentIndex != currentSegmentIndex {
                if !currentPoints.isEmpty {
                    segments.append(currentPoints)
                }
                currentSegmentIndex = point.routeSegmentIndex
                currentPoints = []
            }
            currentPoints.append(point)
        }

        if !currentPoints.isEmpty {
            segments.append(currentPoints)
        }
        return segments
    }
}
