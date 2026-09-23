import Foundation

// MARK: - Recorded altitude sensor

/// What a workout's source file says about the sensor behind its recorded
/// altitude. It decides whether DEM elevation may replace recorded altitude:
/// barometric altitude outranks DEM, and DEM outranks every other recorded
/// altitude.
public enum RecordedAltitudeSensor: Hashable, Sendable {
    /// The source declares an onboard barometric altimeter. Only FIT carries
    /// this evidence: a `device_info` message whose `source_type` is local and
    /// whose `device_type` is barometer (see `FITAltitudeSensorEvidence`).
    case barometric
    /// The source does not say. Recorded altitude may be GPS-derived,
    /// barometric, or already corrected by another service; DEM elevation
    /// replaces it wherever a tile covers the point.
    case unknown
}

extension RecordedAltitudeSensor: Codable {
    public init(from decoder: any Decoder) throws {
        // A value this build does not know decodes as `.unknown` instead of
        // failing the workout snapshot (#207).
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "barometric" ? .barometric : .unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .barometric ? "barometric" : "unknown")
    }
}

// MARK: - DEM tiles

/// One XYZ tile of a DEM tile folder at its tile set's zoom. `y` counts from
/// the north edge, as `z/x/y` tile folders do (not TMS). Ordered by (y, x).
public struct DEMTileKey: Hashable, Comparable, Codable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static func < (lhs: DEMTileKey, rhs: DEMTileKey) -> Bool {
        lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x
    }
}

/// The tiles a DEM correction read: which folder, at which zoom and tile size.
/// A correction made with a different identity than the current settings is
/// stale.
public struct DEMTileSetIdentity: Hashable, Codable, Sendable {
    /// Minted when the user chooses a folder; never a path.
    public let folderID: UUID
    public let zoom: Int
    public let tileSize: Int

    public init(folderID: UUID, zoom: Int, tileSize: Int) {
        self.folderID = folderID
        self.zoom = zoom
        self.tileSize = tileSize
    }
}

// MARK: - Coverage

/// Point and tile counts from one DEM correction pass.
///
/// Every point gets exactly one sampling status, so the five status counts sum
/// to `pointCount`; every sampled point is used exactly one way, so the three
/// usage counts sum to `sampledPointCount`.
public struct DEMElevationCoverage: Hashable, Sendable {
    public var pointCount = 0

    // Sampling status
    public var sampledPointCount = 0
    public var missingTilePointCount = 0
    public var implausibleHeightPointCount = 0
    public var invalidCoordinatePointCount = 0
    public var outsideProjectionPointCount = 0

    // How sampled points were used
    /// DEM elevation replaced a recorded altitude whose sensor is unknown.
    public var replacedRecordedPointCount = 0
    /// DEM elevation filled a point that had no recorded altitude.
    public var filledMissingPointCount = 0
    /// Recorded barometric altitude outranked the DEM sample.
    public var keptBarometricPointCount = 0

    // Tiles
    public var plannedTileCount = 0
    public var loadedTileCount = 0
    /// Planned tiles whose file exists but could not be read or decoded.
    public var unreadableTileCount = 0

    public init() {}

    /// Points that carry DEM elevation after the pass.
    public var appliedPointCount: Int {
        replacedRecordedPointCount + filledMissingPointCount
    }

    /// Planned tiles the folder does not have.
    public var missingTileCount: Int {
        max(0, plannedTileCount - loadedTileCount - unreadableTileCount)
    }

    /// Points a tile could cover: every point with a coordinate inside the
    /// Web Mercator projection.
    public var coverablePointCount: Int {
        sampledPointCount + missingTilePointCount + implausibleHeightPointCount
    }

    /// Share of coverable points that a present tile covered, in 0...1; `nil`
    /// when no point was coverable.
    public var tileCoverageFraction: Double? {
        guard coverablePointCount > 0 else { return nil }
        return Double(sampledPointCount) / Double(coverablePointCount)
    }
}

