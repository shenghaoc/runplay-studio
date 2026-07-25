import Foundation
import RunPlayCore
import Combine


/// Controls playback of a running workout replay.
///
/// Thin Combine/Timer wrapper around `PlaybackEngine` (RunPlayCore).
/// Timer-driven playback updates current position at 30fps.
@MainActor
class ReplayController: ObservableObject {

    // MARK: - Published State (mirrors PlaybackEngine)

    @Published var state = ReplayState()
    @Published var isPlaying = false

    // MARK: - Engine

    let engine = PlaybackEngine()

    // MARK: - Private State

    private var timer: Timer?
    private let updateInterval: TimeInterval = 1.0 / 30.0 // 30fps

    // MARK: - Configuration

    /// Available playback speeds.
    static let speedOptions: [Double] = PlaybackEngine.speedOptions

    /// Called after a logical replay state change. The application session
    /// controller throttles this callback so timer ticks never write at 30 fps.
    var onStateChange: (@MainActor () -> Void)?

    /// Called when replay transitions from playing to paused/stopped or reaches
    /// its end. The application session controller uses this to flush the
    /// latest position immediately.
    var onPause: (@MainActor () -> Void)?

    // MARK: - Public Interface

    /// Load a workout for replay.
    func load(_ workout: RunWorkout) {
        stopTimer()
        engine.load(workout)
        // Selection persistence owns the commit boundary for a newly loaded
        // workout; do not save a transient pre-commit replay state here.
        syncFromEngine(notifyState: false, notifyPause: false)
    }

    /// Restore a durable replay position. Loading the workout remains the
    /// authority for route data; persisted time is clamped by the engine and
    /// playback is always paused after restoration.
    func restore(
        workout: RunWorkout,
        elapsedSeconds: Double,
        playbackSpeed: Double
    ) {
        stopTimer()
        engine.load(workout)
        let speed = Self.speedOptions.contains(playbackSpeed) ? playbackSpeed : 1
        engine.setSpeed(speed)
        engine.seekToTime(elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0)
        engine.pause()
        syncFromEngine(notifyState: false, notifyPause: false)
        stopTimer()
    }

    /// Start or resume playback.
    func play() {
        engine.play()
        syncFromEngine()
        if engine.isPlaying {
            startTimer()
        }
    }

    /// Pause playback.
    func pause() {
        engine.pause()
        syncFromEngine()
        stopTimer()
    }

    /// Stop playback and reset to beginning.
    func stop() {
        engine.stop()
        syncFromEngine()
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
        engine.seekToTime(time)
        syncFromEngine()
    }

    /// Seek to a fraction of total duration (0...1).
    func seekToProgress(_ progress: Double) {
        engine.seekToProgress(progress)
        syncFromEngine()
    }

    /// Seek to a specific distance.
    func seekToDistance(_ distance: Double) {
        engine.seekToDistance(distance)
        syncFromEngine()
    }

    /// Set playback speed.
    func setSpeed(_ speed: Double) {
        engine.setSpeed(speed)
        syncFromEngine()
    }

    /// Seek by a signed elapsed-time delta (clamped by the engine).
    func seekBySeconds(_ delta: Double) {
        engine.seekBySeconds(delta)
        syncFromEngine()
    }

    /// Choose the previous slower supported speed.
    @discardableResult
    func slower() -> Double {
        let speed = engine.slower()
        syncFromEngine()
        return speed
    }

    /// Choose the next faster supported speed.
    @discardableResult
    func faster() -> Double {
        let speed = engine.faster()
        syncFromEngine()
        return speed
    }

    /// Restart from the beginning and remain paused.
    func restart() {
        stop()
    }

    /// Step forward one frame.
    func stepForward() {
        engine.stepForward()
        syncFromEngine()
    }

    /// Step backward one frame.
    func stepBackward() {
        engine.stepBackward()
        syncFromEngine()
    }

    /// Get the current route point.
    var currentRoutePoint: RoutePoint? {
        engine.currentRoutePoint
    }

    /// Get the current scene point index.
    var currentSceneIndex: Int {
        engine.currentSceneIndex
    }

    var canStepBackward: Bool { engine.canStepBackward }
    var canStepForward: Bool { engine.canStepForward }
    var hasPlayableTimeline: Bool {
        state.totalDuration.isFinite
            && state.totalDuration > 0
            && currentRoutePoint != nil
    }

    /// Selected metrics at the current position.
    var selectedMetrics: SelectedMetrics {
        engine.selectedMetrics
    }

    // MARK: - Internal (testable)

    var hasActiveTimer: Bool {
        timer != nil
    }

    /// Advance playback by a custom time interval.
    ///
    /// Extracted from the timer path so tests can exercise the tick logic
    /// deterministically without waiting for real `Timer` fires.
    func advancePlayback(by interval: TimeInterval) {
        engine.advancePlayback(by: interval)
        syncFromEngine()
        if !engine.isPlaying {
            stopTimer()
        }
    }

    // MARK: - Private

    private func syncFromEngine() {
        syncFromEngine(notifyState: true, notifyPause: true)
    }

    private func syncFromEngine(notifyState: Bool, notifyPause: Bool) {
        let wasPlaying = isPlaying
        state = engine.state
        isPlaying = engine.isPlaying
        if notifyState {
            onStateChange?()
        }
        if notifyPause, wasPlaying, !isPlaying {
            onPause?()
        }
    }

    private func startTimer() {
        stopTimer()
        let interval = updateInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advancePlayback(by: interval)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
