import Foundation

/// The role a cumulative-distance boundary plays in a forward range.
///
/// A pause can produce two route points at the same cumulative distance: the
/// final point before the pause and the first point after recording resumes.
/// Range starts select the resumed point; range ends select the pre-pause
/// endpoint. This keeps a pause exactly on a split boundary between the two
/// splits instead of assigning it to either one.
public enum WorkoutDistanceBoundaryRole: Sendable {
    case rangeStart
    case rangeEnd
}

/// The role an elapsed-time boundary plays in a forward time range.
///
/// Duplicate timestamps and recording gaps use the same partition rule as
/// distance boundaries: a range start owns the resume side; a range end owns
/// the hold side. Exact-boundary ownership for consecutive ranges is half-open
/// on the end (`[start, end)`), except the final sample of the workout which a
/// range end may include.
public enum WorkoutTimeBoundaryRole: Sendable {
    case rangeStart
    case rangeEnd
}

/// Platform-neutral authority for elapsed, active, pause, distance, and replay
/// time semantics.
///
/// Valid route timestamps define the elapsed clock. When timestamps do not
/// span but normalized points contain a valid elapsed series, that series is
/// used instead and is treated as active because pause boundaries are unknown.
/// Otherwise, the active clock sums only positive adjacent timestamp deltas
/// inside the same route segment. The original route points are never mutated.
public struct WorkoutTimeline: Sendable {

    /// Time values at a cumulative route distance.
    public struct DistanceSample: Sendable {
        public let distanceMeters: Double
        public let elapsedSeconds: Double
        public let activeSeconds: Double
        /// Deterministic real point selected for range metrics and seeking.
        public let pointIndex: Int
        public let isInterpolated: Bool
    }

    /// Aggregated clocks and source points for a forward distance range.
    public struct DistanceRange: Sendable {
        public let start: DistanceSample
        public let end: DistanceSample
        public let elapsedSeconds: Double
        public let activeSeconds: Double
        public let pausedSeconds: Double
        public let sourcePointRange: Range<Int>
    }

    /// The route state displayed at an elapsed replay time.
    public struct ReplaySample: Sendable {
        public let pointIndex: Int
        public let elapsedSeconds: Double
        public let activeSeconds: Double
        public let distanceMeters: Double
        public let isInRecordingGap: Bool
    }

    /// Time values at an elapsed-clock boundary.
    public struct ElapsedSample: Sendable {
        public let elapsedSeconds: Double
        public let activeSeconds: Double
        public let distanceMeters: Double
        /// Deterministic real point selected for range metrics and seeking.
        public let pointIndex: Int
        public let isInterpolated: Bool
        public let isInRecordingGap: Bool
    }

    /// Aggregated clocks and source points for a forward elapsed-time range.
    public struct TimeRange: Sendable {
        public let start: ElapsedSample
        public let end: ElapsedSample
        public let elapsedSeconds: Double
        public let activeSeconds: Double
        public let pausedSeconds: Double
        public let sourcePointRange: Range<Int>
    }

    private enum DistanceLocation {
        case point(Int)
        case interval(before: Int, after: Int, fraction: Double)
    }

    private enum ElapsedLocation {
        case point(Int)
        case interval(before: Int, after: Int, fraction: Double)
        case gap(before: Int, after: Int)
    }

    private let routePoints: [RoutePoint]
    private let elevationProfile: ElevationProfile
    private let elapsedSecondsByPoint: [Double]
    private let activeSecondsByPoint: [Double]
    private let distanceMetersByPoint: [Double]

    public let totalElapsedSeconds: Double
    public let totalActiveSeconds: Double
    public let totalPausedSeconds: Double
    public let startDistanceMeters: Double
    public let totalDistanceMeters: Double

    public init(workout: RunWorkout) {
        self.init(routePoints: workout.routePoints)
    }

    public init(routePoints: [RoutePoint]) {
        self.init(
            routePoints: routePoints,
            elevationProfile: ElevationProfile(routePoints: routePoints)
        )
    }

