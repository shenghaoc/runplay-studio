import Foundation

/// Estimated per-interval movement classification derived from normalised
/// route points, the authoritative `WorkoutTimeline`, and a central policy.
///
/// `MovementProfile` does not mutate route points. It only classifies time.
/// Its primary consumers are `WorkoutAnalyzer` (summary, splits),
/// `PlaybackEngine` (replay state), and comparison/export services.
///
/// The two-pass algorithm first classifies each consecutive point pair using
/// geometry-first evidence, then applies hysteresis and dwell rules to merge
/// short blips into their surrounding state.
public struct MovementProfile: Sendable {
    /// Movement state for each consecutive point pair within the same route
    /// segment. `states[i]` describes the interval between `routePoints[i]`
    /// and `routePoints[i+1]`. Inter-segment boundaries are `.paused`.
    public let states: [MovementState]

    /// Cumulative moving seconds at each route point index.
    public let movingSecondsByPoint: [Double]

    /// Cumulative stopped seconds at each route point index.
    public let stoppedSecondsByPoint: [Double]

    /// Total estimated moving seconds across the workout.
    public let totalMovingSeconds: Double

    /// Total estimated stopped seconds across the workout.
    public let totalStoppedSeconds: Double

    /// Diagnostics describing detection reliability.
    public let diagnostics: MovementDiagnostics

    // MARK: - Public queries

    /// Movement state for the interval starting at a point index.
    public func state(atPointIndex index: Int) -> MovementState? {
        guard states.indices.contains(index) else { return nil }
        return states[index]
    }

    /// Cumulative moving seconds at a point index.
    public func movingSeconds(atPointIndex index: Int) -> Double? {
        guard movingSecondsByPoint.indices.contains(index) else { return nil }
        return movingSecondsByPoint[index]
    }

    /// Cumulative stopped seconds at a point index.
    public func stoppedSeconds(atPointIndex index: Int) -> Double? {
        guard stoppedSecondsByPoint.indices.contains(index) else { return nil }
        return stoppedSecondsByPoint[index]
    }

    /// Moving time within a distance range, using the timeline's boundary rules.
    public func movingSeconds(from startDistance: Double,
                               to endDistance: Double,
                               timeline: WorkoutTimeline) -> Double? {
        guard let range = timeline.distanceRange(from: startDistance, to: endDistance),
              let startMoving = movingSeconds(at: range.start, boundary: .rangeStart, timeline: timeline),
              let endMoving = movingSeconds(at: range.end, boundary: .rangeEnd, timeline: timeline)
        else {
            return nil
        }
        return max(0, endMoving - startMoving)
    }

    /// Stopped time within a distance range.
    public func stoppedSeconds(from startDistance: Double,
                                to endDistance: Double,
                                timeline: WorkoutTimeline) -> Double? {
        guard let range = timeline.distanceRange(from: startDistance, to: endDistance),
              let startStopped = stoppedSeconds(at: range.start, boundary: .rangeStart, timeline: timeline),
              let endStopped = stoppedSeconds(at: range.end, boundary: .rangeEnd, timeline: timeline)
        else {
            return nil
        }
        return max(0, endStopped - startStopped)
    }

    /// Cumulative moving time at a timeline distance sample. The boundary role
    /// preserves the timeline's duplicate-distance policy and proportionally
    /// includes a partial continuous interval.
    public func movingSeconds(
        at sample: WorkoutTimeline.DistanceSample,
        boundary: WorkoutDistanceBoundaryRole,
        timeline: WorkoutTimeline
    ) -> Double? {
        interpolatedCumulative(
            movingSecondsByPoint,
            at: sample,
            boundary: boundary,
            timeline: timeline
        )
    }

