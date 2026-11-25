import Testing
import RunPlayEngine
import RunPlayEngineTestSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Ports `DemElevationSamplingTests.cpp` case for case, with the same names and
/// literals.
///
/// Unrepresentable by construction (kept in the C++ tests until PR 10): null
/// samples, tiles, heights or output with a nonzero count or capacity; an output
/// capacity below the sample count; and the zero- and short-capacity planning
/// cases. A `Span` cannot pair a positive count with null storage, and the engine
/// returns exactly what it planned or sampled. The capacity cases keep their
/// closest Swift form: the planner returns exactly the tiles a corner needs.
/// "Leaves output untouched" holds by construction, because a throwing call
/// returns no result.
@Suite
struct DemElevationSamplingTests {
    private typealias Key = DemTileKey
    private typealias Policy = DemSamplingPolicy

    private static let gridZoom: UInt32 = 2
    private static let gridTileSize: UInt32 = 4
    private static let gridWorldPixels = 16.0
    private static let quietNaN = Double.nan
    private static let infinity = Double.infinity

    // The default test grid: zoom 2 with 4-pixel tiles, so the world is 16 pixels
    // (4 x 4 tiles) and one pixel spans 22.5 degrees of longitude.
    private static func makePolicy(_ zoom: UInt32 = gridZoom, _ tileSize: UInt32 = gridTileSize, _ maximumTileCount: UInt64 = 64) -> Policy {
        Policy(zoom: zoom, tileSize: tileSize, maximumTileCount: maximumTileCount,
               minimumPlausibleElevationMeters: -500.0, maximumPlausibleElevationMeters: 9_000.0)
    }

    private static func longitudeAt(_ globalX: Double, _ worldPixels: Double = gridWorldPixels) -> Double {
        globalX / worldPixels * 360.0 - 180.0
    }

    private static func latitudeAt(_ globalY: Double, _ worldPixels: Double = gridWorldPixels) -> Double {
        let yFraction = globalY / worldPixels
        let mercator = Double.pi * (1.0 - 2.0 * yFraction)
        return atan(sinh(mercator)) * 180.0 / Double.pi
    }

    private static func atPixel(_ globalX: Double, _ globalY: Double, _ worldPixels: Double = gridWorldPixels) -> DemRouteSample {
        DemRouteSample(latitudeDegrees: latitudeAt(globalY, worldPixels), longitudeDegrees: longitudeAt(globalX, worldPixels))
    }

    private static func route(_ latitude: Double, _ longitude: Double) -> DemRouteSample {
        DemRouteSample(latitudeDegrees: latitude, longitudeDegrees: longitude)
    }

    private static func plan(_ samples: [DemRouteSample], _ policy: Policy = makePolicy()) throws(DemTilePlanError) -> DemTilePlanResult {
        try DemTilePlanning.plan(samples: samples.span, policy: policy)
    }

