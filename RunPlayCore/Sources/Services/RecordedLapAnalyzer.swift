import Foundation

/// Derives canonical recorded-lap metrics from source boundaries and shared
/// analysis context. Does not invent laps from calculated splits or segments.
public struct RecordedLapAnalyzer: Sendable {

    /// Absolute and relative tolerances for material source/route mismatches.
    public struct MismatchPolicy: Sendable {
        public var absoluteTimeSeconds: Double
        public var relativeTime: Double
        public var absoluteDistanceMeters: Double
        public var relativeDistance: Double

        public static let runningDefault = MismatchPolicy(
            absoluteTimeSeconds: 5,
            relativeTime: 0.02,
            absoluteDistanceMeters: 25,
            relativeDistance: 0.02
        )

        public init(
            absoluteTimeSeconds: Double = 5,
            relativeTime: Double = 0.02,
            absoluteDistanceMeters: Double = 25,
            relativeDistance: Double = 0.02
        ) {
            self.absoluteTimeSeconds = Self.nonNegativeFinite(absoluteTimeSeconds)
            self.relativeTime = Self.nonNegativeFinite(relativeTime)
            self.absoluteDistanceMeters = Self.nonNegativeFinite(absoluteDistanceMeters)
            self.relativeDistance = Self.nonNegativeFinite(relativeDistance)
        }

        private static func nonNegativeFinite(_ value: Double) -> Double {
            value.isFinite ? max(0, value) : 0
        }
    }

    public struct Result: Sendable {
        public var laps: [RecordedLap]
        public var diagnostics: RecordedLapDiagnostics
        public var warnings: [WorkoutAnalysisWarning]
    }

    public init() {}

