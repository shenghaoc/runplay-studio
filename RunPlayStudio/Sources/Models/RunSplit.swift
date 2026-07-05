import Foundation

/// A kilometer or mile split with summary metrics.
struct RunSplit: Identifiable, Codable, Equatable {
    let id: UUID
    var splitIndex: Int
    var distanceMeters: Double
    var elapsedSeconds: Double
    var paceSecondsPerKilometer: Double
    var averageHeartRateBPM: Double?
    var elevationGainMeters: Double?
    var startDistanceMeters: Double
    var endDistanceMeters: Double

    init(
        id: UUID = UUID(),
        splitIndex: Int,
        distanceMeters: Double = 1000,
        elapsedSeconds: Double,
        paceSecondsPerKilometer: Double,
        averageHeartRateBPM: Double? = nil,
        elevationGainMeters: Double? = nil,
        startDistanceMeters: Double,
        endDistanceMeters: Double
    ) {
        self.id = id
        self.splitIndex = splitIndex
        self.distanceMeters = distanceMeters
        self.elapsedSeconds = elapsedSeconds
        self.paceSecondsPerKilometer = paceSecondsPerKilometer
        self.averageHeartRateBPM = averageHeartRateBPM
        self.elevationGainMeters = elevationGainMeters
        self.startDistanceMeters = startDistanceMeters
        self.endDistanceMeters = endDistanceMeters
    }

    /// Formatted pace as MM:SS per km.
    var formattedPace: String {
        let minutes = Int(paceSecondsPerKilometer) / 60
        let seconds = Int(paceSecondsPerKilometer) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Formatted elapsed time as MM:SS.
    var formattedElapsed: String {
        let minutes = Int(elapsedSeconds) / 60
        let seconds = Int(elapsedSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
