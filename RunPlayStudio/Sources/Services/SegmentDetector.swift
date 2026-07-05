import Foundation

/// Detects notable segments in a running workout.
struct SegmentDetector {

    /// Detect notable segments (fastest km, steepest climb, etc.)
    static func detectSegments(from workout: RunWorkout) -> [SegmentHighlight] {
        var segments: [SegmentHighlight] = []

        if let fastest = findFastestKilometer(workout) {
            segments.append(fastest)
        }

        if let slowest = findSlowestKilometer(workout) {
            segments.append(slowest)
        }

        if let climb = findSteepestSegment(workout, ascending: true) {
            segments.append(climb)
        }

        if let descent = findSteepestSegment(workout, ascending: false) {
            segments.append(descent)
        }

        return segments
    }

    /// Find the fastest 1km segment.
    private static func findFastestKilometer(_ workout: RunWorkout) -> SegmentHighlight? {
        findBestKilometer(workout, fastest: true)
    }

    /// Find the slowest 1km segment.
    private static func findSlowestKilometer(_ workout: RunWorkout) -> SegmentHighlight? {
        findBestKilometer(workout, fastest: false)
    }

    private static func findBestKilometer(_ workout: RunWorkout, fastest: Bool) -> SegmentHighlight? {
        let points = workout.routePoints
        guard points.count >= 2 else { return nil }

        let totalDistance = points.last?.distanceFromStartMeters ?? 0
        guard totalDistance >= 1000 else { return nil }

        var bestPace: Double = fastest ? .infinity : 0
        var bestStartIdx = 0
        var bestEndIdx = 0
        var bestStartDist: Double = 0
        var bestEndDist: Double = 0

        // Slide a 1km window across the route
        var windowStart: Double = 0
        while windowStart + 1000 <= totalDistance {
            let windowEnd = windowStart + 1000

            // Find points in window
            let startIdx = points.firstIndex { $0.distanceFromStartMeters >= windowStart } ?? 0
            let endIdx = points.lastIndex { $0.distanceFromStartMeters <= windowEnd } ?? (points.count - 1)

            guard endIdx > startIdx else {
                windowStart += 100
                continue
            }

            let startPoint = points[startIdx]
            let endPoint = points[endIdx]
            let elapsed = endPoint.elapsedSeconds - startPoint.elapsedSeconds
            let distance = endPoint.distanceFromStartMeters - startPoint.distanceFromStartMeters

            guard distance > 0 else {
                windowStart += 100
                continue
            }

            let pace = (elapsed / distance) * 1000.0

            if (fastest && pace < bestPace) || (!fastest && pace > bestPace) {
                bestPace = pace
                bestStartIdx = startIdx
                bestEndIdx = endIdx
                bestStartDist = windowStart
                bestEndDist = windowEnd
            }

            windowStart += 100 // Slide by 100m increments
        }

        guard bestPace.isFinite && bestPace > 0 else { return nil }

        let type: SegmentType = fastest ? .fastestKilometer : .slowestKilometer
        let label = formatPace(bestPace)

        return SegmentHighlight(
            type: type,
            startIndex: bestStartIdx,
            endIndex: bestEndIdx,
            startDistanceMeters: bestStartDist,
            endDistanceMeters: bestEndDist,
            value: bestPace,
            label: label
        )
    }

    /// Find the steepest ascending or descending segment.
    private static func findSteepestSegment(_ workout: RunWorkout, ascending: Bool) -> SegmentHighlight? {
        let points = workout.routePoints
        guard points.count >= 10 else { return nil }

        // Need altitude data
        let hasAltitude = points.contains { $0.altitudeMeters != nil }
        guard hasAltitude else { return nil }

        let segmentLength = max(10, points.count / 10) // ~10% of route
        var bestGradient: Double = 0
        var bestStartIdx = 0
        var bestEndIdx = 0

        for i in 0...(points.count - segmentLength) {
            let startPt = points[i]
            let endPt = points[i + segmentLength - 1]

            guard let startAlt = startPt.altitudeMeters,
                  let endAlt = endPt.altitudeMeters else { continue }

            let dist = endPt.distanceFromStartMeters - startPt.distanceFromStartMeters
            guard dist > 0 else { continue }

            let gradient = (endAlt - startAlt) / dist * 100 // percent

            if (ascending && gradient > bestGradient) || (!ascending && gradient < bestGradient) {
                bestGradient = gradient
                bestStartIdx = i
                bestEndIdx = i + segmentLength - 1
            }
        }

        guard bestGradient != 0 else { return nil }

        let type: SegmentType = ascending ? .steepestClimb : .steepestDescent
        let label = String(format: "%.1f%%", abs(bestGradient))

        return SegmentHighlight(
            type: type,
            startIndex: bestStartIdx,
            endIndex: bestEndIdx,
            startDistanceMeters: points[bestStartIdx].distanceFromStartMeters,
            endDistanceMeters: points[bestEndIdx].distanceFromStartMeters,
            value: bestGradient,
            label: label
        )
    }

    private static func formatPace(_ paceSeconds: Double) -> String {
        let mins = Int(paceSeconds) / 60
        let secs = Int(paceSeconds) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }
}
