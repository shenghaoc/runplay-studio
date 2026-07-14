import Foundation

/// A kilometer or mile split with explicit elapsed and active clocks.
public struct RunSplit: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var splitIndex: Int
    public var distanceMeters: Double
    /// Wall-clock duration between the split boundaries, including pauses.
    public var elapsedSeconds: Double
    /// Recorded timer duration inside continuous route segments.
    public var activeSeconds: Double
    /// Estimated moving time within this split.
    public var movingSeconds: Double
    /// Estimated stopped time within this split.
    public var stoppedSeconds: Double
    /// Active pace retained under the source-compatible canonical name.
    public var paceSecondsPerKilometer: Double
    public var elapsedPaceSecondsPerKilometer: Double
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
        self.init(
            id: id,
            splitIndex: splitIndex,
            distanceMeters: distanceMeters,
            elapsedSeconds: elapsedSeconds,
            activeSeconds: elapsedSeconds,
            movingSeconds: elapsedSeconds,
            stoppedSeconds: 0,
            paceSecondsPerKilometer: paceSecondsPerKilometer,
            elapsedPaceSecondsPerKilometer: paceSecondsPerKilometer,
            averageHeartRateBPM: averageHeartRateBPM,
            elevationGainMeters: elevationGainMeters,
            startDistanceMeters: startDistanceMeters,
            endDistanceMeters: endDistanceMeters
        )
    }

    public init(
        id: UUID = UUID(),
        splitIndex: Int,
        distanceMeters: Double = 1000,
        elapsedSeconds: Double,
        activeSeconds: Double,
        movingSeconds: Double? = nil,
        stoppedSeconds: Double? = nil,
        paceSecondsPerKilometer: Double,
        elapsedPaceSecondsPerKilometer: Double? = nil,
        averageHeartRateBPM: Double? = nil,
        elevationGainMeters: Double? = nil,
        startDistanceMeters: Double,
        endDistanceMeters: Double
    ) {
        let safeElapsed = Self.nonNegativeFinite(elapsedSeconds)
        let safeActive = min(Self.nonNegativeFinite(activeSeconds), safeElapsed)
        self.id = id
        self.splitIndex = max(0, splitIndex)
        self.distanceMeters = Self.nonNegativeFinite(distanceMeters)
        self.elapsedSeconds = safeElapsed
        self.activeSeconds = safeActive
        let safeMoving = min(Self.nonNegativeFinite(movingSeconds ?? safeActive), safeActive)
        self.movingSeconds = safeMoving
        // This derived invariant intentionally wins over inconsistent input.
        self.stoppedSeconds = max(0, safeActive - safeMoving)
        _ = stoppedSeconds
        self.paceSecondsPerKilometer = Self.nonNegativeFinite(paceSecondsPerKilometer)
        self.elapsedPaceSecondsPerKilometer = Self.nonNegativeFinite(
            elapsedPaceSecondsPerKilometer ?? paceSecondsPerKilometer
        )
        self.averageHeartRateBPM = Self.finiteOptional(averageHeartRateBPM)
        self.elevationGainMeters = Self.finiteOptional(elevationGainMeters)
        self.startDistanceMeters = Self.nonNegativeFinite(startDistanceMeters)
        self.endDistanceMeters = max(self.startDistanceMeters, Self.nonNegativeFinite(endDistanceMeters))
    }

    /// Formatted active pace as MM:SS (no "/km" suffix).
    public var formattedPace: String {
        DisplayFormatter.formatPaceShort(paceSecondsPerKilometer)
    }

    public var formattedElapsedPace: String {
        DisplayFormatter.formatPaceShort(elapsedPaceSecondsPerKilometer)
    }

    public var formattedElapsed: String {
        DisplayFormatter.formatElapsed(elapsedSeconds)
    }

    public var formattedActive: String {
        DisplayFormatter.formatElapsed(activeSeconds)
    }

    public var formattedMoving: String {
        DisplayFormatter.formatElapsed(movingSeconds)
    }

    public var formattedStopped: String {
        DisplayFormatter.formatElapsed(stoppedSeconds)
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, splitIndex, distanceMeters, elapsedSeconds, activeSeconds
        case movingSeconds, stoppedSeconds
        case paceSecondsPerKilometer, elapsedPaceSecondsPerKilometer
        case averageHeartRateBPM, elevationGainMeters
        case startDistanceMeters, endDistanceMeters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let elapsed = try container.decode(Double.self, forKey: .elapsedSeconds)
        let active = try container.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? elapsed
        let activePace = try container.decode(Double.self, forKey: .paceSecondsPerKilometer)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            splitIndex: try container.decode(Int.self, forKey: .splitIndex),
            distanceMeters: try container.decode(Double.self, forKey: .distanceMeters),
            elapsedSeconds: elapsed,
            activeSeconds: active,
            movingSeconds: try container.decodeIfPresent(Double.self, forKey: .movingSeconds),
            stoppedSeconds: try container.decodeIfPresent(Double.self, forKey: .stoppedSeconds),
            paceSecondsPerKilometer: activePace,
            elapsedPaceSecondsPerKilometer: try container.decodeIfPresent(Double.self, forKey: .elapsedPaceSecondsPerKilometer) ?? activePace,
            averageHeartRateBPM: try container.decodeIfPresent(Double.self, forKey: .averageHeartRateBPM),
            elevationGainMeters: try container.decodeIfPresent(Double.self, forKey: .elevationGainMeters),
            startDistanceMeters: try container.decode(Double.self, forKey: .startDistanceMeters),
            endDistanceMeters: try container.decode(Double.self, forKey: .endDistanceMeters)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(splitIndex, forKey: .splitIndex)
        try container.encode(distanceMeters, forKey: .distanceMeters)
        try container.encode(elapsedSeconds, forKey: .elapsedSeconds)
        try container.encode(activeSeconds, forKey: .activeSeconds)
        try container.encode(movingSeconds, forKey: .movingSeconds)
        try container.encode(stoppedSeconds, forKey: .stoppedSeconds)
        try container.encode(paceSecondsPerKilometer, forKey: .paceSecondsPerKilometer)
        try container.encode(elapsedPaceSecondsPerKilometer, forKey: .elapsedPaceSecondsPerKilometer)
        try container.encodeIfPresent(averageHeartRateBPM, forKey: .averageHeartRateBPM)
        try container.encodeIfPresent(elevationGainMeters, forKey: .elevationGainMeters)
        try container.encode(startDistanceMeters, forKey: .startDistanceMeters)
        try container.encode(endDistanceMeters, forKey: .endDistanceMeters)
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func finiteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
