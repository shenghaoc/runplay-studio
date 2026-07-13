import Foundation

/// Detects notable segments using cumulative distance.
///
/// Fastest and slowest windows use active pace. Windows may span recording
/// gaps, but elevation never connects points from different route segments.
public struct SegmentDetector {

    public static func detectSegments(from workout: RunWorkout) -> [SegmentHighlight] {
        detectSegments(from: workout, timeline: WorkoutTimeline(workout: workout))
    }

    public static func detectSegments(
        from workout: RunWorkout,
        timeline: WorkoutTimeline
    ) -> [SegmentHighlight] {
        var segments: [SegmentHighlight] = []

        if let segment = findFastestWindow(
            workout,
            timeline: timeline,
            distanceMeters: 400,
            type: .fastest400m
        ) {
            segments.append(segment)
        }
        if let segment = findFastestWindow(
            workout,
            timeline: timeline,
            distanceMeters: 1000,
            type: .fastest1km
        ) {
            segments.append(segment)
        }
        if let segment = findSlowestWindow(
            workout,
            timeline: timeline,
            distanceMeters: 1000,
            type: .slowest1km
        ) {
            segments.append(segment)
        }
        if let segment = findBiggestElevationSegment(workout, timeline: timeline, ascending: true) {
            segments.append(segment)
        }
        if let segment = findBiggestElevationSegment(workout, timeline: timeline, ascending: false) {
            segments.append(segment)
        }

        return segments.sorted { $0.displayPriority < $1.displayPriority }
    }

    // MARK: - Active-pace windows

    private static func findFastestWindow(
        _ workout: RunWorkout,
        timeline: WorkoutTimeline,
        distanceMeters: Double,
        type: SegmentType
    ) -> SegmentHighlight? {
        guard workout.routePoints.count >= 2,
              timeline.totalDistanceMeters - timeline.startDistanceMeters >= distanceMeters
        else {
            return nil
        }

        var bestPace = Double.infinity
        var bestResult: WindowEvaluation?
        var bestStart = timeline.startDistanceMeters
        let stepSize = min(50.0, distanceMeters / 4)
        var windowStart = timeline.startDistanceMeters

        while windowStart + distanceMeters <= timeline.totalDistanceMeters {
            let windowEnd = windowStart + distanceMeters
            if let result = evaluateWindow(
                timeline: timeline,
                startDistance: windowStart,
                endDistance: windowEnd
            ), result.pace < bestPace {
                bestPace = result.pace
                bestResult = result
                bestStart = windowStart
            }
            windowStart += stepSize
        }

        guard let result = bestResult, bestPace.isFinite, bestPace > 0 else { return nil }
        return makePaceHighlight(
            type: type,
            result: result,
            startDistance: bestStart,
            endDistance: bestStart + distanceMeters,
            distanceMeters: distanceMeters,
            displayPriority: type == .fastest400m ? 1 : 2
        )
    }

    private static func findSlowestWindow(
        _ workout: RunWorkout,
        timeline: WorkoutTimeline,
        distanceMeters: Double,
        type: SegmentType
    ) -> SegmentHighlight? {
        guard workout.routePoints.count >= 2,
              timeline.totalDistanceMeters - timeline.startDistanceMeters >= distanceMeters
        else {
            return nil
        }

        var slowestPace: Double = 0
        var slowestResult: WindowEvaluation?
        var slowestStart = timeline.startDistanceMeters
        let stepSize = min(50.0, distanceMeters / 4)
        var windowStart = timeline.startDistanceMeters

        while windowStart + distanceMeters <= timeline.totalDistanceMeters {
            let windowEnd = windowStart + distanceMeters
            if let result = evaluateWindow(
                timeline: timeline,
                startDistance: windowStart,
                endDistance: windowEnd
            ), result.pace > slowestPace {
                slowestPace = result.pace
                slowestResult = result
                slowestStart = windowStart
            }
            windowStart += stepSize
        }

        guard let result = slowestResult, slowestPace.isFinite, slowestPace > 0 else { return nil }
        return makePaceHighlight(
            type: type,
            result: result,
            startDistance: slowestStart,
            endDistance: slowestStart + distanceMeters,
            distanceMeters: distanceMeters,
            displayPriority: 3
        )
    }

    private struct WindowEvaluation {
        let range: WorkoutTimeline.DistanceRange
        let pace: Double
        let elevationDelta: Double?
        let averageHeartRate: Double?
    }

