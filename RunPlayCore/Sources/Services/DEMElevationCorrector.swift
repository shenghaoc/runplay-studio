import Foundation

// MARK: - Tile source

/// Heights for one decoded DEM tile: `tileSize * tileSize` values in metres,
/// row-major from the tile's north-west pixel, at pixel centres. Non-finite
/// values read as unusable heights.
public struct DEMDecodedTile: Sendable {
    public let key: DEMTileKey
    public let heightsMeters: [Float]

    public init(key: DEMTileKey, heightsMeters: [Float]) {
        self.key = key
        self.heightsMeters = heightsMeters
    }
}

/// What a tile source produced for one request.
public struct DEMTileLoadResult: Sendable {
    /// Decoded tiles, each one of the requested keys.
    public var tiles: [DEMDecodedTile]
    /// Requested tiles whose file exists but could not be read or decoded.
    public var unreadableTiles: [DEMTileKey]

    public init(tiles: [DEMDecodedTile] = [], unreadableTiles: [DEMTileKey] = []) {
        self.tiles = tiles
        self.unreadableTiles = unreadableTiles
    }
}

/// A folder of DEM tiles at one zoom and tile size.
///
/// A correction asks once for exactly the tiles its route's samples read. A
/// requested tile the source does not have is left out of the result, and the
/// points it would cover keep their recorded altitude.
public protocol DEMTileSource: Sendable {
    var tileSet: DEMTileSetIdentity { get }

    /// Decodes whichever of `keys` the source has. Throws only for
    /// cancellation or a failure of the whole source; one bad tile belongs in
    /// `unreadableTiles`.
    func loadTiles(
        _ keys: [DEMTileKey],
        isCancelled: @Sendable () -> Bool
    ) throws -> DEMTileLoadResult
}

// MARK: - Corrector

public enum DEMElevationCorrectionError: Error, Equatable, Sendable {
    /// The tile set's zoom or tile size is outside what the engine samples.
    case unsupportedTileSet
    /// The route exceeds the supported workout size.
    case routeTooLarge
    /// The sampling engine rejected its input: a defect, not a data problem.
    case samplingFailed
}

/// Writes DEM elevation onto a workout's route points and refreshes every
/// result that depends on elevation.
///
/// Precedence is decided here, once per point: a recorded altitude from an
/// onboard barometer outranks DEM, DEM outranks every other recorded altitude,
/// and DEM fills points that have none. A point no present, plausible tile
/// covers keeps its recorded altitude, so a missing or unreadable tile never
/// fails a correction and never invents elevation. Each correction replaces
/// the workout's DEM elevation and correction record completely.
public struct DEMElevationCorrector: Sendable {
    public struct Policy: Hashable, Sendable {
        /// Heights outside this range, such as no-data fill values, are unusable.
        public var plausibleElevationMeters: ClosedRange<Double>
        /// Decoded height bytes one correction may hold. The tile budget follows
        /// from it; handing the heights to the engine briefly doubles it.
        public var maximumDecodedTileBytes: Int
        public var cancellationCheckStride: Int

        public init(
            plausibleElevationMeters: ClosedRange<Double> = -500...9_000,
            maximumDecodedTileBytes: Int = 64 << 20,
            cancellationCheckStride: Int = 2_048
        ) {
            self.plausibleElevationMeters = plausibleElevationMeters
            self.maximumDecodedTileBytes = maximumDecodedTileBytes
            self.cancellationCheckStride = cancellationCheckStride
        }

        public static let standard = Policy()

        /// Tiles of `tileSize` pixels one correction may decode; at least one.
        public func tileBudget(tileSize: Int) -> Int {
            let tileBytes = max(1, tileSize * tileSize * MemoryLayout<Float>.size)
            return min(
                RunPlayEngineLimits.demMaximumTileCount,
                max(1, maximumDecodedTileBytes / tileBytes)
            )
        }
    }

    public let policy: Policy

