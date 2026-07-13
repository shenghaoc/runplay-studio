import Foundation

/// Pure, platform-neutral state machine for elapsed-clock workout replay.
public class PlaybackEngine {

    public private(set) var state = ReplayState()
    public private(set) var isPlaying = false

    private var workout: RunWorkout?
    private var timeline: WorkoutTimeline?

    public static let speedOptions: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

    public init() {}

    public func load(_ workout: RunWorkout) {
        stop()
        self.workout = workout
        let timeline = WorkoutTimeline(workout: workout)
        self.timeline = timeline

        state = ReplayState(
            playbackState: .stopped,
            currentTime: 0,
            currentDistance: timeline.startDistanceMeters,
            currentPointIndex: 0,
            playbackSpeed: 1,
            totalDuration: timeline.totalElapsedSeconds,
            totalDistance: timeline.totalDistanceMeters
        )
        selectElapsedStart()
    }

    public func play() {
        guard workout != nil else { return }
        if state.currentTime >= state.totalDuration {
            selectElapsedStart()
        }
        state.playbackState = .playing
        isPlaying = true
    }

    public func pause() {
        state.playbackState = .paused
        isPlaying = false
    }

    public func stop() {
        state.playbackState = .stopped
        selectElapsedStart()
        isPlaying = false
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func seekToTime(_ time: Double) {
        guard time.isFinite,
              let timeline,
              let sample = timeline.replaySample(atElapsedTime: time)
        else {
            return
        }
        apply(sample)
    }

    public func seekToProgress(_ progress: Double) {
        guard progress.isFinite else { return }
        seekToTime(max(0, min(progress, 1)) * state.totalDuration)
    }

    public func seekToDistance(_ distance: Double) {
        guard let timeline,
              let sample = timeline.distanceSample(at: distance, boundary: .rangeEnd),
              let workout,
              workout.routePoints.indices.contains(sample.pointIndex)
        else {
            return
        }

        state.currentPointIndex = sample.pointIndex
        state.currentTime = sample.elapsedSeconds
        state.currentDistance = sample.distanceMeters
    }

    public func setSpeed(_ speed: Double) {
        guard speed.isFinite else { return }
        state.playbackSpeed = max(0.1, min(speed, 16))
    }

    /// Step between real route points, including points with duplicate times.
    public func stepForward() {
        guard let workout, !workout.routePoints.isEmpty else { return }
        selectPoint(at: min(state.currentPointIndex + 1, workout.routePoints.count - 1))
    }

    public func stepBackward() {
        guard let workout, !workout.routePoints.isEmpty else { return }
        selectPoint(at: max(state.currentPointIndex - 1, 0))
    }

    public var currentRoutePoint: RoutePoint? {
        guard let workout,
              workout.routePoints.indices.contains(state.currentPointIndex)
        else {
            return nil
        }
        return workout.routePoints[state.currentPointIndex]
    }

    public var currentSceneIndex: Int { state.currentPointIndex }

    public var canStepBackward: Bool {
        workout != nil && state.currentPointIndex > 0
    }

    public var canStepForward: Bool {
        guard let workout else { return false }
        return state.currentPointIndex + 1 < workout.routePoints.count
    }

    public var selectedMetrics: SelectedMetrics {
        guard let point = currentRoutePoint else { return SelectedMetrics() }
        let replaySample = timeline?.replaySample(atElapsedTime: state.currentTime)
        let pointActive = timeline?.activeSeconds(atPointIndex: state.currentPointIndex)

        return SelectedMetrics(
            elapsedSeconds: state.currentTime,
            activeSeconds: replaySample?.pointIndex == state.currentPointIndex
                ? replaySample?.activeSeconds
                : pointActive,
            isInRecordingGap: replaySample?.isInRecordingGap ?? false,
            distanceMeters: state.currentDistance,
            paceSecondsPerKilometer: point.paceSecondsPerKilometer,
            altitudeMeters: point.altitudeMeters,
            heartRateBPM: point.heartRateBPM,
            speedMetersPerSecond: point.speedMetersPerSecond,
            cadence: point.cadence,
            splitIndex: findCurrentSplitIndex()
        )
    }

    public func advancePlayback(by interval: TimeInterval) {
        guard interval.isFinite, interval >= 0, isPlaying, let timeline else { return }
        let newTime = state.currentTime + (interval * state.playbackSpeed)

        if newTime >= state.totalDuration {
            if let final = timeline.replaySample(atElapsedTime: state.totalDuration) {
                apply(final)
            }
            pause()
            return
        }

        if let sample = timeline.replaySample(atElapsedTime: newTime) {
            apply(sample)
        }
    }

    /// Replay-specific lookup: latest point at or before `time`.
    public func findPointIndex(forTime time: Double, in points: [RoutePoint]) -> Int? {
        WorkoutTimeline(routePoints: points).replayPointIndex(atElapsedTime: time)
    }

    /// Nearest-distance lookup retained for source compatibility.
    public func findPointIndex(forDistance distance: Double, in points: [RoutePoint]) -> Int? {
        guard !points.isEmpty, distance.isFinite else { return nil }
        var low = 0
        var high = points.count - 1

        while low < high {
            let middle = (low + high) / 2
            if points[middle].distanceFromStartMeters < distance {
                low = middle + 1
            } else {
                high = middle
            }
        }

        guard low > 0 else { return low }
        let previousDifference = abs(points[low - 1].distanceFromStartMeters - distance)
        let currentDifference = abs(points[low].distanceFromStartMeters - distance)
        return previousDifference < currentDifference ? low - 1 : low
    }

    private func apply(_ sample: WorkoutTimeline.ReplaySample) {
        state.currentTime = sample.elapsedSeconds
        state.currentDistance = sample.distanceMeters
        state.currentPointIndex = sample.pointIndex
    }

    private func selectPoint(at index: Int) {
        guard let workout,
              let timeline,
              workout.routePoints.indices.contains(index),
              let elapsed = timeline.elapsedSeconds(atPointIndex: index)
        else {
            return
        }

        state.currentPointIndex = index
        state.currentTime = elapsed
        state.currentDistance = max(0, workout.routePoints[index].distanceFromStartMeters)
    }

    private func findCurrentSplitIndex() -> Int? {
        guard let workout else { return nil }
        for (index, split) in workout.splits.enumerated()
        where state.currentDistance >= split.startDistanceMeters {
            if state.currentDistance < split.endDistanceMeters {
                return index
            }

            guard index + 1 < workout.splits.count,
                  Self.isSameDistance(state.currentDistance, split.endDistanceMeters),
                  let timeline,
                  let stop = timeline.distanceSample(
                    at: split.endDistanceMeters,
                    boundary: .rangeEnd
                  ),
                  let resume = timeline.distanceSample(
                    at: split.endDistanceMeters,
                    boundary: .rangeStart
                  ),
                  stop.pointIndex != resume.pointIndex
            else {
                continue
            }

            // A duplicated distance at a route-segment boundary represents
            // two real states: the stop point remains in the prior split,
            // while the resume point begins the next split.
            if state.currentPointIndex <= stop.pointIndex {
                return index
            }
        }

        if let final = workout.splits.last,
           state.currentDistance >= final.endDistanceMeters {
            return workout.splits.count - 1
        }
        return nil
    }

    private func selectElapsedStart() {
        guard let sample = timeline?.replaySample(atElapsedTime: 0) else {
            state.currentTime = 0
            state.currentDistance = 0
            state.currentPointIndex = 0
            return
        }
        apply(sample)
    }

    private static func isSameDistance(_ first: Double, _ second: Double) -> Bool {
        abs(first - second) <= 0.000_001
    }
}
