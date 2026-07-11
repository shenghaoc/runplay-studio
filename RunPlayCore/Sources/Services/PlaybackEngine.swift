import Foundation


/// Pure state machine for workout replay playback.
///
/// Platform-neutral — no Combine/Timer dependencies.
/// Timer-driven playback is handled by `ReplayController` (RunPlayStudio).
public class PlaybackEngine {

    // MARK: - State

    public private(set) var state = ReplayState()
    public private(set) var isPlaying = false

    // MARK: - Private State

    private var workout: RunWorkout?

    // MARK: - Configuration

    /// Available playback speeds.
    public static let speedOptions: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

    public init() {}

    // MARK: - Public Interface

    /// Load a workout for replay.
    public func load(_ workout: RunWorkout) {
        stop()
        self.workout = workout

        let totalDuration = workout.routePoints.last?.elapsedSeconds ?? 0
        let totalDistance = workout.routePoints.last?.distanceFromStartMeters ?? 0

        state = ReplayState(
            playbackState: .stopped,
            currentTime: 0,
            currentDistance: 0,
            currentPointIndex: 0,
            playbackSpeed: 1.0,
            totalDuration: totalDuration,
            totalDistance: totalDistance
        )
    }

    /// Start or resume playback.
    public func play() {
        guard workout != nil else { return }

        if state.currentTime >= state.totalDuration {
            // Restart if at end
            state.currentTime = 0
            state.currentDistance = 0
            state.currentPointIndex = 0
        }

        state.playbackState = .playing
        isPlaying = true
    }

    /// Pause playback.
    public func pause() {
        state.playbackState = .paused
        isPlaying = false
    }

    /// Stop playback and reset to beginning.
    public func stop() {
        state.playbackState = .stopped
        state.currentTime = 0
        state.currentDistance = 0
        state.currentPointIndex = 0
        isPlaying = false
    }

    /// Toggle between play and pause.
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seek to a specific time (0...totalDuration).
    public func seekToTime(_ time: Double) {
        guard let workout = workout, time.isFinite else { return }

        let clampedTime = max(0, min(time, state.totalDuration))
        state.currentTime = clampedTime

        // Find the closest route point
        if let index = findPointIndex(forTime: clampedTime, in: workout.routePoints) {
            state.currentPointIndex = index
            state.currentDistance = workout.routePoints[index].distanceFromStartMeters
        }
    }

    /// Seek to a fraction of total duration (0...1).
    public func seekToProgress(_ progress: Double) {
        guard progress.isFinite else { return }
        seekToTime(progress * state.totalDuration)
    }

    /// Seek to a specific distance.
    public func seekToDistance(_ distance: Double) {
        guard let workout = workout, distance.isFinite else { return }

        let clampedDist = max(0, min(distance, state.totalDistance))
        state.currentDistance = clampedDist

        if let index = findPointIndex(forDistance: clampedDist, in: workout.routePoints) {
            state.currentPointIndex = index
            state.currentTime = workout.routePoints[index].elapsedSeconds
        }
    }

    /// Set playback speed.
    public func setSpeed(_ speed: Double) {
        guard speed.isFinite else { return }
        state.playbackSpeed = max(0.1, min(speed, 16.0))
    }

    /// Step forward one frame.
    public func stepForward() {
        guard let workout = workout, !workout.routePoints.isEmpty else { return }
        let nextIdx = min(state.currentPointIndex + 1, workout.routePoints.count - 1)
        guard nextIdx >= 0 && nextIdx < workout.routePoints.count else { return }
        seekToTime(workout.routePoints[nextIdx].elapsedSeconds)
    }

    /// Step backward one frame.
    public func stepBackward() {
        guard let workout = workout, !workout.routePoints.isEmpty else { return }
        let prevIdx = max(state.currentPointIndex - 1, 0)
        guard prevIdx < workout.routePoints.count else { return }
        seekToTime(workout.routePoints[prevIdx].elapsedSeconds)
    }

    /// Get the current route point.
    public var currentRoutePoint: RoutePoint? {
        guard let workout = workout,
              state.currentPointIndex < workout.routePoints.count else {
            return nil
        }
        return workout.routePoints[state.currentPointIndex]
    }

    /// Get the current scene point index.
    public var currentSceneIndex: Int {
        state.currentPointIndex
    }

    /// Selected metrics at the current position.
    public var selectedMetrics: SelectedMetrics {
        guard let point = currentRoutePoint else {
            return SelectedMetrics()
        }

        let splitIndex = findCurrentSplitIndex()

        return SelectedMetrics(
            elapsedSeconds: point.elapsedSeconds,
            distanceMeters: point.distanceFromStartMeters,
            paceSecondsPerKilometer: point.paceSecondsPerKilometer,
            altitudeMeters: point.altitudeMeters,
            heartRateBPM: point.heartRateBPM,
            speedMetersPerSecond: point.speedMetersPerSecond,
            cadence: point.cadence,
            splitIndex: splitIndex
        )
    }

    // MARK: - Advance Playback

    /// Advance playback by a custom time interval.
    ///
    /// Called by the timer in `ReplayController` or directly in tests.
    public func advancePlayback(by interval: TimeInterval) {
        guard interval.isFinite, interval >= 0 else { return }
        guard let workout = workout, isPlaying else { return }

        let timeIncrement = interval * state.playbackSpeed
        let newTime = state.currentTime + timeIncrement

        if newTime >= state.totalDuration {
            // Reached the end - land on final route point
            state.currentTime = state.totalDuration
            if let lastIndex = workout.routePoints.indices.last {
                state.currentPointIndex = lastIndex
                state.currentDistance = workout.routePoints[lastIndex].distanceFromStartMeters
            }
            pause()
            return
        }

        state.currentTime = newTime

        if let index = findPointIndex(forTime: newTime, in: workout.routePoints) {
            state.currentPointIndex = index
            state.currentDistance = workout.routePoints[index].distanceFromStartMeters
        }
    }

    // MARK: - Private

    /// Find the current split index based on distance.
    private func findCurrentSplitIndex() -> Int? {
        guard let workout = workout else { return nil }
        let distance = state.currentDistance

        for (index, split) in workout.splits.enumerated() {
            if distance >= split.startDistanceMeters && distance < split.endDistanceMeters {
                return index
            }
        }

        // If past all splits, return last
        if let lastSplit = workout.splits.last, distance >= lastSplit.endDistanceMeters {
            return workout.splits.count - 1
        }

        return nil
    }

    /// Binary search for the route point closest to a given time.
    public func findPointIndex(forTime time: Double, in points: [RoutePoint]) -> Int? {
        guard !points.isEmpty else { return nil }

        var low = 0
        var high = points.count - 1

        while low < high {
            let mid = (low + high) / 2
            if points[mid].elapsedSeconds < time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // Return the closest point
        if low > 0 {
            let prevDiff = abs(points[low - 1].elapsedSeconds - time)
            let currDiff = abs(points[low].elapsedSeconds - time)
            return prevDiff < currDiff ? low - 1 : low
        }
        return low
    }

    /// Binary search for the route point closest to a given distance.
    public func findPointIndex(forDistance distance: Double, in points: [RoutePoint]) -> Int? {
        guard !points.isEmpty else { return nil }

        var low = 0
        var high = points.count - 1

        while low < high {
            let mid = (low + high) / 2
            if points[mid].distanceFromStartMeters < distance {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low > 0 {
            let prevDiff = abs(points[low - 1].distanceFromStartMeters - distance)
            let currDiff = abs(points[low].distanceFromStartMeters - distance)
            return prevDiff < currDiff ? low - 1 : low
        }
        return low
    }
}
