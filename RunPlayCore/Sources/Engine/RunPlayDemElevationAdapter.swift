import Foundation

internal import RunPlayEngine

// MARK: - Pure-Swift values

/// One XYZ tile address at the sampling zoom. `y` counts from the north edge
/// (slippy-map folders), not TMS. Ordered by (y, x): north to south, then west
/// to east, the order every tile list crosses the engine boundary in.
struct RunPlayDemTileKey: Hashable, Comparable, Sendable {
    let x: UInt32
    let y: UInt32

    static func < (lhs: RunPlayDemTileKey, rhs: RunPlayDemTileKey) -> Bool {
        lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x
    }
}

/// The tile grid and plausibility bounds one DEM pass samples with.
struct RunPlayDemSamplingGrid: Equatable, Sendable {
    let zoom: Int
    let tileSize: Int
    /// Distinct tiles one pass may need; a route needing more is not sampled.
    let maximumTileCount: Int
    /// A corner height outside this range, or non-finite, is unusable.
    let plausibleElevationMeters: ClosedRange<Double>
}

/// Heights for one decoded tile: `tileSize * tileSize` values in metres,
/// row-major from the tile's north-west pixel. Non-finite values are allowed
/// and read as unusable heights.
struct RunPlayDemDecodedTile: Sendable {
    let key: RunPlayDemTileKey
    let heightsMeters: [Float]
}

/// Why a route point has, or lacks, a DEM elevation. When several reasons
/// apply the engine reports the first in this order.
enum RunPlayDemSampleStatus: Equatable, Sendable {
    case sampled
    case invalidCoordinate
    case outsideProjection
    case missingTile
    case implausibleHeight
}

/// Per-point DEM elevations for one route, aligned with its route points.
struct RunPlayDemSamplingResult: Sendable {
    /// A value exactly where `statuses` is `.sampled`.
    let elevationsMeters: [Double?]
    let statuses: [RunPlayDemSampleStatus]
    /// Every tile the planner listed, ascending by (y, x).
    let plannedTiles: [RunPlayDemTileKey]
    /// The planned tiles `loadTiles` supplied; the rest were missing.
    let loadedTileCount: Int

    let sampledCount: Int
    let invalidCoordinateCount: Int
    let outsideProjectionCount: Int
    let missingTileCount: Int
    let implausibleHeightCount: Int
}

enum RunPlayDemSamplingOutcome: Sendable {
    case sampled(RunPlayDemSamplingResult)
    /// The route needs more than the grid's `maximumTileCount` tiles. Nothing
    /// was loaded or sampled, so the caller keeps recorded elevation. The count
    /// is a lower bound.
    case tileBudgetExceeded(minimumRequiredTileCount: Int)
}

enum RunPlayDemElevationBridgeError: Error, Equatable {
    case resourceLimit
    case invalidGrid
    /// `loadTiles` returned a tile the planner did not list, a duplicate, or
    /// a tile with the wrong number of heights.
    case invalidLoadedTiles
    case engineContractViolation
}

// MARK: - Adapter