extension DEMElevationCoverage: Codable {
    private enum CodingKeys: String, CodingKey {
        case pointCount, sampledPointCount, missingTilePointCount
        case implausibleHeightPointCount, invalidCoordinatePointCount, outsideProjectionPointCount
        case replacedRecordedPointCount, filledMissingPointCount, keptBarometricPointCount
        case plannedTileCount, loadedTileCount, unreadableTileCount
    }

    /// Every count defaults to zero when absent, so a later build can add a
    /// count without making this build's snapshots undecodable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int {
            try container.decodeIfPresent(Int.self, forKey: key) ?? 0
        }
        pointCount = try count(.pointCount)
        sampledPointCount = try count(.sampledPointCount)
        missingTilePointCount = try count(.missingTilePointCount)
        implausibleHeightPointCount = try count(.implausibleHeightPointCount)
        invalidCoordinatePointCount = try count(.invalidCoordinatePointCount)
        outsideProjectionPointCount = try count(.outsideProjectionPointCount)
        replacedRecordedPointCount = try count(.replacedRecordedPointCount)
        filledMissingPointCount = try count(.filledMissingPointCount)
        keptBarometricPointCount = try count(.keptBarometricPointCount)
        plannedTileCount = try count(.plannedTileCount)
        loadedTileCount = try count(.loadedTileCount)
        unreadableTileCount = try count(.unreadableTileCount)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pointCount, forKey: .pointCount)
        try container.encode(sampledPointCount, forKey: .sampledPointCount)
        try container.encode(missingTilePointCount, forKey: .missingTilePointCount)
        try container.encode(implausibleHeightPointCount, forKey: .implausibleHeightPointCount)
        try container.encode(invalidCoordinatePointCount, forKey: .invalidCoordinatePointCount)
        try container.encode(outsideProjectionPointCount, forKey: .outsideProjectionPointCount)
        try container.encode(replacedRecordedPointCount, forKey: .replacedRecordedPointCount)
        try container.encode(filledMissingPointCount, forKey: .filledMissingPointCount)
        try container.encode(keptBarometricPointCount, forKey: .keptBarometricPointCount)
        try container.encode(plannedTileCount, forKey: .plannedTileCount)
        try container.encode(loadedTileCount, forKey: .loadedTileCount)
        try container.encode(unreadableTileCount, forKey: .unreadableTileCount)
    }
}

// MARK: - Correction record

/// The outcome of the last DEM elevation correction of one workout.
///
/// Stored on the workout snapshot beside the per-point
/// `RoutePoint.demAltitudeMeters` values it describes. `nil` on a workout means
/// it was never corrected.
public struct DEMElevationCorrection: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// DEM elevation was written wherever a present tile covered a point
        /// and precedence allowed it (possibly nowhere, when recorded
        /// barometric altitude outranked every sample).
        case applied
        /// No point was covered by a present, plausible tile; recorded
        /// altitude is used everywhere.
        case noCoverage
        /// The route needs more tiles than one pass may decode at this zoom;
        /// recorded altitude is used everywhere.
        case tileBudgetExceeded(minimumRequiredTileCount: Int, tileBudget: Int)
        /// The user chose recorded elevation for this workout; library passes
        /// leave it alone.
        case optedOut
    }

    /// At most this many missing and unreadable tiles are listed; the counts
    /// in `coverage` are always complete.
    public static let listedTileLimit = 16

    public var outcome: Outcome
    /// The tiles used. `nil` only for `.optedOut`.
    public var tileSet: DEMTileSetIdentity?
    public var correctedAt: Date
    public var coverage: DEMElevationCoverage
    /// The first planned tiles the folder does not have, ascending by (y, x).
    public var missingTiles: [DEMTileKey]
    /// The first planned tiles whose file could not be read, ascending by (y, x).
    public var unreadableTiles: [DEMTileKey]

    public init(
        outcome: Outcome,
        tileSet: DEMTileSetIdentity?,
        correctedAt: Date,
        coverage: DEMElevationCoverage = DEMElevationCoverage(),
        missingTiles: [DEMTileKey] = [],
        unreadableTiles: [DEMTileKey] = []
    ) {
        self.outcome = outcome
        self.tileSet = tileSet
        self.correctedAt = correctedAt
        self.coverage = coverage
        self.missingTiles = Array(missingTiles.sorted().prefix(Self.listedTileLimit))
        self.unreadableTiles = Array(unreadableTiles.sorted().prefix(Self.listedTileLimit))
    }

    /// Whether a library pass with `tileSet` could change this workout.
    ///
    /// Opted-out workouts are never touched. A different tile set always
    /// warrants a pass. With the same tile set, a pass is worthwhile only when
    /// some point lacked a tile or a tile could not be read, because tiles may
    /// have been added or repaired since; a fully covered workout, or one
    /// whose route exceeds the budget at this tile set, would not change.
    public func shouldRecorrect(with tileSet: DEMTileSetIdentity) -> Bool {
        switch outcome {
        case .optedOut:
            return false
        case .tileBudgetExceeded:
            return self.tileSet != tileSet
        case .applied, .noCoverage:
            return self.tileSet != tileSet
                || coverage.missingTilePointCount > 0
                || coverage.unreadableTileCount > 0
        }
    }
}

