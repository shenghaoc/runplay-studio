import Foundation
import XCTest
@testable import RunPlayCore

/// The Swift adapter over the two DEM engine calls: a synthetic 2×2 tile set
/// crossed by a route, the loader contract, the tile budget, grid validation,
/// cancellation, and the planner/sampler property through the bridge.
final class RunPlayDemElevationBridgeTests: XCTestCase {
    // MARK: - A synthetic 2×2 tile set crossed by a route

    /// Zoom 12 with 256-pixel tiles, the tiles (2130, 1450) through
    /// (2131, 1451): a realistic grid around a synthetic location.
    private static let zoom = 12
    private static let tileSize = 256
    private static let originTile = RunPlayDemTileKey(x: 2_130, y: 1_450)
    private static let worldPixels = Double((1 << zoom) * tileSize)

    /// A plane in pixel space relative to the 2×2 block's north-west pixel.
    /// Exact in single precision, and reproduced by bilinear interpolation.
    private static func planeHeight(column: Int, row: Int) -> Float {
        let dx = Double(column - Int(originTile.x) * tileSize)
        let dy = Double(row - Int(originTile.y) * tileSize)
        return Float(1_000 + 0.25 * dx - 0.125 * dy)
    }

    /// The plane evaluated independently of the bridge: Web Mercator pixel
    /// position, then the half-pixel offset of pixel-centre heights.
    private static func expectedPlaneHeight(latitude: Double, longitude: Double) -> Double {
        let globalX = (longitude + 180) / 360 * worldPixels
        let mercator = asinh(tan(latitude * .pi / 180))
        let globalY = (0.5 - mercator / (2 * .pi)) * worldPixels
        let dx = globalX - 0.5 - Double(Int(originTile.x) * tileSize)
        let dy = globalY - 0.5 - Double(Int(originTile.y) * tileSize)
        return 1_000 + 0.25 * dx - 0.125 * dy
    }

    private static func coordinate(globalX: Double, globalY: Double) -> (latitude: Double, longitude: Double) {
        let longitude = globalX / worldPixels * 360 - 180
        let mercator = Double.pi * (1 - 2 * globalY / worldPixels)
        let latitude = atan(sinh(mercator)) * 180 / .pi
        return (latitude, longitude)
    }

    private static func decodedTile(_ key: RunPlayDemTileKey) -> RunPlayDemDecodedTile {
        var heights: [Float] = []
        heights.reserveCapacity(tileSize * tileSize)
        for row in 0..<tileSize {
            for column in 0..<tileSize {
                heights.append(planeHeight(
                    column: Int(key.x) * tileSize + column,
                    row: Int(key.y) * tileSize + row
                ))
            }
        }
        return RunPlayDemDecodedTile(key: key, heightsMeters: heights)
    }

    /// Web Mercator latitude limit, atan(sinh(pi)) in degrees.
    private static let mercatorLatitudeLimit = 85.0511287798066

    private static var blockTiles: [RunPlayDemTileKey] {
        [
            RunPlayDemTileKey(x: originTile.x, y: originTile.y),
            RunPlayDemTileKey(x: originTile.x + 1, y: originTile.y),
            RunPlayDemTileKey(x: originTile.x, y: originTile.y + 1),
            RunPlayDemTileKey(x: originTile.x + 1, y: originTile.y + 1),
        ]
    }

    private static var blockGrid: RunPlayDemSamplingGrid {
        RunPlayDemSamplingGrid(
            zoom: zoom,
            tileSize: tileSize,
            maximumTileCount: 16,
            plausibleElevationMeters: -500...9_000
        )
    }

    /// A route that crosses the vertical tile edge, the horizontal tile edge,
    /// and the shared corner of the 2×2 block, all inside the block.
    private static func crossingRoute() -> [RoutePoint] {
        let blockX = Double(Int(originTile.x) * tileSize)
        let blockY = Double(Int(originTile.y) * tileSize)
        var points: [RoutePoint] = []
        for step in 0..<64 {
            let t = Double(step) / 63
            // Diagonal from the north-west tile to the south-east tile, through
            // the shared corner at (blockX + 256, blockY + 256).
            let globalX = blockX + 40 + t * 430
            let globalY = blockY + 60 + t * 400
            points.append(makePoint(index: step, coordinate: coordinate(globalX: globalX, globalY: globalY)))
        }
        // Exactly on the vertical edge between the two northern tiles, and on
        // the shared corner.
        points.append(makePoint(index: 64, coordinate: coordinate(globalX: blockX + 256, globalY: blockY + 100)))
        points.append(makePoint(index: 65, coordinate: coordinate(globalX: blockX + 256, globalY: blockY + 256)))
        return points
    }