    /// Cumulative stopped time at a timeline distance sample. The boundary role
    /// preserves the timeline's duplicate-distance policy and proportionally
    /// includes a partial continuous interval.
    public func stoppedSeconds(
        at sample: WorkoutTimeline.DistanceSample,
        boundary: WorkoutDistanceBoundaryRole,
        timeline: WorkoutTimeline
    ) -> Double? {
        interpolatedCumulative(
            stoppedSecondsByPoint,
            at: sample,
            boundary: boundary,
            timeline: timeline
        )
    }

    private func interpolatedCumulative(
        _ cumulative: [Double],
        at sample: WorkoutTimeline.DistanceSample,
        boundary: WorkoutDistanceBoundaryRole,
        timeline: WorkoutTimeline
    ) -> Double? {
        guard cumulative.indices.contains(sample.pointIndex) else { return nil }
        guard sample.isInterpolated else { return cumulative[sample.pointIndex] }

        let before = boundary == .rangeStart ? sample.pointIndex - 1 : sample.pointIndex
        let after = boundary == .rangeStart ? sample.pointIndex : sample.pointIndex + 1
        guard cumulative.indices.contains(before), cumulative.indices.contains(after),
              let startActive = timeline.activeSeconds(atPointIndex: before),
              let endActive = timeline.activeSeconds(atPointIndex: after),
              endActive > startActive
        else { return cumulative[sample.pointIndex] }

        let fraction = min(1, max(0, (sample.activeSeconds - startActive) / (endActive - startActive)))
        return cumulative[before] + (cumulative[after] - cumulative[before]) * fraction
    }

    /// Movement state at an elapsed replay time.
    public func state(atElapsedTime time: Double, timeline: WorkoutTimeline) -> MovementState {
        guard let sample = timeline.replaySample(atElapsedTime: time) else {
            return .uncertain
        }
        if sample.isInRecordingGap { return .paused }
        let idx = sample.pointIndex
        guard states.indices.contains(idx) else { return .uncertain }
        return states[idx]
    }

    /// Moving time within an elapsed-time range.
    public func movingSeconds(
        fromElapsed startElapsed: Double,
        toElapsed endElapsed: Double,
        timeline: WorkoutTimeline
    ) -> Double? {
        guard let range = timeline.timeRange(from: startElapsed, to: endElapsed),
              let startMoving = movingSeconds(atElapsed: range.start, timeline: timeline),
              let endMoving = movingSeconds(atElapsed: range.end, timeline: timeline)
        else {
            return nil
        }
        return max(0, endMoving - startMoving)
    }

    /// Stopped time within an elapsed-time range.
    public func stoppedSeconds(
        fromElapsed startElapsed: Double,
        toElapsed endElapsed: Double,
        timeline: WorkoutTimeline
    ) -> Double? {
        guard let range = timeline.timeRange(from: startElapsed, to: endElapsed),
              let startStopped = stoppedSeconds(atElapsed: range.start, timeline: timeline),
              let endStopped = stoppedSeconds(atElapsed: range.end, timeline: timeline)
        else {
            return nil
        }
        return max(0, endStopped - startStopped)
    }

    /// Cumulative moving time at an elapsed-time sample.
    public func movingSeconds(
        atElapsed sample: WorkoutTimeline.ElapsedSample,
        timeline: WorkoutTimeline
    ) -> Double? {
        interpolatedCumulative(movingSecondsByPoint, atElapsed: sample, timeline: timeline)
    }

    /// Cumulative stopped time at an elapsed-time sample.
    public func stoppedSeconds(
        atElapsed sample: WorkoutTimeline.ElapsedSample,
        timeline: WorkoutTimeline
    ) -> Double? {
        interpolatedCumulative(stoppedSecondsByPoint, atElapsed: sample, timeline: timeline)
    }

