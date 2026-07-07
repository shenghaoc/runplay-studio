import Foundation

/// Aggregated metrics for an entire running workout.
public struct RunSummary: Codable, Hashable {
    public var totalDistanceMeters: Double
    public var totalElapsedSeconds: Double
    public var averagePaceSecondsPerKilometer: Double
    public var averageSpeedMetersPerSecond: Double
    public var elevationGainMeters: Double
    public var elevationLossMeters: Double
    public var averageHeartRateBPM: Double?
    public var maxHeartRateBPM: Double?
    public var caloriesEstimate: Double?

    public init(
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
    public var totalDistanceKilometers: Double {
        totalDistanceMeters / 1000.0
    }

    /// Formatted average pace as MM:SS per km.
    public var formattedPace: String {
        DisplayFormatter.formatPace(averagePaceSecondsPerKilometer)
    }

    /// Formatted total elapsed time.
    public var formattedDuration: String {
        DisplayFormatter.formatDuration(totalElapsedSeconds)
    }

    /// Formatted total distance.
    public var formattedDistance: String {
        DisplayFormatter.formatDistanceKm(totalDistanceMeters)
    }
}