    private static func makePoint(index: Int, coordinate: (latitude: Double, longitude: Double)) -> RoutePoint {
        let seconds: TimeInterval = 900_000_000 + Double(index)
        return RoutePoint(
            timestamp: Date(timeIntervalSinceReferenceDate: seconds),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            elapsedSeconds: Double(index)
        )
    }

    func testTwoByTwoTileSetSamplesTheRouteAcrossEveryTileBoundary() throws {
        let route = Self.crossingRoute()
        var requested: [RunPlayDemTileKey] = []
        let outcome = try RunPlayDemElevationBridge.sampleElevations(
            routePoints: route,
            grid: Self.blockGrid,
            cancellationCheckStride: 16,
            loadTiles: { planned in
                requested = planned
                return planned.map(Self.decodedTile)
            },
            isCancelled: { false }
        )

        guard case .sampled(let result) = outcome else {
            return XCTFail("the 2×2 block fits the budget")
        }
        XCTAssertEqual(requested, Self.blockTiles, "the route needs exactly the four tiles, in (y, x) order")
        XCTAssertEqual(result.plannedTiles, Self.blockTiles)
        XCTAssertEqual(result.loadedTileCount, 4)
        XCTAssertEqual(result.sampledCount, route.count)
        XCTAssertEqual(result.statuses, Array(repeating: .sampled, count: route.count))
        for (point, elevation) in zip(route, result.elevationsMeters) {
            let expected = Self.expectedPlaneHeight(latitude: point.latitude, longitude: point.longitude)
            XCTAssertEqual(try XCTUnwrap(elevation), expected, accuracy: 1e-6)
        }
    }

    func testMissingTileInTheBlockFallsBackPerPoint() throws {
        let route = Self.crossingRoute()
        let missing = RunPlayDemTileKey(x: Self.originTile.x + 1, y: Self.originTile.y + 1)
        let outcome = try RunPlayDemElevationBridge.sampleElevations(
            routePoints: route,
            grid: Self.blockGrid,
            cancellationCheckStride: 16,
            loadTiles: { planned in planned.filter { $0 != missing }.map(Self.decodedTile) },
            isCancelled: { false }
        )
        guard case .sampled(let result) = outcome else {
            return XCTFail("the 2×2 block fits the budget")
        }

        XCTAssertEqual(result.loadedTileCount, 3)
        XCTAssertGreaterThan(result.missingTileCount, 0, "points in or next to the missing tile fall back")
        XCTAssertGreaterThan(result.sampledCount, 0, "points elsewhere are still sampled")
        XCTAssertEqual(result.sampledCount + result.missingTileCount, route.count)
        let blockX = Double(Int(Self.originTile.x) * Self.tileSize)
        let blockY = Double(Int(Self.originTile.y) * Self.tileSize)
        for (index, point) in route.enumerated() {
            let globalX = (point.longitude + 180) / 360 * Self.worldPixels
            let mercator = asinh(tan(point.latitude * .pi / 180))
            let globalY = (0.5 - mercator / (2 * .pi)) * Self.worldPixels
            // Within half a pixel of the missing tile the sample needs it.
            let needsMissingTile = globalX > blockX + 255.5 && globalY > blockY + 255.5
            XCTAssertEqual(
                result.statuses[index],
                needsMissingTile ? .missingTile : .sampled,
                "point \(index)"
            )
            XCTAssertEqual(result.elevationsMeters[index] != nil, result.statuses[index] == .sampled)
        }
    }

    // MARK: - Loader contract

