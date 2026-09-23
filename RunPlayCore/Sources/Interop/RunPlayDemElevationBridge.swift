import Foundation

// Keep imported C++ declarations confined to the internal Interop layer.
internal import CxxStdlib
internal import RunPlayEngineCpp

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
    /// was loaded or sampled; the count is a lower bound.
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

/// Diagnostic-only phase timings for one complete bridge invocation.
/// Production callers never request or collect these clocks.
struct RunPlayDemSamplingBenchmarkReport: Sendable {
    let inputConversionMilliseconds: Double
    let nativePlanningMilliseconds: Double
    let tileLoadingMilliseconds: Double
    let heightPackingMilliseconds: Double
    let nativeSamplingMilliseconds: Double
    let outputTranslationMilliseconds: Double
}

// MARK: - Bridge

/// Production adapter for the two DEM engine calls.
///
/// One invocation covers one route: it converts the coordinates once, calls
/// `plan_dem_tiles`, hands the planned tile list to `loadTiles` (Swift decodes
/// whichever of those tiles exist), packs the decoded heights into one
/// Swift-owned buffer, and calls `sample_dem_elevations`. C++ never calls back:
/// `loadTiles` runs in Swift between the two native calls, retains nothing,
/// and every buffer is Swift-owned. Cancellation is checked during conversion,
/// around each native call, around tile loading, and during translation —
/// never inside a native call.
enum RunPlayDemElevationBridge {
    static func sampleElevations(
        routePoints: [RoutePoint],
        grid: RunPlayDemSamplingGrid,
        cancellationCheckStride: Int,
        loadTiles: ([RunPlayDemTileKey]) throws -> [RunPlayDemDecodedTile],
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayDemSamplingOutcome {
        try sampleNative(
            routePoints: routePoints,
            grid: grid,
            cancellationCheckStride: cancellationCheckStride,
            loadTiles: loadTiles,
            isCancelled: isCancelled,
            collectBenchmarkTimings: false
        ).outcome
    }

    /// Diagnostic-only profiled bridge used by release benchmarks. The outcome
    /// travels through the same conversion, native calls, tile loading,
    /// validation, and translation as production.
    static func sampleElevationsCollectingBenchmarkReport(
        routePoints: [RoutePoint],
        grid: RunPlayDemSamplingGrid,
        loadTiles: ([RunPlayDemTileKey]) throws -> [RunPlayDemDecodedTile]
    ) throws -> (outcome: RunPlayDemSamplingOutcome, report: RunPlayDemSamplingBenchmarkReport) {
        let profiled = try sampleNative(
            routePoints: routePoints,
            grid: grid,
            cancellationCheckStride: 2_048,
            loadTiles: loadTiles,
            isCancelled: { false },
            collectBenchmarkTimings: true
        )
        guard let report = profiled.report else {
            throw RunPlayDemElevationBridgeError.engineContractViolation
        }
        return (profiled.outcome, report)
    }

    // MARK: Implementation

    /// Nested so every temporary C++ value is destroyed before the pure-Swift
    /// outcome returns to production code.
    private static func sampleNative(
        routePoints: [RoutePoint],
        grid: RunPlayDemSamplingGrid,
        cancellationCheckStride: Int,
        loadTiles: ([RunPlayDemTileKey]) throws -> [RunPlayDemDecodedTile],
        isCancelled: @Sendable () -> Bool,
        collectBenchmarkTimings: Bool
    ) throws -> (outcome: RunPlayDemSamplingOutcome, report: RunPlayDemSamplingBenchmarkReport?) {
        let count = routePoints.count
        guard count <= WorkoutImportResourceLimits.maxRoutePointCount else {
            throw RunPlayDemElevationBridgeError.resourceLimit
        }
        let policy = try nativePolicy(for: grid)
        try checkCancellation(isCancelled)

        if count == 0 {
            let empty = RunPlayDemSamplingResult(
                elevationsMeters: [],
                statuses: [],
                plannedTiles: [],
                loadedTileCount: 0,
                sampledCount: 0,
                invalidCoordinateCount: 0,
                outsideProjectionCount: 0,
                missingTileCount: 0,
                implausibleHeightCount: 0
            )
            let report = collectBenchmarkTimings
                ? RunPlayDemSamplingBenchmarkReport(
                    inputConversionMilliseconds: 0,
                    nativePlanningMilliseconds: 0,
                    tileLoadingMilliseconds: 0,
                    heightPackingMilliseconds: 0,
                    nativeSamplingMilliseconds: 0,
                    outputTranslationMilliseconds: 0
                )
                : nil
            return (.sampled(empty), report)
        }

        let stride = max(1, cancellationCheckStride)
        var clock = PhaseClock(enabled: collectBenchmarkTimings)

        // ---- Coordinates, converted once for both native calls ----
        var samples = ContiguousArray<runplay.DemRouteSample>()
        samples.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }
            var sample = runplay.DemRouteSample()
            sample.latitude_degrees = routePoints[index].latitude
            sample.longitude_degrees = routePoints[index].longitude
            samples.append(sample)
        }
        let conversionMilliseconds = clock.lap()

