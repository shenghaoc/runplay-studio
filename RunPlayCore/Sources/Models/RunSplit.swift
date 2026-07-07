import Foundation

/// A kilometer or mile split with summary metrics.
public struct RunSplit: Identifiable, Codable, Hashable {
    public let id: UUID
    public var splitIndex: Int
    public var distanceMeters: Double
    public var elapsedSeconds: Double
    public var paceSecondsPerKilometer: Double
    public var averageHeartRateBPM: Double?
    public var elevationGainMeters: Double?
    public var startDistanceMeters: Double
    public var endDistanceMeters: Double

    public init(
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

    /// Formatted pace as MM:SS (no "/km" suffix, for narrow table contexts).
    public var formattedPace: String {
        DisplayFormatter.formatPaceShort(paceSecondsPerKilometer)
    }

    /// Formatted elapsed time as MM:SS.
    public var formattedElapsed: String {
        DisplayFormatter.formatElapsed(elapsedSeconds)
    }
}