    private func interpolatedCumulative(
        _ cumulative: [Double],
        atElapsed sample: WorkoutTimeline.ElapsedSample,
        timeline: WorkoutTimeline
    ) -> Double? {
        guard cumulative.indices.contains(sample.pointIndex) else { return nil }
        if sample.isInRecordingGap || !sample.isInterpolated {
            return cumulative[sample.pointIndex]
        }

        // Interpolate within the continuous interval surrounding the sample.
        let index = sample.pointIndex
        let before: Int
        let after: Int
        if index + 1 < cumulative.count,
           let nextActive = timeline.activeSeconds(atPointIndex: index + 1),
           let currentActive = timeline.activeSeconds(atPointIndex: index),
           nextActive > currentActive,
           sample.activeSeconds >= currentActive,
           sample.activeSeconds <= nextActive {
            before = index
            after = index + 1
        } else if index > 0,
                  let previousActive = timeline.activeSeconds(atPointIndex: index - 1),
                  let currentActive = timeline.activeSeconds(atPointIndex: index),
                  currentActive > previousActive {
            before = index - 1
            after = index
        } else {
            return cumulative[sample.pointIndex]
        }

        guard let startActive = timeline.activeSeconds(atPointIndex: before),
              let endActive = timeline.activeSeconds(atPointIndex: after),
              endActive > startActive
        else {
            return cumulative[sample.pointIndex]
        }
        let fraction = min(1, max(0, (sample.activeSeconds - startActive) / (endActive - startActive)))
        return cumulative[before] + (cumulative[after] - cumulative[before]) * fraction
    }

    // MARK: - Construction

