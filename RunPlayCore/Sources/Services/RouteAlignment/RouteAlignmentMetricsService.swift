import Foundation

/// Builds matched-section metrics and chart series from an alignment snapshot.
///
/// Does not recompute DTW. Clocks begin at each alignment block's start anchor.
public struct RouteAlignmentMetricsService: Sendable {
    public init() {}

    public func metrics(
        atAlignedProgress progress: Double,
        snapshot: RouteAlignmentSnapshot,
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext
    ) -> ComparisonAlignedMetrics {
        guard snapshot.availability.isAvailable,
              let position = snapshot.positions(atAlignedProgress: progress),
              snapshot.blocks.indices.contains(position.blockIndex)
        else {
            return .empty
        }

        let block = snapshot.blocks[position.blockIndex]
        guard let blockStart = block.anchors.first else { return .empty }

        let primaryTimeline = primaryContext.timeline
        let comparisonTimeline = comparisonContext.timeline

        let primaryNow = primaryTimeline.distanceSample(
            at: position.primaryDistanceMeters,
            boundary: .rangeEnd
        )
        let comparisonNow = comparisonTimeline.distanceSample(
            at: position.comparisonDistanceMeters,
            boundary: .rangeEnd
        )
        let primaryStart = primaryTimeline.distanceSample(
            at: blockStart.primaryDistanceMeters,
            boundary: .rangeEnd
        )
        let comparisonStart = comparisonTimeline.distanceSample(
            at: blockStart.comparisonDistanceMeters,
            boundary: .rangeEnd
        )

        let primaryElapsed = matchedClock(
            current: primaryNow?.elapsedSeconds,
            start: primaryStart?.elapsedSeconds
        )
        let comparisonElapsed = matchedClock(
            current: comparisonNow?.elapsedSeconds,
            start: comparisonStart?.elapsedSeconds
        )
        let primaryActive = matchedClock(
            current: primaryNow?.activeSeconds,
            start: primaryStart?.activeSeconds
        )
        let comparisonActive = matchedClock(
            current: comparisonNow?.activeSeconds,
            start: comparisonStart?.activeSeconds
        )

        func moving(at sample: WorkoutTimeline.DistanceSample?, context: WorkoutAnalysisContext, timeline: WorkoutTimeline) -> Double? {
            guard let sample else { return nil }
            return context.movementProfile?.movingSeconds(
                at: sample,
                boundary: .rangeEnd,
                timeline: timeline
            )
        }
        func stopped(at sample: WorkoutTimeline.DistanceSample?, context: WorkoutAnalysisContext, timeline: WorkoutTimeline) -> Double? {
            guard let sample else { return nil }
            return context.movementProfile?.stoppedSeconds(
                at: sample,
                boundary: .rangeEnd,
                timeline: timeline
            )
        }

        let primaryMoving = matchedClock(
            current: moving(at: primaryNow, context: primaryContext, timeline: primaryTimeline),
            start: moving(at: primaryStart, context: primaryContext, timeline: primaryTimeline)
        )
        let comparisonMoving = matchedClock(
            current: moving(at: comparisonNow, context: comparisonContext, timeline: comparisonTimeline),
            start: moving(at: comparisonStart, context: comparisonContext, timeline: comparisonTimeline)
        )
        let primaryStopped = matchedClock(
            current: stopped(at: primaryNow, context: primaryContext, timeline: primaryTimeline),
            start: stopped(at: primaryStart, context: primaryContext, timeline: primaryTimeline)
        )
        let comparisonStopped = matchedClock(
            current: stopped(at: comparisonNow, context: comparisonContext, timeline: comparisonTimeline),
            start: stopped(at: comparisonStart, context: comparisonContext, timeline: comparisonTimeline)
        )

        let primaryMatchedDistance = max(
            0,
            position.primaryDistanceMeters - blockStart.primaryDistanceMeters
        )
        let comparisonMatchedDistance = max(
            0,
            position.comparisonDistanceMeters - blockStart.comparisonDistanceMeters
        )
        let primaryPace = pace(seconds: primaryActive, distanceMeters: primaryMatchedDistance)
        let comparisonPace = pace(seconds: comparisonActive, distanceMeters: comparisonMatchedDistance)

        return ComparisonAlignedMetrics(
            alignedProgressMeters: position.alignedProgressMeters,
            totalAlignedDistanceMeters: snapshot.totalAlignedDistanceMeters,
            blockIndex: position.blockIndex,
            primaryDistanceMeters: position.primaryDistanceMeters,
            comparisonDistanceMeters: position.comparisonDistanceMeters,
            spatialSeparationMeters: position.spatialSeparationMeters,
            primaryElapsedSeconds: primaryElapsed,
            comparisonElapsedSeconds: comparisonElapsed,
            elapsedDeltaSeconds: optionalDifference(primaryElapsed, comparisonElapsed),
            primaryActiveSeconds: primaryActive,
            comparisonActiveSeconds: comparisonActive,
            activeDeltaSeconds: optionalDifference(primaryActive, comparisonActive),
            primaryMovingSeconds: primaryMoving,
            comparisonMovingSeconds: comparisonMoving,
            movingDeltaSeconds: optionalDifference(primaryMoving, comparisonMoving),
            primaryStoppedSeconds: primaryStopped,
            comparisonStoppedSeconds: comparisonStopped,
            stoppedDeltaSeconds: optionalDifference(primaryStopped, comparisonStopped),
            primaryActivePaceSecondsPerKm: primaryPace,
            comparisonActivePaceSecondsPerKm: comparisonPace,
            activePaceDeltaSecondsPerKm: optionalDifference(primaryPace, comparisonPace)
        )
    }