    public init(routePoints: [RoutePoint], elevationProfile: ElevationProfile) {
        self.routePoints = routePoints
        self.elevationProfile = elevationProfile

        guard let first = routePoints.first else {
            elapsedSecondsByPoint = []
            activeSecondsByPoint = []
            distanceMetersByPoint = []
            totalElapsedSeconds = 0
            totalActiveSeconds = 0
            totalPausedSeconds = 0
            startDistanceMeters = 0
            totalDistanceMeters = 0
            return
        }

        let finalTimestampDelta = routePoints.last?.timestamp.timeIntervalSince(first.timestamp) ?? 0
        let timestampElapsedTotal = Self.nonNegativeFinite(finalTimestampDelta)

        // When timestamps do not span (all equal or invalid) but the route
        // points carry a valid elapsedSeconds series, fall back to that series.
        // RoutePointSanitizer already normalises this case for imported or
        // synthetic workouts whose timestamps cannot supply elapsed time.
        let useTimestampElapsed: Bool
        let elapsedTotal: Double

        if timestampElapsedTotal > 0 {
            useTimestampElapsed = true
            elapsedTotal = timestampElapsedTotal
        } else if let last = routePoints.last,
                  last.elapsedSeconds.isFinite,
                  last.elapsedSeconds > 0 {
            useTimestampElapsed = false
            elapsedTotal = last.elapsedSeconds
        } else {
            useTimestampElapsed = true
            elapsedTotal = 0
        }

        var elapsedValues: [Double] = []
        elapsedValues.reserveCapacity(routePoints.count)
        var previousElapsed: Double = 0

        for (index, point) in routePoints.enumerated() {
            if index == 0 {
                elapsedValues.append(0)
                continue
            }

            let candidate: Double
            if useTimestampElapsed {
                let timestampElapsed = point.timestamp.timeIntervalSince(first.timestamp)
                // Invalid or regressing intermediate timestamps hold the previous
                // elapsed position. They must not turn the separately stored
                // RoutePoint.elapsedSeconds value into fabricated timer time.
                candidate = timestampElapsed.isFinite
                    ? Self.clamp(timestampElapsed, lowerBound: 0, upperBound: elapsedTotal)
                    : previousElapsed
            } else {
                // Fall back to the per-point elapsed series normalised by
                // RoutePointSanitizer. Non-finite or regressing values hold the
                // prior position.
                candidate = point.elapsedSeconds.isFinite
                    ? Self.clamp(point.elapsedSeconds, lowerBound: 0, upperBound: elapsedTotal)
                    : previousElapsed
            }
            previousElapsed = max(previousElapsed, candidate)
            elapsedValues.append(previousElapsed)
        }

        var activeValues = Array(repeating: 0.0, count: routePoints.count)
        var activeTotal: Double = 0
        if routePoints.count >= 2 {
            if useTimestampElapsed {
                for index in 1..<routePoints.count {
                    let previous = routePoints[index - 1]
                    let current = routePoints[index]
                    let delta = current.timestamp.timeIntervalSince(previous.timestamp)

                    if current.routeSegmentIndex == previous.routeSegmentIndex,
                       delta.isFinite,
                       delta > 0 {
                        activeTotal += delta
                    }

                    activeTotal = min(
                        Self.nonNegativeFinite(activeTotal),
                        elapsedValues[index],
                        elapsedTotal
                    )
                    activeValues[index] = activeTotal
                }
            } else {
                // When timestamps do not span we cannot distinguish pauses from
                // recording gaps. Treat all elapsed time as active so workouts
                // with only supplied elapsed values are not analysed as zero
                // active duration.
                activeValues = elapsedValues
                activeTotal = elapsedTotal
            }
        }

        var distanceValues: [Double] = []
        distanceValues.reserveCapacity(routePoints.count)
        var previousDistance = Self.nonNegativeFinite(first.distanceFromStartMeters)
        distanceValues.append(previousDistance)
        for point in routePoints.dropFirst() {
            let supplied = Self.nonNegativeFinite(point.distanceFromStartMeters)
            previousDistance = max(previousDistance, supplied)
            distanceValues.append(previousDistance)
        }

        elapsedSecondsByPoint = elapsedValues
        activeSecondsByPoint = activeValues
        distanceMetersByPoint = distanceValues
        totalElapsedSeconds = elapsedTotal
        totalActiveSeconds = min(activeValues.last ?? 0, totalElapsedSeconds)
        totalPausedSeconds = Self.safeDifference(totalElapsedSeconds, totalActiveSeconds)
        startDistanceMeters = distanceValues.first ?? 0
        totalDistanceMeters = distanceValues.last ?? 0
    }

