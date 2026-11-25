/// Failures representable with a valid Span and owned output storage.
package enum ElevationProfileError: Error, Equatable {
    case resourceLimit
    case invalidPolicy
    case invalidInputContract
}

/// A route point already compacted into the continuity groups used by elevation.
package struct EngineElevationProfileInput: Sendable {
    package let distanceMeters: Double
    package let altitudeMeters: Double
    package let continuityGroup: Int32
    // Keep the native tag contract for typed validation, including malformed inputs.
    package let hasAltitude: UInt8

    package init(distanceMeters: Double, altitudeMeters: Double, continuityGroup: Int32, hasAltitude: UInt8) {
        self.distanceMeters = distanceMeters
        self.altitudeMeters = altitudeMeters
        self.continuityGroup = continuityGroup
        self.hasAltitude = hasAltitude
    }
}

package struct EngineElevationProfilePolicy: Sendable {
    package let plausibleAltitudeMinimumMeters: Double
    package let plausibleAltitudeMaximumMeters: Double
    package let spikeMinimumDeviationMeters: Double
    package let shortExcursionMinimumDeviationMeters: Double
    package let shortExcursionMaximumSampleCount: UInt64
    package let spikeMaximumNeighborDifferenceMeters: Double
    package let spikeMaximumHorizontalSpanMeters: Double
    package let smoothingRadiusMeters: Double
    package let minimumReliableSampleCount: UInt64
    package let gainLossDeadbandMeters: Double

    package init(
        plausibleAltitudeMinimumMeters: Double,
        plausibleAltitudeMaximumMeters: Double,
        spikeMinimumDeviationMeters: Double,
        shortExcursionMinimumDeviationMeters: Double,
        shortExcursionMaximumSampleCount: UInt64,
        spikeMaximumNeighborDifferenceMeters: Double,
        spikeMaximumHorizontalSpanMeters: Double,
        smoothingRadiusMeters: Double,
        minimumReliableSampleCount: UInt64,
        gainLossDeadbandMeters: Double
    ) {
        self.plausibleAltitudeMinimumMeters = plausibleAltitudeMinimumMeters
        self.plausibleAltitudeMaximumMeters = plausibleAltitudeMaximumMeters
        self.spikeMinimumDeviationMeters = spikeMinimumDeviationMeters
        self.shortExcursionMinimumDeviationMeters = shortExcursionMinimumDeviationMeters
        self.shortExcursionMaximumSampleCount = shortExcursionMaximumSampleCount
        self.spikeMaximumNeighborDifferenceMeters = spikeMaximumNeighborDifferenceMeters
        self.spikeMaximumHorizontalSpanMeters = spikeMaximumHorizontalSpanMeters
        self.smoothingRadiusMeters = smoothingRadiusMeters
        self.minimumReliableSampleCount = minimumReliableSampleCount
        self.gainLossDeadbandMeters = gainLossDeadbandMeters
    }
}

package struct EngineElevationProfileSample: Sendable {
    package internal(set) var correctedAltitudeMeters = 0.0
    package internal(set) var cumulativeAscentMeters = 0.0
    package internal(set) var cumulativeDescentMeters = 0.0
    package internal(set) var cumulativeSignedChangeMeters = 0.0
    package internal(set) var reliableIntervalCount = 0.0
    package internal(set) var runIdentifier: Int32 = -1
    package internal(set) var reliableRunIdentifier: Int32 = -1
    package internal(set) var hasCorrectedAltitude = false
    package internal(set) var sourceAltitudeWasRejected = false
}

package struct EngineElevationProfileResult: Sendable {
    package let samples: [EngineElevationProfileSample]
    package let rejectedAltitudeCount: Int
    package let runCount: Int
    package let reliableRunCount: Int
    package let hasMeaningfulElevation: Bool
    package let totalAscentMeters: Double
    package let totalDescentMeters: Double
}
