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

    // MARK: - Public Interface

    /// Load a workout for replay.
    func load(_ workout: RunWorkout) {
        stopTimer()
        engine.load(workout)
        syncFromEngine()
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
        state = engine.state
        isPlaying = engine.isPlaying
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