    /// Active elapsed time at each route point, aligned with the source array.
    public var activeElapsedSecondsByPoint: [Double] {
        activeSecondsByPoint
    }

    public func elapsedSeconds(atPointIndex index: Int) -> Double? {
        guard elapsedSecondsByPoint.indices.contains(index) else { return nil }
        return elapsedSecondsByPoint[index]
    }

    public func activeSeconds(atPointIndex index: Int) -> Double? {
        guard activeSecondsByPoint.indices.contains(index) else { return nil }
        return activeSecondsByPoint[index]
    }

    /// Sample the two clocks at cumulative distance using an explicit boundary
    /// role. Interpolation occurs only inside one continuous route segment.
    public func distanceSample(
        at distance: Double,
        boundary role: WorkoutDistanceBoundaryRole
    ) -> DistanceSample? {
        guard let location = distanceLocation(at: distance, boundary: role) else {
            return nil
        }

        let clampedDistance = Self.clamp(
            distance,
            lowerBound: startDistanceMeters,
            upperBound: totalDistanceMeters
        )

        switch location {
        case .point(let index):
            return DistanceSample(
                distanceMeters: distanceMetersByPoint[index],
                elapsedSeconds: elapsedSecondsByPoint[index],
                activeSeconds: activeSecondsByPoint[index],
                pointIndex: index,
                isInterpolated: false
            )

        case .interval(let before, let after, let fraction):
            let selectedIndex = role == .rangeStart ? after : before
            return DistanceSample(
                distanceMeters: clampedDistance,
                elapsedSeconds: Self.interpolate(
                    elapsedSecondsByPoint[before],
                    elapsedSecondsByPoint[after],
                    fraction
                ),
                activeSeconds: Self.interpolate(
                    activeSecondsByPoint[before],
                    activeSecondsByPoint[after],
                    fraction
                ),
                pointIndex: selectedIndex,
                isInterpolated: true
            )
        }
    }

    /// Build a forward distance range using the documented duplicate-boundary
    /// rule. Only the final workout remainder should be a partial split.
    public func distanceRange(from startDistance: Double, to endDistance: Double) -> DistanceRange? {
        guard startDistance.isFinite,
              endDistance.isFinite,
              startDistance <= endDistance,
              let start = distanceSample(at: startDistance, boundary: .rangeStart),
              let end = distanceSample(at: endDistance, boundary: .rangeEnd)
        else {
            return nil
        }

        let elapsed = Self.safeDifference(end.elapsedSeconds, start.elapsedSeconds)
        let active = min(Self.safeDifference(end.activeSeconds, start.activeSeconds), elapsed)
        let paused = Self.safeDifference(elapsed, active)
        let lower = min(start.pointIndex, end.pointIndex)
        let upper = max(start.pointIndex, end.pointIndex)

        return DistanceRange(
            start: start,
            end: end,
            elapsedSeconds: elapsed,
            activeSeconds: active,
            pausedSeconds: paused,
            sourcePointRange: lower..<(upper + 1)
        )
    }

    /// Unweighted average of valid recorded heart-rate samples inside a range.
    /// Samples from every covered route segment are included.
    public func averageHeartRate(from startDistance: Double, to endDistance: Double) -> Double? {
        guard let range = distanceRange(from: startDistance, to: endDistance) else {
            return nil
        }

        var sumHR: Double = 0
        var countHR: Int = 0

        for point in routePoints[range.sourcePointRange] {
            if let value = point.heartRateBPM, MetricValidation.isValidHeartRate(value) {
                sumHR += value
                countHR += 1
            }
        }

        guard countHR > 0 else { return nil }
        return sumHR / Double(countHR)
    }

    /// Cumulative positive elevation change inside a distance range, never
    /// connecting the endpoint of one route segment to the next segment.
    public func elevationGain(from startDistance: Double, to endDistance: Double) -> Double? {
        elevationProfile.ascent(from: startDistance, to: endDistance)
    }

    /// Signed elevation change accumulated only across continuous intervals.
    public func signedElevationChange(from startDistance: Double, to endDistance: Double) -> Double? {
        elevationProfile.signedChange(from: startDistance, to: endDistance)
    }

    public func elevationLoss(from startDistance: Double, to endDistance: Double) -> Double? {
        elevationProfile.descent(from: startDistance, to: endDistance)
    }

