import Foundation

/// Where a summary's distance and duration came from.
///
/// `gpsDerived` is the historical behaviour: the workout carried route points,
/// so distance and every time figure were derived from the route. It covers
/// both coordinate-derived and device-supplied distance series, because both
/// come from the route; `RunWorkout.routeDistanceSource` keeps that finer
/// distinction.
///
/// `sourceReported` means the workout has no route at all, so the importer's
/// own totals were carried through analysis unchanged. Pace is then the only
/// speed the source supports, and active time equals elapsed time because a
/// route-less source records no pauses.
public enum SummaryDistanceProvenance: String, Codable, Hashable, Sendable {
    case gpsDerived
    case sourceReported
}

/// Aggregated metrics for an entire running workout.
///
/// `averagePaceSecondsPerKilometer` and `averageSpeedMetersPerSecond` retain
/// their source-compatible names but use active time. Elapsed variants include
/// recording gaps.
public struct RunSummary: Codable, Hashable, Sendable {
    public var totalDistanceMeters: Double
    public var totalElapsedSeconds: Double
    public var totalActiveSeconds: Double
    public var totalPausedSeconds: Double
    public var averagePaceSecondsPerKilometer: Double
    public var elapsedPaceSecondsPerKilometer: Double
    public var averageSpeedMetersPerSecond: Double
    public var elapsedAverageSpeedMetersPerSecond: Double
    public var elevationGainMeters: Double
    public var elevationLossMeters: Double
    public var totalMovingSeconds: Double
    public var totalStoppedSeconds: Double
    /// Estimated moving pace; active pace remains the canonical pace field.
    public var movingPaceSecondsPerKilometer: Double
    /// Estimated moving speed; active speed remains the canonical speed field.
    public var movingAverageSpeedMetersPerSecond: Double
    public var averageHeartRateBPM: Double?
    public var maxHeartRateBPM: Double?
    public var caloriesEstimate: Double?
    /// Mean valid running power in watts. Nil when the source carried none.
    public var averagePowerWatts: Double?
    /// Maximum valid running power in watts.
    public var maxPowerWatts: Double?
    /// Highest mean power over any 1200-second window that fits entirely
    /// inside one route segment. A time-domain effort metric (unlike the
    /// distance-domain record windows); nil when no qualifying window exists.
    public var best20MinutePowerWatts: Double?
    /// Mean ground contact time in milliseconds across valid samples.
    public var averageGroundContactTimeMilliseconds: Double?
    /// Mean vertical oscillation in millimeters across valid samples.
    public var averageVerticalOscillationMillimeters: Double?
    /// Mean vertical ratio in percent across valid samples.
    public var averageVerticalRatioPercent: Double?
    /// Mean stance time balance in percent across valid samples.
    public var averageStanceTimeBalancePercent: Double?
    /// Mean step length in meters across valid samples.
    public var averageStepLengthMeters: Double?
    /// Raw ascent: sum of positive adjacent altitude deltas within one route
    /// segment, with no spike rejection, smoothing, or deadband. `nil` when no
    /// two adjacent points carry finite altitude. Trends uses this as the
    /// fallback when corrected elevation is not meaningful.
    public var rawElevationGainMeters: Double?
    /// Raw descent counterpart of `rawElevationGainMeters`.
    public var rawElevationLossMeters: Double?
    /// Whether distance and duration were derived from a route or carried
    /// through from the source's own totals (route-less workouts only).
    ///
    /// Defaults to `.gpsDerived`, and `.gpsDerived` is deliberately omitted
    /// from the encoded form so every snapshot written before this field
    /// existed re-encodes byte for byte identically.
    public var distanceProvenance: SummaryDistanceProvenance

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
        self.init(
            totalDistanceMeters: totalDistanceMeters,
            totalElapsedSeconds: totalElapsedSeconds,
            totalActiveSeconds: totalElapsedSeconds,
            totalPausedSeconds: 0,
            totalMovingSeconds: totalElapsedSeconds,
            totalStoppedSeconds: 0,
            movingPaceSecondsPerKilometer: averagePaceSecondsPerKilometer,
            movingAverageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
            averagePaceSecondsPerKilometer: averagePaceSecondsPerKilometer,
            elapsedPaceSecondsPerKilometer: averagePaceSecondsPerKilometer,
            averageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
            elapsedAverageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
            elevationGainMeters: elevationGainMeters,
            elevationLossMeters: elevationLossMeters,
            averageHeartRateBPM: averageHeartRateBPM,
            maxHeartRateBPM: maxHeartRateBPM,
            caloriesEstimate: caloriesEstimate
        )
    }

    public init(
        totalDistanceMeters: Double = 0,
        totalElapsedSeconds: Double = 0,
        totalActiveSeconds: Double,
        totalPausedSeconds: Double? = nil,
        totalMovingSeconds: Double? = nil,
        totalStoppedSeconds: Double? = nil,
        movingPaceSecondsPerKilometer: Double? = nil,
        movingAverageSpeedMetersPerSecond: Double? = nil,
        averagePaceSecondsPerKilometer: Double = 0,
        elapsedPaceSecondsPerKilometer: Double? = nil,
        averageSpeedMetersPerSecond: Double = 0,
        elapsedAverageSpeedMetersPerSecond: Double? = nil,
        elevationGainMeters: Double = 0,
        elevationLossMeters: Double = 0,
        averageHeartRateBPM: Double? = nil,
        maxHeartRateBPM: Double? = nil,
        caloriesEstimate: Double? = nil,
        averagePowerWatts: Double? = nil,
        maxPowerWatts: Double? = nil,
        best20MinutePowerWatts: Double? = nil,
        averageGroundContactTimeMilliseconds: Double? = nil,
        averageVerticalOscillationMillimeters: Double? = nil,
        averageVerticalRatioPercent: Double? = nil,
        averageStanceTimeBalancePercent: Double? = nil,
        averageStepLengthMeters: Double? = nil,
        rawElevationGainMeters: Double? = nil,
        rawElevationLossMeters: Double? = nil,
        distanceProvenance: SummaryDistanceProvenance = .gpsDerived
    ) {
        let elapsed = Self.nonNegativeFinite(totalElapsedSeconds)
        let active = min(Self.nonNegativeFinite(totalActiveSeconds), elapsed)

        self.totalDistanceMeters = Self.nonNegativeFinite(totalDistanceMeters)
        self.totalElapsedSeconds = elapsed
        self.totalActiveSeconds = active
        self.totalPausedSeconds = Self.nonNegativeFinite(elapsed - active)
        let moving = min(Self.nonNegativeFinite(totalMovingSeconds ?? active), active)
        self.totalMovingSeconds = moving
        // This derived invariant intentionally wins over inconsistent input.
        self.totalStoppedSeconds = max(0, active - moving)
        _ = totalPausedSeconds
        _ = totalStoppedSeconds
        self.averagePaceSecondsPerKilometer = Self.nonNegativeFinite(averagePaceSecondsPerKilometer)
        self.elapsedPaceSecondsPerKilometer = Self.nonNegativeFinite(
            elapsedPaceSecondsPerKilometer ?? averagePaceSecondsPerKilometer
        )
        self.averageSpeedMetersPerSecond = Self.nonNegativeFinite(averageSpeedMetersPerSecond)
        self.elapsedAverageSpeedMetersPerSecond = Self.nonNegativeFinite(
            elapsedAverageSpeedMetersPerSecond ?? averageSpeedMetersPerSecond
        )
        let derivedMovingSpeed = moving > 0 ? self.totalDistanceMeters / moving : 0
        self.movingAverageSpeedMetersPerSecond = Self.nonNegativeFinite(
            movingAverageSpeedMetersPerSecond ?? derivedMovingSpeed
        )
        self.movingPaceSecondsPerKilometer = Self.nonNegativeFinite(
            movingPaceSecondsPerKilometer ?? (self.movingAverageSpeedMetersPerSecond > 0
                ? 1_000 / self.movingAverageSpeedMetersPerSecond : 0)
        )
        self.elevationGainMeters = Self.nonNegativeFinite(elevationGainMeters)
        self.elevationLossMeters = Self.nonNegativeFinite(elevationLossMeters)
        self.averageHeartRateBPM = Self.finiteOptional(averageHeartRateBPM)
        self.maxHeartRateBPM = Self.finiteOptional(maxHeartRateBPM)
        self.caloriesEstimate = Self.nonNegativeFiniteOptional(caloriesEstimate)
        self.averagePowerWatts = Self.nonNegativeFiniteOptional(averagePowerWatts)
        self.maxPowerWatts = Self.nonNegativeFiniteOptional(maxPowerWatts)
        self.best20MinutePowerWatts = Self.nonNegativeFiniteOptional(best20MinutePowerWatts)
        self.averageGroundContactTimeMilliseconds = Self.nonNegativeFiniteOptional(
            averageGroundContactTimeMilliseconds
        )
        self.averageVerticalOscillationMillimeters = Self.nonNegativeFiniteOptional(
            averageVerticalOscillationMillimeters
        )
        self.averageVerticalRatioPercent = Self.nonNegativeFiniteOptional(
            averageVerticalRatioPercent
        )
        self.averageStanceTimeBalancePercent = Self.nonNegativeFiniteOptional(
            averageStanceTimeBalancePercent
        )
        self.averageStepLengthMeters = Self.nonNegativeFiniteOptional(
            averageStepLengthMeters
        )
        self.rawElevationGainMeters = Self.nonNegativeFiniteOptional(rawElevationGainMeters)
        self.rawElevationLossMeters = Self.nonNegativeFiniteOptional(rawElevationLossMeters)
        self.distanceProvenance = distanceProvenance
    }

    /// Total distance in kilometers.
    public var totalDistanceKilometers: Double {
        totalDistanceMeters / 1000.0
    }

    /// Formatted active pace as MM:SS per km.
    public var formattedPace: String {
        DisplayFormatter.formatPace(averagePaceSecondsPerKilometer)
    }

    public var formattedElapsedPace: String {
        DisplayFormatter.formatPace(elapsedPaceSecondsPerKilometer)
    }

    public var formattedElapsed: String {
        DisplayFormatter.formatDuration(totalElapsedSeconds)
    }

    public var formattedActive: String {
        DisplayFormatter.formatDuration(totalActiveSeconds)
    }

    public var formattedPaused: String {
        DisplayFormatter.formatDuration(totalPausedSeconds)
    }

    public var formattedMoving: String {
        DisplayFormatter.formatDuration(totalMovingSeconds)
    }

    public var formattedStopped: String {
        DisplayFormatter.formatDuration(totalStoppedSeconds)
    }

    public var formattedMovingPace: String {
        DisplayFormatter.formatPace(movingPaceSecondsPerKilometer)
    }

    /// Backward-compatible display alias. Duration means true elapsed time.
    public var formattedDuration: String {
        formattedElapsed
    }

    /// Formatted total distance.
    public var formattedDistance: String {
        DisplayFormatter.formatDistanceKm(totalDistanceMeters)
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case totalDistanceMeters
        case totalElapsedSeconds
        case totalActiveSeconds
        case totalPausedSeconds
        case totalMovingSeconds
        case totalStoppedSeconds
        case movingPaceSecondsPerKilometer
        case movingAverageSpeedMetersPerSecond
        case averagePaceSecondsPerKilometer
        case elapsedPaceSecondsPerKilometer
        case averageSpeedMetersPerSecond
        case elapsedAverageSpeedMetersPerSecond
        case elevationGainMeters
        case elevationLossMeters
        case averageHeartRateBPM
        case maxHeartRateBPM
        case caloriesEstimate
        case averagePowerWatts
        case maxPowerWatts
        case best20MinutePowerWatts
        case averageGroundContactTimeMilliseconds
        case averageVerticalOscillationMillimeters
        case averageVerticalRatioPercent
        case averageStanceTimeBalancePercent
        case averageStepLengthMeters
        case rawElevationGainMeters
        case rawElevationLossMeters
        case distanceProvenance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyElapsed = try container.decode(Double.self, forKey: .totalElapsedSeconds)
        let active = try container.decodeIfPresent(Double.self, forKey: .totalActiveSeconds) ?? legacyElapsed
        let activePace = try container.decode(Double.self, forKey: .averagePaceSecondsPerKilometer)
        let activeSpeed = try container.decode(Double.self, forKey: .averageSpeedMetersPerSecond)

        self.init(
            totalDistanceMeters: try container.decode(Double.self, forKey: .totalDistanceMeters),
            totalElapsedSeconds: legacyElapsed,
            totalActiveSeconds: active,
            totalPausedSeconds: try container.decodeIfPresent(Double.self, forKey: .totalPausedSeconds),
            totalMovingSeconds: try container.decodeIfPresent(Double.self, forKey: .totalMovingSeconds),
            totalStoppedSeconds: try container.decodeIfPresent(Double.self, forKey: .totalStoppedSeconds),
            movingPaceSecondsPerKilometer: try container.decodeIfPresent(Double.self, forKey: .movingPaceSecondsPerKilometer),
            movingAverageSpeedMetersPerSecond: try container.decodeIfPresent(Double.self, forKey: .movingAverageSpeedMetersPerSecond),
            averagePaceSecondsPerKilometer: activePace,
            elapsedPaceSecondsPerKilometer: try container.decodeIfPresent(Double.self, forKey: .elapsedPaceSecondsPerKilometer) ?? activePace,
            averageSpeedMetersPerSecond: activeSpeed,
            elapsedAverageSpeedMetersPerSecond: try container.decodeIfPresent(Double.self, forKey: .elapsedAverageSpeedMetersPerSecond) ?? activeSpeed,
            elevationGainMeters: try container.decode(Double.self, forKey: .elevationGainMeters),
            elevationLossMeters: try container.decode(Double.self, forKey: .elevationLossMeters),
            averageHeartRateBPM: try container.decodeIfPresent(Double.self, forKey: .averageHeartRateBPM),
            maxHeartRateBPM: try container.decodeIfPresent(Double.self, forKey: .maxHeartRateBPM),
            caloriesEstimate: try container.decodeIfPresent(Double.self, forKey: .caloriesEstimate),
            averagePowerWatts: try container.decodeIfPresent(Double.self, forKey: .averagePowerWatts),
            maxPowerWatts: try container.decodeIfPresent(Double.self, forKey: .maxPowerWatts),
            best20MinutePowerWatts: try container.decodeIfPresent(Double.self, forKey: .best20MinutePowerWatts),
            averageGroundContactTimeMilliseconds: try container.decodeIfPresent(Double.self, forKey: .averageGroundContactTimeMilliseconds),
            averageVerticalOscillationMillimeters: try container.decodeIfPresent(Double.self, forKey: .averageVerticalOscillationMillimeters),
            averageVerticalRatioPercent: try container.decodeIfPresent(Double.self, forKey: .averageVerticalRatioPercent),
            averageStanceTimeBalancePercent: try container.decodeIfPresent(Double.self, forKey: .averageStanceTimeBalancePercent),
            averageStepLengthMeters: try container.decodeIfPresent(Double.self, forKey: .averageStepLengthMeters),
            rawElevationGainMeters: try container.decodeIfPresent(Double.self, forKey: .rawElevationGainMeters),
            rawElevationLossMeters: try container.decodeIfPresent(Double.self, forKey: .rawElevationLossMeters),
            // Absent on every snapshot written before provenance existed, and
            // those summaries were all route-derived by construction.
            distanceProvenance: try container.decodeIfPresent(
                SummaryDistanceProvenance.self,
                forKey: .distanceProvenance
            ) ?? .gpsDerived
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalDistanceMeters, forKey: .totalDistanceMeters)
        try container.encode(totalElapsedSeconds, forKey: .totalElapsedSeconds)
        try container.encode(totalActiveSeconds, forKey: .totalActiveSeconds)
        try container.encode(totalPausedSeconds, forKey: .totalPausedSeconds)
        try container.encode(totalMovingSeconds, forKey: .totalMovingSeconds)
        try container.encode(totalStoppedSeconds, forKey: .totalStoppedSeconds)
        try container.encode(movingPaceSecondsPerKilometer, forKey: .movingPaceSecondsPerKilometer)
        try container.encode(movingAverageSpeedMetersPerSecond, forKey: .movingAverageSpeedMetersPerSecond)
        try container.encode(averagePaceSecondsPerKilometer, forKey: .averagePaceSecondsPerKilometer)
        try container.encode(elapsedPaceSecondsPerKilometer, forKey: .elapsedPaceSecondsPerKilometer)
        try container.encode(averageSpeedMetersPerSecond, forKey: .averageSpeedMetersPerSecond)
        try container.encode(elapsedAverageSpeedMetersPerSecond, forKey: .elapsedAverageSpeedMetersPerSecond)
        try container.encode(elevationGainMeters, forKey: .elevationGainMeters)
        try container.encode(elevationLossMeters, forKey: .elevationLossMeters)
        try container.encodeIfPresent(averageHeartRateBPM, forKey: .averageHeartRateBPM)
        try container.encodeIfPresent(maxHeartRateBPM, forKey: .maxHeartRateBPM)
        try container.encodeIfPresent(caloriesEstimate, forKey: .caloriesEstimate)
        try container.encodeIfPresent(averagePowerWatts, forKey: .averagePowerWatts)
        try container.encodeIfPresent(maxPowerWatts, forKey: .maxPowerWatts)
        try container.encodeIfPresent(best20MinutePowerWatts, forKey: .best20MinutePowerWatts)
        try container.encodeIfPresent(averageGroundContactTimeMilliseconds, forKey: .averageGroundContactTimeMilliseconds)
        try container.encodeIfPresent(averageVerticalOscillationMillimeters, forKey: .averageVerticalOscillationMillimeters)
        try container.encodeIfPresent(averageVerticalRatioPercent, forKey: .averageVerticalRatioPercent)
        try container.encodeIfPresent(averageStanceTimeBalancePercent, forKey: .averageStanceTimeBalancePercent)
        try container.encodeIfPresent(averageStepLengthMeters, forKey: .averageStepLengthMeters)
        try container.encodeIfPresent(rawElevationGainMeters, forKey: .rawElevationGainMeters)
        try container.encodeIfPresent(rawElevationLossMeters, forKey: .rawElevationLossMeters)
        // Omit the historical default so snapshots written before this field
        // existed re-encode byte for byte identically.
        if distanceProvenance != .gpsDerived {
            try container.encode(distanceProvenance, forKey: .distanceProvenance)
        }
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func finiteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func nonNegativeFiniteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}