    func testLoaderMaySkipAndReorderPlannedTiles() throws {
        let route = Self.crossingRoute()
        let outcome = try RunPlayDemElevationBridge.sampleElevations(
            routePoints: route,
            grid: Self.blockGrid,
            cancellationCheckStride: 16,
            loadTiles: { planned in planned.reversed().dropLast().map(Self.decodedTile) },
            isCancelled: { false }
        )
        guard case .sampled(let result) = outcome else {
            return XCTFail("the 2×2 block fits the budget")
        }
        XCTAssertEqual(result.loadedTileCount, 3, "reversed order is accepted and the skipped tile is missing")
        XCTAssertGreaterThan(result.missingTileCount, 0)
    }

    func testLoaderContractViolationsAreRejected() {
        let route = Self.crossingRoute()
        let unplanned = RunPlayDemTileKey(x: Self.originTile.x + 5, y: Self.originTile.y)
        let violations: [(String, ([RunPlayDemTileKey]) -> [RunPlayDemDecodedTile])] = [
            ("a tile the planner did not list", { planned in (planned + [unplanned]).map(Self.decodedTile) }),
            ("a duplicate tile", { planned in (planned + [planned[0]]).map(Self.decodedTile) }),
            ("too few heights", { planned in
                [RunPlayDemDecodedTile(key: planned[0], heightsMeters: [1, 2, 3])]
            }),
        ]
        for (name, loader) in violations {
            XCTAssertThrowsError(
                try RunPlayDemElevationBridge.sampleElevations(
                    routePoints: route,
                    grid: Self.blockGrid,
                    cancellationCheckStride: 16,
                    loadTiles: loader,
                    isCancelled: { false }
                ),
                name
            ) { error in
                XCTAssertEqual(error as? RunPlayDemElevationBridgeError, .invalidLoadedTiles, name)
            }
        }
    }

    // MARK: - Budget, grid, empty input

    func testTileBudgetExceededSkipsLoadingAndSampling() throws {
        var grid = Self.blockGrid
        grid = RunPlayDemSamplingGrid(
            zoom: grid.zoom,
            tileSize: grid.tileSize,
            maximumTileCount: 3,
            plausibleElevationMeters: grid.plausibleElevationMeters
        )
        var loaderCalled = false
        let outcome = try RunPlayDemElevationBridge.sampleElevations(
            routePoints: Self.crossingRoute(),
            grid: grid,
            cancellationCheckStride: 16,
            loadTiles: { planned in
                loaderCalled = true
                return planned.map(Self.decodedTile)
            },
            isCancelled: { false }
        )
        guard case .tileBudgetExceeded(let minimum) = outcome else {
            return XCTFail("four tiles exceed a budget of three")
        }
        XCTAssertEqual(minimum, 4)
        XCTAssertFalse(loaderCalled, "no tile is decoded for a route over budget")
    }

    func testInvalidGridsAreRejectedBeforeAnyWork() {
        let invalid: [RunPlayDemSamplingGrid] = [
            .init(zoom: 25, tileSize: 256, maximumTileCount: 16, plausibleElevationMeters: -500...9_000),
            .init(zoom: -1, tileSize: 256, maximumTileCount: 16, plausibleElevationMeters: -500...9_000),
            .init(zoom: 12, tileSize: 1, maximumTileCount: 16, plausibleElevationMeters: -500...9_000),
            .init(zoom: 12, tileSize: 4_097, maximumTileCount: 16, plausibleElevationMeters: -500...9_000),
            .init(zoom: 12, tileSize: 256, maximumTileCount: 0, plausibleElevationMeters: -500...9_000),
            .init(zoom: 12, tileSize: 256, maximumTileCount: 65_537, plausibleElevationMeters: -500...9_000),
            .init(zoom: 12, tileSize: 256, maximumTileCount: 16, plausibleElevationMeters: 10...10),
            .init(zoom: 12, tileSize: 256, maximumTileCount: 16, plausibleElevationMeters: -.infinity...9_000),
        ]
        for grid in invalid {
            XCTAssertThrowsError(
                try RunPlayDemElevationBridge.sampleElevations(
                    routePoints: Self.crossingRoute(),
                    grid: grid,
                    cancellationCheckStride: 16,
                    loadTiles: { _ in
                        XCTFail("no tile is loaded for an invalid grid")
                        return []
                    },
                    isCancelled: { false }
                )
            ) { error in
                XCTAssertEqual(error as? RunPlayDemElevationBridgeError, .invalidGrid)
            }
        }
    }

