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
            self.absoluteTimeSeconds = max(0, absoluteTimeSeconds)
            self.relativeTime = max(0, relativeTime)
            self.absoluteDistanceMeters = max(0, absoluteDistanceMeters)
            self.relativeDistance = max(0, relativeDistance)
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
            let paused = range.pausedSeconds

            let moving = context.movementProfile?.movingSeconds(
                fromElapsed: startElapsed,
                toElapsed: endElapsed,
                timeline: timeline
            ) ?? active
            let safeMoving = min(max(0, moving), active)
            let stopped = max(0, active - safeMoving)

            let activePace = pace(seconds: active, distanceMeters: distance)
            let movingPace = pace(seconds: safeMoving, distanceMeters: distance)
            let elapsedPace = pace(seconds: elapsed, distanceMeters: distance)

            let (avgHR, maxHR) = heartRateStats(
                in: range.sourcePointRange,
                routePoints: routePoints
            )
            let avgCadence = averageCadence(
                in: range.sourcePointRange,
                routePoints: routePoints
            )

            let elevGain = context.elevationProfile.ascent(
                from: range.start.distanceMeters,
                to: range.end.distanceMeters
            )
            let elevLoss = context.elevationProfile.descent(
                from: range.start.distanceMeters,
                to: range.end.distanceMeters
            )

            if let reported = provisional.reportedMetrics {
                if differsMaterially(
                    reported.elapsedSeconds,
                    from: elapsed,
                    absolute: mismatchPolicy.absoluteTimeSeconds,
                    relative: mismatchPolicy.relativeTime
                ) || differsMaterially(
                    reported.timerSeconds,
                    from: active,
                    absolute: mismatchPolicy.absoluteTimeSeconds,
                    relative: mismatchPolicy.relativeTime
                ) {
                    timeMismatches += 1
                }
                if differsMaterially(
                    reported.distanceMeters,
                    from: distance,
                    absolute: mismatchPolicy.absoluteDistanceMeters,
                    relative: mismatchPolicy.relativeDistance
                ) {
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
                distanceMeters: distance,
                elapsedSeconds: elapsed,
                activeSeconds: active,
                movingSeconds: safeMoving,
                stoppedSeconds: stopped,
                pausedSeconds: paused,
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

        var warnings: [WorkoutAnalysisWarning] = []
        if malformed > 0 {
            warnings.append(.recordedLapsMalformedSkipped)
        }
        if timeMismatches + distanceMismatches > 0,
           Double(timeMismatches + distanceMismatches) >= max(1, Double(laps.count) * 0.25)
            || timeMismatches + distanceMismatches >= 3 {
            warnings.append(.recordedLapSourceTotalsMismatch)
        }

        return Result(laps: laps, diagnostics: diagnostics, warnings: warnings)
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
        let clampDiagnosticEpsilon = 0.01
        let total = timeline.totalElapsedSeconds

        var startElapsed: Double?
        var endElapsed: Double?

        if let startDate = provisional.sourceStartDate, let workoutStart {
            startElapsed = startDate.timeIntervalSince(workoutStart)
        }
        if let endDate = provisional.sourceEndDate, let workoutStart {
            endElapsed = endDate.timeIntervalSince(workoutStart)
        }

        // Prefer already-analyzed elapsed bounds when source dates are missing
        // (reanalysis of persisted laps).
        if startElapsed == nil, provisional.endElapsedSeconds > provisional.startElapsedSeconds
            || provisional.startElapsedSeconds > 0 {
            startElapsed = provisional.startElapsedSeconds
        }
        if endElapsed == nil, provisional.endElapsedSeconds > 0 {
            endElapsed = provisional.endElapsedSeconds
        }

        // Safe fallbacks from reported totals.
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

        guard var start = startElapsed, var end = endElapsed,
              start.isFinite, end.isFinite
        else {
            return nil
        }

        // Clamp source-clock overhangs onto the retained route. A first GPS
        // fix may legitimately arrive well after the device opened the lap.
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

    private static func heartRateStats(
        in range: Range<Int>,
        routePoints: [RoutePoint]
    ) -> (average: Double?, maximum: Double?) {
        var sum: Double = 0
        var count = 0
        var maximum: Double?
        for index in range {
            guard routePoints.indices.contains(index),
                  let hr = routePoints[index].heartRateBPM,
                  MetricValidation.isValidHeartRate(hr)
            else {
                continue
            }
            sum += hr
            count += 1
            maximum = maximum.map { max($0, hr) } ?? hr
        }
        guard count > 0 else { return (nil, nil) }
        return (sum / Double(count), maximum)
    }

    private static func averageCadence(
        in range: Range<Int>,
        routePoints: [RoutePoint]
    ) -> Double? {
        var sum: Double = 0
        var count = 0
        for index in range {
            guard routePoints.indices.contains(index),
                  let cadence = routePoints[index].cadence,
                  cadence.isFinite,
                  cadence >= 0
            else {
                continue
            }
            sum += cadence
            count += 1
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
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
