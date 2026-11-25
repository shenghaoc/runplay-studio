#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// DEM tiles form the XYZ ("slippy map") Web Mercator grid used by z/x/y tile
// folders: at zoom `z` the world is 2^z x 2^z square tiles of `tileSize` pixels,
// x grows eastward from the antimeridian and y grows southward from the north
// edge (not TMS). Pixels are areas; the elevation of pixel (i, j) is the terrain
// height at the pixel centre, so bilinear interpolation runs between pixel
// centres and a point within half a pixel of a tile edge needs the neighbouring
// tile. Columns wrap across the antimeridian; rows clamp at the Web Mercator
// latitude limit and never wrap across a pole. The engine performs no file I/O
// and no image decoding: Swift decodes tiles and passes decoded heights.

package enum EngineDemLimits {
    /// At zoom 24 with 4,096-pixel tiles the global pixel grid is 2^36 pixels
    /// wide, well inside the 2^53 range in which a double holds every integer.
    package static let maximumZoom = 24
    package static let minimumTileSize = 2
    package static let maximumTileSize = 4_096
    /// Engine ceiling on distinct tiles in one pass.
    package static let maximumTileCount = 65_536
    /// Web Mercator latitude limit, atan(sinh(pi)) in degrees.
    package static let webMercatorMaximumLatitudeDegrees = 85.0511287798066
}

/// One route coordinate in source order.
package struct DemRouteSample: Sendable {
    package var latitudeDegrees: Double
    package var longitudeDegrees: Double

    package init(latitudeDegrees: Double = 0, longitudeDegrees: Double = 0) {
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
    }
}

/// One tile address at the policy zoom. Every tile list crossing the boundary is
/// strictly ascending by `(y, x)`: north to south, then west to east.
package struct DemTileKey: Sendable, Equatable {
    package var x: UInt32
    package var y: UInt32

    package init(x: UInt32 = 0, y: UInt32 = 0) {
        self.x = x
        self.y = y
    }
}

package struct DemSamplingPolicy: Sendable {
    package var zoom: UInt32
    package var tileSize: UInt32
    package var maximumTileCount: UInt64
    package var minimumPlausibleElevationMeters: Double
    package var maximumPlausibleElevationMeters: Double

    package init(
        zoom: UInt32 = 0, tileSize: UInt32 = 0, maximumTileCount: UInt64 = 0,
        minimumPlausibleElevationMeters: Double = 0, maximumPlausibleElevationMeters: Double = 0
    ) {
        self.zoom = zoom
        self.tileSize = tileSize
        self.maximumTileCount = maximumTileCount
        self.minimumPlausibleElevationMeters = minimumPlausibleElevationMeters
        self.maximumPlausibleElevationMeters = maximumPlausibleElevationMeters
    }
}

/// Why a coordinate has, or lacks, a DEM elevation. When several reasons apply,
/// the first in this order is reported.
package enum DemSampleStatus: UInt8, Sendable {
    case sampled = 0
    case invalidCoordinate
    case outsideProjection
    /// A tile holding a non-zero-weight corner is not in the directory.
    case missingTile
    /// A non-zero-weight corner height is non-finite or outside the plausible range.
    case implausibleHeight
}

/// `hasElevation` is 1 exactly when `status` is `.sampled`; otherwise
/// `elevationMeters` is 0 and carries no meaning.
package struct DemElevationOutputSample: Sendable {
    package var elevationMeters: Double = 0
    package var status: DemSampleStatus = .invalidCoordinate
    package var hasElevation: UInt8 = 0

    package init() {}
}

/// The status failures tile planning can report with a borrowed input span.
/// The engine returns exactly the tiles it planned, so there is no buffer or
/// capacity failure.
package enum DemTilePlanError: Error, Equatable {
    case invalidPolicy
    /// The route needs more than `maximumTileCount` tiles. Core keeps recorded
    /// elevation for this workout; this is not a retry signal.
    case tileBudgetExceeded
    case resourceLimit
    case internalFailure
}

/// The status failures bilinear sampling can report with borrowed inputs.
package enum DemSamplingError: Error, Equatable {
    case invalidPolicy
    /// The tile directory breaks its contract: order, key range, count, or the
    /// height buffer's size. Checked before the first output write.
    case invalidTileDirectory
    case resourceLimit
    case internalFailure
}

