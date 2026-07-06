import Foundation

/// Metrics at the currently selected replay position.
///
/// This is a snapshot of the route point data at the current position,
/// used to drive the current metrics panel and synchronized views.
public struct SelectedMetrics {
    public var elapsedSeconds: Double?
    public var distanceMeters: Double?
    public var paceSecondsPerKilometer: Double?
    public var altitudeMeters: Double?
    public var heartRateBPM: Double?
    public var speedMetersPerSecond: Double?
    public var cadence: Double?
    public var splitIndex: Int?

    public init(
        elapsedSeconds: Double? = nil,
        distanceMeters: Double? = nil,
        paceSecondsPerKilometer: Double? = nil,
        altitudeMeters: Double? = nil,
        heartRateBPM: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        cadence: Double? = nil,
        splitIndex: Int? = nil
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.distanceMeters = distanceMeters
        self.paceSecondsPerKilometer = paceSecondsPerKilometer
        self.altitudeMeters = altitudeMeters
        self.heartRateBPM = heartRateBPM
        self.speedMetersPerSecond = speedMetersPerSecond
        self.cadence = cadence
        self.splitIndex = splitIndex
    }

    public var formattedElapsed: String {
        guard let seconds = elapsedSeconds else { return "--:--" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    public var formattedDistance: String {
        guard let meters = distanceMeters else { return "--- km" }
        return String(format: "%.2f km", meters / 1000.0)
    }

    public var formattedPace: String {
        guard let pace = paceSecondsPerKilometer, pace > 0, pace.isFinite else { return "--:-- /km" }
        let mins = Int(pace) / 60
        let secs = Int(pace) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }

    public var formattedElevation: String {
        guard let alt = altitudeMeters else { return "--- m" }
        return String(format: "%.0f m", alt)
    }

    public var formattedHeartRate: String {
        guard let hr = heartRateBPM else { return "--- bpm" }
        return String(format: "%.0f bpm", hr)
    }

    public var formattedSpeed: String {
        guard let speed = speedMetersPerSecond else { return "--- m/s" }
        return String(format: "%.1f m/s", speed)
    }

    public var formattedCadence: String {
        guard let cad = cadence else { return "--- spm" }
        return String(format: "%.0f spm", cad)
    }

    public var formattedSplit: String {
        guard let idx = splitIndex else { return "---" }
        return "Split \(idx + 1)"
    }
}
