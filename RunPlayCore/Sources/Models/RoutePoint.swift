import Foundation

/// A single GPS point along a running route with optional biometric data.
public struct RoutePoint: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double?
    /// Terrain elevation in metres sampled from user-supplied DEM tiles.
    ///
    /// Derived, not source data: it sits beside `altitudeMeters` and never
    /// overwrites it. When present, elevation analysis reads it in place of
    /// `altitudeMeters` (see `ElevationProfile`). `nil` when the point has not
    /// been DEM-corrected, when no tile covered it, or when recorded barometric
    /// altitude outranks DEM. Uncorrected points omit the key when encoded, so
    /// snapshots without DEM data keep their existing size and bytes.
    public var demAltitudeMeters: Double?
    public var distanceFromStartMeters: Double
    public var elapsedSeconds: Double
    public var speedMetersPerSecond: Double?
    public var paceSecondsPerKilometer: Double?
    public var heartRateBPM: Double?
    public var cadence: Double?
    /// Running power in watts, when the source recorded it (native FIT record
    /// power or a recognized developer field such as Stryd or Garmin running
    /// power). `nil` when the source carried no power data.
    public var powerWatts: Double?
    /// Running dynamics: ground contact time in milliseconds.
    public var groundContactTimeMilliseconds: Double?
    /// Running dynamics: vertical oscillation in millimeters.
    public var verticalOscillationMillimeters: Double?
    /// Running dynamics: vertical ratio in percent.
    public var verticalRatioPercent: Double?
    /// Running dynamics: stance time balance in percent.
    public var stanceTimeBalancePercent: Double?
    /// Running dynamics: step length in meters.
    public var stepLengthMeters: Double?
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
        demAltitudeMeters: Double? = nil,
        distanceFromStartMeters: Double = 0,
        elapsedSeconds: Double = 0,
        speedMetersPerSecond: Double? = nil,
        paceSecondsPerKilometer: Double? = nil,
        heartRateBPM: Double? = nil,
        cadence: Double? = nil,
        powerWatts: Double? = nil,
        groundContactTimeMilliseconds: Double? = nil,
        verticalOscillationMillimeters: Double? = nil,
        verticalRatioPercent: Double? = nil,
        stanceTimeBalancePercent: Double? = nil,
        stepLengthMeters: Double? = nil,
        horizontalAccuracy: Double? = nil,
        routeSegmentIndex: Int = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.demAltitudeMeters = demAltitudeMeters
        self.distanceFromStartMeters = distanceFromStartMeters
        self.elapsedSeconds = elapsedSeconds
        self.speedMetersPerSecond = speedMetersPerSecond
        self.paceSecondsPerKilometer = paceSecondsPerKilometer
        self.heartRateBPM = heartRateBPM
        self.cadence = cadence
        self.powerWatts = powerWatts
        self.groundContactTimeMilliseconds = groundContactTimeMilliseconds
        self.verticalOscillationMillimeters = verticalOscillationMillimeters
        self.verticalRatioPercent = verticalRatioPercent
        self.stanceTimeBalancePercent = stanceTimeBalancePercent
        self.stepLengthMeters = stepLengthMeters
        self.horizontalAccuracy = horizontalAccuracy
        self.routeSegmentIndex = routeSegmentIndex
    }
}

// MARK: - Backward-Compatible Codable

extension RoutePoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, latitude, longitude, altitudeMeters, demAltitudeMeters
        case distanceFromStartMeters, elapsedSeconds, speedMetersPerSecond
        case paceSecondsPerKilometer, heartRateBPM, cadence
        case powerWatts, groundContactTimeMilliseconds
        case verticalOscillationMillimeters, verticalRatioPercent
        case stanceTimeBalancePercent, stepLengthMeters, horizontalAccuracy
        case routeSegmentIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        altitudeMeters = try container.decodeIfPresent(Double.self, forKey: .altitudeMeters)
        demAltitudeMeters = try container.decodeIfPresent(Double.self, forKey: .demAltitudeMeters)
        distanceFromStartMeters = try container.decode(Double.self, forKey: .distanceFromStartMeters)
        elapsedSeconds = try container.decode(Double.self, forKey: .elapsedSeconds)
        speedMetersPerSecond = try container.decodeIfPresent(Double.self, forKey: .speedMetersPerSecond)
        paceSecondsPerKilometer = try container.decodeIfPresent(Double.self, forKey: .paceSecondsPerKilometer)
        heartRateBPM = try container.decodeIfPresent(Double.self, forKey: .heartRateBPM)
        cadence = try container.decodeIfPresent(Double.self, forKey: .cadence)
        powerWatts = try container.decodeIfPresent(Double.self, forKey: .powerWatts)
        groundContactTimeMilliseconds = try container.decodeIfPresent(
            Double.self, forKey: .groundContactTimeMilliseconds)
        verticalOscillationMillimeters = try container.decodeIfPresent(
            Double.self, forKey: .verticalOscillationMillimeters)
        verticalRatioPercent = try container.decodeIfPresent(
            Double.self, forKey: .verticalRatioPercent)
        stanceTimeBalancePercent = try container.decodeIfPresent(
            Double.self, forKey: .stanceTimeBalancePercent)
        stepLengthMeters = try container.decodeIfPresent(
            Double.self, forKey: .stepLengthMeters)
        horizontalAccuracy = try container.decodeIfPresent(Double.self, forKey: .horizontalAccuracy)
        // Backward compatibility: older snapshots lack routeSegmentIndex; default to 0.
        routeSegmentIndex = try container.decodeIfPresent(Int.self, forKey: .routeSegmentIndex) ?? 0
    }

    /// Every optional is written with `encodeIfPresent`, so an absent value
    /// omits its key. A point without DEM elevation therefore encodes exactly
    /// as it did before `demAltitudeMeters` existed.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encodeIfPresent(altitudeMeters, forKey: .altitudeMeters)
        try container.encodeIfPresent(demAltitudeMeters, forKey: .demAltitudeMeters)
        try container.encode(distanceFromStartMeters, forKey: .distanceFromStartMeters)
        try container.encode(elapsedSeconds, forKey: .elapsedSeconds)
        try container.encodeIfPresent(speedMetersPerSecond, forKey: .speedMetersPerSecond)
        try container.encodeIfPresent(paceSecondsPerKilometer, forKey: .paceSecondsPerKilometer)
        try container.encodeIfPresent(heartRateBPM, forKey: .heartRateBPM)
        try container.encodeIfPresent(cadence, forKey: .cadence)
        try container.encodeIfPresent(powerWatts, forKey: .powerWatts)
        try container.encodeIfPresent(
            groundContactTimeMilliseconds, forKey: .groundContactTimeMilliseconds)
        try container.encodeIfPresent(
            verticalOscillationMillimeters, forKey: .verticalOscillationMillimeters)
        try container.encodeIfPresent(verticalRatioPercent, forKey: .verticalRatioPercent)
        try container.encodeIfPresent(
            stanceTimeBalancePercent, forKey: .stanceTimeBalancePercent)
        try container.encodeIfPresent(stepLengthMeters, forKey: .stepLengthMeters)
        try container.encodeIfPresent(horizontalAccuracy, forKey: .horizontalAccuracy)
        try container.encode(routeSegmentIndex, forKey: .routeSegmentIndex)
    }
}
