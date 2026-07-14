import Foundation

/// Detects notable segments using cumulative distance.
///
/// Fastest and slowest windows use active pace. Windows may span recording
/// gaps, but elevation never connects points from different route segments.
public struct SegmentDetector {

    public static func detectSegments(from workout: RunWorkout) -> [SegmentHighlight] {
        detectSegments(from: workout, context: WorkoutAnalysisContext(workout: workout))
    }

    public static func detectSegments(
        from workout: RunWorkout,
        timeline: WorkoutTimeline
    ) -> [SegmentHighlight] {
        detectSegments(
            from: workout,
            context: WorkoutAnalysisContext(
                timeline: timeline,
                elevationProfile: ElevationProfile(routePoints: workout.routePoints)
            )
        )
    }

    public static func detectSegments(
        from workout: RunWorkout,
        context: WorkoutAnalysisContext
    ) -> [SegmentHighlight] {
        (try? detectSegments(
            from: workout,
            context: context,
            policy: .runningDefault,
            isCancelled: { false }
        )) ?? []
    }

    static func detectSegments(
        from workout: RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> [SegmentHighlight] {
        let timeline = context.timeline
        var segments: [SegmentHighlight] = []

        if let segment = try findFastestWindow(
            workout,
            timeline: timeline,
            distanceMeters: 400,
            type: .fastest400m,
            isCancelled: isCancelled
        ) {
            segments.append(segment)
        }
        if let segment = try findFastestWindow(
            workout,
            timeline: timeline,
            distanceMeters: 1000,
            type: .fastest1km,
            isCancelled: isCancelled
        ) {
            segments.append(segment)
        }
        if let segment = try findSlowestWindow(
            workout,
            timeline: timeline,
            distanceMeters: 1000,
            type: .slowest1km,
            isCancelled: isCancelled
        ) {
            segments.append(segment)
        }
        if let segment = try findBiggestElevationSegment(
            workout,
            context: context,
            ascending: true,
            policy: policy,
            isCancelled: isCancelled
        ) {
            segments.append(segment)
        }
        if let segment = try findBiggestElevationSegment(
            workout,
            context: context,
            ascending: false,
            policy: policy,
            isCancelled: isCancelled
        ) {
            segments.append(segment)
        }

        return segments.sorted { $0.displayPriority < $1.displayPriority }
    }

    // MARK: - Active-pace windows

    private static func findFastestWindow(
        _ workout: RunWorkout,
        timeline: WorkoutTimeline,
        distanceMeters: Double,
        type: SegmentType,
        isCancelled: @Sendable () -> Bool
    ) throws -> SegmentHighlight? {
        guard workout.routePoints.count >= 2,
              timeline.totalDistanceMeters - timeline.startDistanceMeters >= distanceMeters
        else {
            return nil
        }

        var bestPace = Double.infinity
        var bestResult: WindowEvaluation?
        var bestStart = timeline.startDistanceMeters
        let preferredStep = min(50.0, distanceMeters / 4)
        let stepSize = RouteAnalysisBudget.boundedStep(
            preferredStep: preferredStep,
            distanceSpan: timeline.totalDistanceMeters - timeline.startDistanceMeters,
            routePointCount: workout.routePoints.count
        )
        var windowStart = timeline.startDistanceMeters

        while windowStart + distanceMeters <= timeline.totalDistanceMeters {
            if isCancelled() { throw CancellationError() }
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
        type: SegmentType,
        isCancelled: @Sendable () -> Bool
    ) throws -> SegmentHighlight? {
        guard workout.routePoints.count >= 2,
              timeline.totalDistanceMeters - timeline.startDistanceMeters >= distanceMeters
        else {
            return nil
        }

        var slowestPace: Double = 0
        var slowestResult: WindowEvaluation?
        var slowestStart = timeline.startDistanceMeters
        let preferredStep = min(50.0, distanceMeters / 4)
        let stepSize = RouteAnalysisBudget.boundedStep(
            preferredStep: preferredStep,
            distanceSpan: timeline.totalDistanceMeters - timeline.startDistanceMeters,
            routePointCount: workout.routePoints.count
        )
        var windowStart = timeline.startDistanceMeters

        while windowStart + distanceMeters <= timeline.totalDistanceMeters {
            if isCancelled() { throw CancellationError() }
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
        context: WorkoutAnalysisContext,
        ascending: Bool,
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> SegmentHighlight? {
        let points = workout.routePoints
        let timeline = context.timeline
        let elevationProfile = context.elevationProfile
        guard points.count >= 2,
              elevationProfile.hasMeaningfulElevation,
              timeline.totalDistanceMeters >= policy.elevationHighlightMinimumWindowMeters
        else {
            return nil
        }

        let windowDistance = max(
            policy.elevationHighlightMinimumWindowMeters,
            min(
                policy.elevationHighlightMaximumWindowMeters,
                timeline.totalDistanceMeters * policy.elevationHighlightWindowRouteFraction
            )
        )
        let preferredStep = max(
            policy.elevationHighlightMinimumStepMeters,
            windowDistance / Double(policy.elevationHighlightStepsPerWindow)
        )
        let stepSize = RouteAnalysisBudget.boundedStep(
            preferredStep: preferredStep,
            distanceSpan: timeline.totalDistanceMeters - timeline.startDistanceMeters,
            routePointCount: points.count
        )
        var bestDelta: Double = 0
        var bestStart = timeline.startDistanceMeters
        var windowStart = timeline.startDistanceMeters

        while windowStart + windowDistance <= timeline.totalDistanceMeters {
            if isCancelled() { throw CancellationError() }
            let windowEnd = windowStart + windowDistance
            defer { windowStart += stepSize }

            guard elevationProfile.hasContinuousReliableElevation(
                from: windowStart,
                to: windowEnd
            ), let change = elevationProfile.change(from: windowStart, to: windowEnd)
            else {
                continue
            }

            let delta = ascending ? change.ascentMeters : -change.descentMeters
            if (ascending && delta > bestDelta) || (!ascending && delta < bestDelta) {
                bestDelta = delta
                bestStart = windowStart
            }
        }

        let bestEnd = bestStart + windowDistance
        guard bestDelta != 0,
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
