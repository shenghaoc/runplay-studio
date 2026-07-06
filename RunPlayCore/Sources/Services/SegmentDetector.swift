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
        var bestResult: WindowEvaluation?
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
                    bestResult = result
                    bestStartDist = windowStart
                    bestEndDist = windowEnd
                }
            }

            windowStart += stepSize
        }

        guard bestPace.isFinite && bestPace > 0, let bestResult else { return nil }
        let sourceRange = sourceRange(points: points, startDist: bestStartDist, endDist: bestEndDist)

        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: formatPace(bestPace),
            startDistanceMeters: bestStartDist,
            endDistanceMeters: bestEndDist,
            startElapsedSeconds: bestResult.startElapsed,
            endElapsedSeconds: bestResult.endElapsed,
            durationSeconds: bestResult.endElapsed - bestResult.startElapsed,
            distanceMeters: distanceMeters,
            paceSecondsPerKilometer: bestPace,
            elevationDeltaMeters: bestResult.elevationDelta,
            averageHeartRate: bestResult.averageHeartRate,
            sourcePointRange: sourceRange,
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
        var bestResult: WindowEvaluation?
        var bestStartDist: Double = 0
        var bestEndDist: Double = 0

        let stepSize = min(50.0, distanceMeters / 4)
        var windowStart: Double = 0

        while windowStart + distanceMeters <= totalDistance {
            let windowEnd = windowStart + distanceMeters

            if let result = evaluateWindow(points: points, startDist: windowStart, endDist: windowEnd) {
                if result.pace > worstPace && result.pace.isFinite && result.pace < 1200 {
                    worstPace = result.pace
                    bestResult = result
                    bestStartDist = windowStart
                    bestEndDist = windowEnd
                }
            }

            windowStart += stepSize
        }

        guard worstPace > 0 && worstPace.isFinite, let bestResult else { return nil }
        let sourceRange = sourceRange(points: points, startDist: bestStartDist, endDist: bestEndDist)

        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: formatPace(worstPace),
            startDistanceMeters: bestStartDist,
            endDistanceMeters: bestEndDist,
            startElapsedSeconds: bestResult.startElapsed,
            endElapsedSeconds: bestResult.endElapsed,
            durationSeconds: bestResult.endElapsed - bestResult.startElapsed,
            distanceMeters: distanceMeters,
            paceSecondsPerKilometer: worstPace,
            elevationDeltaMeters: bestResult.elevationDelta,
            averageHeartRate: bestResult.averageHeartRate,
            sourcePointRange: sourceRange,
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
        guard points.count >= 2 else { return nil }

        // Check for altitude data
        let hasAltitude = points.contains { $0.altitudeMeters != nil }
        guard hasAltitude else { return nil }

        let totalDistance = points.last?.distanceFromStartMeters ?? 0
        guard totalDistance >= 100 else { return nil }

        let windowDistance = max(100, min(1_000, totalDistance * 0.2))
        let stepSize = max(25, windowDistance / 10)
        var bestDelta: Double = 0
        var bestStartDist: Double = 0
        var bestEndDist: Double = 0
        var bestStartPoint: RoutePoint?
        var bestEndPoint: RoutePoint?

        var windowStart: Double = 0
        while windowStart + windowDistance <= totalDistance {
            let windowEnd = windowStart + windowDistance
            defer { windowStart += stepSize }

            guard
                let startPt = RoutePointInterpolator.point(at: windowStart, in: points),
                let endPt = RoutePointInterpolator.point(at: windowEnd, in: points),
                let startAlt = startPt.altitudeMeters,
                let endAlt = endPt.altitudeMeters
            else { continue }

            let delta = endAlt - startAlt
            let dist = windowEnd - windowStart
            guard dist > 0 else { continue }

            if (ascending && delta > bestDelta) || (!ascending && delta < bestDelta) {
                bestDelta = delta
                bestStartDist = windowStart
                bestEndDist = windowEnd
                bestStartPoint = startPt
                bestEndPoint = endPt
            }
        }

        guard bestDelta != 0, let startPt = bestStartPoint, let endPt = bestEndPoint else { return nil }

        let dist = bestEndDist - bestStartDist
        let hrAvg = RoutePointInterpolator.averageHeartRate(in: points, from: bestStartDist, to: bestEndDist)
        let sourceRange = sourceRange(points: points, startDist: bestStartDist, endDist: bestEndDist)

        let type: SegmentType = ascending ? .biggestClimb : .biggestDescent

        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: String(format: "%.0f m %@", abs(bestDelta), ascending ? "↑" : "↓"),
            startDistanceMeters: bestStartDist,
            endDistanceMeters: bestEndDist,
            startElapsedSeconds: startPt.elapsedSeconds,
            endElapsedSeconds: endPt.elapsedSeconds,
            durationSeconds: endPt.elapsedSeconds - startPt.elapsedSeconds,
            distanceMeters: dist,
            elevationDeltaMeters: bestDelta,
            averageHeartRate: hrAvg,
            sourcePointRange: sourceRange,
            displayPriority: ascending ? 4 : 5
        )
    }

    // MARK: - Helpers

    /// Evaluate a distance window and return pace and point indices.
    private struct WindowEvaluation {
        let startElapsed: Double
        let endElapsed: Double
        let pace: Double
        let elevationDelta: Double?
        let averageHeartRate: Double?
    }

    private static func evaluateWindow(points: [RoutePoint], startDist: Double, endDist: Double) -> WindowEvaluation? {
        guard
            let startPoint = RoutePointInterpolator.point(at: startDist, in: points),
            let endPoint = RoutePointInterpolator.point(at: endDist, in: points)
        else { return nil }

        let elapsed = endPoint.elapsedSeconds - startPoint.elapsedSeconds
        let distance = endDist - startDist

        guard distance > 0, elapsed > 0 else { return nil }

        let pace = (elapsed / distance) * 1000.0

        // Filter unreasonable pace values
        guard pace >= 120, pace <= 1200, pace.isFinite, !pace.isNaN else { return nil }

        let elevationDelta: Double?
        if let startAltitude = startPoint.altitudeMeters, let endAltitude = endPoint.altitudeMeters {
            elevationDelta = endAltitude - startAltitude
        } else {
            elevationDelta = nil
        }

        return WindowEvaluation(
            startElapsed: startPoint.elapsedSeconds,
            endElapsed: endPoint.elapsedSeconds,
            pace: pace,
            elevationDelta: elevationDelta,
            averageHeartRate: RoutePointInterpolator.averageHeartRate(in: points, from: startDist, to: endDist)
        )
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

    private static func sourceRange(points: [RoutePoint], startDist: Double, endDist: Double) -> Range<Int> {
        guard !points.isEmpty else { return 0..<0 }
        let startIdx = RoutePointInterpolator.firstIndex(atOrAfter: startDist, in: points) ?? 0
        let endIdx = RoutePointInterpolator.lastIndex(atOrBefore: endDist, in: points) ?? startIdx
        let lower = max(0, min(startIdx, points.count - 1))
        let upper = max(lower + 1, min(points.count, endIdx + 1))
        return lower..<upper
    }

    private static func formatPace(_ paceSeconds: Double) -> String {
        let mins = Int(paceSeconds) / 60
        let secs = Int(paceSeconds) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }
}
