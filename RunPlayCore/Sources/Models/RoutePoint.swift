import Foundation

/// A single GPS point along a running route with optional biometric data.
public struct RoutePoint: Identifiable, Codable, Hashable {
    public let id: UUID
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double?
    public var distanceFromStartMeters: Double
    public var elapsedSeconds: Double
    public var speedMetersPerSecond: Double?
    public var paceSecondsPerKilometer: Double?
    public var heartRateBPM: Double?
    public var cadence: Double?
    public var horizontalAccuracy: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double? = nil,
        distanceFromStartMeters: Double = 0,
        elapsedSeconds: Double = 0,
        speedMetersPerSecond: Double? = nil,
        paceSecondsPerKilometer: Double? = nil,
        heartRateBPM: Double? = nil,
        cadence: Double? = nil,
        horizontalAccuracy: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.distanceFromStartMeters = distanceFromStartMeters
        self.elapsedSeconds = elapsedSeconds
        self.speedMetersPerSecond = speedMetersPerSecond
        self.paceSecondsPerKilometer = paceSecondsPerKilometer
        self.heartRateBPM = heartRateBPM
        self.cadence = cadence
        self.horizontalAccuracy = horizontalAccuracy
    }
}