    public init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// Samples `source` along the workout's route, writes DEM elevation where
    /// precedence allows, reanalyzes elevation, and records the outcome on the
    /// workout, which is left unchanged if this throws.
    @discardableResult
    public func correct(
        _ workout: inout RunWorkout,
        using source: any DEMTileSource,
        at date: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) throws -> DEMElevationCorrection {
        let tileSet = source.tileSet
        guard RunPlayEngineLimits.demZoomRange.contains(tileSet.zoom),
              RunPlayEngineLimits.demTileSizeRange.contains(tileSet.tileSize)
        else {
            throw DEMElevationCorrectionError.unsupportedTileSet
        }
        let grid = RunPlayDemSamplingGrid(
            zoom: tileSet.zoom,
            tileSize: tileSet.tileSize,
            maximumTileCount: policy.tileBudget(tileSize: tileSet.tileSize),
            plausibleElevationMeters: policy.plausibleElevationMeters
        )

        var loadedKeys = Set<DEMTileKey>()
        var unreadableKeys = Set<DEMTileKey>()
        let outcome: RunPlayDemSamplingOutcome
        do {
            outcome = try RunPlayDemElevationBridge.sampleElevations(
                routePoints: workout.routePoints,
                grid: grid,
                cancellationCheckStride: policy.cancellationCheckStride,
                loadTiles: { planned in
                    let accepted = Self.acceptedTiles(
                        try source.loadTiles(planned.map(DEMTileKey.init), isCancelled: isCancelled),
                        planned: planned,
                        tileSize: tileSet.tileSize
                    )
                    loadedKeys = accepted.loaded
                    unreadableKeys = accepted.unreadable
                    return accepted.tiles
                },
                isCancelled: isCancelled
            )
        } catch let error as RunPlayDemElevationBridgeError {
            throw error == .resourceLimit
                ? DEMElevationCorrectionError.routeTooLarge
                : DEMElevationCorrectionError.samplingFailed
        }

        let record: DEMElevationCorrection
        var demAltitudes = [Double?](repeating: nil, count: workout.routePoints.count)
        switch outcome {
        case .tileBudgetExceeded(let minimumRequiredTileCount):
            record = DEMElevationCorrection(
                outcome: .tileBudgetExceeded(
                    minimumRequiredTileCount: minimumRequiredTileCount,
                    tileBudget: grid.maximumTileCount
                ),
                tileSet: tileSet,
                correctedAt: date
            )
        case .sampled(let result):
            var coverage = DEMElevationCoverage()
            coverage.pointCount = workout.routePoints.count
            coverage.sampledPointCount = result.sampledCount
            coverage.missingTilePointCount = result.missingTileCount
            coverage.implausibleHeightPointCount = result.implausibleHeightCount
            coverage.invalidCoordinatePointCount = result.invalidCoordinateCount
            coverage.outsideProjectionPointCount = result.outsideProjectionCount
            coverage.plannedTileCount = result.plannedTiles.count
            coverage.loadedTileCount = result.loadedTileCount
            coverage.unreadableTileCount = unreadableKeys.count

            let keepsRecorded = workout.recordedAltitudeSensor == .barometric
            let stride = max(1, policy.cancellationCheckStride)
            for (index, point) in workout.routePoints.enumerated() {
                if index.isMultiple(of: stride), isCancelled() {
                    throw CancellationError()
                }
                guard let elevation = result.elevationsMeters[index] else { continue }
                let hasRecorded = point.altitudeMeters?.isFinite == true
                if hasRecorded && keepsRecorded {
                    coverage.keptBarometricPointCount += 1
                } else {
                    demAltitudes[index] = elevation
                    if hasRecorded {
                        coverage.replacedRecordedPointCount += 1
                    } else {
                        coverage.filledMissingPointCount += 1
                    }
                }
            }
            record = DEMElevationCorrection(
                outcome: result.sampledCount > 0 ? .applied : .noCoverage,
                tileSet: tileSet,
                correctedAt: date,
                coverage: coverage,
                missingTiles: result.plannedTiles.lazy
                    .map(DEMTileKey.init)
                    .filter { !loadedKeys.contains($0) && !unreadableKeys.contains($0) },
                unreadableTiles: Array(unreadableKeys)
            )
        }

        try apply(demAltitudes, record: record, to: &workout, isCancelled: isCancelled)
        return record
    }

    /// Removes the workout's DEM elevation, reanalyzes with recorded altitude,
    /// and records the opt-out so library passes leave the workout alone.
    public func useRecordedElevation(
        _ workout: inout RunWorkout,
        at date: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) throws {
        try apply(
            [Double?](repeating: nil, count: workout.routePoints.count),
            record: DEMElevationCorrection(outcome: .optedOut, tileSet: nil, correctedAt: date),
            to: &workout,
            isCancelled: isCancelled
        )
    }

    private func apply(
        _ demAltitudes: [Double?],
        record: DEMElevationCorrection,
        to workout: inout RunWorkout,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        var updated = workout
        var changed = false
        for index in updated.routePoints.indices
        where updated.routePoints[index].demAltitudeMeters != demAltitudes[index] {
            updated.routePoints[index].demAltitudeMeters = demAltitudes[index]
            changed = true
        }
        if changed {
            try WorkoutAnalyzer().reanalyzeAfterElevationChange(
                &updated,
                previousRoutePoints: workout.routePoints,
                isCancelled: isCancelled
            )
        }
        updated.demElevationCorrection = record
        workout = updated
    }

    /// Keeps each planned tile once, at the grid's size, unless the source
    /// called it unreadable. A wrongly sized tile counts as unreadable; a tile
    /// that was never requested, or a repeat, is dropped.
    static func acceptedTiles(
        _ load: DEMTileLoadResult,
        planned: [RunPlayDemTileKey],
        tileSize: Int
    ) -> (tiles: [RunPlayDemDecodedTile], loaded: Set<DEMTileKey>, unreadable: Set<DEMTileKey>) {
        let plannedKeys = Set(planned.map(DEMTileKey.init))
        var unreadable = Set(load.unreadableTiles).intersection(plannedKeys)
        var loaded = Set<DEMTileKey>()
        var tiles: [RunPlayDemDecodedTile] = []
        tiles.reserveCapacity(min(load.tiles.count, plannedKeys.count))
        for tile in load.tiles
        where plannedKeys.contains(tile.key)
            && !unreadable.contains(tile.key)
            && !loaded.contains(tile.key) {
            guard tile.heightsMeters.count == tileSize * tileSize else {
                unreadable.insert(tile.key)
                continue
            }
            loaded.insert(tile.key)
            tiles.append(RunPlayDemDecodedTile(
                key: RunPlayDemTileKey(x: UInt32(tile.key.x), y: UInt32(tile.key.y)),
                heightsMeters: tile.heightsMeters
            ))
        }
        return (tiles, loaded, unreadable)
    }
}

extension DEMTileKey {
    init(_ key: RunPlayDemTileKey) {
        self.init(x: Int(key.x), y: Int(key.y))
    }
}
