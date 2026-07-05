import Foundation

/// Playback state for route replay.
enum PlaybackState: String, Codable {
    case stopped
    case playing
    case paused
}

/// Controls for the route replay timeline.
struct ReplayState {
    var playbackState: PlaybackState
    var currentTime: Double
    var currentDistance: Double
    var currentPointIndex: Int
    var playbackSpeed: Double
    var totalDuration: Double
    var totalDistance: Double

    init(
        playbackState: PlaybackState = .stopped,
        currentTime: Double = 0,
        currentDistance: Double = 0,
        currentPointIndex: Int = 0,
        playbackSpeed: Double = 1.0,
        totalDuration: Double = 0,
        totalDistance: Double = 0
    ) {
        self.playbackState = playbackState
        self.currentTime = currentTime
        self.currentDistance = currentDistance
        self.currentPointIndex = currentPointIndex
        self.playbackSpeed = playbackSpeed
        self.totalDuration = totalDuration
        self.totalDistance = totalDistance
    }

    /// Progress as a fraction 0...1.
    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return min(currentTime / totalDuration, 1.0)
    }

    /// Distance progress as a fraction 0...1.
    var distanceProgress: Double {
        guard totalDistance > 0 else { return 0 }
        return min(currentDistance / totalDistance, 1.0)
    }

    /// Formatted current time.
    var formattedCurrentTime: String {
        formatSeconds(currentTime)
    }

    /// Formatted total duration.
    var formattedTotalDuration: String {
        formatSeconds(totalDuration)
    }

    /// Formatted current distance in km.
    var formattedCurrentDistance: String {
        String(format: "%.2f km", currentDistance / 1000.0)
    }

    /// Formatted playback speed.
    var formattedSpeed: String {
        if playbackSpeed == 1.0 { return "1×" }
        return String(format: "%.1f×", playbackSpeed)
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
