import Foundation

/// A single GPS point along a running route with optional biometric data.
public struct RoutePoint: Identifiable, Hashable, Sendable {
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
    /// Index of the continuous route segment this point belongs to.
    /// The first segment uses index 0. Each GPX `<trkseg>` or TCX `<Track>`
    /// boundary increments the index. Points in distinct segments are not
    /// connected by geometry, distance, speed, or elevation calculations.
    public var routeSegmentIndex: Int

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
        horizontalAccuracy: Double? = nil,
        routeSegmentIndex: Int = 0
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
        self.routeSegmentIndex = routeSegmentIndex
    }
}

// MARK: - Backward-Compatible Codable

extension RoutePoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, latitude, longitude, altitudeMeters
        case distanceFromStartMeters, elapsedSeconds, speedMetersPerSecond
        case paceSecondsPerKilometer, heartRateBPM, cadence, horizontalAccuracy
        case routeSegmentIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        altitudeMeters = try container.decodeIfPresent(Double.self, forKey: .altitudeMeters)
        distanceFromStartMeters = try container.decode(Double.self, forKey: .distanceFromStartMeters)
        elapsedSeconds = try container.decode(Double.self, forKey: .elapsedSeconds)
        speedMetersPerSecond = try container.decodeIfPresent(Double.self, forKey: .speedMetersPerSecond)
        paceSecondsPerKilometer = try container.decodeIfPresent(Double.self, forKey: .paceSecondsPerKilometer)
        heartRateBPM = try container.decodeIfPresent(Double.self, forKey: .heartRateBPM)
        cadence = try container.decodeIfPresent(Double.self, forKey: .cadence)
        horizontalAccuracy = try container.decodeIfPresent(Double.self, forKey: .horizontalAccuracy)
        // Backward compatibility: older snapshots lack routeSegmentIndex; default to 0.
        routeSegmentIndex = try container.decodeIfPresent(Int.self, forKey: .routeSegmentIndex) ?? 0
    }
}