    func testEmptyRouteSamplesNothingWithoutLoading() throws {
        let outcome = try RunPlayDemElevationBridge.sampleElevations(
            routePoints: [],
            grid: Self.blockGrid,
            cancellationCheckStride: 16,
            loadTiles: { _ in
                XCTFail("an empty route needs no tile")
                return []
            },
            isCancelled: { false }
        )
        guard case .sampled(let result) = outcome else {
            return XCTFail("an empty route is sampled trivially")
        }
        XCTAssertTrue(result.statuses.isEmpty && result.plannedTiles.isEmpty)
    }

    func testRouteWithoutProjectableCoordinatesNeedsNoTile() throws {
        let route = [
            Self.makePoint(index: 0, coordinate: (89.5, 10)),
            Self.makePoint(index: 1, coordinate: (.nan, 10)),
            Self.makePoint(index: 2, coordinate: (10, 190)),
        ]
        let outcome = try RunPlayDemElevationBridge.sampleElevations(
            routePoints: route,
            grid: Self.blockGrid,
            cancellationCheckStride: 16,
            loadTiles: { _ in
                XCTFail("no tile is needed")
                return []
            },
            isCancelled: { false }
        )
        guard case .sampled(let result) = outcome else {
            return XCTFail("no tile means no budget problem")
        }
        XCTAssertEqual(result.statuses, [.outsideProjection, .invalidCoordinate, .invalidCoordinate])
        XCTAssertEqual(result.elevationsMeters, [nil, nil, nil])
    }

    // MARK: - Cancellation

    func testCancellationAtEachPhase() {
        let route = Self.crossingRoute()
        // For this 66-point route with stride 16 the bridge checks 20 times:
        // once after grid validation, 5 times while converting, before and
        // after planning, after loading, once per packed tile (4), before and
        // after sampling, and 5 times while translating. Cancelling at each
        // check covers every phase.
        for cancelOnCall in 1...20 {
            let gate = DemCancellationGate(cancelOnCall: cancelOnCall)
            XCTAssertThrowsError(
                try RunPlayDemElevationBridge.sampleElevations(
                    routePoints: route,
                    grid: Self.blockGrid,
                    cancellationCheckStride: 16,
                    loadTiles: { planned in planned.map(Self.decodedTile) },
                    isCancelled: { gate.shouldCancel() }
                ),
                "cancel on check \(cancelOnCall)"
            ) { error in
                XCTAssertTrue(error is CancellationError, "cancel on check \(cancelOnCall)")
            }
        }
    }

