import Foundation

/// Analyzes a normalized workout and populates derived metrics.
public struct WorkoutAnalyzer: Sendable {

    public init() {}

    public static let validHeartRateRange: ClosedRange<Double> = 30...230

    /// Analyze a workout in place using `WorkoutTimeline` as the sole time
    /// authority for the summary, splits, and notable pace windows.
    public func analyze(_ workout: inout RunWorkout) {
        analyze(
            &workout,
            context: WorkoutAnalysisContext(workout: workout),
            policy: .runningDefault
        )
    }

    public func analyze(_ workout: inout RunWorkout, context: WorkoutAnalysisContext) {
        analyze(&workout, context: context, policy: .runningDefault)
    }

    private func analyze(
        _ workout: inout RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy
    ) {
        try? analyzeCancellable(
            &workout,
            context: context,
            policy: policy,
            isCancelled: { false }
        )
    }

    private func analyzeCancellable(
        _ workout: inout RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        try throwIfCancelled(isCancelled)
        try calculateDerivedMetrics(
            &workout,
            timeline: context.timeline,
            policy: policy,
            isCancelled: isCancelled
        )
        try throwIfCancelled(isCancelled)

        // Build movement profile from the (possibly updated) route points
        let movementProfile: MovementProfile
        if let existing = context.movementProfile {
            movementProfile = existing
        } else {
            movementProfile = try MovementProfile(
                routePoints: workout.routePoints,
                timeline: context.timeline,
                isCancelled: isCancelled
            )
        }
        let ctx = WorkoutAnalysisContext(
            routePoints: workout.routePoints,
            elevationProfile: context.elevationProfile,
            movementProfile: movementProfile
        )

        workout.summary = calculateSummary(workout, context: ctx, policy: policy)
        try throwIfCancelled(isCancelled)
        workout.splits = try SplitCalculator.calculateSplits(
            from: workout,
            context: ctx,
            policy: policy,
            isCancelled: isCancelled
        )
        try throwIfCancelled(isCancelled)

        // Recorded laps: rederive canonical metrics while preserving source fields.
        // Never fabricate laps from splits or route segments.
        let lapWarnings = try reanalyzeRecordedLaps(
            &workout,
            context: ctx,
            policy: policy,
            isCancelled: isCancelled
        )

        workout.segments = try SegmentDetector.detectSegments(
            from: workout,
            context: ctx,
            policy: policy,
            isCancelled: isCancelled
        )
        try throwIfCancelled(isCancelled)
        workout.analysisVersion = RunWorkout.currentAnalysisVersion
        workout.movementDiagnostics = movementProfile.diagnostics

        // Attach movement diagnostics as analysis warnings
        var warnings = workout.analysisWarnings.filter {
            $0 != .movementEstimatedStoppedTime
                && $0 != .movementLowReliability
                && $0 != .recordedLapsMalformedSkipped
                && $0 != .recordedLapSourceTotalsMismatch
                && $0 != .recordedLapsRequireReimport
        }
        if movementProfile.totalStoppedSeconds > 0 {
            if !warnings.contains(.movementEstimatedStoppedTime) {
                warnings.append(.movementEstimatedStoppedTime)
            }
        }
        if movementProfile.diagnostics.usedConservativeFallback {
            if !warnings.contains(.movementLowReliability) {
                warnings.append(.movementLowReliability)
            }
        }
        for warning in lapWarnings where !warnings.contains(warning) {
            warnings.append(warning)
        }
        if workout.mayRequireReimportForRecordedLaps,
           !warnings.contains(.recordedLapsRequireReimport) {
            warnings.append(.recordedLapsRequireReimport)
            var diagnostics = workout.recordedLapDiagnostics
            diagnostics.requiresReimportForSourceLaps = true
            workout.recordedLapDiagnostics = diagnostics
        }
        workout.analysisWarnings = warnings
    }