    public init(
        routePoints: [RoutePoint],
        timeline: WorkoutTimeline,
        policy: MovementDetectionPolicy = .runningDefault,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws {
        let count = routePoints.count

        guard count >= 2 else {
            states = []
            movingSecondsByPoint = Array(repeating: 0.0, count: count)
            stoppedSecondsByPoint = Array(repeating: 0.0, count: count)
            totalMovingSeconds = 0
            totalStoppedSeconds = 0
            diagnostics = MovementDiagnostics(
                policyVersion: MovementDetectionPolicy.currentVersion,
                usedConservativeFallback: true
            )
            return
        }

        // Pass 1: classify each pair independently
        var rawStates: [MovementState] = []
        rawStates.reserveCapacity(count - 1)
        var activeDeltas: [Double] = []
        activeDeltas.reserveCapacity(count - 1)
        var distanceDeltas: [Double] = []
        distanceDeltas.reserveCapacity(count - 1)

        var reliableCount = 0

        for i in 0..<(count - 1) {
            if i % policy.cancellationCheckStride == 0, isCancelled() {
                throw CancellationError()
            }

            let current = routePoints[i]
            let next = routePoints[i + 1]

            guard next.routeSegmentIndex == current.routeSegmentIndex else {
                rawStates.append(.paused)
                activeDeltas.append(0)
                distanceDeltas.append(0)
                continue
            }

            let elapsed = Self.safeDifference(
                timeline.elapsedSeconds(atPointIndex: i + 1),
                timeline.elapsedSeconds(atPointIndex: i)
            )
            let activeDelta = Self.safeDifference(
                timeline.activeSeconds(atPointIndex: i + 1),
                timeline.activeSeconds(atPointIndex: i)
            )
            let distance = Self.safeDifference(
                next.distanceFromStartMeters,
                current.distanceFromStartMeters
            )
            let displacement = GeoDistance.distanceMeters(
                fromLat: current.latitude,
                lon: current.longitude,
                toLat: next.latitude,
                lon: next.longitude
            )

            let isReliable = elapsed >= policy.minimumReliableIntervalDurationSeconds
                && elapsed <= policy.maximumDirectSpeedIntervalDurationSeconds
            if isReliable { reliableCount += 1 }

            let geometricSpeed: Double = (elapsed > 0 && displacement.isFinite)
                ? displacement / elapsed : 0

            let isStationary: Bool
            if isReliable {
                isStationary = geometricSpeed <= policy.stopSpeedMetersPerSecond
                    && displacement <= policy.maximumStationaryRadiusMeters
                    && distance <= policy.maximumStationaryDriftMeters
            } else {
                isStationary = distance <= policy.maximumStationaryDriftMeters * 0.5
                    && displacement <= policy.maximumStationaryRadiusMeters * 0.5
            }

            let isMoving: Bool
            if isReliable {
                isMoving = geometricSpeed >= policy.resumeSpeedMetersPerSecond
                    && displacement > policy.maximumStationaryRadiusMeters
            } else {
                isMoving = distance > policy.maximumStationaryDriftMeters
                    || displacement > policy.maximumStationaryRadiusMeters * 2
            }

            if isStationary {
                rawStates.append(.stopped)
            } else if isMoving {
                rawStates.append(.moving)
            } else {
                rawStates.append(.uncertain)
            }
            activeDeltas.append(activeDelta)
            distanceDeltas.append(distance)
        }

        // Pass 2: apply hysteresis — merge short blips
        var merged = rawStates
        var i = 0

        while i < merged.count {
            guard merged[i] != .paused else { i += 1; continue }

            var runEnd = i
            while runEnd + 1 < merged.count,
                  merged[runEnd + 1] == merged[i],
                  merged[runEnd + 1] != .paused {
                runEnd += 1
            }

            let runDuration = activeDeltas[i...runEnd].reduce(0, +)
            let runDistance = distanceDeltas[i...runEnd].reduce(0, +)

            if merged[i] == .stopped, runDuration < policy.minimumStopDurationSeconds {
                for j in i...runEnd { merged[j] = .uncertain }
            } else if merged[i] == .moving,
                      runDuration < policy.minimumResumeDurationSeconds,
                      runDistance < policy.minimumResumeDistanceMeters {
                for j in i...runEnd { merged[j] = .uncertain }
            }

            i = runEnd + 1
        }

        let usedFallback = reliableCount < policy.minimumReliableSampleCount
        if usedFallback {
            // Sparse or irregular timing cannot support a trustworthy stop
            // estimate, so preserve the conservative active-time clock.
            for index in merged.indices where merged[index] == .stopped {
                merged[index] = .uncertain
            }
        }

        let stopCount = merged.filter { $0 == .stopped }.count
        let uncertainCount = merged.filter { $0 == .uncertain }.count

        // Build cumulative arrays: uncertain counts as moving (conservative)
        var movingCum: [Double] = []
        movingCum.reserveCapacity(count)
        var stoppedCum: [Double] = []
        stoppedCum.reserveCapacity(count)
        movingCum.append(0)
        stoppedCum.append(0)

        for i in 0..<merged.count {
            let delta = activeDeltas[i]
            switch merged[i] {
            case .moving, .uncertain:
                movingCum.append((movingCum.last ?? 0) + delta)
                stoppedCum.append(stoppedCum.last ?? 0)
            case .stopped:
                movingCum.append(movingCum.last ?? 0)
                stoppedCum.append((stoppedCum.last ?? 0) + delta)
            case .paused:
                movingCum.append(movingCum.last ?? 0)
                stoppedCum.append(stoppedCum.last ?? 0)
            }
        }

        // Enforce invariants
        let rawMoving = movingCum.last ?? 0
        let totalActive = timeline.totalActiveSeconds
        let totalMoving = min(Self.nonNegativeFinite(rawMoving), totalActive)
        let totalStopped = max(0, totalActive - totalMoving)

        states = merged
        movingSecondsByPoint = movingCum
        stoppedSecondsByPoint = stoppedCum
        totalMovingSeconds = totalMoving
        totalStoppedSeconds = totalStopped

        diagnostics = MovementDiagnostics(
            policyVersion: MovementDetectionPolicy.currentVersion,
            reliableIntervalCount: reliableCount,
            stoppedIntervalCount: stopCount,
            uncertainIntervalCount: uncertainCount,
            usedConservativeFallback: usedFallback,
            analysedPointPairCount: merged.count
        )
    }

    // MARK: - Helpers

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func safeDifference(_ later: Double?, _ earlier: Double?) -> Double {
        guard let later, let earlier, later.isFinite, earlier.isFinite else { return 0 }
        return max(0, later - earlier)
    }
}
