import Foundation

/// Detects notable segments in a running workout using distance-based sliding windows.
///
/// All detection uses cumulative distance, not point count, to handle uneven GPS sampling.
public struct SegmentDetector {

    /// Detect all notable segments from a workout.
    public static func detectSegments(from workout: RunWorkout) -> [SegmentHighlight] {
        var segments: [SegmentHighlight] = []

        if let seg = findFastest400m(workout) {
            segments.append(seg)
        }

        if let seg = findFastestWindow(workout, distanceMeters: 1000, type: .fastest1km) {
            segments.append(seg)
        }

        if let seg = findSlowestWindow(workout, distanceMeters: 1000, type: .slowest1km) {
            segments.append(seg)
        }

        if let seg = findBiggestClimb(workout) {
            segments.append(seg)
        }

        if let seg = findBiggestDescent(workout) {
            segments.append(seg)
        }

        // Sort by display priority
        return segments.sorted { $0.displayPriority < $1.displayPriority }
    }

    // MARK: - Fastest Distance Windows

    /// Find fastest 400m segment using distance-based sliding window.
    private static func findFastest400m(_ workout: RunWorkout) -> SegmentHighlight? {
        findFastestWindow(workout, distanceMeters: 400, type: .fastest400m)
    }

    /// Find fastest window of given distance.
    private static func findFastestWindow(_ workout: RunWorkout, distanceMeters: Double, type: SegmentType) -> SegmentHighlight? {
        let points = workout.routePoints
        guard points.count >= 2 else { return nil }

        let totalDistance = points.last?.distanceFromStartMeters ?? 0
        guard totalDistance >= distanceMeters else { return nil }

        var bestPace: Double = .infinity
        var bestStartIdx = 0
        var bestEndIdx = 0
        var bestStartDist: Double = 0
        var bestEndDist: Double = 0

        // Slide window in 50m increments for finer resolution
        let stepSize = min(50.0, distanceMeters / 4)
        var windowStart: Double = 0

        while windowStart + distanceMeters <= totalDistance {
            let windowEnd = windowStart + distanceMeters

            if let result = evaluateWindow(points: points, startDist: windowStart, endDist: windowEnd) {
                if result.pace < bestPace && result.pace > 0 && result.pace.isFinite {
                    bestPace = result.pace
                    bestStartIdx = result.startIdx
                    bestEndIdx = result.endIdx
                    bestStartDist = windowStart
                    bestEndDist = windowEnd
                }
            }

            windowStart += stepSize
        }

        guard bestPace.isFinite && bestPace > 0 else { return nil }

        let (startElapsed, endElapsed) = getElapsedRange(points: points, startIdx: bestStartIdx, endIdx: bestEndIdx)
        let hrAvg = getAverageHeartRate(points: points, range: bestStartIdx..<bestEndIdx+1)

        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: formatPace(bestPace),
            startDistanceMeters: bestStartDist,
            endDistanceMeters: bestEndDist,
            startElapsedSeconds: startElapsed,
            endElapsedSeconds: endElapsed,
            durationSeconds: endElapsed - startElapsed,
            distanceMeters: distanceMeters,
            paceSecondsPerKilometer: bestPace,
            elevationDeltaMeters: getElevationDelta(points: points, range: bestStartIdx..<bestEndIdx+1),
            averageHeartRate: hrAvg,
            sourcePointRange: bestStartIdx..<bestEndIdx+1,
            displayPriority: type == .fastest400m ? 1 : 2
        )
    }

    /// Find slowest window of given distance.
    private static func findSlowestWindow(_ workout: RunWorkout, distanceMeters: Double, type: SegmentType) -> SegmentHighlight? {
        let points = workout.routePoints
        guard points.count >= 2 else { return nil }

        let totalDistance = points.last?.distanceFromStartMeters ?? 0
        guard totalDistance >= distanceMeters else { return nil }

        var worstPace: Double = 0
        var bestStartIdx = 0
        var bestEndIdx = 0
        var bestStartDist: Double = 0
        var bestEndDist: Double = 0

        let stepSize = min(50.0, distanceMeters / 4)
        var windowStart: Double = 0

        while windowStart + distanceMeters <= totalDistance {
            let windowEnd = windowStart + distanceMeters

            if let result = evaluateWindow(points: points, startDist: windowStart, endDist: windowEnd) {
                if result.pace > worstPace && result.pace.isFinite && result.pace < 1200 {
                    worstPace = result.pace
                    bestStartIdx = result.startIdx
                    bestEndIdx = result.endIdx
                    bestStartDist = windowStart
                    bestEndDist = windowEnd
                }
            }

            windowStart += stepSize
        }

        guard worstPace > 0 && worstPace.isFinite else { return nil }

        let (startElapsed, endElapsed) = getElapsedRange(points: points, startIdx: bestStartIdx, endIdx: bestEndIdx)
        let hrAvg = getAverageHeartRate(points: points, range: bestStartIdx..<bestEndIdx+1)

        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: formatPace(worstPace),
            startDistanceMeters: bestStartDist,
            endDistanceMeters: bestEndDist,
            startElapsedSeconds: startElapsed,
            endElapsedSeconds: endElapsed,
            durationSeconds: endElapsed - startElapsed,
            distanceMeters: distanceMeters,
            paceSecondsPerKilometer: worstPace,
            elevationDeltaMeters: getElevationDelta(points: points, range: bestStartIdx..<bestEndIdx+1),
            averageHeartRate: hrAvg,
            sourcePointRange: bestStartIdx..<bestEndIdx+1,
            displayPriority: 3
        )
    }

    // MARK: - Elevation Segments

    /// Find biggest climb (most elevation gain in a contiguous segment).
    private static func findBiggestClimb(_ workout: RunWorkout) -> SegmentHighlight? {
        findBiggestElevationSegment(workout, ascending: true)
    }

    /// Find biggest descent (most elevation loss in a contiguous segment).
    private static func findBiggestDescent(_ workout: RunWorkout) -> SegmentHighlight? {
        findBiggestElevationSegment(workout, ascending: false)
    }

    private static func findBiggestElevationSegment(_ workout: RunWorkout, ascending: Bool) -> SegmentHighlight? {
        let points = workout.routePoints
        guard points.count >= 10 else { return nil }

        // Check for altitude data
        let hasAltitude = points.contains { $0.altitudeMeters != nil }
        guard hasAltitude else { return nil }

        // Use a window of ~10% of route or at least 10 points
        let windowSize = max(10, points.count / 10)
        var bestDelta: Double = 0
        var bestStartIdx = 0
        var bestEndIdx = 0

        for i in 0...(points.count - windowSize) {
            let startPt = points[i]
            let endPt = points[i + windowSize - 1]

            guard let startAlt = startPt.altitudeMeters,
                  let endAlt = endPt.altitudeMeters else { continue }

            let delta = endAlt - startAlt
            let dist = endPt.distanceFromStartMeters - startPt.distanceFromStartMeters
            guard dist > 0 else { continue }

            if (ascending && delta > bestDelta) || (!ascending && delta < bestDelta) {
                bestDelta = delta
                bestStartIdx = i
                bestEndIdx = i + windowSize - 1
            }
        }

        guard bestDelta != 0 else { return nil }

        let startPt = points[bestStartIdx]
        let endPt = points[bestEndIdx]
        let dist = endPt.distanceFromStartMeters - startPt.distanceFromStartMeters
        let (startElapsed, endElapsed) = getElapsedRange(points: points, startIdx: bestStartIdx, endIdx: bestEndIdx)
        let hrAvg = getAverageHeartRate(points: points, range: bestStartIdx..<bestEndIdx+1)

        let type: SegmentType = ascending ? .biggestClimb : .biggestDescent

        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: String(format: "%.0f m %@", abs(bestDelta), ascending ? "↑" : "↓"),
            startDistanceMeters: startPt.distanceFromStartMeters,
            endDistanceMeters: endPt.distanceFromStartMeters,
            startElapsedSeconds: startElapsed,
            endElapsedSeconds: endElapsed,
            durationSeconds: endElapsed - startElapsed,
            distanceMeters: dist,
            elevationDeltaMeters: bestDelta,
            averageHeartRate: hrAvg,
            sourcePointRange: bestStartIdx..<bestEndIdx+1,
            displayPriority: ascending ? 4 : 5
        )
    }

    // MARK: - Helpers

    /// Evaluate a distance window and return pace and point indices.
    private static func evaluateWindow(points: [RoutePoint], startDist: Double, endDist: Double) -> (startIdx: Int, endIdx: Int, pace: Double)? {
        // Find first point at or after startDist
        guard let startIdx = points.firstIndex(where: { $0.distanceFromStartMeters >= startDist }) else { return nil }
        // Find last point at or before endDist
        guard let endIdx = points.lastIndex(where: { $0.distanceFromStartMeters <= endDist }) else { return nil }
        guard endIdx > startIdx else { return nil }

        let startPoint = points[startIdx]
        let endPoint = points[endIdx]
        let elapsed = endPoint.elapsedSeconds - startPoint.elapsedSeconds
        let distance = endPoint.distanceFromStartMeters - startPoint.distanceFromStartMeters

        guard distance > 0, elapsed > 0 else { return nil }

        let pace = (elapsed / distance) * 1000.0

        // Filter unreasonable pace values
        guard pace >= 120, pace <= 1200, pace.isFinite, !pace.isNaN else { return nil }

        return (startIdx, endIdx, pace)
    }

    /// Get elapsed time range for point indices.
    private static func getElapsedRange(points: [RoutePoint], startIdx: Int, endIdx: Int) -> (Double, Double) {
        guard startIdx < points.count, endIdx < points.count else { return (0, 0) }
        return (points[startIdx].elapsedSeconds, points[endIdx].elapsedSeconds)
    }

    /// Get elevation delta for a point range.
    private static func getElevationDelta(points: [RoutePoint], range: Range<Int>) -> Double? {
        guard range.lowerBound < points.count, range.upperBound <= points.count else { return nil }
        let slice = points[range]
        guard let startAlt = slice.first?.altitudeMeters, let endAlt = slice.last?.altitudeMeters else { return nil }
        return endAlt - startAlt
    }

    /// Get average heart rate for a point range.
    private static func getAverageHeartRate(points: [RoutePoint], range: Range<Int>) -> Double? {
        guard range.lowerBound < points.count, range.upperBound <= points.count else { return nil }
        let slice = points[range]
        let hrValues = slice.compactMap { $0.heartRateBPM }
        guard !hrValues.isEmpty else { return nil }
        return hrValues.reduce(0, +) / Double(hrValues.count)
    }

    private static func formatPace(_ paceSeconds: Double) -> String {
        let mins = Int(paceSeconds) / 60
        let secs = Int(paceSeconds) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }
}