        // ---- Plan ----
        try checkCancellation(isCancelled)
        let plan = try planTiles(samples: samples, policy: policy, grid: grid)
        let planningMilliseconds = clock.lap()
        try checkCancellation(isCancelled)

        let plannedTiles: [RunPlayDemTileKey]
        switch plan {
        case .exceeded(let minimumRequiredTileCount):
            let report = collectBenchmarkTimings
                ? RunPlayDemSamplingBenchmarkReport(
                    inputConversionMilliseconds: conversionMilliseconds,
                    nativePlanningMilliseconds: planningMilliseconds,
                    tileLoadingMilliseconds: 0,
                    heightPackingMilliseconds: 0,
                    nativeSamplingMilliseconds: 0,
                    outputTranslationMilliseconds: 0
                )
                : nil
            return (.tileBudgetExceeded(minimumRequiredTileCount: minimumRequiredTileCount), report)
        case .planned(let tiles):
            plannedTiles = tiles
        }

        // ---- Swift decodes whichever planned tiles exist ----
        let loaded = plannedTiles.isEmpty ? [] : try loadTiles(plannedTiles)
        let loadingMilliseconds = clock.lap()
        try checkCancellation(isCancelled)
        let directory = try validatedDirectory(loaded, plannedTiles: plannedTiles, tileSize: grid.tileSize)

        // ---- Pack the directory and heights into Swift-owned buffers ----
        let heightsPerTile = grid.tileSize * grid.tileSize
        var keys = ContiguousArray<runplay.DemTileKey>()
        keys.reserveCapacity(directory.count)
        var heights = ContiguousArray<runplay.DemTileHeightSample>()
        heights.reserveCapacity(directory.count * heightsPerTile)
        for tile in directory {
            try checkCancellation(isCancelled)
            var key = runplay.DemTileKey()
            key.x = tile.key.x
            key.y = tile.key.y
            keys.append(key)
            for height in tile.heightsMeters {
                var sample = runplay.DemTileHeightSample()
                sample.height_meters = height
                heights.append(sample)
            }
        }
        var output = ContiguousArray<runplay.DemElevationOutputSample>(
            repeating: runplay.DemElevationOutputSample(),
            count: count
        )
        let packingMilliseconds = clock.lap()