    func testLoaderCancellationPropagates() {
        XCTAssertThrowsError(
            try RunPlayDemElevationBridge.sampleElevations(
                routePoints: Self.crossingRoute(),
                grid: Self.blockGrid,
                cancellationCheckStride: 16,
                loadTiles: { _ in throw CancellationError() },
                isCancelled: { false }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Seeded property

    /// Every tile the sampler touches is in the planner's returned set: given
    /// exactly the planned tiles, no point is missing one.
    func testSamplingWithThePlannedTilesNeverMissesATile() throws {
        var random = DemSplitMix64(seed: 0xD3A1)
        for fixture in 0..<200 {
            let grid = Self.randomGrid(&random, maximumTileCount: 4_096)
            let route = Self.randomRoute(&random, grid: grid)
            let outcome = try RunPlayDemElevationBridge.sampleElevations(
                routePoints: route,
                grid: grid,
                cancellationCheckStride: 64,
                loadTiles: { planned in planned.map { Self.randomTile($0, grid: grid, random: &random, defects: false) } },
                isCancelled: { false }
            )
            guard case .sampled(let result) = outcome else {
                return XCTFail("fixture \(fixture) fits a 4,096-tile budget")
            }
            XCTAssertEqual(result.missingTileCount, 0, "fixture \(fixture)")
            XCTAssertEqual(
                result.sampledCount + result.invalidCoordinateCount + result.outsideProjectionCount,
                route.count,
                "fixture \(fixture)"
            )
        }
    }

    // MARK: - Fixtures

    private static func randomGrid(_ random: inout DemSplitMix64, maximumTileCount: Int) -> RunPlayDemSamplingGrid {
        let zooms = [0, 1, 2, 3, 4, 6, 8, 10, 12, 16]
        let tileSizes = [2, 3, 4, 8, 16]
        return RunPlayDemSamplingGrid(
            zoom: zooms[random.nextInt(below: zooms.count)],
            tileSize: tileSizes[random.nextInt(below: tileSizes.count)],
            maximumTileCount: maximumTileCount,
            plausibleElevationMeters: -500...9_000
        )
    }

    /// Routes mixing a local walk, exact tile edges and corners, the
    /// antimeridian, the latitude limit, and coordinates that need no tile.
    private static func randomRoute(_ random: inout DemSplitMix64, grid: RunPlayDemSamplingGrid) -> [RoutePoint] {
        let world = Double((1 << grid.zoom) * grid.tileSize)
        let tilesPerAxis = 1 << grid.zoom
        var coordinates: [(latitude: Double, longitude: Double)] = []

        var latitude = random.nextDouble(in: -70...70)
        var longitude = random.nextDouble(in: -180...180)
        let walkLength = 4 + random.nextInt(below: 24)
        let step = 360 / world * 0.7
        for _ in 0..<walkLength {
            latitude = min(max(latitude + random.nextDouble(in: -step...step), -80), 80)
            longitude += random.nextDouble(in: -step...step)
            if longitude > 180 { longitude -= 360 }
            if longitude < -180 { longitude += 360 }
            coordinates.append((latitude, longitude))
        }
        for _ in 0..<(1 + random.nextInt(below: 6)) {
            // Exact vertical tile edges, the equator (a tile-row edge when the
            // zoom is positive), and exact pixel centres on edge pixels.
            let edgeX = Double(random.nextInt(below: tilesPerAxis) * grid.tileSize)
            coordinates.append((0, edgeX / world * 360 - 180))
            coordinates.append((random.nextDouble(in: -60...60), edgeX / world * 360 - 180))
            coordinates.append((0, (edgeX + 0.5) / world * 360 - 180))
        }
        let specials: [(latitude: Double, longitude: Double)] = [
            (0, 180), (0, -180), (12.5, 179.99999), (-12.5, -179.99999),
            (mercatorLatitudeLimit, 30),
            (-mercatorLatitudeLimit, -30),
            (85.06, 0), (-90, 0), (.nan, 0), (0, .infinity), (91, 0),
        ]
        for special in specials where random.nextBool(probability: 0.3) {
            coordinates.append(special)
        }
        return coordinates.enumerated().map { index, coordinate in
            makePoint(index: index, coordinate: coordinate)
        }
    }

    private static func randomTile(
        _ key: RunPlayDemTileKey,
        grid: RunPlayDemSamplingGrid,
        random: inout DemSplitMix64,
        defects: Bool
    ) -> RunPlayDemDecodedTile {
        let count = grid.tileSize * grid.tileSize
        var heights: [Float] = []
        heights.reserveCapacity(count)
        for _ in 0..<count {
            if defects, random.nextBool(probability: 0.01) {
                heights.append(random.nextBool(probability: 0.5) ? .nan : 9_500)
            } else {
                // Terrarium-representable values: multiples of 1/256 m.
                heights.append(Float(random.nextInt(below: 400_000) - 100_000) / 256)
            }
        }
        return RunPlayDemDecodedTile(key: key, heightsMeters: heights)
    }
}

/// Deterministic seeded generator for fixtures.
struct DemSplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(UInt64(1) << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    mutating func nextInt(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func nextBool(probability: Double) -> Bool {
        nextDouble(in: 0...1) < probability
    }
}

private final class DemCancellationGate: @unchecked Sendable {
    private let cancelOnCall: Int
    private let lock = NSLock()
    private var calls = 0

    init(cancelOnCall: Int) {
        self.cancelOnCall = cancelOnCall
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls >= cancelOnCall
    }
}
