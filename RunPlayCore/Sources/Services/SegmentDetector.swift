import Foundation

/// Detects notable segments and personal-record windows using cumulative
/// distance.
///
/// Fastest and slowest windows use active pace. Windows may span recording
/// gaps, but elevation never connects points from different route segments.
///
/// The C++23 engine selects at most ten winning distance windows — the five
/// segment highlights plus five fixed-distance personal-record windows —
/// through one bulk native call per detection pass. Swift retains public
/// highlight and record materialization, UUIDs, titles, subtitles, final
/// range metadata, HR averages, and cancellation.
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
        (try? detectSegmentsAndPersonalRecords(
            from: workout,
            context: context,
            policy: .runningDefault,
            isCancelled: { false }
        ))?.segments ?? []
    }

    /// Computes the best fixed-distance personal-record windows for one
    /// workout. Convenience for callers (such as the library backfill) that
    /// only need records; it shares the same single native call per pass.
    public static func detectPersonalRecords(
        from workout: RunWorkout,
        context: WorkoutAnalysisContext
    ) -> WorkoutPersonalRecords {
        let records = (try? detectSegmentsAndPersonalRecords(
            from: workout,
            context: context,
            policy: .runningDefault,
            isCancelled: { false }
        ))?.records ?? []
        return WorkoutPersonalRecords(windows: records)
    }

    /// Segment-only throwing entry retained for parity tests and benchmarks.
    /// Delegates to the combined pass, so a call remains exactly one native
    /// detection invocation.
    static func detectSegments(
        from workout: RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> [SegmentHighlight] {
        try detectSegmentsAndPersonalRecords(
            from: workout,
            context: context,
            policy: policy,
            isCancelled: isCancelled
        ).segments
    }

    /// Result of one detection pass: the five segment highlights and the
    /// fixed-distance record windows, both produced by one native call.
    struct DetectionResult {
        let segments: [SegmentHighlight]
        let records: [PersonalRecordWindow]
    }

    static func detectSegmentsAndPersonalRecords(
        from workout: RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> DetectionResult {
        let points = workout.routePoints
        let timeline = context.timeline
        let elevationProfile = context.elevationProfile

        guard points.count >= 2 else {
            return DetectionResult(segments: [], records: [])
        }

        // Build search configuration from policy
        let config = searchConfiguration(
            points: points,
            timeline: timeline,
            elevationProfile: elevationProfile,
            policy: policy
        )

        // One native call
        let result = try RunPlaySegmentDetectorBridge.search(
            routePoints: points,
            timeline: timeline,
            elevationProfile: elevationProfile,
            configuration: config,
            cancellationCheckStride: policy.cancellationCheckStride,
            isCancelled: isCancelled
        )

        // Finalize candidates in Swift
        var segments: [SegmentHighlight] = []
        var records: [PersonalRecordWindow] = []

        for candidate in result.candidates {
            if isCancelled() { throw CancellationError() }

            switch candidate.kind {
            case .fastest400m:
                if let highlight = finalizePaceCandidate(
                    candidate,
                    type: .fastest400m,
                    timeline: timeline,
                    displayPriority: 1
                ) {
                    segments.append(highlight)
                    if let window = recordWindow(
                        for: .fastest400m,
                        highlight: highlight
                    ) {
                        records.append(window)
                    }
                }
            case .fastest1km:
                if let highlight = finalizePaceCandidate(
                    candidate,
                    type: .fastest1km,
                    timeline: timeline,
                    displayPriority: 2
                ) {
                    segments.append(highlight)
                    if let window = recordWindow(
                        for: .fastest1km,
                        highlight: highlight
                    ) {
                        records.append(window)
                    }
                }
            case .slowest1km:
                if let highlight = finalizePaceCandidate(
                    candidate,
                    type: .slowest1km,
                    timeline: timeline,
                    displayPriority: 3
                ) {
                    segments.append(highlight)
                }
            case .biggestClimb:
                if let highlight = finalizeElevationCandidate(
                    candidate,
                    ascending: true,
                    context: context,
                    timeline: timeline,
                    displayPriority: 4
                ) {
                    segments.append(highlight)
                }
            case .biggestDescent:
                if let highlight = finalizeElevationCandidate(
                    candidate,
                    ascending: false,
                    context: context,
                    timeline: timeline,
                    displayPriority: 5
                ) {
                    segments.append(highlight)
                }
            case .fastestOneMile:
                appendRecordWindow(
                    for: .fastest1mile,
                    candidate: candidate,
                    timeline: timeline,
                    into: &records
                )
            case .fastest5km:
                appendRecordWindow(
                    for: .fastest5km,
                    candidate: candidate,
                    timeline: timeline,
                    into: &records
                )
            case .fastest10km:
                appendRecordWindow(
                    for: .fastest10km,
                    candidate: candidate,
                    timeline: timeline,
                    into: &records
                )
            case .fastestHalfMarathon:
                appendRecordWindow(
                    for: .fastestHalfMarathon,
                    candidate: candidate,
                    timeline: timeline,
                    into: &records
                )
            case .fastestMarathon:
                appendRecordWindow(
                    for: .fastestMarathon,
                    candidate: candidate,
                    timeline: timeline,
                    into: &records
                )
            }
        }

        return DetectionResult(
            segments: segments.sorted { $0.displayPriority < $1.displayPriority },
            records: records
        )
    }

    /// Revalidates one record candidate through the timeline and
    /// materializes the public window model.
    private static func appendRecordWindow(
        for category: PersonalRecordCategory,
        candidate: RunPlaySegmentWindowCandidate,
        timeline: WorkoutTimeline,
        into records: inout [PersonalRecordWindow]
    ) {
        guard let highlight = finalizePaceCandidate(
            candidate,
            type: .custom,
            timeline: timeline,
            displayPriority: 0
        ) else {
            return
        }
        guard let window = recordWindow(
            for: category,
            highlight: highlight
        ) else {
            return
        }
        records.append(window)
    }

    /// Materializes the public record window from a finalized pace highlight.
    /// Returns `nil` without a pace rather than substituting one: a zero would
    /// be a 0 s/km effort that wins every later comparison in the library.
    private static func recordWindow(
        for category: PersonalRecordCategory,
        highlight: SegmentHighlight
    ) -> PersonalRecordWindow? {
        guard let pace = highlight.paceSecondsPerKilometer else { return nil }
        return PersonalRecordWindow(
            category: category,
            startDistanceMeters: highlight.startDistanceMeters,
            endDistanceMeters: highlight.endDistanceMeters,
            startElapsedSeconds: highlight.startElapsedSeconds,
            endElapsedSeconds: highlight.endElapsedSeconds,
            activeSeconds: highlight.durationSeconds,
            paceSecondsPerKilometer: pace,
            averageHeartRateBPM: highlight.averageHeartRate,
            sourcePointRange: highlight.sourcePointRange
        )
    }

    // MARK: - Configuration

    private static func searchConfiguration(
        points: [RoutePoint],
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        policy: RouteQualityPolicy
    ) -> SegmentDetectorSearchConfiguration {
        let distanceSpan = timeline.totalDistanceMeters - timeline.startDistanceMeters
        let routePointCount = points.count

        // 400m step
        let preferred400Step = min(50.0, 400.0 / 4)
        let bounded400Step = RouteAnalysisBudget.boundedStep(
            preferredStep: preferred400Step,
            distanceSpan: distanceSpan,
            routePointCount: routePointCount
        )

        // 1km step
        let preferred1kmStep = min(50.0, 1_000.0 / 4)
        let bounded1kmStep = RouteAnalysisBudget.boundedStep(
            preferredStep: preferred1kmStep,
            distanceSpan: distanceSpan,
            routePointCount: routePointCount
        )

        // Personal-record windows. One mile is the shortest of the five, and
        // min(50, w/4) is 50 m for it and therefore for every longer window,
        // so one bounded value serves all five searches. `boundedStep` never
        // returns less than distanceSpan / (maximumEvaluations - 1), so each
        // search fits the per-search evaluation budget regardless of window
        // length and the engine pre-check cannot trip.
        let oneMileDistance = PersonalRecordCategory.fastest1mile.nominalWindowDistanceMeters ?? 0
        let preferredRecordStep = min(50.0, oneMileDistance / 4)
        let boundedRecordStep = RouteAnalysisBudget.boundedStep(
            preferredStep: preferredRecordStep,
            distanceSpan: distanceSpan,
            routePointCount: routePointCount
        )
        let fiveKmDistance = PersonalRecordCategory.fastest5km.nominalWindowDistanceMeters ?? 0
        let tenKmDistance = PersonalRecordCategory.fastest10km.nominalWindowDistanceMeters ?? 0
        let halfMarathonDistance =
            PersonalRecordCategory.fastestHalfMarathon.nominalWindowDistanceMeters ?? 0
        let marathonDistance = PersonalRecordCategory.fastestMarathon.nominalWindowDistanceMeters ?? 0

        // Elevation
        let elevationEnabled = elevationProfile.hasMeaningfulElevation
            && timeline.totalDistanceMeters >= policy.elevationHighlightMinimumWindowMeters

        let elevationWindowDistance: Double
        let elevationStep: Double
        if elevationEnabled {
            elevationWindowDistance = max(
                policy.elevationHighlightMinimumWindowMeters,
                min(
                    policy.elevationHighlightMaximumWindowMeters,
                    timeline.totalDistanceMeters * policy.elevationHighlightWindowRouteFraction
                )
            )
            let preferredElevationStep = max(
                policy.elevationHighlightMinimumStepMeters,
                elevationWindowDistance / Double(policy.elevationHighlightStepsPerWindow)
            )
            elevationStep = RouteAnalysisBudget.boundedStep(
                preferredStep: preferredElevationStep,
                distanceSpan: distanceSpan,
                routePointCount: routePointCount
            )
        } else {
            elevationWindowDistance = 0
            elevationStep = 0
        }

        return SegmentDetectorSearchConfiguration(
            fastest400mDistanceMeters: 400,
            fastest400mStepMeters: bounded400Step,
            oneKilometerDistanceMeters: 1_000,
            oneKilometerStepMeters: bounded1kmStep,
            oneMileDistanceMeters: oneMileDistance,
            oneMileStepMeters: boundedRecordStep,
            fiveKilometerDistanceMeters: fiveKmDistance,
            fiveKilometerStepMeters: boundedRecordStep,
            tenKilometerDistanceMeters: tenKmDistance,
            tenKilometerStepMeters: boundedRecordStep,
            halfMarathonDistanceMeters: halfMarathonDistance,
            halfMarathonStepMeters: boundedRecordStep,
            marathonDistanceMeters: marathonDistance,
            marathonStepMeters: boundedRecordStep,
            minimumValidPaceSecondsPerKilometer: 120,
            maximumValidPaceSecondsPerKilometer: 1_200,
            elevationEnabled: elevationEnabled,
            elevationWindowDistanceMeters: elevationWindowDistance,
            elevationStepMeters: elevationStep,
            maximumEvaluationsPerSearch: UInt64(
                RouteAnalysisBudget.maximumEvaluations(forRoutePointCount: routePointCount)
            )
        )
    }

    // MARK: - Pace finalization

    private struct WindowEvaluation {
        let range: WorkoutTimeline.DistanceRange
        let pace: Double
        let elevationDelta: Double?
        let averageHeartRate: Double?
    }

    private static func finalizePaceCandidate(
        _ candidate: RunPlaySegmentWindowCandidate,
        type: SegmentType,
        timeline: WorkoutTimeline,
        displayPriority: Int
    ) -> SegmentHighlight? {
        // Evaluate the winning window to get range and metadata
        guard let result = evaluateWindow(
            timeline: timeline,
            startDistance: candidate.startDistanceMeters,
            endDistance: candidate.endDistanceMeters
        ) else {
            return nil
        }

        // Verify pace matches C++ selection within tolerance
        let tolerance = max(1e-9, abs(candidate.selectionValue) * 1e-12)
        guard abs(result.pace - candidate.selectionValue) <= tolerance else {
            return nil
        }

        let distanceMeters = candidate.endDistanceMeters - candidate.startDistanceMeters
        return makePaceHighlight(
            type: type,
            result: result,
            startDistance: candidate.startDistanceMeters,
            endDistance: candidate.endDistanceMeters,
            distanceMeters: distanceMeters,
            displayPriority: displayPriority
        )
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

    // MARK: - Elevation finalization

    private static func finalizeElevationCandidate(
        _ candidate: RunPlaySegmentWindowCandidate,
        ascending: Bool,
        context: WorkoutAnalysisContext,
        timeline: WorkoutTimeline,
        displayPriority: Int
    ) -> SegmentHighlight? {
        let elevationProfile = context.elevationProfile

        // Verify continuous reliable elevation
        guard elevationProfile.hasContinuousReliableElevation(
            from: candidate.startDistanceMeters,
            to: candidate.endDistanceMeters
        ) else {
            return nil
        }

        // Get change from profile and verify against C++ selection
        guard let change = elevationProfile.change(
            from: candidate.startDistanceMeters,
            to: candidate.endDistanceMeters
        ) else {
            return nil
        }

        let delta = ascending ? change.ascentMeters : -change.descentMeters
        let tolerance = max(1e-9, abs(candidate.selectionValue) * 1e-12)
        guard abs(delta - candidate.selectionValue) <= tolerance else {
            return nil
        }
        guard delta != 0 else { return nil }

        // Get timeline range
        guard let range = timeline.distanceRange(
            from: candidate.startDistanceMeters,
            to: candidate.endDistanceMeters
        ) else {
            return nil
        }

        let type: SegmentType = ascending ? .biggestClimb : .biggestDescent
        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: String(format: "%.0f m %@", abs(delta), ascending ? "↑" : "↓"),
            startDistanceMeters: candidate.startDistanceMeters,
            endDistanceMeters: candidate.endDistanceMeters,
            startElapsedSeconds: range.start.elapsedSeconds,
            endElapsedSeconds: range.end.elapsedSeconds,
            durationSeconds: range.activeSeconds,
            distanceMeters: candidate.endDistanceMeters - candidate.startDistanceMeters,
            elevationDeltaMeters: delta,
            averageHeartRate: timeline.averageHeartRate(
                from: candidate.startDistanceMeters,
                to: candidate.endDistanceMeters
            ),
            sourcePointRange: range.sourcePointRange,
            displayPriority: displayPriority
        )
    }

    private static func formatPace(_ paceSeconds: Double) -> String {
        DisplayFormatter.formatPace(paceSeconds)
    }
}