        // ---- Sample ----
        try checkCancellation(isCancelled)
        NativeCallObserver.record(.demSampling)
        let summary = samples.withUnsafeBufferPointer { sampleBuffer in
            keys.withUnsafeBufferPointer { keyBuffer in
                heights.withUnsafeBufferPointer { heightBuffer in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        runplay.sample_dem_elevations(
                            sampleBuffer.baseAddress,
                            sampleBuffer.count,
                            policy,
                            keyBuffer.baseAddress,
                            keyBuffer.count,
                            heightBuffer.baseAddress,
                            heightBuffer.count,
                            outputBuffer.baseAddress,
                            outputBuffer.count
                        )
                    }
                }
            }
        }
        let samplingMilliseconds = clock.lap()
        try checkCancellation(isCancelled)

        switch summary.status {
        case .success:
            break
        case .resource_limit:
            throw RunPlayDemElevationBridgeError.resourceLimit
        default:
            // The grid and directory were validated in Swift, so any other
            // status means the two sides disagree about the contract.
            throw RunPlayDemElevationBridgeError.engineContractViolation
        }
        guard summary.sample_count == UInt64(count),
              summary.required_output_capacity == UInt64(count)
        else {
            throw RunPlayDemElevationBridgeError.engineContractViolation
        }

        // ---- Translate ----
        var elevations: [Double?] = []
        elevations.reserveCapacity(count)
        var statuses: [RunPlayDemSampleStatus] = []
        statuses.reserveCapacity(count)
        var tallies = StatusTallies()
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }
            let native = output[index]
            let status: RunPlayDemSampleStatus
            switch native.status {
            case .sampled: status = .sampled
            case .invalid_coordinate: status = .invalidCoordinate
            case .outside_projection: status = .outsideProjection
            case .missing_tile: status = .missingTile
            case .implausible_height: status = .implausibleHeight
            default:
                throw RunPlayDemElevationBridgeError.engineContractViolation
            }
            if status == .sampled {
                guard native.has_elevation == 1, native.elevation_meters.isFinite else {
                    throw RunPlayDemElevationBridgeError.engineContractViolation
                }
                elevations.append(native.elevation_meters)
            } else {
                guard native.has_elevation == 0, native.elevation_meters == 0 else {
                    throw RunPlayDemElevationBridgeError.engineContractViolation
                }
                elevations.append(nil)
            }
            statuses.append(status)
            tallies.count(status)
        }
        guard UInt64(tallies.sampled) == summary.sampled_count,
              UInt64(tallies.invalidCoordinate) == summary.invalid_coordinate_count,
              UInt64(tallies.outsideProjection) == summary.outside_projection_count,
              UInt64(tallies.missingTile) == summary.missing_tile_count,
              UInt64(tallies.implausibleHeight) == summary.implausible_height_count
        else {
            throw RunPlayDemElevationBridgeError.engineContractViolation
        }
        let translationMilliseconds = clock.lap()

        let result = RunPlayDemSamplingResult(
            elevationsMeters: elevations,
            statuses: statuses,
            plannedTiles: plannedTiles,
            loadedTileCount: directory.count,
            sampledCount: tallies.sampled,
            invalidCoordinateCount: tallies.invalidCoordinate,
            outsideProjectionCount: tallies.outsideProjection,
            missingTileCount: tallies.missingTile,
            implausibleHeightCount: tallies.implausibleHeight
        )
        let report = collectBenchmarkTimings
            ? RunPlayDemSamplingBenchmarkReport(
                inputConversionMilliseconds: conversionMilliseconds,
                nativePlanningMilliseconds: planningMilliseconds,
                tileLoadingMilliseconds: loadingMilliseconds,
                heightPackingMilliseconds: packingMilliseconds,
                nativeSamplingMilliseconds: samplingMilliseconds,
                outputTranslationMilliseconds: translationMilliseconds
            )
            : nil
        return (.sampled(result), report)
    }

    private enum PlanResult {
        case planned([RunPlayDemTileKey])
        case exceeded(minimumRequiredTileCount: Int)
    }

    /// One native planning call. Swift allocates the budget as the capacity,
    /// so `insufficient_output_capacity` can only mean a contract violation.
    private static func planTiles(
        samples: ContiguousArray<runplay.DemRouteSample>,
        policy: runplay.DemSamplingPolicy,
        grid: RunPlayDemSamplingGrid
    ) throws -> PlanResult {
        var planned = ContiguousArray<runplay.DemTileKey>(
            repeating: runplay.DemTileKey(),
            count: grid.maximumTileCount
        )
        NativeCallObserver.record(.demTilePlanning)
        let summary = samples.withUnsafeBufferPointer { sampleBuffer in
            planned.withUnsafeMutableBufferPointer { plannedBuffer in
                runplay.plan_dem_tiles(
                    sampleBuffer.baseAddress,
                    sampleBuffer.count,
                    policy,
                    plannedBuffer.baseAddress,
                    plannedBuffer.count
                )
            }
        }

        switch summary.status {
        case .success:
            break
        case .tile_budget_exceeded:
            guard summary.required_tile_count == UInt64(grid.maximumTileCount) + 1,
                  summary.written_tile_count == 0,
                  let minimum = Int(exactly: summary.required_tile_count)
            else {
                throw RunPlayDemElevationBridgeError.engineContractViolation
            }
            return .exceeded(minimumRequiredTileCount: minimum)
        case .resource_limit:
            throw RunPlayDemElevationBridgeError.resourceLimit
        default:
            throw RunPlayDemElevationBridgeError.engineContractViolation
        }

        guard summary.sample_count == UInt64(samples.count),
              summary.written_tile_count == summary.required_tile_count,
              summary.projectable_sample_count + summary.invalid_coordinate_count
                + summary.outside_projection_count == summary.sample_count,
              let written = Int(exactly: summary.written_tile_count),
              written <= planned.count
        else {
            throw RunPlayDemElevationBridgeError.engineContractViolation
        }

        let tilesPerAxis = UInt64(1) << UInt64(grid.zoom)
        var tiles: [RunPlayDemTileKey] = []
        tiles.reserveCapacity(written)
        for index in 0..<written {
            let key = RunPlayDemTileKey(x: planned[index].x, y: planned[index].y)
            guard UInt64(key.x) < tilesPerAxis, UInt64(key.y) < tilesPerAxis,
                  tiles.last.map({ $0 < key }) ?? true
            else {
                throw RunPlayDemElevationBridgeError.engineContractViolation
            }
            tiles.append(key)
        }
        return .planned(tiles)
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

    private static func nativePolicy(for grid: RunPlayDemSamplingGrid) throws -> runplay.DemSamplingPolicy {
        let range = grid.plausibleElevationMeters
        guard RunPlayEngineLimits.demZoomRange.contains(grid.zoom),
              RunPlayEngineLimits.demTileSizeRange.contains(grid.tileSize),
              (1...RunPlayEngineLimits.demMaximumTileCount).contains(grid.maximumTileCount),
              range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound < range.upperBound
        else {
            throw RunPlayDemElevationBridgeError.invalidGrid
        }
        var policy = runplay.DemSamplingPolicy()
        policy.zoom = UInt32(grid.zoom)
        policy.tile_size = UInt32(grid.tileSize)
        policy.maximum_tile_count = UInt64(grid.maximumTileCount)
        policy.minimum_plausible_elevation_meters = range.lowerBound
        policy.maximum_plausible_elevation_meters = range.upperBound
        return policy
    }

    private static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}

private struct StatusTallies {
    var sampled = 0
    var invalidCoordinate = 0
    var outsideProjection = 0
    var missingTile = 0
    var implausibleHeight = 0

    mutating func count(_ status: RunPlayDemSampleStatus) {
        switch status {
        case .sampled: sampled += 1
        case .invalidCoordinate: invalidCoordinate += 1
        case .outsideProjection: outsideProjection += 1
        case .missingTile: missingTile += 1
        case .implausibleHeight: implausibleHeight += 1
        }
    }
}

/// Lap timer for the diagnostic report; reads no clock unless enabled.
private struct PhaseClock {
    let enabled: Bool
    private var last: UInt64

    init(enabled: Bool) {
        self.enabled = enabled
        self.last = enabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    mutating func lap() -> Double {
        guard enabled else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        defer { last = now }
        return Double(now - last) / 1_000_000
    }
}