    /// Rederive recorded-lap metrics from source boundaries. Empty collections
    /// stay empty; calculated splits are never treated as source laps.
    private func reanalyzeRecordedLaps(
        _ workout: inout RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> [WorkoutAnalysisWarning] {
        guard !workout.recordedLaps.isEmpty else {
            return []
        }

        let result = try RecordedLapAnalyzer.analyze(
            provisionalLaps: workout.recordedLaps,
            routePoints: workout.routePoints,
            context: context,
            source: workout.source,
            cancellationCheckStride: policy.cancellationCheckStride,
            isCancelled: isCancelled
        )
        workout.recordedLaps = result.laps
        // Preserve reimport flag if already set on a legacy snapshot that somehow
        // retained empty-but-flagged diagnostics without inventing laps.
        var diagnostics = result.diagnostics
        if workout.recordedLapDiagnostics.requiresReimportForSourceLaps,
           result.laps.isEmpty {
            diagnostics.requiresReimportForSourceLaps = true
        }
        workout.recordedLapDiagnostics = diagnostics
        return result.warnings
    }

    /// Apply route normalization before analysis. Importers and normalization
    /// migrations use this path so cancellation propagates before persistence.
    public func normalizeAndAnalyze(
        _ workout: inout RunWorkout,
        distancePolicy: RouteDistancePolicy,
        policy: RouteQualityPolicy = .runningDefault,
        sourceInvalidCoordinatePointCount: Int = 0,
        isCancelled: @escaping @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) throws {
        let quality = try RouteQualityProcessor(policy: policy).process(
            workout.routePoints,
            distancePolicy: distancePolicy,
            sourceInvalidCoordinatePointCount: sourceInvalidCoordinatePointCount,
            isCancelled: isCancelled
        )
        try throwIfCancelled(isCancelled)
        var analyzed = workout
        analyzed.routePoints = quality.routePoints
        analyzed.normalizationVersion = RunWorkout.currentNormalizationVersion
        analyzed.qualityDiagnostics = quality.diagnostics
        analyzed.routeDistanceSource = quality.distanceSource
        analyzed.routeDistanceProvenance = quality.distanceProvenance
        let nonQualityWarnings = analyzed.analysisWarnings.filter { !$0.isRouteQualityWarning }
        analyzed.analysisWarnings = Self.uniqued(nonQualityWarnings + quality.analysisWarnings)
        let context = WorkoutAnalysisContext(
            routePoints: quality.routePoints,
            elevationProfile: quality.elevationProfile
        )
        try throwIfCancelled(isCancelled)
        try analyzeCancellable(
            &analyzed,
            context: context,
            policy: policy,
            isCancelled: isCancelled
        )
        try throwIfCancelled(isCancelled)
        workout = analyzed
    }

    /// Recompute stale persisted analysis while preserving the exact stored
    /// route-point payload, including IDs and optional source metrics.
    public func reanalyzePreservingRoutePoints(_ workout: inout RunWorkout) {
        let storedRoutePoints = workout.routePoints
        analyze(&workout)
        workout.routePoints = storedRoutePoints
    }

    private func calculateDerivedMetrics(
        _ workout: inout RunWorkout,
        timeline: WorkoutTimeline,
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let points = workout.routePoints
        guard points.count >= 2 else { return }

        for index in 1..<points.count {
            if index % policy.cancellationCheckStride == 0 {
                try throwIfCancelled(isCancelled)
            }
            let previous = points[index - 1]
            let current = points[index]
            guard current.routeSegmentIndex == previous.routeSegmentIndex,
                  let previousElapsed = timeline.elapsedSeconds(atPointIndex: index - 1),
                  let currentElapsed = timeline.elapsedSeconds(atPointIndex: index)
            else {
                continue
            }

            if workout.routePoints[index].speedMetersPerSecond == nil {
                let distance = current.distanceFromStartMeters - previous.distanceFromStartMeters
                let elapsed = currentElapsed - previousElapsed
                if distance.isFinite, distance >= 0, elapsed.isFinite, elapsed > 0 {
                    let derivedSpeed = distance / elapsed
                    if derivedSpeed.isFinite,
                       derivedSpeed <= policy.maximumSourceSpeedMetersPerSecond {
                        workout.routePoints[index].speedMetersPerSecond = derivedSpeed
                    }
                }
            }

            if let speed = workout.routePoints[index].speedMetersPerSecond,
               speed.isFinite,
               speed > 0,
               speed <= policy.maximumSourceSpeedMetersPerSecond {
                workout.routePoints[index].paceSecondsPerKilometer = 1000.0 / speed
            } else {
                if let speed = workout.routePoints[index].speedMetersPerSecond,
                   !speed.isFinite || speed < 0 || speed > policy.maximumSourceSpeedMetersPerSecond {
                    workout.routePoints[index].speedMetersPerSecond = nil
                }
                workout.routePoints[index].paceSecondsPerKilometer = nil
            }
        }
    }

    private func throwIfCancelled(
        _ isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
    }

    private func calculateSummary(
        _ workout: RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy
    ) -> RunSummary {
        let points = workout.routePoints
        guard !points.isEmpty else { return RunSummary() }

        let timeline = context.timeline

        let totalDistance = timeline.totalDistanceMeters
        let activeSpeed = Self.speed(
            distanceMeters: totalDistance,
            seconds: timeline.totalActiveSeconds,
            maximumMetersPerSecond: policy.maximumSourceSpeedMetersPerSecond
        )
        let elapsedSpeed = Self.speed(
            distanceMeters: totalDistance,
            seconds: timeline.totalElapsedSeconds,
            maximumMetersPerSecond: policy.maximumSourceSpeedMetersPerSecond
        )
        let activePace = activeSpeed > 0 ? 1_000 / activeSpeed : 0
        let elapsedPace = elapsedSpeed > 0 ? 1_000 / elapsedSpeed : 0
        let movingSpeed = Self.speed(
            distanceMeters: totalDistance,
            seconds: context.movementProfile?.totalMovingSeconds ?? timeline.totalActiveSeconds,
            maximumMetersPerSecond: policy.maximumSourceSpeedMetersPerSecond
        )
        let movingPace = movingSpeed > 0 ? 1_000 / movingSpeed : 0

        let elevationGain = context.elevationProfile.totalAscentMeters ?? 0
        let elevationLoss = context.elevationProfile.totalDescentMeters ?? 0

        // ⚡ Bolt: Replaced .compactMap { ... }.filter { ... }.reduce chain with inline loop.
        // This avoids intermediate O(N) array allocations for heart rate aggregations.
        var sumHR: Double = 0
        var countHR = 0
        var maxHR: Double? = nil

        for point in points {
            if let hr = point.heartRateBPM, Self.validHeartRateRange.contains(hr), hr.isFinite {
                sumHR += hr
                countHR += 1
                if let currentMax = maxHR {
                    maxHR = max(currentMax, hr)
                } else {
                    maxHR = hr
                }
            }
        }
        let averageHeartRate = countHR > 0 ? sumHR / Double(countHR) : nil

        return RunSummary(
            totalDistanceMeters: totalDistance,
            totalElapsedSeconds: timeline.totalElapsedSeconds,
            totalActiveSeconds: timeline.totalActiveSeconds,
            totalPausedSeconds: timeline.totalPausedSeconds,
            totalMovingSeconds: context.movementProfile?.totalMovingSeconds,
            totalStoppedSeconds: context.movementProfile?.totalStoppedSeconds,
            movingPaceSecondsPerKilometer: movingPace,
            movingAverageSpeedMetersPerSecond: movingSpeed,
            averagePaceSecondsPerKilometer: activePace,
            elapsedPaceSecondsPerKilometer: elapsedPace,
            averageSpeedMetersPerSecond: activeSpeed,
            elapsedAverageSpeedMetersPerSecond: elapsedSpeed,
            elevationGainMeters: elevationGain,
            elevationLossMeters: elevationLoss,
            averageHeartRateBPM: averageHeartRate,
            maxHeartRateBPM: maxHR
        )
    }

    private static func speed(
        distanceMeters: Double,
        seconds: Double,
        maximumMetersPerSecond: Double
    ) -> Double {
        guard seconds.isFinite,
              seconds > 0,
              distanceMeters.isFinite,
              distanceMeters > 0
        else {
            return 0
        }
        let value = distanceMeters / seconds
        guard value.isFinite, value <= maximumMetersPerSecond else { return 0 }
        return value
    }

    public func calculateDistance(from: RoutePoint, to: RoutePoint) -> Double {
        GeoDistance.distanceMeters(
            fromLat: from.latitude,
            lon: from.longitude,
            toLat: to.latitude,
            lon: to.longitude
        )
    }

    private static func uniqued(_ warnings: [WorkoutAnalysisWarning]) -> [WorkoutAnalysisWarning] {
        var seen: Set<WorkoutAnalysisWarning> = []
        return warnings.filter { seen.insert($0).inserted }
    }
}