package struct DemTilePlanResult: Sendable {
    package var sampleCount: UInt64 = 0
    package var projectableSampleCount: UInt64 = 0
    package var invalidCoordinateCount: UInt64 = 0
    package var outsideProjectionCount: UInt64 = 0
    /// Distinct tiles, strictly ascending by `(y, x)`.
    package var tiles: [DemTileKey] = []

    package init() {}
}

package struct DemSamplingResult: Sendable {
    package var sampleCount: UInt64 = 0
    package var sampledCount: UInt64 = 0
    package var invalidCoordinateCount: UInt64 = 0
    package var outsideProjectionCount: UInt64 = 0
    package var missingTileCount: UInt64 = 0
    package var implausibleHeightCount: UInt64 = 0
    /// One entry per input coordinate.
    package var samples: [DemElevationOutputSample] = []

    package init() {}
}

// MARK: - Shared tile-grid geometry

private enum DemCoordinateClass {
    case projectable
    case invalidCoordinate
    case outsideProjection
}

/// The global pixels a bilinear sample of one coordinate reads. Only pixels with
/// non-zero bilinear weight are listed.
private struct DemPixelFootprint {
    var classification: DemCoordinateClass = .invalidCoordinate
    var column0: Int64 = 0, column1: Int64 = 0
    var row0: Int64 = 0, row1: Int64 = 0
    var columnCount: Int = 0
    var rowCount: Int = 0
    /// Weight of the second column / row; meaningful only when its count is two.
    var columnFraction: Double = 0
    var rowFraction: Double = 0

    func column(_ index: Int) -> Int64 { index == 0 ? column0 : column1 }
    func row(_ index: Int) -> Int64 { index == 0 ? row0 : row1 }
}

/// Distinct tiles holding the pixels of one footprint: at most four.
///
/// The C++ source walks the corners row by row and drops a key it has already
/// seen. The result is the distinct row tiles crossed with the distinct column
/// tiles, in row-major first-occurrence order, which is what this stores: one
/// tile index per distinct column and row instead of one comparison per corner.
private struct DemFootprintTiles: Equatable {
    var column0: UInt32 = 0, column1: UInt32 = 0
    var row0: UInt32 = 0, row1: UInt32 = 0
    var columnCount = 0
    var rowCount = 0

    var count: Int { columnCount * rowCount }

    func key(_ index: Int) -> DemTileKey {
        let row = index / columnCount
        let column = index - row * columnCount
        return DemTileKey(x: column == 0 ? column0 : column1, y: row == 0 ? row0 : row1)
    }
}

@inline(__always)
private func demWrapColumn(_ column: Int64, _ world: Int64) -> Int64 {
    column < 0 ? column + world : (column >= world ? column - world : column)
}

/// C++ `std::clamp(v, lo, hi)` is `(v < lo) ? lo : (hi < v) ? hi : v`.
@inline(__always)
private func demClamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    value < low ? low : (high < value ? high : value)
}

