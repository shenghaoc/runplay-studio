import Foundation

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
        self.init(
            totalDistanceMeters: totalDistanceMeters,
            totalElapsedSeconds: totalElapsedSeconds,
            totalActiveSeconds: totalElapsedSeconds,
            totalPausedSeconds: 0,
            totalMovingSeconds: totalElapsedSeconds,
            totalStoppedSeconds: 0,
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
        averagePaceSecondsPerKilometer: Double = 0,
        elapsedPaceSecondsPerKilometer: Double? = nil,
        averageSpeedMetersPerSecond: Double = 0,
        elapsedAverageSpeedMetersPerSecond: Double? = nil,
        elevationGainMeters: Double = 0,
        elevationLossMeters: Double = 0,
        averageHeartRateBPM: Double? = nil,
        maxHeartRateBPM: Double? = nil,
        caloriesEstimate: Double? = nil
    ) {
        let elapsed = Self.nonNegativeFinite(totalElapsedSeconds)
        let active = min(Self.nonNegativeFinite(totalActiveSeconds), elapsed)

        self.totalDistanceMeters = Self.nonNegativeFinite(totalDistanceMeters)
        self.totalElapsedSeconds = elapsed
        self.totalActiveSeconds = active
        self.totalPausedSeconds = Self.nonNegativeFinite(elapsed - active)
        let moving = min(Self.nonNegativeFinite(totalMovingSeconds ?? active), active)
        self.totalMovingSeconds = moving
        self.totalStoppedSeconds = Self.nonNegativeFinite(totalStoppedSeconds ?? max(0, active - moving))
        self.averagePaceSecondsPerKilometer = Self.nonNegativeFinite(averagePaceSecondsPerKilometer)
        self.elapsedPaceSecondsPerKilometer = Self.nonNegativeFinite(
            elapsedPaceSecondsPerKilometer ?? averagePaceSecondsPerKilometer
        )
        self.averageSpeedMetersPerSecond = Self.nonNegativeFinite(averageSpeedMetersPerSecond)
        self.elapsedAverageSpeedMetersPerSecond = Self.nonNegativeFinite(
            elapsedAverageSpeedMetersPerSecond ?? averageSpeedMetersPerSecond
        )
        self.elevationGainMeters = Self.nonNegativeFinite(elevationGainMeters)
        self.elevationLossMeters = Self.nonNegativeFinite(elevationLossMeters)
        self.averageHeartRateBPM = Self.finiteOptional(averageHeartRateBPM)
        self.maxHeartRateBPM = Self.finiteOptional(maxHeartRateBPM)
        self.caloriesEstimate = Self.nonNegativeFiniteOptional(caloriesEstimate)
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
        case averagePaceSecondsPerKilometer
        case elapsedPaceSecondsPerKilometer
        case averageSpeedMetersPerSecond
        case elapsedAverageSpeedMetersPerSecond
        case elevationGainMeters
        case elevationLossMeters
        case averageHeartRateBPM
        case maxHeartRateBPM
        case caloriesEstimate
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
            averagePaceSecondsPerKilometer: activePace,
            elapsedPaceSecondsPerKilometer: try container.decodeIfPresent(Double.self, forKey: .elapsedPaceSecondsPerKilometer) ?? activePace,
            averageSpeedMetersPerSecond: activeSpeed,
            elapsedAverageSpeedMetersPerSecond: try container.decodeIfPresent(Double.self, forKey: .elapsedAverageSpeedMetersPerSecond) ?? activeSpeed,
            elevationGainMeters: try container.decode(Double.self, forKey: .elevationGainMeters),
            elevationLossMeters: try container.decode(Double.self, forKey: .elevationLossMeters),
            averageHeartRateBPM: try container.decodeIfPresent(Double.self, forKey: .averageHeartRateBPM),
            maxHeartRateBPM: try container.decodeIfPresent(Double.self, forKey: .maxHeartRateBPM),
            caloriesEstimate: try container.decodeIfPresent(Double.self, forKey: .caloriesEstimate)
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
        try container.encode(averagePaceSecondsPerKilometer, forKey: .averagePaceSecondsPerKilometer)
        try container.encode(elapsedPaceSecondsPerKilometer, forKey: .elapsedPaceSecondsPerKilometer)
        try container.encode(averageSpeedMetersPerSecond, forKey: .averageSpeedMetersPerSecond)
        try container.encode(elapsedAverageSpeedMetersPerSecond, forKey: .elapsedAverageSpeedMetersPerSecond)
        try container.encode(elevationGainMeters, forKey: .elevationGainMeters)
        try container.encode(elevationLossMeters, forKey: .elevationLossMeters)
        try container.encodeIfPresent(averageHeartRateBPM, forKey: .averageHeartRateBPM)
        try container.encodeIfPresent(maxHeartRateBPM, forKey: .maxHeartRateBPM)
        try container.encodeIfPresent(caloriesEstimate, forKey: .caloriesEstimate)
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