    /// Latest source point whose elapsed time is at or before the replay clock.
    /// Active time advances inside recorded intervals and remains fixed in gaps.
    public func replaySample(atElapsedTime time: Double) -> ReplaySample? {
        guard !routePoints.isEmpty else { return nil }

        let clampedTime = Self.clamp(time, lowerBound: 0, upperBound: totalElapsedSeconds)
        let index = time.isFinite && time < 0
            ? 0
            : (replayPointIndex(atElapsedTime: clampedTime) ?? 0)

        var active = activeSecondsByPoint[index]
        var isGap = false

        if index + 1 < routePoints.count {
            let nextIndex = index + 1
            let pointTime = elapsedSecondsByPoint[index]
            let nextTime = elapsedSecondsByPoint[nextIndex]
            let sameSegment = routePoints[index].routeSegmentIndex == routePoints[nextIndex].routeSegmentIndex

            if sameSegment, nextTime > pointTime, clampedTime > pointTime {
                let intervalActive = Self.safeDifference(
                    activeSecondsByPoint[nextIndex],
                    activeSecondsByPoint[index]
                )
                let fraction = min(1, (clampedTime - pointTime) / (nextTime - pointTime))
                active += intervalActive * fraction
            } else if !sameSegment,
                      nextTime > pointTime,
                      clampedTime > pointTime,
                      clampedTime < nextTime {
                isGap = true
            }
        }

        return ReplaySample(
            pointIndex: index,
            elapsedSeconds: clampedTime,
            activeSeconds: min(Self.nonNegativeFinite(active), totalActiveSeconds),
            distanceMeters: distanceMetersByPoint[index],
            isInRecordingGap: isGap
        )
    }