/// Production adapter for the two DEM engine calls.
///
/// One invocation covers one route: it converts the coordinates once, plans the
/// tiles, hands the planned tile list to `loadTiles` (Swift decodes whichever of
/// those tiles exist), packs the decoded heights into one array, and samples.
/// The engine never calls back: `loadTiles` runs in Swift between the two engine
/// calls. Cancellation is checked during conversion, around each engine call,
/// around tile loading, and during translation, never inside an engine call.
enum RunPlayDemElevationBridge {
    static func sampleElevations(
        routePoints: [RoutePoint],
        grid: RunPlayDemSamplingGrid,
        cancellationCheckStride: Int,
        loadTiles: ([RunPlayDemTileKey]) throws -> [RunPlayDemDecodedTile],
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayDemSamplingOutcome {
        let count = routePoints.count
        guard count <= WorkoutImportResourceLimits.maxRoutePointCount else {
            throw RunPlayDemElevationBridgeError.resourceLimit
        }
        let policy = try enginePolicy(for: grid)
        if isCancelled() { throw CancellationError() }

        if count == 0 {
            return .sampled(RunPlayDemSamplingResult(
                elevationsMeters: [], statuses: [], plannedTiles: [], loadedTileCount: 0,
                sampledCount: 0, invalidCoordinateCount: 0, outsideProjectionCount: 0,
                missingTileCount: 0, implausibleHeightCount: 0
            ))
        }

        let stride = max(1, cancellationCheckStride)

        // ---- Coordinates, converted once for both engine calls ----
        var samples = [DemRouteSample]()
        samples.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            samples.append(DemRouteSample(
                latitudeDegrees: routePoints[index].latitude, longitudeDegrees: routePoints[index].longitude
            ))
        }

        // ---- Plan ----
        if isCancelled() { throw CancellationError() }
        NativeCallObserver.record(.demTilePlanning)
        let plan: DemTilePlanResult
        do {
            plan = try DemTilePlanning.plan(samples: samples.span, policy: policy)
        } catch {
            switch error {
            case .tileBudgetExceeded:
                return .tileBudgetExceeded(minimumRequiredTileCount: grid.maximumTileCount + 1)
            case .resourceLimit:
                throw RunPlayDemElevationBridgeError.resourceLimit
            case .invalidPolicy, .internalFailure:
                throw RunPlayDemElevationBridgeError.engineContractViolation
            }
        }
        if isCancelled() { throw CancellationError() }
        let plannedTiles = plan.tiles.map { RunPlayDemTileKey(x: $0.x, y: $0.y) }

        // ---- Swift decodes whichever planned tiles exist ----
        let loaded = plannedTiles.isEmpty ? [] : try loadTiles(plannedTiles)
        if isCancelled() { throw CancellationError() }
        let directory = try validatedDirectory(loaded, plannedTiles: plannedTiles, tileSize: grid.tileSize)

        // ---- Pack the directory and heights ----
        var keys = [DemTileKey]()
        keys.reserveCapacity(directory.count)
        var heights = [Float]()
        heights.reserveCapacity(directory.count * grid.tileSize * grid.tileSize)
        for tile in directory {
            if isCancelled() { throw CancellationError() }
            keys.append(DemTileKey(x: tile.key.x, y: tile.key.y))
            heights.append(contentsOf: tile.heightsMeters)
        }

        // ---- Sample ----
        if isCancelled() { throw CancellationError() }
        NativeCallObserver.record(.demSampling)
        let sampled: DemSamplingResult
        do {
            sampled = try DemElevationSampling.sample(
                samples: samples.span, policy: policy, tiles: keys.span, tileHeights: heights.span
            )
        } catch {
            switch error {
            case .resourceLimit:
                throw RunPlayDemElevationBridgeError.resourceLimit
            case .invalidPolicy, .invalidTileDirectory, .internalFailure:
                // The grid and directory were validated in Swift, so any other
                // error means the two sides disagree about the contract.
                throw RunPlayDemElevationBridgeError.engineContractViolation
            }
        }
        if isCancelled() { throw CancellationError() }
        guard sampled.samples.count == count else {
            throw RunPlayDemElevationBridgeError.engineContractViolation
        }

        // ---- Translate ----
        var elevations: [Double?] = []
        elevations.reserveCapacity(count)
        var statuses: [RunPlayDemSampleStatus] = []
        statuses.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            let output = sampled.samples[index]
            switch output.status {
            case .sampled:
                elevations.append(output.elevationMeters)
                statuses.append(.sampled)
            case .invalidCoordinate:
                elevations.append(nil)
                statuses.append(.invalidCoordinate)
            case .outsideProjection:
                elevations.append(nil)
                statuses.append(.outsideProjection)
            case .missingTile:
                elevations.append(nil)
                statuses.append(.missingTile)
            case .implausibleHeight:
                elevations.append(nil)
                statuses.append(.implausibleHeight)
            }
        }

        guard let sampledCount = Int(exactly: sampled.sampledCount),
              let invalidCount = Int(exactly: sampled.invalidCoordinateCount),
              let outsideCount = Int(exactly: sampled.outsideProjectionCount),
              let missingCount = Int(exactly: sampled.missingTileCount),
              let implausibleCount = Int(exactly: sampled.implausibleHeightCount)
        else {
            throw RunPlayDemElevationBridgeError.engineContractViolation
        }
        return .sampled(RunPlayDemSamplingResult(
            elevationsMeters: elevations, statuses: statuses, plannedTiles: plannedTiles,
            loadedTileCount: directory.count, sampledCount: sampledCount,
            invalidCoordinateCount: invalidCount, outsideProjectionCount: outsideCount,
            missingTileCount: missingCount, implausibleHeightCount: implausibleCount
        ))
    }

    /// The loaded tiles, validated against the plan and sorted into the
    /// directory order the engine requires.
    private static func validatedDirectory(
        _ loaded: [RunPlayDemDecodedTile],
        plannedTiles: [RunPlayDemTileKey],
        tileSize: Int
    ) throws -> [RunPlayDemDecodedTile] {
        let heightsPerTile = tileSize * tileSize
        let planned = Set(plannedTiles)
        var seen = Set<RunPlayDemTileKey>()
        seen.reserveCapacity(loaded.count)
        for tile in loaded {
            guard planned.contains(tile.key),
                  seen.insert(tile.key).inserted,
                  tile.heightsMeters.count == heightsPerTile
            else {
                throw RunPlayDemElevationBridgeError.invalidLoadedTiles
            }
        }
        return loaded.sorted { $0.key < $1.key }
    }

    private static func enginePolicy(for grid: RunPlayDemSamplingGrid) throws -> DemSamplingPolicy {
        let range = grid.plausibleElevationMeters
        guard RunPlayEngineLimits.demZoomRange.contains(grid.zoom),
              RunPlayEngineLimits.demTileSizeRange.contains(grid.tileSize),
              (1...RunPlayEngineLimits.demMaximumTileCount).contains(grid.maximumTileCount),
              range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound < range.upperBound
        else {
            throw RunPlayDemElevationBridgeError.invalidGrid
        }
        return DemSamplingPolicy(
            zoom: UInt32(grid.zoom), tileSize: UInt32(grid.tileSize),
            maximumTileCount: UInt64(grid.maximumTileCount),
            minimumPlausibleElevationMeters: range.lowerBound,
            maximumPlausibleElevationMeters: range.upperBound
        )
    }
}
