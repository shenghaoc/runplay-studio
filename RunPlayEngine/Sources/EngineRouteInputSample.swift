package enum EngineRouteLimits {
    /// Internal kernel safety ceiling, not the product limit. Keep the existing 25% margin.
    package static let maxRouteInputSamples = 1_250_000
}

/// One route input value; the eventual route-quality kernel borrows a Span of these.
package struct EngineRouteInputSample: Sendable {
    package let sourceIndex: UInt64
    package let timestampSecondsSinceReferenceDate: Double
    package let latitude: Double
    package let longitude: Double
    package let altitudeMeters: Double?
    package let demAltitudeMeters: Double?
    package let distanceFromStartMeters: Double
    package let elapsedSeconds: Double
    package let speedMetersPerSecond: Double?
    package let paceSecondsPerKilometer: Double?
    package let heartRateBPM: Double?
    package let cadence: Double?
    package let powerWatts: Double?
    package let groundContactTimeMilliseconds: Double?
    package let verticalOscillationMillimeters: Double?
    package let verticalRatioPercent: Double?
    package let stanceTimeBalancePercent: Double?
    package let stepLengthMeters: Double?
    package let horizontalAccuracy: Double?
    package let routeSegmentIndex: Int64

    package init(
        sourceIndex: UInt64, timestampSecondsSinceReferenceDate: Double,
        latitude: Double, longitude: Double,
        altitudeMeters: Double? = nil, demAltitudeMeters: Double? = nil,
        distanceFromStartMeters: Double, elapsedSeconds: Double,
        speedMetersPerSecond: Double? = nil, paceSecondsPerKilometer: Double? = nil,
        heartRateBPM: Double? = nil, cadence: Double? = nil, powerWatts: Double? = nil,
        groundContactTimeMilliseconds: Double? = nil, verticalOscillationMillimeters: Double? = nil,
        verticalRatioPercent: Double? = nil, stanceTimeBalancePercent: Double? = nil,
        stepLengthMeters: Double? = nil, horizontalAccuracy: Double? = nil,
        routeSegmentIndex: Int64
    ) {
        self.sourceIndex = sourceIndex
        self.timestampSecondsSinceReferenceDate = timestampSecondsSinceReferenceDate
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
