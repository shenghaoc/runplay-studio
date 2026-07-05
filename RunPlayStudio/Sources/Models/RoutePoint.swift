import Foundation

/// A single GPS point along a running route with optional biometric data.
struct RoutePoint: Identifiable, Codable, Equatable {
    let id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var distanceFromStartMeters: Double
    var elapsedSeconds: Double
    var speedMetersPerSecond: Double?
    var paceSecondsPerKilometer: Double?
    var heartRateBPM: Double?
    var cadence: Double?
    var horizontalAccuracy: Double?

    init(
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
