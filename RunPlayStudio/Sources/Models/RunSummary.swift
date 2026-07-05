import Foundation

/// Aggregated metrics for an entire running workout.
struct RunSummary: Codable, Equatable {
    var totalDistanceMeters: Double
    var totalElapsedSeconds: Double
    var averagePaceSecondsPerKilometer: Double
    var averageSpeedMetersPerSecond: Double
    var elevationGainMeters: Double
    var elevationLossMeters: Double
    var averageHeartRateBPM: Double?
    var maxHeartRateBPM: Double?
    var caloriesEstimate: Double?

    init(
        totalDistanceMeters: Double = 0,
        totalElapsedSeconds: Double = 0,
        averagePaceSecondsPerKilometer: Double = 0,
        averageSpeedMetersPerSecond: Double = 0,
        elevationGainMeters: Double = 0,
        elevationLossMeters: Double = 0,
        averageHeartRateBPM: Double? = nil,
        maxHeartRateBPM: Double? = nil,
        caloriesEstimate: Double? = nil
    ) {
        self.totalDistanceMeters = totalDistanceMeters
        self.totalElapsedSeconds = totalElapsedSeconds
        self.averagePaceSecondsPerKilometer = averagePaceSecondsPerKilometer
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
        self.elevationGainMeters = elevationGainMeters
        self.elevationLossMeters = elevationLossMeters
        self.averageHeartRateBPM = averageHeartRateBPM
        self.maxHeartRateBPM = maxHeartRateBPM
        self.caloriesEstimate = caloriesEstimate
    }

    /// Total distance in kilometers.
    var totalDistanceKilometers: Double {
        totalDistanceMeters / 1000.0
    }

    /// Formatted average pace as MM:SS per km.
    var formattedPace: String {
        let minutes = Int(averagePaceSecondsPerKilometer) / 60
        let seconds = Int(averagePaceSecondsPerKilometer) % 60
        return String(format: "%d:%02d /km", minutes, seconds)
    }

    /// Formatted total elapsed time.
    var formattedDuration: String {
        let hours = Int(totalElapsedSeconds) / 3600
        let minutes = (Int(totalElapsedSeconds) % 3600) / 60
        let seconds = Int(totalElapsedSeconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Formatted total distance.
    var formattedDistance: String {
        String(format: "%.2f km", totalDistanceKilometers)
    }
}