@inline(__always)
private func demClamp(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 {
    value < low ? low : (high < value ? high : value)
}

@inline(__always)
private func demKeyLess(_ lhs: DemTileKey, _ rhs: DemTileKey) -> Bool {
    lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x
}

/// Pixel-to-tile arithmetic for one pass. Pixels are non-negative, so for a
/// power-of-two tile size a shift and a mask give exactly the quotient and
/// remainder of the division the C++ source performs.
private struct DemTileGrid {
    let size: Int64
    let world: Int64
    /// log2(size) when `size` is a power of two, otherwise -1.
    let shift: Int64

    init(zoom: UInt32, tileSize: UInt32) {
        size = Int64(tileSize)
        world = (Int64(1) &<< Int64(zoom)) &* Int64(tileSize)
        shift = tileSize & (tileSize &- 1) == 0 ? Int64(tileSize.trailingZeroBitCount) : -1
    }

    @inline(__always)
    func tileIndex(_ pixel: Int64) -> Int64 { shift >= 0 ? pixel &>> shift : pixel / size }

    @inline(__always)
    func localIndex(_ pixel: Int64) -> Int64 { shift >= 0 ? pixel & (size &- 1) : pixel % size }

    /// Columns are wrapped and rows clamped into [0, world), so both indexes are
    /// below 2^24 and fit in UInt32.
    @inline(__always)
    func tile(_ column: Int64, _ row: Int64) -> DemTileKey {
        DemTileKey(x: UInt32(truncatingIfNeeded: tileIndex(column)), y: UInt32(truncatingIfNeeded: tileIndex(row)))
    }
}

/// Classifies one coordinate and, when projectable, lists the pixels its bilinear
/// sample reads. Pixel (i, j) holds the height at its centre, so the sample
/// position is offset by half a pixel before flooring. Planning and sampling both
/// call this, so every tile a sample reads is a tile the planner lists.
///
/// Statements are split so no single expression holds both a multiply and an add:
/// the C++ build's default `-ffp-contract=on` could otherwise fuse them, and Swift
/// performs them as two rounded operations.
@inline(__always)
private func demPixelFootprint(
    _ latitudeDegrees: Double, _ longitudeDegrees: Double, _ grid: DemTileGrid
) -> DemPixelFootprint {
    let world = grid.world
    var footprint = DemPixelFootprint()
    if !EngineGeodesy.isValidCoordinate(latitude: latitudeDegrees, longitude: longitudeDegrees) {
        footprint.classification = .invalidCoordinate
        return footprint
    }
    if abs(latitudeDegrees) > EngineDemLimits.webMercatorMaximumLatitudeDegrees {
        footprint.classification = .outsideProjection
        return footprint
    }
    footprint.classification = .projectable

    let worldPixels = Double(world)

    // Longitude: x grows east from the antimeridian. ±180 give fractions 0 and 1,
    // which wrap to the same column pair below.
    let shiftedLongitude = longitudeDegrees + 180.0
    let xFraction = shiftedLongitude / 360.0
    let globalX = xFraction * worldPixels
    let columnPosition = globalX - 0.5
    let columnFloor = columnPosition.rounded(.down)
    let columnFraction = columnPosition - columnFloor
    let firstColumn = Int64(columnFloor)

    // Latitude: spherical Web Mercator, y grows south from the north edge.
    // Clamping absorbs the last ulp at the latitude limit.
    let latitudeRadians = latitudeDegrees * Double.pi / 180.0
    let mercator = asinh(tan(latitudeRadians))
    let mercatorFraction = mercator / (2.0 * Double.pi)
    let yFraction = demClamp(0.5 - mercatorFraction, 0.0, 1.0)
    let globalY = yFraction * worldPixels
    let rowPosition = globalY - 0.5
    let rowFloor = rowPosition.rounded(.down)
    let rowFraction = rowPosition - rowFloor
    let firstRow = Int64(rowFloor)

    footprint.column0 = demWrapColumn(firstColumn, world)
    footprint.columnCount = 1
    if columnFraction > 0.0 {
        footprint.column1 = demWrapColumn(firstColumn + 1, world)
        footprint.columnCount = 2
        footprint.columnFraction = columnFraction
    }

    let lastRow = world - 1
    footprint.row0 = demClamp(firstRow, 0, lastRow)
    footprint.rowCount = 1
    let secondRow = demClamp(firstRow + 1, 0, lastRow)
    if rowFraction > 0.0 && secondRow != footprint.row0 {
        footprint.row1 = secondRow
        footprint.rowCount = 2
        footprint.rowFraction = rowFraction
    }
    return footprint
}

@inline(__always)
private func demFootprintTiles(_ footprint: DemPixelFootprint, _ grid: DemTileGrid) -> DemFootprintTiles {
    var tiles = DemFootprintTiles()
    tiles.column0 = UInt32(truncatingIfNeeded: grid.tileIndex(footprint.column0))
    tiles.columnCount = 1
    if footprint.columnCount == 2 {
        let second = UInt32(truncatingIfNeeded: grid.tileIndex(footprint.column1))
        if second != tiles.column0 {
            tiles.column1 = second
            tiles.columnCount = 2
        }
    }
    tiles.row0 = UInt32(truncatingIfNeeded: grid.tileIndex(footprint.row0))
    tiles.rowCount = 1
    if footprint.rowCount == 2 {
        let second = UInt32(truncatingIfNeeded: grid.tileIndex(footprint.row1))
        if second != tiles.row0 {
            tiles.row1 = second
            tiles.rowCount = 2
        }
    }
    return tiles
}

private func isValidDemPolicy(_ policy: DemSamplingPolicy) -> Bool {
    policy.zoom <= UInt32(EngineDemLimits.maximumZoom)
        && policy.tileSize >= UInt32(EngineDemLimits.minimumTileSize)
        && policy.tileSize <= UInt32(EngineDemLimits.maximumTileSize)
        && policy.maximumTileCount >= 1
        && policy.maximumTileCount <= UInt64(EngineDemLimits.maximumTileCount)
        && policy.minimumPlausibleElevationMeters.isFinite
        && policy.maximumPlausibleElevationMeters.isFinite
        && policy.minimumPlausibleElevationMeters < policy.maximumPlausibleElevationMeters
}

// MARK: - Tile planning

package enum DemTilePlanning {
    /// Lists every tile whose pixels a bilinear sample of the route will read.
    /// Internal storage is bounded by `maximumTileCount`, never by route length.
    package static func plan(
        samples: Span<DemRouteSample>, policy: DemSamplingPolicy
    ) throws(DemTilePlanError) -> DemTilePlanResult {
        let sampleCount = samples.count
        if sampleCount == 0 {
            guard isValidDemPolicy(policy) else { throw .invalidPolicy }
            return DemTilePlanResult()
        }
        guard sampleCount <= EngineRouteLimits.maxRouteInputSamples else { throw .resourceLimit }
        guard isValidDemPolicy(policy) else { throw .invalidPolicy }

        // Pixels across the world at this zoom: at most 2^24 tiles x 4,096 pixels.
        let grid = DemTileGrid(zoom: policy.zoom, tileSize: policy.tileSize)

        // Strictly ascending (y, x) set, bounded by the tile budget. Consecutive
        // points usually share their tiles, so the previous footprint is checked
        // before the binary search.
        var tiles: [DemTileKey] = []
        tiles.reserveCapacity(Int(min(policy.maximumTileCount, 256)))
        var previous = DemFootprintTiles()

        var result = DemTilePlanResult()
        result.sampleCount = UInt64(sampleCount)

        for index in 0..<sampleCount {
            let sample = samples[index]
            let footprint = demPixelFootprint(sample.latitudeDegrees, sample.longitudeDegrees, grid)
            if footprint.classification == .invalidCoordinate {
                result.invalidCoordinateCount += 1
                continue
            }
            if footprint.classification == .outsideProjection {
                result.outsideProjectionCount += 1
                continue
            }
            result.projectableSampleCount += 1

            let current = demFootprintTiles(footprint, grid)
            // Every tile of the previous footprint is already in `tiles`, so an
            // identical tile set adds nothing.
            if current == previous { continue }
            for keyIndex in 0..<current.count {
                let key = current.key(keyIndex)
                var recent = false
                for seen in 0..<previous.count { recent = recent || previous.key(seen) == key }
                if recent { continue }
                var position = 0
                var length = tiles.count
                while length > 0 {
                    let half = length >> 1
                    let middle = position + half
                    if demKeyLess(tiles[middle], key) {
                        position = middle + 1
                        length -= half + 1
                    } else {
                        length = half
                    }
                }
                if position < tiles.count && tiles[position] == key { continue }
                if UInt64(tiles.count) >= policy.maximumTileCount { throw .tileBudgetExceeded }
                tiles.insert(key, at: position)
            }
            previous = current
        }
        result.tiles = tiles
        return result
    }
}

// MARK: - Bilinear sampling

package enum DemElevationSampling {
    /// `first + (second - first) * fraction`, split so no statement holds both a
    /// multiply and an add.
    private static func interpolate(_ first: Double, _ second: Double, _ fraction: Double) -> Double {
        let difference = second - first
        let scaled = difference * fraction
        return first + scaled
    }

    /// Directory contract: at most `maximumTileCount` keys, strictly ascending by
    /// `(y, x)`, every key inside the zoom's grid, and exactly `tileSize^2` heights
    /// per key. Checked in full before sampling writes anything.
    private static func isValidTileDirectory(
        _ policy: DemSamplingPolicy, _ tiles: Span<DemTileKey>, heightCount: Int
    ) -> Bool {
        if UInt64(tiles.count) > policy.maximumTileCount { return false }
        // tileCount <= 65,536 and tileSize^2 <= 2^24, so the product fits.
        let heightsPerTile = UInt64(policy.tileSize) * UInt64(policy.tileSize)
        if UInt64(heightCount) != UInt64(tiles.count) * heightsPerTile { return false }
        let tilesPerAxis = UInt64(1) << UInt64(policy.zoom)
        // Each key is read once into a local. Swift 6.3.3 crashes in an optimized
        // build (CopyPropagation, "leaked owned value") on the form that
        // subscripts the span three times per iteration.
        guard tiles.count > 0 else { return true }
        var previous = tiles[0]
        if UInt64(previous.x) >= tilesPerAxis || UInt64(previous.y) >= tilesPerAxis { return false }
        for index in 1..<tiles.count {
            let key = tiles[index]
            if UInt64(key.x) >= tilesPerAxis || UInt64(key.y) >= tilesPerAxis { return false }
            if !demKeyLess(previous, key) { return false }
            previous = key
        }
        return true
    }

    /// Directory position of `key`, remembering the previous hit because consecutive
    /// corners and consecutive points usually share a tile.
    @inline(__always)
    private static func findTile(
        _ key: DemTileKey, in tiles: Span<DemTileKey>, cachedPosition: inout Int, hasCached: inout Bool
    ) -> Int? {
        // The span is never read inside the right-hand side of `&&` or `||`: that
        // autoclosure form crashes Swift 6.3.3 in an optimized build
        // (CopyPropagation, "leaked owned value").
        if hasCached {
            if tiles[cachedPosition] == key { return cachedPosition }
        }
        var low = 0
        var length = tiles.count
        while length > 0 {
            let half = length >> 1
            let middle = low + half
            if demKeyLess(tiles[middle], key) {
                low = middle + 1
                length -= half + 1
            } else {
                length = half
            }
        }
        if low == tiles.count { return nil }
        if tiles[low] != key { return nil }
        cachedPosition = low
        hasCached = true
        return low
    }

    /// Bilinearly samples Swift-decoded tile heights at every route coordinate.
    /// A tile absent from the directory is not an error: each affected coordinate
    /// reports `.missingTile` and falls back on its own.
    package static func sample(
        samples: Span<DemRouteSample>, policy: DemSamplingPolicy,
        tiles: Span<DemTileKey>, tileHeights: Span<Float>
    ) throws(DemSamplingError) -> DemSamplingResult {
        let sampleCount = samples.count
        guard sampleCount <= EngineRouteLimits.maxRouteInputSamples else { throw .resourceLimit }
        guard isValidDemPolicy(policy) else { throw .invalidPolicy }
        guard isValidTileDirectory(policy, tiles, heightCount: tileHeights.count) else { throw .invalidTileDirectory }

        var result = DemSamplingResult()
        result.sampleCount = UInt64(sampleCount)

        let tileSize = Int(policy.tileSize)
        let heightsPerTile = tileSize * tileSize
        let grid = DemTileGrid(zoom: policy.zoom, tileSize: policy.tileSize)
        var counts = (sampled: UInt64(0), invalid: UInt64(0), outside: UInt64(0), missing: UInt64(0), implausible: UInt64(0))

        let output = unsafe [DemElevationOutputSample](unsafeUninitializedCapacity: sampleCount) { buffer, initialized in
            // SAFETY: each element is initialized once, in order, before `initialized` grows.
            var cachedPosition = 0
            var hasCached = false
            var sampled: UInt64 = 0, invalid: UInt64 = 0, outside: UInt64 = 0, missing: UInt64 = 0, implausible: UInt64 = 0
            for index in 0..<sampleCount {
                var out = DemElevationOutputSample()
                let footprint = demPixelFootprint(samples[index].latitudeDegrees, samples[index].longitudeDegrees, grid)
                if footprint.classification == .invalidCoordinate {
                    out.status = .invalidCoordinate
                } else if footprint.classification == .outsideProjection {
                    out.status = .outsideProjection
                } else {
                    // corner[row * 2 + column]; only non-zero-weight corners are resolved.
                    // A tile and a local index depend on the column or the row alone,
                    // so each is computed once per distinct column and row.
                    var corner: (Double, Double, Double, Double) = (0, 0, 0, 0)
                    var missing = false
                    var implausible = false
                    let columnTile0 = UInt32(truncatingIfNeeded: grid.tileIndex(footprint.column0))
                    let columnTile1 = UInt32(truncatingIfNeeded: grid.tileIndex(footprint.column1))
                    let columnLocal0 = Int(grid.localIndex(footprint.column0))
                    let columnLocal1 = Int(grid.localIndex(footprint.column1))
                    let rowTile0 = UInt32(truncatingIfNeeded: grid.tileIndex(footprint.row0))
                    let rowTile1 = UInt32(truncatingIfNeeded: grid.tileIndex(footprint.row1))
                    let rowLocal0 = Int(grid.localIndex(footprint.row0))
                    let rowLocal1 = Int(grid.localIndex(footprint.row1))
                    // Resolve each distinct tile once: corners that share a tile share its
                    // directory position. -1 marks a tile absent from the directory.
                    let sameColumnTile = footprint.columnCount == 1 || columnTile1 == columnTile0
                    let sameRowTile = footprint.rowCount == 1 || rowTile1 == rowTile0
                    let position00 = findTile(DemTileKey(x: columnTile0, y: rowTile0), in: tiles, cachedPosition: &cachedPosition, hasCached: &hasCached) ?? -1
                    let position01 = sameColumnTile ? position00
                        : (findTile(DemTileKey(x: columnTile1, y: rowTile0), in: tiles, cachedPosition: &cachedPosition, hasCached: &hasCached) ?? -1)
                    let position10 = sameRowTile ? position00
                        : (findTile(DemTileKey(x: columnTile0, y: rowTile1), in: tiles, cachedPosition: &cachedPosition, hasCached: &hasCached) ?? -1)
                    let position11 = sameRowTile ? position01
                        : (sameColumnTile ? position10
                            : (findTile(DemTileKey(x: columnTile1, y: rowTile1), in: tiles, cachedPosition: &cachedPosition, hasCached: &hasCached) ?? -1))
                    let plausibleMinimum = policy.minimumPlausibleElevationMeters
                    let plausibleMaximum = policy.maximumPlausibleElevationMeters
                    if footprint.columnCount == 2 && footprint.rowCount == 2 && sameColumnTile && sameRowTile && position00 >= 0 {
                        // The usual case: all four corners are in one present tile.
                        let base = position00 * heightsPerTile
                        corner.0 = Double(tileHeights[base + rowLocal0 * tileSize + columnLocal0])
                        corner.1 = Double(tileHeights[base + rowLocal0 * tileSize + columnLocal1])
                        corner.2 = Double(tileHeights[base + rowLocal1 * tileSize + columnLocal0])
                        corner.3 = Double(tileHeights[base + rowLocal1 * tileSize + columnLocal1])
                        func usable(_ height: Double) -> Bool {
                            height.isFinite && !(height < plausibleMinimum) && !(height > plausibleMaximum)
                        }
                        implausible = !(usable(corner.0) && usable(corner.1) && usable(corner.2) && usable(corner.3))
                    } else {
                    for row in 0..<footprint.rowCount {
                        let localRow = row == 0 ? rowLocal0 : rowLocal1
                        for column in 0..<footprint.columnCount {
                            let position = row == 0 ? (column == 0 ? position00 : position01) : (column == 0 ? position10 : position11)
                            if position < 0 {
                                missing = true
                                continue
                            }
                            let localColumn = column == 0 ? columnLocal0 : columnLocal1
                            let offset = position * heightsPerTile + localRow * tileSize + localColumn
                            let height = Double(tileHeights[offset])
                            if !height.isFinite || height < policy.minimumPlausibleElevationMeters
                                || height > policy.maximumPlausibleElevationMeters {
                                implausible = true
                            }
                            switch row * 2 + column {
                            case 0: corner.0 = height
                            case 1: corner.1 = height
                            case 2: corner.2 = height
                            default: corner.3 = height
                            }
                        }
                    }
                    }

                    if missing {
                        out.status = .missingTile
                    } else if implausible {
                        out.status = .implausibleHeight
                    } else {
                        let top = footprint.columnCount == 2
                            ? interpolate(corner.0, corner.1, footprint.columnFraction) : corner.0
                        var elevation = top
                        if footprint.rowCount == 2 {
                            let bottom = footprint.columnCount == 2
                                ? interpolate(corner.2, corner.3, footprint.columnFraction) : corner.2
                            elevation = interpolate(top, bottom, footprint.rowFraction)
                        }
                        out.status = .sampled
                        out.elevationMeters = elevation
                        out.hasElevation = 1
                    }
                }
                switch out.status {
                case .sampled: sampled += 1
                case .invalidCoordinate: invalid += 1
                case .outsideProjection: outside += 1
                case .missingTile: missing += 1
                case .implausibleHeight: implausible += 1
                }
                unsafe buffer.initializeElement(at: index, to: out)
                initialized += 1
            }
            counts = (sampled, invalid, outside, missing, implausible)
        }
        result.sampledCount = counts.sampled
        result.invalidCoordinateCount = counts.invalid
        result.outsideProjectionCount = counts.outside
        result.missingTileCount = counts.missing
        result.implausibleHeightCount = counts.implausible
        result.samples = output
        return result
    }
}
