import Foundation

/// Test-only reference for DEM tile planning and bilinear sampling.
///
/// An independent pure-Swift implementation of the documented rules: XYZ Web
/// Mercator tiles with `y` from the north edge, heights at pixel centres,
/// bilinear interpolation over non-zero-weight corners only, columns wrapping
/// across the antimeridian, rows clamping at the latitude limit. It must not
/// call the C++ bridge or share helpers with it. Operation order matches the
/// documented split statements (and Swift never contracts a multiply-add), so
/// on one platform the oracle and the engine agree bit for bit.
enum SwiftDemSamplingOracle {
    struct Key: Hashable, Comparable {
        let x: UInt32
        let y: UInt32

        static func < (lhs: Key, rhs: Key) -> Bool {
            lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x
        }
    }

    struct Grid {
        let zoom: Int
        let tileSize: Int
        let maximumTileCount: Int
        let plausibleElevationMeters: ClosedRange<Double>
    }

    enum Sample: Equatable {
        case sampled(Double)
        case invalidCoordinate
        case outsideProjection
        case missingTile
        case implausibleHeight
    }

    enum Plan: Equatable {
        case planned([Key])
        case exceeded(minimumRequiredTileCount: Int)
    }

    static let maximumLatitudeDegrees = 85.0511287798066

    // MARK: Footprint

    private struct Footprint {
        var columns: [Int64] = []
        var rows: [Int64] = []
        var columnFraction = 0.0
        var rowFraction = 0.0
    }

    private enum Classified {
        case invalid
        case outside
        case projectable(Footprint)
    }

    private static func classify(latitude: Double, longitude: Double, grid: Grid) -> Classified {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180
        else {
            return .invalid
        }
        guard abs(latitude) <= maximumLatitudeDegrees else {
            return .outside
        }

        let world = (Int64(1) << Int64(grid.zoom)) * Int64(grid.tileSize)
        let worldPixels = Double(world)

        let shiftedLongitude = longitude + 180
        let xFraction = shiftedLongitude / 360
        let globalX = xFraction * worldPixels
        let columnPosition = globalX - 0.5
        let columnFloor = columnPosition.rounded(.down)
        let columnFraction = columnPosition - columnFloor
        let firstColumn = Int64(columnFloor)

        let latitudeRadians = latitude * Double.pi / 180
        let mercator = asinh(tan(latitudeRadians))
        let mercatorFraction = mercator / (2 * Double.pi)
        let yFraction = min(max(0.5 - mercatorFraction, 0), 1)
        let globalY = yFraction * worldPixels
        let rowPosition = globalY - 0.5
        let rowFloor = rowPosition.rounded(.down)
        let rowFraction = rowPosition - rowFloor
        let firstRow = Int64(rowFloor)

        func wrap(_ column: Int64) -> Int64 {
            ((column % world) + world) % world
        }
        func clampRow(_ row: Int64) -> Int64 {
            min(max(row, 0), world - 1)
        }

        var footprint = Footprint()
        footprint.columns = [wrap(firstColumn)]
        if columnFraction > 0 {
            footprint.columns.append(wrap(firstColumn + 1))
            footprint.columnFraction = columnFraction
        }
        footprint.rows = [clampRow(firstRow)]
        let secondRow = clampRow(firstRow + 1)
        if rowFraction > 0, secondRow != footprint.rows[0] {
            footprint.rows.append(secondRow)
            footprint.rowFraction = rowFraction
        }
        return .projectable(footprint)
    }

    private static func key(column: Int64, row: Int64, tileSize: Int) -> Key {
        Key(x: UInt32(column / Int64(tileSize)), y: UInt32(row / Int64(tileSize)))
    }

    // MARK: Planning

    static func plan(_ coordinates: [(latitude: Double, longitude: Double)], grid: Grid) -> Plan {
        var tiles = Set<Key>()
        for coordinate in coordinates {
            guard case .projectable(let footprint) = classify(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                grid: grid
            ) else {
                continue
            }
            for row in footprint.rows {
                for column in footprint.columns {
                    tiles.insert(key(column: column, row: row, tileSize: grid.tileSize))
                    if tiles.count > grid.maximumTileCount {
                        return .exceeded(minimumRequiredTileCount: grid.maximumTileCount + 1)
                    }
                }
            }
        }
        return .planned(tiles.sorted())
    }

    // MARK: Sampling

    /// `tiles` maps each present tile to `tileSize * tileSize` heights,
    /// row-major from its north-west pixel.
    static func sample(
        _ coordinates: [(latitude: Double, longitude: Double)],
        grid: Grid,
        tiles: [Key: [Float]]
    ) -> [Sample] {
        coordinates.map { coordinate in
            switch classify(latitude: coordinate.latitude, longitude: coordinate.longitude, grid: grid) {
            case .invalid:
                return .invalidCoordinate
            case .outside:
                return .outsideProjection
            case .projectable(let footprint):
                return sample(footprint, grid: grid, tiles: tiles)
            }
        }
    }

    private static func sample(_ footprint: Footprint, grid: Grid, tiles: [Key: [Float]]) -> Sample {
        var corners: [[Double]] = []
        var missing = false
        var implausible = false
        for row in footprint.rows {
            var cornerRow: [Double] = []
            for column in footprint.columns {
                guard let heights = tiles[key(column: column, row: row, tileSize: grid.tileSize)] else {
                    missing = true
                    cornerRow.append(0)
                    continue
                }
                let size = Int64(grid.tileSize)
                let localColumn = Int(column % size)
                let localRow = Int(row % size)
                let height = Double(heights[localRow * grid.tileSize + localColumn])
                if !height.isFinite || !grid.plausibleElevationMeters.contains(height) {
                    implausible = true
                }
                cornerRow.append(height)
            }
            corners.append(cornerRow)
        }
        if missing {
            return .missingTile
        }
        if implausible {
            return .implausibleHeight
        }

        func interpolate(_ first: Double, _ second: Double, _ fraction: Double) -> Double {
            let difference = second - first
            let scaled = difference * fraction
            return first + scaled
        }
        let top = corners[0].count == 2
            ? interpolate(corners[0][0], corners[0][1], footprint.columnFraction)
            : corners[0][0]
        guard corners.count == 2 else {
            return .sampled(top)
        }
        let bottom = corners[1].count == 2
            ? interpolate(corners[1][0], corners[1][1], footprint.columnFraction)
            : corners[1][0]
        return .sampled(interpolate(top, bottom, footprint.rowFraction))
    }
}