    private static func evaluateWindow(
        timeline: WorkoutTimeline,
        startDistance: Double,
        endDistance: Double
    ) -> WindowEvaluation? {
        guard let range = timeline.distanceRange(from: startDistance, to: endDistance) else {
            return nil
        }

        let distance = endDistance - startDistance
        guard distance > 0, range.activeSeconds > 0 else { return nil }
        let pace = (range.activeSeconds / distance) * 1000
        guard pace.isFinite, (120...1200).contains(pace) else { return nil }

        return WindowEvaluation(
            range: range,
            pace: pace,
            elevationDelta: timeline.signedElevationChange(from: startDistance, to: endDistance),
            averageHeartRate: timeline.averageHeartRate(from: startDistance, to: endDistance)
        )
    }

    private static func makePaceHighlight(
        type: SegmentType,
        result: WindowEvaluation,
        startDistance: Double,
        endDistance: Double,
        distanceMeters: Double,
        displayPriority: Int
    ) -> SegmentHighlight {
        SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: formatPace(result.pace),
            startDistanceMeters: startDistance,
            endDistanceMeters: endDistance,
            startElapsedSeconds: result.range.start.elapsedSeconds,
            endElapsedSeconds: result.range.end.elapsedSeconds,
            durationSeconds: result.range.activeSeconds,
            distanceMeters: distanceMeters,
            paceSecondsPerKilometer: result.pace,
            elevationDeltaMeters: result.elevationDelta,
            averageHeartRate: result.averageHeartRate,
            sourcePointRange: result.range.sourcePointRange,
            displayPriority: displayPriority
        )
    }

    // MARK: - Elevation highlights

    private static func findBiggestElevationSegment(
        _ workout: RunWorkout,
        timeline: WorkoutTimeline,
        ascending: Bool
    ) -> SegmentHighlight? {
        let points = workout.routePoints
        guard points.count >= 2,
              points.contains(where: { $0.altitudeMeters != nil }),
              timeline.totalDistanceMeters >= 100
        else {
            return nil
        }

        let windowDistance = max(100, min(1000, timeline.totalDistanceMeters * 0.2))
        let stepSize = max(25, windowDistance / 10)
        var bestDelta: Double = 0
        var bestStart = timeline.startDistanceMeters
        var bestStartPoint: RoutePoint?
        var bestEndPoint: RoutePoint?
        var windowStart = timeline.startDistanceMeters

        while windowStart + windowDistance <= timeline.totalDistanceMeters {
            let windowEnd = windowStart + windowDistance
            defer { windowStart += stepSize }

            guard let startPoint = RoutePointInterpolator.point(at: windowStart, in: points),
                  let endPoint = RoutePointInterpolator.point(at: windowEnd, in: points),
                  startPoint.routeSegmentIndex == endPoint.routeSegmentIndex,
                  let startAltitude = startPoint.altitudeMeters,
                  let endAltitude = endPoint.altitudeMeters,
                  startAltitude.isFinite,
                  endAltitude.isFinite
            else {
                continue
            }

            let delta = endAltitude - startAltitude
            if (ascending && delta > bestDelta) || (!ascending && delta < bestDelta) {
                bestDelta = delta
                bestStart = windowStart
                bestStartPoint = startPoint
                bestEndPoint = endPoint
            }
        }

        let bestEnd = bestStart + windowDistance
        guard bestDelta != 0,
              bestStartPoint != nil,
              bestEndPoint != nil,
              let range = timeline.distanceRange(from: bestStart, to: bestEnd)
        else {
            return nil
        }

        let type: SegmentType = ascending ? .biggestClimb : .biggestDescent
        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: String(format: "%.0f m %@", abs(bestDelta), ascending ? "↑" : "↓"),
            startDistanceMeters: bestStart,
            endDistanceMeters: bestEnd,
            startElapsedSeconds: range.start.elapsedSeconds,
            endElapsedSeconds: range.end.elapsedSeconds,
            durationSeconds: range.activeSeconds,
            distanceMeters: windowDistance,
            elevationDeltaMeters: bestDelta,
            averageHeartRate: timeline.averageHeartRate(from: bestStart, to: bestEnd),
            sourcePointRange: range.sourcePointRange,
            displayPriority: ascending ? 4 : 5
        )
    }

    private static func formatPace(_ paceSeconds: Double) -> String {
        DisplayFormatter.formatPace(paceSeconds)
    }
}
