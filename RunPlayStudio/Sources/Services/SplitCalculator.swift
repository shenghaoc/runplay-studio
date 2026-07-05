import Foundation

/// Calculates kilometer splits from a running workout.
struct SplitCalculator {

    /// Calculate 1km splits for a workout.
    static func calculateSplits(from workout: RunWorkout) -> [RunSplit] {
        let points = workout.routePoints
        guard points.count >= 2 else { return [] }

        var splits: [RunSplit] = []
        let splitDistance: Double = 1000.0 // 1 km
        var currentSplitStart: Double = 0
        var splitIndex = 1

        while currentSplitStart < (points.last?.distanceFromStartMeters ?? 0) {
            let splitEnd = currentSplitStart + splitDistance

            // Find points within this split
            let splitPoints = points.filter {
                $0.distanceFromStartMeters >= currentSplitStart &&
                $0.distanceFromStartMeters < splitEnd
            }

            guard let firstPoint = splitPoints.first,
                  let lastPoint = splitPoints.last else {
                break
            }

            // Interpolate exact split boundaries
            let actualDistance = min(splitEnd, points.last?.distanceFromStartMeters ?? splitEnd) - currentSplitStart
            let elapsed = lastPoint.elapsedSeconds - firstPoint.elapsedSeconds

            guard elapsed > 0 else {
                currentSplitStart = splitEnd
                splitIndex += 1
                continue
            }

            let pace = (elapsed / actualDistance) * 1000.0

            // Average heart rate for split
            let hrValues = splitPoints.compactMap { $0.heartRateBPM }
            let avgHR = hrValues.isEmpty ? nil : hrValues.reduce(0, +) / Double(hrValues.count)

            // Elevation gain for split
            var elevGain: Double = 0
            var prevAlt: Double?
            for point in splitPoints {
                if let alt = point.altitudeMeters, let prev = prevAlt {
                    let diff = alt - prev
                    if diff > 0 { elevGain += diff }
                }
                prevAlt = point.altitudeMeters
            }

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

            // Stop if we've covered the total distance
            if currentSplitStart >= (points.last?.distanceFromStartMeters ?? 0) {
                break
            }
        }

        // Add partial final split if needed
        if let lastPoint = points.last,
           let lastSplit = splits.last,
           lastSplit.endDistanceMeters < lastPoint.distanceFromStartMeters {
            let startDist = lastSplit.endDistanceMeters
            let endDist = lastPoint.distanceFromStartMeters
            let dist = endDist - startDist

            let startPoint = points.first { $0.distanceFromStartMeters >= startDist }
            let endPoint = points.last { $0.distanceFromStartMeters <= endDist }

            if let start = startPoint, let end = endPoint {
                let elapsed = end.elapsedSeconds - start.elapsedSeconds
                let pace = dist > 0 ? (elapsed / dist) * 1000.0 : 0

                let partialSplit = RunSplit(
                    splitIndex: splits.count + 1,
                    distanceMeters: dist,
                    elapsedSeconds: elapsed,
                    paceSecondsPerKilometer: pace,
                    startDistanceMeters: startDist,
                    endDistanceMeters: endDist
                )
                splits.append(partialSplit)
            }
        }

        return splits
    }
}