    public func chartPoints(
        snapshot: RouteAlignmentSnapshot,
        primary: RunWorkout,
        comparison: RunWorkout,
        policy: RouteAlignmentPolicy = .default
    ) -> [AlignedComparisonMetricPoint] {
        guard snapshot.availability.isAvailable, !snapshot.blocks.isEmpty else { return [] }

        var points: [AlignedComparisonMetricPoint] = []
        let maxCount = max(1, policy.maximumChartSampleCount)
        let preferred = policy.preferredChartSampleIntervalMeters.isFinite
            && policy.preferredChartSampleIntervalMeters > 0
            ? policy.preferredChartSampleIntervalMeters
            : 50

        for block in snapshot.blocks {
            guard let first = block.anchors.first, let last = block.anchors.last else { continue }
            let span = max(0, last.alignedProgressMeters - first.alignedProgressMeters)
            let step = max(preferred, span / Double(max(1, maxCount / max(1, snapshot.blocks.count) - 1)))
            var progress = first.alignedProgressMeters
            var emittedInBlock = 0
            while progress <= last.alignedProgressMeters + 1e-6 {
                if points.count >= maxCount { return points }
                if let position = snapshot.positions(atAlignedProgress: progress) {
                    let primaryPoint = RoutePointInterpolator.point(
                        at: position.primaryDistanceMeters,
                        in: primary.routePoints
                    )
                    let comparisonPoint = RoutePointInterpolator.point(
                        at: position.comparisonDistanceMeters,
                        in: comparison.routePoints
                    )
                    let primaryPace = positiveFinite(primaryPoint?.paceSecondsPerKilometer)
                    let comparisonPace = positiveFinite(comparisonPoint?.paceSecondsPerKilometer)
                    points.append(
                        AlignedComparisonMetricPoint(
                            alignedProgressMeters: position.alignedProgressMeters,
                            primaryDistanceMeters: position.primaryDistanceMeters,
                            comparisonDistanceMeters: position.comparisonDistanceMeters,
                            primaryPace: primaryPace,
                            comparisonPace: comparisonPace,
                            paceDelta: optionalDifference(primaryPace, comparisonPace),
                            spatialSeparationMeters: position.spatialSeparationMeters,
                            blockIndex: block.id
                        )
                    )
                }
                emittedInBlock += 1
                if progress >= last.alignedProgressMeters { break }
                progress = min(last.alignedProgressMeters, progress + step)
                if emittedInBlock > maxCount { break }
            }
        }
        return points
    }

    private func matchedClock(current: Double?, start: Double?) -> Double? {
        guard let current, let start, current.isFinite, start.isFinite else { return nil }
        return max(0, current - start)
    }

    private func pace(seconds: Double?, distanceMeters: Double) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 0,
              distanceMeters.isFinite, distanceMeters > 0 else { return nil }
        return (seconds / distanceMeters) * 1000
    }

    private func positiveFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func optionalDifference(_ first: Double?, _ second: Double?) -> Double? {
        guard let first, let second, first.isFinite, second.isFinite else { return nil }
        return first - second
    }
}
