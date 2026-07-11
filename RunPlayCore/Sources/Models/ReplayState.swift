import Foundation

/// Playback state for route replay.
public enum PlaybackState: String, Codable, Sendable {
    case stopped
    case playing
    case paused
}

/// Controls for the route replay timeline.
public struct ReplayState: Sendable {
    public var playbackState: PlaybackState
    public var currentTime: Double
    public var currentDistance: Double
    public var currentPointIndex: Int
    public var playbackSpeed: Double
    public var totalDuration: Double
    public var totalDistance: Double

    public init(
        playbackState: PlaybackState = .stopped,
        currentTime: Double = 0,
        currentDistance: Double = 0,
        currentPointIndex: Int = 0,
        playbackSpeed: Double = 1.0,
        totalDuration: Double = 0,
        totalDistance: Double = 0
    ) {
        self.playbackState = playbackState
        self.totalDuration = Self.nonNegativeFinite(totalDuration)
        self.totalDistance = Self.nonNegativeFinite(totalDistance)
        self.currentTime = Self.clamp(currentTime, upperBound: self.totalDuration)
        self.currentDistance = Self.clamp(currentDistance, upperBound: self.totalDistance)
        self.currentPointIndex = max(0, currentPointIndex)
        self.playbackSpeed = playbackSpeed.isFinite && playbackSpeed > 0 ? playbackSpeed : 1.0
    }

    /// Progress as a fraction 0...1.
    public var progress: Double {
        guard totalDuration > 0, currentTime.isFinite else { return 0 }
        return max(0, min(currentTime / totalDuration, 1.0))
    }

    /// Distance progress as a fraction 0...1.
    public var distanceProgress: Double {
        guard totalDistance > 0, currentDistance.isFinite else { return 0 }
        return max(0, min(currentDistance / totalDistance, 1.0))
    }

    /// Formatted current time.
    public var formattedCurrentTime: String {
        formatSeconds(currentTime)
    }

    /// Formatted total duration.
    public var formattedTotalDuration: String {
        formatSeconds(totalDuration)
    }

    /// Formatted current distance in km.
    public var formattedCurrentDistance: String {
        String(format: "%.2f km", currentDistance / 1000.0)
    }

    /// Formatted playback speed.
    public var formattedSpeed: String {
        if playbackSpeed == 1.0 { return "1×" }
        return String(format: "%.1f×", playbackSpeed)
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let clampedSeconds = Self.nonNegativeFinite(seconds)
        let mins = Int(clampedSeconds) / 60
        let secs = Int(clampedSeconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func clamp(_ value: Double, upperBound: Double) -> Double {
        let lowerBounded = nonNegativeFinite(value)
        guard upperBound > 0 else { return 0 }
        return min(lowerBounded, upperBound)
    }
}
