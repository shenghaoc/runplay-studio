import Foundation
import RunPlayCore
import Combine
import RunPlayCore

/// Controls playback of a running workout replay.
///
/// Manages play/pause/stop state, timeline seeking, and playback speed.
/// Timer-driven playback updates current position at 30fps.
class ReplayController: ObservableObject {

    // MARK: - Published State

    @Published var state = ReplayState()
    @Published var isPlaying = false

    // MARK: - Private State

    private var workout: RunWorkout?
    private var timer: Timer?
    private let updateInterval: TimeInterval = 1.0 / 30.0 // 30fps

    // MARK: - Configuration

    /// Available playback speeds.
    static let speedOptions: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

    // MARK: - Public Interface

    /// Load a workout for replay.
    func load(_ workout: RunWorkout) {
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
    func play() {
        guard workout != nil else { return }

        if state.currentTime >= state.totalDuration {
            // Restart if at end
            state.currentTime = 0
            state.currentDistance = 0
            state.currentPointIndex = 0
        }

        state.playbackState = .playing
        isPlaying = true
        startTimer()
    }

    /// Pause playback.
    func pause() {
        state.playbackState = .paused
        isPlaying = false
        stopTimer()
    }

    /// Stop playback and reset to beginning.
    func stop() {
        state.playbackState = .stopped
        state.currentTime = 0
        state.currentDistance = 0
        state.currentPointIndex = 0
        isPlaying = false
        stopTimer()
    }

    /// Toggle between play and pause.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seek to a specific time (0...totalDuration).
    func seekToTime(_ time: Double) {
        guard let workout = workout else { return }

        let clampedTime = max(0, min(time, state.totalDuration))
        state.currentTime = clampedTime

        // Find the closest route point
        if let index = findPointIndex(forTime: clampedTime, in: workout.routePoints) {
            state.currentPointIndex = index
            state.currentDistance = workout.routePoints[index].distanceFromStartMeters
        }
    }

    /// Seek to a fraction of total duration (0...1).
    func seekToProgress(_ progress: Double) {
        seekToTime(progress * state.totalDuration)
    }

    /// Seek to a specific distance.
    func seekToDistance(_ distance: Double) {
        guard let workout = workout else { return }

        let clampedDist = max(0, min(distance, state.totalDistance))
        state.currentDistance = clampedDist

        if let index = findPointIndex(forDistance: clampedDist, in: workout.routePoints) {
            state.currentPointIndex = index
            state.currentTime = workout.routePoints[index].elapsedSeconds
        }
    }

    /// Set playback speed.
    func setSpeed(_ speed: Double) {
        state.playbackSpeed = max(0.1, min(speed, 16.0))
    }

    /// Step forward one frame.
    func stepForward() {
        guard let workout = workout else { return }
        let nextIdx = min(state.currentPointIndex + 1, workout.routePoints.count - 1)
        seekToTime(workout.routePoints[nextIdx].elapsedSeconds)
    }

    /// Step backward one frame.
    func stepBackward() {
        guard let workout = workout else { return }
        let prevIdx = max(state.currentPointIndex - 1, 0)
        seekToTime(workout.routePoints[prevIdx].elapsedSeconds)
    }

    /// Get the current route point.
    var currentRoutePoint: RoutePoint? {
        guard let workout = workout,
              state.currentPointIndex < workout.routePoints.count else {
            return nil
        }
        return workout.routePoints[state.currentPointIndex]
    }

    /// Get the current scene point index.
    var currentSceneIndex: Int {
        state.currentPointIndex
    }

    /// Selected metrics at the current position.
    var selectedMetrics: SelectedMetrics {
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

    // MARK: - Private

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updatePlayback()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updatePlayback() {
        guard let workout = workout, isPlaying else { return }

        let timeIncrement = updateInterval * state.playbackSpeed
        let newTime = state.currentTime + timeIncrement

        if newTime >= state.totalDuration {
            // Reached the end
            state.currentTime = state.totalDuration
            pause()
            return
        }

        state.currentTime = newTime

        if let index = findPointIndex(forTime: newTime, in: workout.routePoints) {
            state.currentPointIndex = index
            state.currentDistance = workout.routePoints[index].distanceFromStartMeters
        }
    }

    /// Binary search for the route point closest to a given time.
    private func findPointIndex(forTime time: Double, in points: [RoutePoint]) -> Int? {
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
    private func findPointIndex(forDistance distance: Double, in points: [RoutePoint]) -> Int? {
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