extension DEMElevationCorrection.Outcome {
    /// The outcome's name in snapshots and exports; decoding reads the same
    /// names back.
    var name: String {
        switch self {
        case .applied: "applied"
        case .noCoverage: "noCoverage"
        case .tileBudgetExceeded: "tileBudgetExceeded"
        case .optedOut: "optedOut"
        }
    }
}

extension DEMElevationCorrection: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome, minimumRequiredTileCount, tileBudget
        case tileSet, correctedAt, coverage, missingTiles, unreadableTiles
    }

    private enum OutcomeKind: String {
        case applied, noCoverage, tileBudgetExceeded, optedOut
    }

    /// An outcome this build does not know throws; `RunWorkout` decodes the
    /// record lossily, so the workout still loads with no correction record.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindValue = try container.decode(String.self, forKey: .outcome)
        guard let kind = OutcomeKind(rawValue: kindValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Unknown DEM correction outcome \(kindValue)"
            )
        }
        switch kind {
        case .applied:
            outcome = .applied
        case .noCoverage:
            outcome = .noCoverage
        case .optedOut:
            outcome = .optedOut
        case .tileBudgetExceeded:
            outcome = .tileBudgetExceeded(
                minimumRequiredTileCount: try container.decode(Int.self, forKey: .minimumRequiredTileCount),
                tileBudget: try container.decode(Int.self, forKey: .tileBudget)
            )
        }
        tileSet = try container.decodeIfPresent(DEMTileSetIdentity.self, forKey: .tileSet)
        correctedAt = try container.decode(Date.self, forKey: .correctedAt)
        coverage = try container.decodeIfPresent(DEMElevationCoverage.self, forKey: .coverage)
            ?? DEMElevationCoverage()
        missingTiles = try container.decodeIfPresent([DEMTileKey].self, forKey: .missingTiles) ?? []
        unreadableTiles = try container.decodeIfPresent([DEMTileKey].self, forKey: .unreadableTiles) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome.name, forKey: .outcome)
        if case .tileBudgetExceeded(let minimumRequiredTileCount, let tileBudget) = outcome {
            try container.encode(minimumRequiredTileCount, forKey: .minimumRequiredTileCount)
            try container.encode(tileBudget, forKey: .tileBudget)
        }
        try container.encodeIfPresent(tileSet, forKey: .tileSet)
        try container.encode(correctedAt, forKey: .correctedAt)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(missingTiles, forKey: .missingTiles)
        try container.encode(unreadableTiles, forKey: .unreadableTiles)
    }
}