    private static func expectTiles(_ result: DemTilePlanResult, _ expected: [[UInt32]], _ message: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.tiles.count == expected.count, message, sourceLocation: sourceLocation)
        for (index, key) in expected.enumerated() where index < result.tiles.count {
            #expect(result.tiles[index].x == key[0] && result.tiles[index].y == key[1], message, sourceLocation: sourceLocation)
        }
    }

    // MARK: Planning

    @Test func test_plan_empty_input() throws {
        let empty = try Self.plan([])
        #expect(empty.sampleCount == 0 && empty.tiles.isEmpty, "empty route plans no tiles")

        var invalid = Self.makePolicy()
        invalid.tileSize = 1
        #expect(throws: DemTilePlanError.invalidPolicy, "empty route still validates the policy") { try Self.plan([], invalid) }
    }

    @Test func test_plan_validation_failures_leave_output_untouched() throws {
        let sample = Self.atPixel(6.25, 6.25)
        let oversized = [DemRouteSample](repeating: sample, count: EngineRouteLimits.maxRouteInputSamples + 1)
        #expect(throws: DemTilePlanError.resourceLimit, "oversized route is rejected") { try Self.plan(oversized) }

        var invalidPolicies: [Policy] = []
        func with(_ mutate: (inout Policy) -> Void) {
            var policy = Self.makePolicy()
            mutate(&policy)
            invalidPolicies.append(policy)
        }
        with { $0.zoom = UInt32(EngineDemLimits.maximumZoom) + 1 }
        with { $0.tileSize = UInt32(EngineDemLimits.minimumTileSize) - 1 }
        with { $0.tileSize = UInt32(EngineDemLimits.maximumTileSize) + 1 }
        with { $0.maximumTileCount = 0 }
        with { $0.maximumTileCount = UInt64(EngineDemLimits.maximumTileCount) + 1 }
        with { $0.minimumPlausibleElevationMeters = Self.quietNaN }
        with { $0.maximumPlausibleElevationMeters = Self.infinity }
        with { $0.maximumPlausibleElevationMeters = -500.0 }
        with { $0.maximumPlausibleElevationMeters = -600.0 }
        for policy in invalidPolicies {
            #expect(throws: DemTilePlanError.invalidPolicy, "invalid policy is rejected") { try Self.plan([sample], policy) }
        }

        var boundary = Self.makePolicy(UInt32(EngineDemLimits.maximumZoom), UInt32(EngineDemLimits.maximumTileSize))
        boundary.maximumTileCount = UInt64(EngineDemLimits.maximumTileCount)
        let accepted = try Self.plan([sample], boundary)
        #expect(!accepted.tiles.isEmpty, "inclusive policy bounds are accepted")
    }

    @Test func test_plan_interior_point_needs_one_tile() throws {
        // Pixel position (6.25, 6.25): bilinear corners at columns 5-6 and rows 5-6, all inside tile (1, 1).
        let result = try Self.plan([Self.atPixel(6.25, 6.25)])
        Self.expectTiles(result, [[1, 1]], "interior point needs its own tile only")
        #expect(result.projectableSampleCount == 1, "interior point is projectable")
    }

    @Test func test_plan_tile_edges() throws {
        Self.expectTiles(try Self.plan([Self.atPixel(4.0, 6.25)]), [[0, 1], [1, 1]],
                         "a sample on a tile edge needs both neighbouring tiles")
        Self.expectTiles(try Self.plan([Self.atPixel(3.75, 6.25)]), [[0, 1], [1, 1]],
                         "within half a pixel of an edge the neighbour carries weight")
        Self.expectTiles(try Self.plan([Self.atPixel(3.5, 6.25)]), [[0, 1]],
                         "a pixel-centre sample needs no zero-weight neighbour")
        Self.expectTiles(try Self.plan([Self.route(0.0, -90.0)]), [[0, 1], [1, 1], [0, 2], [1, 2]],
                         "a sample on a tile corner needs all four tiles, in (y, x) order")
    }

    @Test func test_plan_antimeridian_wraps_columns() throws {
        for longitude in [180.0, -180.0, Self.longitudeAt(15.9), Self.longitudeAt(0.1)] {
            Self.expectTiles(try Self.plan([Self.route(Self.latitudeAt(6.25), longitude)]), [[0, 1], [3, 1]],
                             "the antimeridian pairs the last and first tile columns")
        }
        let single = Self.makePolicy(0, 4)
        Self.expectTiles(try Self.plan([Self.route(10.0, 180.0), Self.route(-10.0, -179.0)], single), [[0, 0]],
                         "zoom 0 wraps within its only tile")
    }

    @Test func test_plan_pole_guards() throws {
        let outside = try Self.plan([Self.route(85.06, 10.0), Self.route(-85.06, 10.0), Self.route(90.0, 10.0), Self.route(-90.0, 10.0)])
        #expect(outside.outsideProjectionCount == 4, "beyond the Mercator limit has no tile")
        #expect(outside.projectableSampleCount == 0, "no projectable samples")
        #expect(outside.tiles.isEmpty, "no tiles for polar samples")

        let limit = EngineDemLimits.webMercatorMaximumLatitudeDegrees
        Self.expectTiles(try Self.plan([Self.route(limit, Self.longitudeAt(6.25))]), [[1, 0]], "the northern limit reads only the top tile row")
        Self.expectTiles(try Self.plan([Self.route(-limit, Self.longitudeAt(6.25))]), [[1, 3]], "the southern limit reads only the bottom tile row")
    }

    @Test func test_plan_invalid_coordinates_need_no_tiles() throws {
        let result = try Self.plan([
            Self.route(Self.quietNaN, 10.0), Self.route(10.0, Self.infinity), Self.route(90.5, 10.0),
            Self.route(10.0, 180.5), Self.route(10.0, -180.0001), Self.atPixel(6.25, 6.25),
        ])
        #expect(result.invalidCoordinateCount == 5, "invalid coordinates are counted")
        #expect(result.projectableSampleCount == 1, "the valid sample is projectable")
        #expect(result.sampleCount == 6, "every sample is counted")
        Self.expectTiles(result, [[1, 1]], "invalid coordinates need no tile")
    }

    @Test func test_plan_output_is_sorted_and_unique() throws {
        let result = try Self.plan([
            Self.atPixel(14.0, 14.0), Self.atPixel(2.0, 2.0), Self.atPixel(10.0, 6.0),
            Self.atPixel(2.0, 2.0), Self.atPixel(14.0, 14.0), Self.atPixel(6.0, 10.0),
        ])
        Self.expectTiles(result, [[0, 0], [2, 1], [1, 2], [3, 3]], "tiles are distinct and strictly ascending by (y, x)")
    }

    @Test func test_plan_tile_budget() throws {
        let fiveTiles = [Self.atPixel(2.0, 2.0), Self.atPixel(6.0, 2.0), Self.atPixel(10.0, 2.0), Self.atPixel(14.0, 2.0), Self.atPixel(2.0, 6.0)]
        // `tile_budget_exceeded` means "keep recorded elevation"; it is a typed error, not a retry signal.
        #expect(throws: DemTilePlanError.tileBudgetExceeded, "budget of four rejects five tiles") {
            try Self.plan(fiveTiles, Self.makePolicy(Self.gridZoom, Self.gridTileSize, 4))
        }
        let exact = try Self.plan(fiveTiles, Self.makePolicy(Self.gridZoom, Self.gridTileSize, 5))
        #expect(exact.tiles.count == 5, "a budget equal to the need succeeds")
    }

    @Test func test_plan_insufficient_capacity_writes_nothing() throws {
        // Closest Swift form: the engine owns the result, so the exact need is returned.
        let corner = try Self.plan([Self.route(0.0, -90.0)])
        #expect(corner.tiles.count == 4, "the corner needs exactly four tiles")
        #expect(corner.projectableSampleCount == 1, "counts stay exact")
    }

    @Test func test_plan_large_route_is_deterministic_and_bounded() throws {
        var route: [DemRouteSample] = []
        route.reserveCapacity(100_000)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var latitude = 46.5
        var longitude = 7.9
        for _ in 0..<100_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let step = Double(state >> 40) / Double(UInt64(1) << 24)
            latitude += (step - 0.45) * 0.0004
            longitude += (step - 0.40) * 0.0006
            route.append(Self.route(latitude, longitude))
        }
        let policy = Self.makePolicy(12, 256, 4_096)
        let first = try Self.plan(route, policy)
        let second = try Self.plan(route, policy)
        #expect(first.projectableSampleCount == UInt64(route.count), "every walk point is projectable")
        #expect(first.tiles == second.tiles, "planning is deterministic")
        for index in first.tiles.indices {
            #expect(first.tiles[index].x < 4_096 && first.tiles[index].y < 4_096, "keys inside the zoom-12 grid")
            if index > 0 {
                let a = first.tiles[index - 1], b = first.tiles[index]
                #expect(a.y != b.y ? a.y < b.y : a.x < b.x, "strictly ascending")
            }
        }
    }

    @Test func test_plan_extreme_grids() throws {
        let fine = try Self.plan(
            [Self.route(-33.8568, 151.2153)],
            Self.makePolicy(UInt32(EngineDemLimits.maximumZoom), UInt32(EngineDemLimits.maximumTileSize), 8)
        )
        #expect(!fine.tiles.isEmpty && fine.tiles.count <= 4, "one footprint needs one to four tiles")
        for key in fine.tiles { #expect(key.x < (1 << 24) && key.y < (1 << 24), "keys inside the zoom-24 grid") }

        Self.expectTiles(
            try Self.plan([Self.route(0.0, 0.0), Self.route(60.0, 179.9), Self.route(-60.0, -179.9)],
                          Self.makePolicy(0, UInt32(EngineDemLimits.minimumTileSize), 4)),
            [[0, 0]], "coarsest grid has one tile"
        )
    }

    // MARK: Sampling

    private struct TileSet {
        var keys: [Key]
        var heights: [Float]
    }

    /// Heights for `keys` (already ascending by (y, x)), where the pixel at global
    /// column c and row r holds `heightAt(c, r)`.
    private static func makeTiles(_ keys: [Key], _ tileSize: UInt32, _ heightAt: (Int64, Int64) -> Float) -> TileSet {
        var heights: [Float] = []
        heights.reserveCapacity(keys.count * Int(tileSize * tileSize))
        for key in keys {
            for row in 0..<tileSize {
                for column in 0..<tileSize {
                    heights.append(heightAt(Int64(key.x) * Int64(tileSize) + Int64(column), Int64(key.y) * Int64(tileSize) + Int64(row)))
                }
            }
        }
        return TileSet(keys: keys, heights: heights)
    }

    private static func allTiles(_ zoom: UInt32) -> [Key] {
        var keys: [Key] = []
        let side = UInt32(1) << zoom
        for y in 0..<side { for x in 0..<side { keys.append(Key(x: x, y: y)) } }
        return keys
    }

    /// A plane in pixel space: exact in single precision on the small test grid,
    /// and reproduced exactly by bilinear interpolation.
    private static func planarHeight(_ column: Int64, _ row: Int64) -> Float {
        Float(100.0 + 0.5 * Double(column) - 0.25 * Double(row))
    }

    private static func planarExpected(_ globalX: Double, _ globalY: Double) -> Double {
        100.0 + 0.5 * (globalX - 0.5) - 0.25 * (globalY - 0.5)
    }

    private static func sample(_ samples: [DemRouteSample], _ tiles: TileSet, _ policy: Policy = makePolicy()) throws(DemSamplingError) -> DemSamplingResult {
        let result = try DemElevationSampling.sample(samples: samples.span, policy: policy, tiles: tiles.keys.span, tileHeights: tiles.heights.span)
        for output in result.samples {
            let sampled = output.status == .sampled
            #expect(output.hasElevation == (sampled ? 1 : 0), "has_elevation mirrors the sampled status")
            #expect(sampled || output.elevationMeters == 0.0, "no elevation value without a sample")
        }
        return result
    }

    private static func near(_ value: Double, _ expected: Double, _ tolerance: Double = 1e-9) -> Bool {
        value.isFinite && abs(value - expected) <= tolerance
    }

    @Test func test_sample_contract() throws {
        let grid = Self.makeTiles(Self.allTiles(Self.gridZoom), Self.gridTileSize, Self.planarHeight)
        let empty = try Self.sample([], grid)
        #expect(empty.sampleCount == 0 && empty.samples.isEmpty, "empty route samples nothing")

        var invalid = Self.makePolicy()
        invalid.zoom = UInt32(EngineDemLimits.maximumZoom) + 1
        #expect(throws: DemSamplingError.invalidPolicy, "empty route still validates the policy") {
            try Self.sample([], TileSet(keys: [], heights: []), invalid)
        }

        let unsorted = TileSet(keys: [Key(x: 1, y: 0), Key(x: 0, y: 0)], heights: [Float](repeating: 0, count: 2 * 16))
        #expect(throws: DemSamplingError.invalidTileDirectory, "empty route still validates the directory") {
            try Self.sample([], unsorted)
        }
    }

    @Test func test_sample_validation_failures_leave_output_untouched() throws {
        let grid = Self.makeTiles(Self.allTiles(Self.gridZoom), Self.gridTileSize, Self.planarHeight)
        let route = [Self.atPixel(6.25, 6.25), Self.atPixel(9.5, 3.0)]

        let oversized = [DemRouteSample](repeating: route[0], count: EngineRouteLimits.maxRouteInputSamples + 1)
        #expect(throws: DemSamplingError.resourceLimit, "oversized route is rejected before the buffers are read") {
            try Self.sample(oversized, grid)
        }

        var badPolicy = Self.makePolicy()
        badPolicy.minimumPlausibleElevationMeters = 9_000.0
        #expect(throws: DemSamplingError.invalidPolicy, "inverted plausible range") { try Self.sample(route, grid, badPolicy) }

        func directoryFailure(_ keys: [Key], _ heightCount: Int, _ policy: Policy, _ message: Comment) {
            let bad = TileSet(keys: keys, heights: [Float](repeating: 0, count: heightCount))
            #expect(throws: DemSamplingError.invalidTileDirectory, message) { try Self.sample(route, bad, policy) }
        }
        directoryFailure([Key(x: 1, y: 1), Key(x: 0, y: 1)], 32, Self.makePolicy(), "keys out of (y, x) order")
        directoryFailure([Key(x: 1, y: 1), Key(x: 1, y: 1)], 32, Self.makePolicy(), "duplicate keys")
        directoryFailure([Key(x: 4, y: 0)], 16, Self.makePolicy(), "x outside the zoom-2 grid")
        directoryFailure([Key(x: 0, y: 4)], 16, Self.makePolicy(), "y outside the zoom-2 grid")
        directoryFailure([Key(x: 0, y: 0)], 15, Self.makePolicy(), "too few heights for one tile")
        directoryFailure([Key(x: 0, y: 0)], 17, Self.makePolicy(), "too many heights for one tile")
        directoryFailure([Key(x: 0, y: 0), Key(x: 1, y: 0)], 32, Self.makePolicy(Self.gridZoom, Self.gridTileSize, 1), "more tiles than the budget")
    }

    @Test func test_sample_bilinear_exactness() throws {
        let grid = Self.makeTiles(Self.allTiles(Self.gridZoom), Self.gridTileSize, Self.planarHeight)

        let centres = try Self.sample([Self.route(0.0, Self.longitudeAt(5.5))], grid)
        #expect(centres.samples[0].elevationMeters == Self.planarExpected(5.5, 8.0), "pixel-centre column, row midpoint")

        for globalX in [0.75, 3.5, 3.75, 4.0, 4.25, 7.875, 8.0, 12.5, 15.25] {
            let result = try Self.sample([Self.route(0.0, Self.longitudeAt(globalX))], grid)
            #expect(result.samples[0].status == .sampled, "equator samples")
            #expect(result.samples[0].elevationMeters == Self.planarExpected(globalX, 8.0), "bilinear reproduces the plane exactly at dyadic positions")
        }

        for globalY in [1.3, 3.9, 4.0, 6.25, 11.7, 14.2] {
            let result = try Self.sample([Self.atPixel(6.3, globalY)], grid)
            #expect(result.samples[0].status == .sampled, "off-equator samples")
            #expect(Self.near(result.samples[0].elevationMeters, Self.planarExpected(6.3, globalY), 1e-6), "plane off the equator")
        }
        #expect(try Self.sample([Self.atPixel(6.25, 6.25)], grid).sampledCount == 1, "summary counts the sample")
    }

    @Test func test_sample_missing_tiles_fall_back_per_point() throws {
        let keys = Self.allTiles(Self.gridZoom).filter { !($0.x == 1 && $0.y == 1) }
        let partial = Self.makeTiles(keys, Self.gridTileSize, Self.planarHeight)
        let result = try Self.sample([
            Self.atPixel(2.25, 6.25), Self.atPixel(4.0, 6.25), Self.atPixel(6.25, 6.25),
            Self.atPixel(3.5, 6.25), Self.atPixel(10.25, 6.25),
        ], partial)
        #expect(result.samples[0].status == .sampled, "a point inside a present tile is sampled")
        #expect(result.samples[1].status == .missingTile, "a point needing the missing tile falls back")
        #expect(result.samples[2].status == .missingTile, "a point inside the missing tile falls back")
        #expect(result.samples[3].status == .sampled, "a zero-weight missing neighbour is not needed")
        #expect(Self.near(result.samples[3].elevationMeters, Self.planarExpected(3.5, 6.25), 1e-6), "edge-pixel centre value")
        #expect(result.samples[4].status == .sampled, "points after a fallback are unaffected")
        #expect(result.sampledCount == 3 && result.missingTileCount == 2, "per-status counts")
    }

    @Test func test_sample_implausible_heights() throws {
        let heightAt: (Int64, Int64) -> Float = { column, row in
            if column == 5 && row == 5 { return .nan }
            if column == 6 && row == 5 { return .infinity }
            if column == 9 && row == 5 { return 9_500.0 }
            if column == 9 && row == 9 { return -600.0 }
            if column == 11 && row == 11 { return .nan }
            return Self.planarHeight(column, row)
        }
        let keys = Self.allTiles(Self.gridZoom).filter { !($0.x == 3 && $0.y == 3) }
        let tiles = Self.makeTiles(keys, Self.gridTileSize, heightAt)
        let result = try Self.sample([
            Self.atPixel(6.0, 5.75), Self.atPixel(9.75, 5.75), Self.atPixel(9.75, 9.75),
            Self.atPixel(5.5, 5.5), Self.atPixel(4.5, 4.5), Self.atPixel(12.25, 12.25),
        ], tiles)
        #expect(result.samples[0].status == .implausibleHeight, "non-finite corner heights")
        #expect(result.samples[1].status == .implausibleHeight, "a corner above the plausible range")
        #expect(result.samples[2].status == .implausibleHeight, "a corner below the plausible range")
        #expect(result.samples[3].status == .implausibleHeight, "a full-weight NaN pixel")
        #expect(result.samples[4].status == .sampled, "zero-weight corners are never read")
        #expect(result.samples[5].status == .missingTile, "missing outranks implausible")
        #expect(result.implausibleHeightCount == 4, "implausible count")
    }

    @Test func test_sample_antimeridian() throws {
        let grid = Self.makeTiles(Self.allTiles(Self.gridZoom), Self.gridTileSize, Self.planarHeight)
        let lastColumn = (Double(Self.planarHeight(15, 7)) + Double(Self.planarHeight(15, 8))) / 2.0
        let firstColumn = (Double(Self.planarHeight(0, 7)) + Double(Self.planarHeight(0, 8))) / 2.0

        let east = try Self.sample([Self.route(0.0, 180.0)], grid)
        let west = try Self.sample([Self.route(0.0, -180.0)], grid)
        #expect(east.samples[0].status == .sampled, "longitude 180 samples")
        #expect(east.samples[0].elevationMeters == west.samples[0].elevationMeters, "+-180 name the same meridian and give the same height")
        #expect(east.samples[0].elevationMeters == (lastColumn + firstColumn) / 2.0, "the antimeridian interpolates between the last and first columns")

        let nearWest = try Self.sample([Self.route(0.0, Self.longitudeAt(0.25))], grid)
        #expect(Self.near(nearWest.samples[0].elevationMeters, lastColumn + (firstColumn - lastColumn) * 0.75), "fractional weight across the antimeridian")
    }

    @Test func test_sample_pole_guards() throws {
        let grid = Self.makeTiles(Self.allTiles(Self.gridZoom), Self.gridTileSize, Self.planarHeight)
        let limit = EngineDemLimits.webMercatorMaximumLatitudeDegrees
        let result = try Self.sample([
            Self.route(limit, Self.longitudeAt(6.25)), Self.route(-limit, Self.longitudeAt(6.25)),
            Self.route(85.06, 10.0), Self.route(-90.0, 10.0), Self.route(Self.quietNaN, 10.0),
        ], grid)
        let topRow = Double(Self.planarHeight(5, 0)) + (Double(Self.planarHeight(6, 0)) - Double(Self.planarHeight(5, 0))) * 0.75
        let bottomRow = Double(Self.planarHeight(5, 15)) + (Double(Self.planarHeight(6, 15)) - Double(Self.planarHeight(5, 15))) * 0.75
        #expect(result.samples[0].status == .sampled, "the northern limit samples")
        #expect(Self.near(result.samples[0].elevationMeters, topRow), "the northern limit reads only the top row")
        #expect(Self.near(result.samples[1].elevationMeters, bottomRow), "the southern limit reads only the bottom row")
        #expect(result.samples[2].status == .outsideProjection, "beyond the limit")
        #expect(result.samples[3].status == .outsideProjection, "the pole itself")
        #expect(result.samples[4].status == .invalidCoordinate, "invalid coordinate")
        #expect(result.sampledCount == 2 && result.outsideProjectionCount == 2 && result.invalidCoordinateCount == 1, "per-status counts sum to the sample count")
    }

    // MARK: The property the two-call design depends on

    private static func unit(_ random: inout SplitMix64) -> Double {
        Double(random.next() >> 11) / Double(UInt64(1) << 53)
    }

    /// Seeded routes that stress the footprint: random walks, scattered points,
    /// exact tile edges and corners, antimeridian crossings, the latitude limit,
    /// and invalid or polar coordinates.
    private static func propertyRoute(_ random: inout SplitMix64, _ zoom: UInt32, _ tileSize: UInt32) -> [DemRouteSample] {
        var route: [DemRouteSample] = []
        let world = Double((UInt64(1) << UInt64(zoom)) * UInt64(tileSize))
        let tiles = Double(UInt64(1) << UInt64(zoom))
        let limit = EngineDemLimits.webMercatorMaximumLatitudeDegrees

        var latitude = -60.0 + 120.0 * unit(&random)
        var longitude = 179.0 + unit(&random)
        for _ in 0..<200 {
            latitude = min(max(latitude + (unit(&random) - 0.5) * 0.4, -limit), limit)
            longitude += unit(&random) * 0.02
            if longitude > 180.0 { longitude -= 360.0 }
            route.append(Self.route(latitude, longitude))
        }
        for _ in 0..<200 {
            route.append(Self.route((unit(&random) * 2.0 - 1.0) * limit, unit(&random) * 360.0 - 180.0))
        }
        for _ in 0..<64 {
            let tileEdgeX = (unit(&random) * tiles).rounded(.down) * Double(tileSize)
            route.append(Self.route(0.0, longitudeAt(tileEdgeX, world)))
            route.append(Self.route((unit(&random) * 2.0 - 1.0) * 80.0, longitudeAt(tileEdgeX, world)))
            route.append(Self.route(0.0, longitudeAt(tileEdgeX + 0.5, world)))
        }
        route.append(Self.route(0.0, 180.0))
        route.append(Self.route(0.0, -180.0))
        route.append(Self.route(limit, 180.0))
        route.append(Self.route(-limit, -180.0))
        route.append(Self.route(89.0, 0.0))
        route.append(Self.route(Self.quietNaN, 0.0))
        route.append(Self.route(0.0, 181.0))
        return route
    }

    @Test func test_sampler_reads_only_planned_tiles() throws {
        let grids: [(UInt32, UInt32)] = [(0, 2), (1, 3), (2, 4), (3, 5), (5, 8), (12, 16), (UInt32(EngineDemLimits.maximumZoom), 2)]
        var random = SplitMix64(seed: 0x5EED)
        let heightAt: (Int64, Int64) -> Float = { column, row in Float(((column * 7_919 + row * 104_729) % 4_001) - 500) }

        for (zoom, tileSize) in grids {
            for _ in 0..<4 {
                let route = Self.propertyRoute(&random, zoom, tileSize)
                let policy = Self.makePolicy(zoom, tileSize, 4_096)
                let planned = try Self.plan(route, policy)

                let plannedTiles = Self.makeTiles(planned.tiles, tileSize, heightAt)
                let sampled = try Self.sample(route, plannedTiles, policy)
                #expect(sampled.missingTileCount == 0, "sampling never needs a tile the planner omitted")
                #expect(sampled.sampledCount == planned.projectableSampleCount, "every projectable sample is sampled from the planned tiles")
                #expect(sampled.invalidCoordinateCount == planned.invalidCoordinateCount
                    && sampled.outsideProjectionCount == planned.outsideProjectionCount,
                    "planning and sampling classify coordinates identically")

                let probes = min(planned.tiles.count, 12)
                for probe in 0..<probes {
                    var without = planned.tiles
                    without.remove(at: probe)
                    let reduced = try Self.sample(route, Self.makeTiles(without, tileSize, heightAt), policy)
                    #expect(reduced.missingTileCount > 0, "every planned tile is read by some sample")
                }

                if zoom <= 3 {
                    let whole = try Self.sample(route, Self.makeTiles(Self.allTiles(zoom), tileSize, heightAt), policy)
                    for index in route.indices {
                        #expect(whole.samples[index].status == sampled.samples[index].status
                            && whole.samples[index].elevationMeters.bitPattern == sampled.samples[index].elevationMeters.bitPattern,
                            "tiles outside the plan never influence a sample")
                    }
                }
            }
        }
    }

    @Test func test_sample_large_route() throws {
        var route: [DemRouteSample] = []
        route.reserveCapacity(100_000)
        var random = SplitMix64(seed: 42)
        var latitude = -33.9
        var longitude = 151.1
        for _ in 0..<100_000 {
            latitude += (Self.unit(&random) - 0.48) * 0.0003
            longitude += (Self.unit(&random) - 0.45) * 0.0003
            route.append(Self.route(latitude, longitude))
        }
        let policy = Self.makePolicy(12, 64, 4_096)
        let planned = try Self.plan(route, policy)
        let heightAt: (Int64, Int64) -> Float = { column, row in Float(((column + 3 * row) % 900) + 10) }
        let tiles = Self.makeTiles(planned.tiles, 64, heightAt)
        let first = try Self.sample(route, tiles, policy)
        let second = try Self.sample(route, tiles, policy)
        #expect(first.sampledCount == UInt64(route.count), "every point of a covered route is sampled")
        for index in route.indices {
            #expect(first.samples[index].elevationMeters.bitPattern == second.samples[index].elevationMeters.bitPattern, "sampling is deterministic")
            #expect(first.samples[index].elevationMeters >= 10.0 && first.samples[index].elevationMeters <= 909.0, "a bilinear value stays inside its corner range")
        }
    }
}
