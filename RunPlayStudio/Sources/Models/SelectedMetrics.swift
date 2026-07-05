import Foundation

/// Metrics at the currently selected replay position.
///
/// This is a snapshot of the route point data at the current position,
/// used to drive the current metrics panel and synchronized views.
struct SelectedMetrics {
    var elapsedSeconds: Double?
    var distanceMeters: Double?
    var paceSecondsPerKilometer: Double?
    var altitudeMeters: Double?
    var heartRateBPM: Double?
    var speedMetersPerSecond: Double?
    var cadence: Double?
    var splitIndex: Int?

    var formattedElapsed: String {
        guard let seconds = elapsedSeconds else { return "--:--" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var formattedDistance: String {
        guard let meters = distanceMeters else { return "--- km" }
        return String(format: "%.2f km", meters / 1000.0)
    }

    var formattedPace: String {
        guard let pace = paceSecondsPerKilometer, pace > 0, pace.isFinite else { return "--:-- /km" }
        let mins = Int(pace) / 60
        let secs = Int(pace) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }

    var formattedElevation: String {
        guard let alt = altitudeMeters else { return "--- m" }
        return String(format: "%.0f m", alt)
    }

    var formattedHeartRate: String {
        guard let hr = heartRateBPM else { return "--- bpm" }
        return String(format: "%.0f bpm", hr)
    }

    var formattedSpeed: String {
        guard let speed = speedMetersPerSecond else { return "--- m/s" }
        return String(format: "%.1f m/s", speed)
    }

    var formattedCadence: String {
        guard let cad = cadence else { return "--- spm" }
        return String(format: "%.0f spm", cad)
    }

    var formattedSplit: String {
        guard let idx = splitIndex else { return "---" }
        return "Split \(idx + 1)"
    }
}