    /// Latest point whose elapsed time is less than or equal to the supplied
    /// replay time. Exact duplicate timestamps select the last duplicate.
    public func replayPointIndex(atElapsedTime time: Double) -> Int? {
        guard !elapsedSecondsByPoint.isEmpty else { return nil }
        if time.isFinite, time < elapsedSecondsByPoint[0] {
            return 0
        }
        let clampedTime = Self.clamp(time, lowerBound: 0, upperBound: totalElapsedSeconds)

        var low = 0
        var high = elapsedSecondsByPoint.count
        while low < high {
            let middle = (low + high) / 2
            if elapsedSecondsByPoint[middle] <= clampedTime {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(0, low - 1)
    }

    public func isInRecordingGap(atElapsedTime time: Double) -> Bool {
        replaySample(atElapsedTime: time)?.isInRecordingGap ?? false
    }

    // MARK: - Elapsed-time boundary sampling

    /// Sample clocks and cumulative distance at an elapsed-time boundary.
    ///
    /// Interpolation occurs only inside one continuous route segment. A
    /// boundary that falls inside a recording gap selects the hold point for
    /// `.rangeEnd` and the resume point for `.rangeStart` without inventing
    /// geographic distance across the gap. Exact duplicate timestamps select
    /// the first sample for range starts and the last for range ends, except
    /// when a terminal range end must include the final workout sample.
    public func elapsedSample(
        at elapsed: Double,
        boundary role: WorkoutTimeBoundaryRole
    ) -> ElapsedSample? {
        guard !routePoints.isEmpty, elapsed.isFinite else { return nil }

        let clampedElapsed = Self.clamp(elapsed, lowerBound: 0, upperBound: totalElapsedSeconds)
        let wasClamped = abs(clampedElapsed - elapsed) > 0.000_001
        _ = wasClamped

        switch elapsedLocation(at: clampedElapsed, boundary: role) {
        case .point(let index):
            return ElapsedSample(
                elapsedSeconds: elapsedSecondsByPoint[index],
                activeSeconds: activeSecondsByPoint[index],
                distanceMeters: distanceMetersByPoint[index],
                pointIndex: index,
                isInterpolated: false,
                isInRecordingGap: false
            )

        case .interval(let before, let after, let fraction):
            let selectedIndex = role == .rangeStart ? after : before
            return ElapsedSample(
                elapsedSeconds: clampedElapsed,
                activeSeconds: Self.interpolate(
                    activeSecondsByPoint[before],
                    activeSecondsByPoint[after],
                    fraction
                ),
                distanceMeters: Self.interpolate(
                    distanceMetersByPoint[before],
                    distanceMetersByPoint[after],
                    fraction
                ),
                pointIndex: selectedIndex,
                isInterpolated: true,
                isInRecordingGap: false
            )

        case .gap(let before, let after):
            let selectedIndex = role == .rangeStart ? after : before
            // No geographic interpolation across a recording gap.
            let active: Double
            if role == .rangeStart {
                active = activeSecondsByPoint[after]
            } else {
                active = activeSecondsByPoint[before]
            }
            return ElapsedSample(
                elapsedSeconds: clampedElapsed,
                activeSeconds: active,
                distanceMeters: distanceMetersByPoint[selectedIndex],
                pointIndex: selectedIndex,
                isInterpolated: false,
                isInRecordingGap: true
            )
        }
    }

    /// Build a forward elapsed-time range using half-open boundary ownership.
    ///
    /// At an exact shared boundary, the prior range owns time up to but not
    /// including the next range's start. Distance is cumulative route distance
    /// at each boundary and never bridges a recording gap.
    public func timeRange(from startElapsed: Double, to endElapsed: Double) -> TimeRange? {
        guard startElapsed.isFinite,
              endElapsed.isFinite,
              startElapsed <= endElapsed,
              let start = elapsedSample(at: startElapsed, boundary: .rangeStart),
              let end = elapsedSample(at: endElapsed, boundary: .rangeEnd)
        else {
            return nil
        }

        let elapsed = Self.safeDifference(end.elapsedSeconds, start.elapsedSeconds)
        let active = min(Self.safeDifference(end.activeSeconds, start.activeSeconds), elapsed)
        let paused = Self.safeDifference(elapsed, active)
        let lower = min(start.pointIndex, end.pointIndex)
        let upper = max(start.pointIndex, end.pointIndex)

        return TimeRange(
            start: start,
            end: end,
            elapsedSeconds: elapsed,
            activeSeconds: active,
            pausedSeconds: paused,
            sourcePointRange: lower..<(upper + 1)
        )
    }

    /// Cumulative route distance at an elapsed-time boundary.
    public func distance(
        atElapsedTime elapsed: Double,
        boundary role: WorkoutTimeBoundaryRole
    ) -> Double? {
        elapsedSample(at: elapsed, boundary: role)?.distanceMeters
    }

    // MARK: - Distance lookup

    private func distanceLocation(
        at distance: Double,
        boundary role: WorkoutDistanceBoundaryRole
    ) -> DistanceLocation? {
        guard !routePoints.isEmpty, distance.isFinite else { return nil }
        guard routePoints.count > 1 else { return .point(0) }

        let target = Self.clamp(
            distance,
            lowerBound: startDistanceMeters,
            upperBound: totalDistanceMeters
        )

        var low = 0
        var high = distanceMetersByPoint.count - 1
        while low < high {
            let middle = (low + high) / 2
            if distanceMetersByPoint[middle] < target {
                low = middle + 1
            } else {
                high = middle
            }
        }

        if distanceMetersByPoint[low] == target {
            return .point(exactBoundaryIndex(startingAt: low, distance: target, role: role))
        }

        guard low > 0 else { return .point(0) }
        let before = low - 1
        let after = low
        guard routePoints[before].routeSegmentIndex == routePoints[after].routeSegmentIndex else {
            return .point(role == .rangeStart ? after : before)
        }

        let intervalDistance = distanceMetersByPoint[after] - distanceMetersByPoint[before]
        guard intervalDistance.isFinite, intervalDistance > 0 else {
            return .point(role == .rangeStart ? after : before)
        }
        let fraction = max(0, min(1, (target - distanceMetersByPoint[before]) / intervalDistance))
        return .interval(before: before, after: after, fraction: fraction)
    }

    private func exactBoundaryIndex(
        startingAt index: Int,
        distance: Double,
        role: WorkoutDistanceBoundaryRole
    ) -> Int {
        var first = index
        while first > 0, distanceMetersByPoint[first - 1] == distance {
            first -= 1
        }

        var last = index
        while last + 1 < distanceMetersByPoint.count,
              distanceMetersByPoint[last + 1] == distance {
            last += 1
        }

        // A same-segment distance plateau is active timer time, not a pause.
        // Interior boundaries use first arrival for both roles so consecutive
        // ranges partition that time exactly once. A terminal range end must
        // use the final sample so the last split and selected-distance metrics
        // still include stationary timer time at the end of the workout. The
        // stop/resume rule below applies only when the duplicate run crosses a
        // route-segment boundary.
        if routePoints[first].routeSegmentIndex == routePoints[last].routeSegmentIndex {
            return role == .rangeEnd && last == routePoints.count - 1 ? last : first
        }

        switch role {
        case .rangeStart:
            let resumedSegment = routePoints[last].routeSegmentIndex
            var selected = last
            while selected > first,
                  routePoints[selected - 1].routeSegmentIndex == resumedSegment {
                selected -= 1
            }
            return selected

        case .rangeEnd:
            let priorSegment = routePoints[first].routeSegmentIndex
            var selected = first
            while selected < last,
                  routePoints[selected + 1].routeSegmentIndex == priorSegment {
                selected += 1
            }
            return selected
        }
    }

    // MARK: - Elapsed lookup

    private func elapsedLocation(
        at elapsed: Double,
        boundary role: WorkoutTimeBoundaryRole
    ) -> ElapsedLocation {
        guard !routePoints.isEmpty else { return .point(0) }
        guard routePoints.count > 1 else { return .point(0) }

        let target = Self.clamp(elapsed, lowerBound: 0, upperBound: totalElapsedSeconds)

        // Binary search for first index with elapsed > target, then back up.
        var low = 0
        var high = elapsedSecondsByPoint.count
        while low < high {
            let middle = (low + high) / 2
            if elapsedSecondsByPoint[middle] <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let insertion = low

        if insertion > 0, elapsedSecondsByPoint[insertion - 1] == target {
            return .point(exactElapsedBoundaryIndex(at: insertion - 1, elapsed: target, role: role))
        }

        if insertion == 0 {
            return .point(0)
        }
        if insertion >= elapsedSecondsByPoint.count {
            return .point(elapsedSecondsByPoint.count - 1)
        }

        let before = insertion - 1
        let after = insertion
        let sameSegment = routePoints[before].routeSegmentIndex == routePoints[after].routeSegmentIndex
        let beforeTime = elapsedSecondsByPoint[before]
        let afterTime = elapsedSecondsByPoint[after]

        if !sameSegment {
            return .gap(before: before, after: after)
        }

        let interval = afterTime - beforeTime
        guard interval.isFinite, interval > 0 else {
            return .point(role == .rangeStart ? after : before)
        }
        let fraction = max(0, min(1, (target - beforeTime) / interval))
        return .interval(before: before, after: after, fraction: fraction)
    }

    private func exactElapsedBoundaryIndex(
        at index: Int,
        elapsed: Double,
        role: WorkoutTimeBoundaryRole
    ) -> Int {
        var first = index
        while first > 0, elapsedSecondsByPoint[first - 1] == elapsed {
            first -= 1
        }

        var last = index
        while last + 1 < elapsedSecondsByPoint.count,
              elapsedSecondsByPoint[last + 1] == elapsed {
            last += 1
        }

        if routePoints[first].routeSegmentIndex == routePoints[last].routeSegmentIndex {
            return role == .rangeEnd ? last : first
        }

        switch role {
        case .rangeStart:
            let resumedSegment = routePoints[last].routeSegmentIndex
            var selected = last
            while selected > first,
                  routePoints[selected - 1].routeSegmentIndex == resumedSegment {
                selected -= 1
            }
            return selected

        case .rangeEnd:
            let priorSegment = routePoints[first].routeSegmentIndex
            var selected = first
            while selected < last,
                  routePoints[selected + 1].routeSegmentIndex == priorSegment {
                selected += 1
            }
            return selected
        }
    }

    // MARK: - Numeric safety

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func safeDifference(_ later: Double, _ earlier: Double) -> Double {
        guard later.isFinite, earlier.isFinite else { return 0 }
        return max(0, later - earlier)
    }

    private static func clamp(_ value: Double, lowerBound: Double, upperBound: Double) -> Double {
        guard value.isFinite else { return lowerBound }
        guard upperBound >= lowerBound else { return lowerBound }
        return max(lowerBound, min(value, upperBound))
    }

    private static func interpolate(_ first: Double, _ second: Double, _ fraction: Double) -> Double {
        first + ((second - first) * fraction)
    }
}