    /// Analyze provisional source laps (or reanalyze persisted ones).
    ///
    /// Preserves IDs, source, trigger, source dates, and reported metrics.
    /// Canonical clocks, distance, pace, HR, cadence, and elevation are
    /// rederived from the route.
    public static func analyze(
        provisionalLaps: [RecordedLap],
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        source: WorkoutSource,
        mismatchPolicy: MismatchPolicy = .runningDefault,
        cancellationCheckStride: Int = 1_024,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Result {
        let timeline = context.timeline
        guard !provisionalLaps.isEmpty else {
            return Result(
                laps: [],
                diagnostics: .empty,
                warnings: []
            )
        }

        var laps: [RecordedLap] = []
        laps.reserveCapacity(provisionalLaps.count)
        var malformed = 0
        var clamped = 0
        var timeMismatches = 0
        var distanceMismatches = 0
        var triggersAvailable = false

        let workoutStart = routePoints.first?.timestamp
        let metricIndex = try RecordedLapMetricIndex(
            routePoints: routePoints,
            cancellationCheckStride: cancellationCheckStride,
            isCancelled: isCancelled
        )

        for (offset, provisional) in provisionalLaps.enumerated() {
            if offset % max(1, cancellationCheckStride) == 0, isCancelled() {
                throw CancellationError()
            }

            if provisional.trigger != .unavailable {
                triggersAvailable = true
            }

            guard let boundaries = resolveBoundaries(
                provisional: provisional,
                workoutStart: workoutStart,
                timeline: timeline,
                clampedBoundaryCount: &clamped
            ) else {
                malformed += 1
                continue
            }

            let startElapsed = boundaries.startElapsed
            let endElapsed = boundaries.endElapsed

            guard let range = timeline.timeRange(from: startElapsed, to: endElapsed) else {
                malformed += 1
                continue
            }

            let distance = max(0, range.end.distanceMeters - range.start.distanceMeters)
            let elapsed = range.elapsedSeconds
            let active = range.activeSeconds

            let moving = context.movementProfile?.movingSeconds(
                fromElapsed: startElapsed,
                toElapsed: endElapsed,
                timeline: timeline
            ) ?? active
            let safeMoving = min(max(0, moving), active)

            let activePace = pace(seconds: active, distanceMeters: distance)
            let movingPace = pace(seconds: safeMoving, distanceMeters: distance)
            let elapsedPace = pace(seconds: elapsed, distanceMeters: distance)

            let (avgHR, maxHR) = metricIndex.heartRateStatistics(in: range.sourcePointRange)
            let avgCadence = metricIndex.averageCadence(in: range.sourcePointRange)

            let elevGain = context.elevationProfile.ascent(
                from: range.start.distanceMeters,
                to: range.end.distanceMeters
            )
            let elevLoss = context.elevationProfile.descent(
                from: range.start.distanceMeters,
                to: range.end.distanceMeters
            )

            if let reported = provisional.reportedMetrics {
                let mismatch = sourceTotalsMismatch(
                    reported, elapsed: elapsed, active: active, distance: distance, policy: mismatchPolicy
                )
                if mismatch.time {
                    timeMismatches += 1
                }
                if mismatch.distance {
                    distanceMismatches += 1
                }
            }

            laps.append(RecordedLap(
                id: provisional.id,
                lapIndex: provisional.lapIndex > 0 ? provisional.lapIndex : offset + 1,
                source: provisional.source == .unknown ? source : provisional.source,
                trigger: provisional.trigger,
                sourceStartDate: provisional.sourceStartDate,
                sourceEndDate: provisional.sourceEndDate,
                startElapsedSeconds: range.start.elapsedSeconds,
                endElapsedSeconds: range.end.elapsedSeconds,
                startDistanceMeters: range.start.distanceMeters,
                endDistanceMeters: range.end.distanceMeters,
                elapsedSeconds: elapsed,
                activeSeconds: active,
                movingSeconds: safeMoving,
                activePaceSecondsPerKilometer: activePace,
                movingPaceSecondsPerKilometer: movingPace,
                elapsedPaceSecondsPerKilometer: elapsedPace,
                averageHeartRateBPM: avgHR,
                maximumHeartRateBPM: maxHR,
                averageCadence: avgCadence,
                elevationGainMeters: elevGain,
                elevationLossMeters: elevLoss,
                reportedMetrics: provisional.reportedMetrics
            ))
        }

        // Ensure deterministic 1-based indices after skips.
        for index in laps.indices {
            laps[index].lapIndex = index + 1
        }

        let diagnostics = RecordedLapDiagnostics(
            sourceLapCount: provisionalLaps.count,
            importedLapCount: laps.count,
            malformedLapCount: malformed,
            clampedBoundaryCount: clamped,
            timeMismatchCount: timeMismatches,
            distanceMismatchCount: distanceMismatches,
            triggersAvailable: triggersAvailable,
            requiresReimportForSourceLaps: false
        )

        let warnings = lapWarnings(
            malformed: malformed, mismatches: timeMismatches + distanceMismatches, lapCount: laps.count
        )

        return Result(laps: laps, diagnostics: diagnostics, warnings: warnings)
    }

    /// Whether the source-reported time (elapsed or timer) and distance differ
    /// materially from the rederived ones.
    private static func sourceTotalsMismatch(
        _ reported: RecordedLapReportedMetrics, elapsed: Double, active: Double, distance: Double,
        policy mismatchPolicy: MismatchPolicy
    ) -> (time: Bool, distance: Bool) {
        let time = differsMaterially(
            reported.elapsedSeconds,
            from: elapsed,
            absolute: mismatchPolicy.absoluteTimeSeconds,
            relative: mismatchPolicy.relativeTime
        ) || differsMaterially(
            reported.timerSeconds,
            from: active,
            absolute: mismatchPolicy.absoluteTimeSeconds,
            relative: mismatchPolicy.relativeTime
        )
        let distanceDiffers = differsMaterially(
            reported.distanceMeters,
            from: distance,
            absolute: mismatchPolicy.absoluteDistanceMeters,
            relative: mismatchPolicy.relativeDistance
        )
        return (time, distanceDiffers)
    }

    /// A warning for skipped malformed laps, and one when source totals
    /// mismatch on at least a quarter of the laps (and at least one) or on
    /// three or more.
    private static func lapWarnings(malformed: Int, mismatches: Int, lapCount: Int) -> [WorkoutAnalysisWarning] {
        var warnings: [WorkoutAnalysisWarning] = []
        if malformed > 0 {
            warnings.append(.recordedLapsMalformedSkipped)
        }
        if mismatches > 0,
           (Double(mismatches) >= max(1, Double(lapCount) * 0.25)
            || mismatches >= 3) {
            warnings.append(.recordedLapSourceTotalsMismatch)
        }
        return warnings
    }

    // MARK: - Boundary resolution

    private struct ResolvedBoundaries {
        var startElapsed: Double
        var endElapsed: Double
    }

    private static func resolveBoundaries(
        provisional: RecordedLap,
        workoutStart: Date?,
        timeline: WorkoutTimeline,
        clampedBoundaryCount: inout Int
    ) -> ResolvedBoundaries? {
        var (startElapsed, endElapsed) = sourceDateBoundaries(of: provisional, workoutStart: workoutStart)
        applyAnalyzedBoundaryFallback(provisional, startElapsed: &startElapsed, endElapsed: &endElapsed)
        applyReportedElapsedFallback(provisional, startElapsed: &startElapsed, endElapsed: &endElapsed)

        guard let start = startElapsed, let end = endElapsed,
              start.isFinite, end.isFinite
        else {
            return nil
        }

        return clampedToRoute(
            start: start, end: end, total: timeline.totalElapsedSeconds,
            clampedBoundaryCount: &clampedBoundaryCount
        )
    }

    /// The lap's source start and end dates as elapsed seconds from the
    /// workout start, when both dates are known.
    private static func sourceDateBoundaries(
        of provisional: RecordedLap, workoutStart: Date?
    ) -> (start: Double?, end: Double?) {
        var startElapsed: Double?
        var endElapsed: Double?

        if let startDate = provisional.sourceStartDate, let workoutStart {
            startElapsed = startDate.timeIntervalSince(workoutStart)
        }
        if let endDate = provisional.sourceEndDate, let workoutStart {
            endElapsed = endDate.timeIntervalSince(workoutStart)
        }
        return (startElapsed, endElapsed)
    }

    /// Prefer already-analyzed elapsed bounds when source dates are missing
    /// (reanalysis of persisted laps).
    private static func applyAnalyzedBoundaryFallback(
        _ provisional: RecordedLap, startElapsed: inout Double?, endElapsed: inout Double?
    ) {
        if startElapsed == nil,
           (provisional.endElapsedSeconds > provisional.startElapsedSeconds
            || provisional.startElapsedSeconds > 0) {
            startElapsed = provisional.startElapsedSeconds
        }
        if endElapsed == nil, provisional.endElapsedSeconds > 0 {
            endElapsed = provisional.endElapsedSeconds
        }
    }

    /// Safe fallbacks from reported totals: a missing bound is the known one
    /// minus or plus the reported elapsed time.
    private static func applyReportedElapsedFallback(
        _ provisional: RecordedLap, startElapsed: inout Double?, endElapsed: inout Double?
    ) {
        if startElapsed == nil,
           let end = endElapsed,
           let reportedElapsed = provisional.reportedMetrics?.elapsedSeconds,
           reportedElapsed.isFinite,
           reportedElapsed > 0 {
            startElapsed = end - reportedElapsed
        }
        if endElapsed == nil,
           let start = startElapsed,
           let reportedElapsed = provisional.reportedMetrics?.elapsedSeconds,
           reportedElapsed.isFinite,
           reportedElapsed > 0 {
            endElapsed = start + reportedElapsed
        }
    }

    /// Clamp source-clock overhangs onto the retained route, counting each
    /// overhang beyond the diagnostic epsilon. A first GPS fix may
    /// legitimately arrive well after the device opened the lap. Nil when the
    /// clamped end is before the start.
    private static func clampedToRoute(
        start startElapsed: Double, end endElapsed: Double, total: Double, clampedBoundaryCount: inout Int
    ) -> ResolvedBoundaries? {
        let clampDiagnosticEpsilon = 0.01
        var start = startElapsed
        var end = endElapsed
        if start < 0 {
            if start < -clampDiagnosticEpsilon {
                clampedBoundaryCount += 1
            }
            start = 0
        }
        if end > total {
            if end > total + clampDiagnosticEpsilon {
                clampedBoundaryCount += 1
            }
            end = total
        }

        start = max(0, min(start, total))
        end = max(0, min(end, total))
        if end < start {
            return nil
        }

        return ResolvedBoundaries(startElapsed: start, endElapsed: end)
    }

    // MARK: - Helpers

    private static func pace(seconds: Double, distanceMeters: Double) -> Double {
        guard seconds.isFinite, seconds > 0, distanceMeters.isFinite, distanceMeters > 0 else {
            return 0
        }
        return (seconds / distanceMeters) * 1000
    }

    private static func differsMaterially(
        _ source: Double?,
        from route: Double,
        absolute: Double,
        relative: Double
    ) -> Bool {
        guard let source, source.isFinite, source >= 0, route.isFinite, route >= 0 else {
            return false
        }
        let tolerance = max(absolute, route * relative)
        return abs(source - route) > tolerance
    }
}
