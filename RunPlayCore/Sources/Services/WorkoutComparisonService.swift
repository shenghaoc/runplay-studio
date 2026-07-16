import Foundation

/// Distance-aligned workout comparison with explicit elapsed and active clocks.
public struct WorkoutComparisonService: Sendable {

    public static let pauseDurationWarningThresholdSeconds: Double = 30

    public init() {}

    public func compare(primary: RunWorkout, comparison: RunWorkout) -> WorkoutComparisonSummary {
        compare(
            primary: primary,
            comparison: comparison,
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison)
        )
    }

    public func compare(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext
    ) -> WorkoutComparisonSummary {
        let primaryTimeline = primaryContext.timeline
        let comparisonTimeline = comparisonContext.timeline
        let primaryDistance = primaryTimeline.totalDistanceMeters
        let comparisonDistance = comparisonTimeline.totalDistanceMeters
        let primaryActivePace = pace(
            seconds: primaryTimeline.totalActiveSeconds,
            distanceMeters: primaryDistance
        )
        let comparisonActivePace = pace(
            seconds: comparisonTimeline.totalActiveSeconds,
            distanceMeters: comparisonDistance
        )
        let primaryElapsedPace = pace(
            seconds: primaryTimeline.totalElapsedSeconds,
            distanceMeters: primaryDistance
        )
        let comparisonElapsedPace = pace(
            seconds: comparisonTimeline.totalElapsedSeconds,
            distanceMeters: comparisonDistance
        )
        let primaryMoving = primaryContext.movementProfile?.totalMovingSeconds
            ?? primaryTimeline.totalActiveSeconds
        let comparisonMoving = comparisonContext.movementProfile?.totalMovingSeconds
            ?? comparisonTimeline.totalActiveSeconds
        let primaryStopped = max(0, primaryTimeline.totalActiveSeconds - primaryMoving)
        let comparisonStopped = max(0, comparisonTimeline.totalActiveSeconds - comparisonMoving)
        let primaryMovingPace = pace(seconds: primaryMoving, distanceMeters: primaryDistance)
        let comparisonMovingPace = pace(seconds: comparisonMoving, distanceMeters: comparisonDistance)
        let primaryElevationGain = primaryContext.elevationProfile.hasMeaningfulElevation
            ? primaryContext.elevationProfile.totalAscentMeters.map(finiteNonNegative)
            : nil
        let comparisonElevationGain = comparisonContext.elevationProfile.hasMeaningfulElevation
            ? comparisonContext.elevationProfile.totalAscentMeters.map(finiteNonNegative)
            : nil

        return WorkoutComparisonSummary(
            primaryTitle: primary.displayName,
            comparisonTitle: comparison.displayName,
            primaryDistanceMeters: primaryDistance,
            comparisonDistanceMeters: comparisonDistance,
            distanceDeltaMeters: primaryDistance - comparisonDistance,
            primaryElapsedSeconds: primaryTimeline.totalElapsedSeconds,
            comparisonElapsedSeconds: comparisonTimeline.totalElapsedSeconds,
            elapsedTimeDeltaSeconds: primaryTimeline.totalElapsedSeconds - comparisonTimeline.totalElapsedSeconds,
            primaryActiveSeconds: primaryTimeline.totalActiveSeconds,
            comparisonActiveSeconds: comparisonTimeline.totalActiveSeconds,
            activeTimeDeltaSeconds: primaryTimeline.totalActiveSeconds - comparisonTimeline.totalActiveSeconds,
            primaryPausedSeconds: primaryTimeline.totalPausedSeconds,
            comparisonPausedSeconds: comparisonTimeline.totalPausedSeconds,
            pausedTimeDeltaSeconds: primaryTimeline.totalPausedSeconds - comparisonTimeline.totalPausedSeconds,
            primaryMovingSeconds: primaryMoving,
            comparisonMovingSeconds: comparisonMoving,
            movingTimeDeltaSeconds: primaryMoving - comparisonMoving,
            primaryStoppedSeconds: primaryStopped,
            comparisonStoppedSeconds: comparisonStopped,
            stoppedTimeDeltaSeconds: primaryStopped - comparisonStopped,
            primaryMovingPaceSecondsPerKm: primaryMovingPace,
            comparisonMovingPaceSecondsPerKm: comparisonMovingPace,
            movingPaceDeltaSecondsPerKm: primaryMovingPace - comparisonMovingPace,
            primaryPaceSecondsPerKm: primaryActivePace,
            comparisonPaceSecondsPerKm: comparisonActivePace,
            paceDeltaSecondsPerKm: primaryActivePace - comparisonActivePace,
            primaryElapsedPaceSecondsPerKm: primaryElapsedPace,
            comparisonElapsedPaceSecondsPerKm: comparisonElapsedPace,
            elapsedPaceDeltaSecondsPerKm: primaryElapsedPace - comparisonElapsedPace,
            primaryElevationGainMeters: primaryElevationGain,
            comparisonElevationGainMeters: comparisonElevationGain,
            elevationGainDeltaMeters: optionalDifference(
                primaryElevationGain,
                comparisonElevationGain
            ),
            primaryAvgHR: finite(primary.summary.averageHeartRateBPM),
            comparisonAvgHR: finite(comparison.summary.averageHeartRateBPM),
            avgHRDelta: difference(primary.summary.averageHeartRateBPM, comparison.summary.averageHeartRateBPM),
            primaryMaxHR: finite(primary.summary.maxHeartRateBPM),
            comparisonMaxHR: finite(comparison.summary.maxHeartRateBPM),
            maxHRDelta: difference(primary.summary.maxHeartRateBPM, comparison.summary.maxHeartRateBPM),
            primaryPointCount: primary.routePoints.count,
            comparisonPointCount: comparison.routePoints.count,
            warnings: generateWarnings(
                primary: primary,
                comparison: comparison,
                primaryTimeline: primaryTimeline,
                comparisonTimeline: comparisonTimeline,
                commonDistanceMeters: min(primaryDistance, comparisonDistance),
                primaryElevationProfile: primaryContext.elevationProfile,
                comparisonElevationProfile: comparisonContext.elevationProfile
            )
        )
    }

    public func compareSplits(primary: RunWorkout, comparison: RunWorkout) -> [SplitComparison] {
        let count = max(primary.splits.count, comparison.splits.count)
        return (0..<count).map { index in
            let primarySplit = primary.splits.indices.contains(index) ? primary.splits[index] : nil
            let comparisonSplit = comparison.splits.indices.contains(index) ? comparison.splits[index] : nil
            let elapsedDelta = optionalDifference(primarySplit?.elapsedSeconds, comparisonSplit?.elapsedSeconds)
            let activeDelta = optionalDifference(primarySplit?.activeSeconds, comparisonSplit?.activeSeconds)
            let movingDelta = optionalDifference(primarySplit?.movingSeconds, comparisonSplit?.movingSeconds)
            let stoppedDelta = optionalDifference(primarySplit?.stoppedSeconds, comparisonSplit?.stoppedSeconds)
            let paceDelta = optionalDifference(
                primarySplit?.paceSecondsPerKilometer,
                comparisonSplit?.paceSecondsPerKilometer
            )
            let winner: ComparisonResult
            if let paceDelta, paceDelta.isFinite {
                winner = abs(paceDelta) < 5 ? .tie : (paceDelta > 0 ? .comparison : .primary)
            } else {
                winner = .unavailable
            }

            return SplitComparison(
                splitIndex: index + 1,
                primarySplit: primarySplit,
                comparisonSplit: comparisonSplit,
                elapsedDurationDeltaSeconds: elapsedDelta,
                activeDurationDeltaSeconds: activeDelta,
                movingDurationDeltaSeconds: movingDelta,
                stoppedDurationDeltaSeconds: stoppedDelta,
                paceDeltaSecondsPerKm: paceDelta,
                winner: winner
            )
        }
    }

    /// Ordinal recorded-lap comparison only. Does not invent route-aligned laps.
    public func compareRecordedLaps(
        primary: RunWorkout,
        comparison: RunWorkout
    ) -> [RecordedLapComparison] {
        let primaryLaps = primary.recordedLaps
        let comparisonLaps = comparison.recordedLaps
        guard !primaryLaps.isEmpty || !comparisonLaps.isEmpty else { return [] }

        let count = max(primaryLaps.count, comparisonLaps.count)
        var rows: [RecordedLapComparison] = []
        rows.reserveCapacity(count)

        for index in 0..<count {
            let primaryLap = primaryLaps.indices.contains(index) ? primaryLaps[index] : nil
            let comparisonLap = comparisonLaps.indices.contains(index) ? comparisonLaps[index] : nil
            var caveats: [String] = []

            if primaryLaps.isEmpty {
                caveats.append("Selected run has no recorded laps")
            } else if comparisonLaps.isEmpty {
                caveats.append("Compared run has no recorded laps")
            }
            if primary.mayRequireReimportForRecordedLaps {
                caveats.append("Selected run may require reimport to recover source laps")
            }
            if comparison.mayRequireReimportForRecordedLaps {
                caveats.append("Compared run may require reimport to recover source laps")
            }
            if primaryLaps.count != comparisonLaps.count {
                caveats.append("Lap counts differ (\(primaryLaps.count) vs \(comparisonLaps.count))")
            }
            if let primaryLap, let comparisonLap {
                if primaryLap.trigger != comparisonLap.trigger {
                    caveats.append("Trigger types differ")
                }
                let distanceDelta = abs(primaryLap.distanceMeters - comparisonLap.distanceMeters)
                if distanceDelta > max(50, primaryLap.distanceMeters * 0.05) {
                    caveats.append("Lap distances differ materially")
                }
            }

            let paceDelta = optionalDifference(
                positiveFinite(primaryLap?.activePaceSecondsPerKilometer),
                positiveFinite(comparisonLap?.activePaceSecondsPerKilometer)
            )
            let winner: ComparisonResult
            if let paceDelta, paceDelta.isFinite {
                winner = abs(paceDelta) < 5 ? .tie : (paceDelta > 0 ? .comparison : .primary)
            } else {
                winner = .unavailable
            }

            rows.append(RecordedLapComparison(
                lapIndex: index + 1,
                primaryLap: primaryLap,
                comparisonLap: comparisonLap,
                distanceDeltaMeters: optionalDifference(
                    primaryLap?.distanceMeters,
                    comparisonLap?.distanceMeters
                ),
                elapsedDurationDeltaSeconds: optionalDifference(
                    primaryLap?.elapsedSeconds,
                    comparisonLap?.elapsedSeconds
                ),
                activeDurationDeltaSeconds: optionalDifference(
                    primaryLap?.activeSeconds,
                    comparisonLap?.activeSeconds
                ),
                movingDurationDeltaSeconds: optionalDifference(
                    primaryLap?.movingSeconds,
                    comparisonLap?.movingSeconds
                ),
                stoppedDurationDeltaSeconds: optionalDifference(
                    primaryLap?.stoppedSeconds,
                    comparisonLap?.stoppedSeconds
                ),
                activePaceDeltaSecondsPerKm: paceDelta,
                movingPaceDeltaSecondsPerKm: optionalDifference(
                    positiveFinite(primaryLap?.movingPaceSecondsPerKilometer),
                    positiveFinite(comparisonLap?.movingPaceSecondsPerKilometer)
                ),
                averageHRDelta: difference(
                    primaryLap?.averageHeartRateBPM,
                    comparisonLap?.averageHeartRateBPM
                ),
                elevationGainDeltaMeters: optionalDifference(
                    primaryLap?.elevationGainMeters,
                    comparisonLap?.elevationGainMeters
                ),
                winner: winner,
                caveats: Array(Set(caveats)).sorted()
            ))
        }

        return rows
    }

    public func compareMetricsOverDistance(
        primary: RunWorkout,
        comparison: RunWorkout,
        sampleIntervalMeters: Double = 100
    ) -> [ComparisonMetricPoint] {
        compareMetricsOverDistance(
            primary: primary,
            comparison: comparison,
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison),
            sampleIntervalMeters: sampleIntervalMeters
        )
    }

    public func compareMetricsOverDistance(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        sampleIntervalMeters: Double = 100
    ) -> [ComparisonMetricPoint] {
        guard !primary.routePoints.isEmpty,
              !comparison.routePoints.isEmpty,
              sampleIntervalMeters.isFinite,
              sampleIntervalMeters > 0
        else {
            return []
        }

        let maximumDistance = min(
            primaryContext.timeline.totalDistanceMeters,
            comparisonContext.timeline.totalDistanceMeters
        )
        guard maximumDistance > 0 else { return [] }

        var result: [ComparisonMetricPoint] = []
        let routePointCount = max(primary.routePoints.count, comparison.routePoints.count)
        let maximumSampleCount = RouteAnalysisBudget.maximumEvaluations(
            forRoutePointCount: routePointCount
        )
        let effectiveInterval = RouteAnalysisBudget.boundedStep(
            preferredStep: sampleIntervalMeters,
            distanceSpan: maximumDistance,
            routePointCount: routePointCount
        )
        result.reserveCapacity(maximumSampleCount)

        func metricPoint(at distance: Double) -> ComparisonMetricPoint {
            let primaryPoint = RoutePointInterpolator.point(at: distance, in: primary.routePoints)
            let comparisonPoint = RoutePointInterpolator.point(at: distance, in: comparison.routePoints)
            let primaryPace = positiveFinite(primaryPoint?.paceSecondsPerKilometer)
            let comparisonPace = positiveFinite(comparisonPoint?.paceSecondsPerKilometer)

            return ComparisonMetricPoint(
                distanceMeters: distance,
                primaryPace: primaryPace,
                comparisonPace: comparisonPace,
                paceDelta: optionalDifference(primaryPace, comparisonPace),
                primaryElevation: primaryContext.elevationProfile.correctedAltitude(
                    atDistance: distance,
                    boundary: .rangeEnd
                ),
                comparisonElevation: comparisonContext.elevationProfile.correctedAltitude(
                    atDistance: distance,
                    boundary: .rangeEnd
                ),
                primaryHR: finite(primaryPoint?.heartRateBPM),
                comparisonHR: finite(comparisonPoint?.heartRateBPM)
            )
        }

        for sampleIndex in 0..<maximumSampleCount {
            let distance = Double(sampleIndex) * effectiveInterval
            guard distance.isFinite, distance <= maximumDistance else { break }
            result.append(metricPoint(at: distance))
        }
        if result.count < maximumSampleCount,
           let lastDistance = result.last?.distanceMeters,
           lastDistance < maximumDistance {
            result.append(metricPoint(at: maximumDistance))
        }
        return result
    }

    public func commonDistance(primary: RunWorkout, comparison: RunWorkout) -> Double {
        min(
            WorkoutTimeline(workout: primary).totalDistanceMeters,
            WorkoutTimeline(workout: comparison).totalDistanceMeters
        )
    }

    public func metricsAtDistance(
        _ selectedDistance: Double,
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryScenePoints: [RouteScenePoint] = [],
        comparisonScenePoints: [RouteScenePoint] = []
    ) -> ComparisonDistanceMetrics {
        // This convenience overload is for one-off callers. High-frequency UI
        // updates must use the context-taking overload with cached analysis.
        metricsAtDistance(
            selectedDistance,
            primary: primary,
            comparison: comparison,
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison),
            primaryScenePoints: primaryScenePoints,
            comparisonScenePoints: comparisonScenePoints
        )
    }

    public func metricsAtDistance(
        _ selectedDistance: Double,
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        primaryScenePoints: [RouteScenePoint] = [],
        comparisonScenePoints: [RouteScenePoint] = []
    ) -> ComparisonDistanceMetrics {
        guard selectedDistance.isFinite, selectedDistance >= 0 else {
            return emptyDistanceMetrics
        }

        let primaryTimeline = primaryContext.timeline
        let comparisonTimeline = comparisonContext.timeline
        let clampedDistance = min(
            selectedDistance,
            min(primaryTimeline.totalDistanceMeters, comparisonTimeline.totalDistanceMeters)
        )
        let primarySample = primaryTimeline.distanceSample(at: clampedDistance, boundary: .rangeEnd)
        let comparisonSample = comparisonTimeline.distanceSample(at: clampedDistance, boundary: .rangeEnd)
        let primaryElapsed = primarySample?.elapsedSeconds
        let comparisonElapsed = comparisonSample?.elapsedSeconds
        let primaryActive = primarySample?.activeSeconds
        let comparisonActive = comparisonSample?.activeSeconds
        let primaryMoving = primarySample.flatMap {
            primaryContext.movementProfile?.movingSeconds(
                at: $0,
                boundary: .rangeEnd,
                timeline: primaryTimeline
            )
        }
        let comparisonMoving = comparisonSample.flatMap {
            comparisonContext.movementProfile?.movingSeconds(
                at: $0,
                boundary: .rangeEnd,
                timeline: comparisonTimeline
            )
        }
        let primaryStopped = primarySample.flatMap {
            primaryContext.movementProfile?.stoppedSeconds(
                at: $0,
                boundary: .rangeEnd,
                timeline: primaryTimeline
            )
        }
        let comparisonStopped = comparisonSample.flatMap {
            comparisonContext.movementProfile?.stoppedSeconds(
                at: $0,
                boundary: .rangeEnd,
                timeline: comparisonTimeline
            )
        }
        let coveredDistance = clampedDistance - max(
            primaryTimeline.startDistanceMeters,
            comparisonTimeline.startDistanceMeters
        )
        let primaryPace = cumulativePace(seconds: primaryActive, distanceMeters: coveredDistance)
        let comparisonPace = cumulativePace(seconds: comparisonActive, distanceMeters: coveredDistance)

        return ComparisonDistanceMetrics(
            selectedDistanceMeters: clampedDistance,
            primaryElapsedSeconds: primaryElapsed,
            comparisonElapsedSeconds: comparisonElapsed,
            timeDeltaSeconds: optionalDifference(primaryElapsed, comparisonElapsed),
            primaryPaceSecondsPerKm: primaryPace,
            comparisonPaceSecondsPerKm: comparisonPace,
            paceDeltaSecondsPerKm: optionalDifference(primaryPace, comparisonPace),
            primaryActiveSeconds: primaryActive,
            comparisonActiveSeconds: comparisonActive,
            activeTimeDeltaSeconds: optionalDifference(primaryActive, comparisonActive),
            primaryMovingSeconds: primaryMoving,
            comparisonMovingSeconds: comparisonMoving,
            movingTimeDeltaSeconds: optionalDifference(primaryMoving, comparisonMoving),
            primaryStoppedSeconds: primaryStopped,
            comparisonStoppedSeconds: comparisonStopped,
            stoppedTimeDeltaSeconds: optionalDifference(primaryStopped, comparisonStopped),
            primaryScenePoint: RoutePointInterpolator.scenePoint(at: clampedDistance, in: primaryScenePoints),
            comparisonScenePoint: RoutePointInterpolator.scenePoint(at: clampedDistance, in: comparisonScenePoints)
        )
    }

    private var emptyDistanceMetrics: ComparisonDistanceMetrics {
        ComparisonDistanceMetrics(
            selectedDistanceMeters: 0,
            primaryElapsedSeconds: nil,
            comparisonElapsedSeconds: nil,
            timeDeltaSeconds: nil,
            primaryPaceSecondsPerKm: nil,
            comparisonPaceSecondsPerKm: nil,
            paceDeltaSecondsPerKm: nil,
            primaryActiveSeconds: nil,
            comparisonActiveSeconds: nil,
            activeTimeDeltaSeconds: nil,
            primaryMovingSeconds: nil,
            comparisonMovingSeconds: nil,
            movingTimeDeltaSeconds: nil,
            primaryStoppedSeconds: nil,
            comparisonStoppedSeconds: nil,
            stoppedTimeDeltaSeconds: nil,
            primaryScenePoint: nil,
            comparisonScenePoint: nil
        )
    }

    private func generateWarnings(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryTimeline: WorkoutTimeline,
        comparisonTimeline: WorkoutTimeline,
        commonDistanceMeters: Double,
        primaryElevationProfile: ElevationProfile,
        comparisonElevationProfile: ElevationProfile
    ) -> [ComparisonWarning] {
        var warnings: [ComparisonWarning] = []
        let primaryDistance = primaryTimeline.totalDistanceMeters
        let comparisonDistance = comparisonTimeline.totalDistanceMeters
        let distanceRatio = primaryDistance > 0 ? comparisonDistance / primaryDistance : 0

        if distanceRatio < 0.7 || distanceRatio > 1.4 { warnings.append(.differentDistances) }
        if min(primaryDistance, comparisonDistance) < 500 { warnings.append(.insufficientOverlap) }
        if primary.routePoints.count < 10 || comparison.routePoints.count < 10 { warnings.append(.tooFewPoints) }
        if routeEndpointsDiffer(
            primary: primary,
            comparison: comparison,
            commonDistanceMeters: commonDistanceMeters
        ) {
            warnings.append(.differentRouteShape)
        }
        if abs(primaryTimeline.totalPausedSeconds - comparisonTimeline.totalPausedSeconds)
            >= Self.pauseDurationWarningThresholdSeconds {
            warnings.append(.differentPauseDurations)
        }
        if !primary.hasHeartRateData || !comparison.hasHeartRateData { warnings.append(.missingHeartRate) }
        if !primaryElevationProfile.hasMeaningfulElevation
            || !comparisonElevationProfile.hasMeaningfulElevation {
            warnings.append(.missingElevation)
        }
        if primary.movementDiagnostics.stoppedIntervalCount > 0 || comparison.movementDiagnostics.stoppedIntervalCount > 0 {
            warnings.append(.movementEstimated)
        }
        if primary.movementDiagnostics.usedConservativeFallback
            != comparison.movementDiagnostics.usedConservativeFallback {
            warnings.append(.movementEstimateReliabilityDiffers)
        }
        return warnings
    }

    private func routeEndpointsDiffer(
        primary: RunWorkout,
        comparison: RunWorkout,
        commonDistanceMeters common: Double
    ) -> Bool {
        guard common > 0 else { return false }
        let threshold = max(200, min(common * 0.1, 1000))
        return [0, common * 0.5, common].contains { distance in
            guard let primaryPoint = RoutePointInterpolator.point(at: distance, in: primary.routePoints),
                  let comparisonPoint = RoutePointInterpolator.point(at: distance, in: comparison.routePoints)
            else {
                return false
            }
            return coordinateDistance(primaryPoint, comparisonPoint) > threshold
        }
    }

    private func coordinateDistance(_ first: RoutePoint, _ second: RoutePoint) -> Double {
        guard GeoDistance.isValidCoordinate(lat: first.latitude, lon: first.longitude),
              GeoDistance.isValidCoordinate(lat: second.latitude, lon: second.longitude)
        else {
            return .infinity
        }
        return GeoDistance.distanceMeters(
            fromLat: first.latitude,
            lon: first.longitude,
            toLat: second.latitude,
            lon: second.longitude
        )
    }

    private func pace(seconds: Double, distanceMeters: Double) -> Double {
        guard seconds.isFinite, seconds > 0, distanceMeters.isFinite, distanceMeters > 0 else { return 0 }
        return (seconds / distanceMeters) * 1000
    }

    private func cumulativePace(seconds: Double?, distanceMeters: Double) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 0, distanceMeters.isFinite, distanceMeters > 0 else {
            return nil
        }
        return (seconds / distanceMeters) * 1000
    }

    private func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private func positiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func finiteNonNegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private func difference(_ first: Double?, _ second: Double?) -> Double? {
        optionalDifference(first, second)
    }

    private func optionalDifference(_ first: Double?, _ second: Double?) -> Double? {
        guard let first, let second, first.isFinite, second.isFinite else { return nil }
        return first - second
    }
}
