import Foundation

/// Platform-neutral Web Mercator projection and fixed-size metric grid for
/// personal heatmap aggregation.
///
/// ## Projection notes
///
/// Coordinates are projected to Web Mercator metres using the spherical Earth
/// radius `GeoDistance.earthRadiusMeters`. This matches common slippy-map
/// conventions and yields stable cell IDs across launches.
///
/// **Distortion:** Cell edges are equal in projected metres, not geodesic
/// metres. Near the equator this is nearly isotropic; at higher latitudes the
/// same projected cell covers less true east–west ground distance. The heatmap
/// is for local running-scale visualization, not survey-grade GIS.
///
/// Latitude is clamped to the valid Web Mercator range (~±85.05112878°) so
/// polar singularities never produce infinite projected Y. Longitude is
/// normalized to (−180, 180].
public enum PersonalHeatmapProjection {

    /// Maximum absolute latitude accepted by Web Mercator (degrees).
    public static let maxLatitudeDegrees: Double = 85.051_128_78

    /// Projected half-world width in metres (`π * R`).
    public static var halfWorldMeters: Double {
        .pi * GeoDistance.earthRadiusMeters
    }

    /// Full projected world width in metres (`2 * π * R`).
    public static var worldWidthMeters: Double {
        2 * halfWorldMeters
    }

    // MARK: - Coordinate normalization

    /// Clamp latitude into the Web Mercator valid range.
    public static func clampLatitude(_ latitude: Double) -> Double {
        min(max(latitude, -maxLatitudeDegrees), maxLatitudeDegrees)
    }

    /// Normalize longitude into (−180, 180].
    public static func normalizeLongitude(_ longitude: Double) -> Double {
        guard longitude.isFinite else { return longitude }
        var lon = longitude.truncatingRemainder(dividingBy: 360)
        if lon <= -180 {
            lon += 360
        } else if lon > 180 {
            lon -= 360
        }
        return lon
    }

    // MARK: - Projection

    /// Project WGS84 degrees to Web Mercator metres.
    ///
    /// Returns `nil` for non-finite inputs. Latitude is clamped; longitude is
    /// normalized before projection.
    public static func project(latitude: Double, longitude: Double) -> (x: Double, y: Double)? {
        guard latitude.isFinite, longitude.isFinite else { return nil }

        let lat = clampLatitude(latitude)
        let lon = normalizeLongitude(longitude)
        let latRad = lat * .pi / 180
        let lonRad = lon * .pi / 180
        let r = GeoDistance.earthRadiusMeters

        let x = r * lonRad
        // Web Mercator Y: R * ln(tan(π/4 + φ/2))
        let y = r * log(tan(.pi / 4 + latRad / 2))
        guard x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }

    /// Inverse-project Web Mercator metres to WGS84 degrees.
    public static func unproject(x: Double, y: Double) -> (latitude: Double, longitude: Double)? {
        guard x.isFinite, y.isFinite else { return nil }
        let r = GeoDistance.earthRadiusMeters
        let lonRad = x / r
        let latRad = 2 * atan(exp(y / r)) - .pi / 2
        let latitude = latRad * 180 / .pi
        let longitude = normalizeLongitude(lonRad * 180 / .pi)
        guard latitude.isFinite, longitude.isFinite else { return nil }
        return (clampLatitude(latitude), longitude)
    }

    // MARK: - Grid cells

    /// Quantize projected metres into a cell index using floor division.
    ///
    /// Uses careful handling so negative coordinates map consistently:
    /// `floor(value / cellSize)` semantics via integer arithmetic.
    public static func cellIndex(projected: Double, cellSizeMeters: Double) -> Int64? {
        guard projected.isFinite,
              cellSizeMeters.isFinite,
              cellSizeMeters > 0 else {
            return nil
        }
        // floor(projected / cellSize) without intermediate overflow of Double→Int64
        // for extreme values: clamp projected to world bounds first.
        let clamped = min(max(projected, -halfWorldMeters), halfWorldMeters)
        let quotient = floor(clamped / cellSizeMeters)
        guard quotient.isFinite,
              quotient >= Double(Int64.min),
              quotient <= Double(Int64.max) else {
            return nil
        }
        return Int64(quotient)
    }

    /// Cell ID for a geographic coordinate at the given cell size.
    public static func cellID(
        latitude: Double,
        longitude: Double,
        cellSizeMeters: Double
    ) -> PersonalHeatmapCellID? {
        guard let projected = project(latitude: latitude, longitude: longitude),
              let x = cellIndex(projected: projected.x, cellSizeMeters: cellSizeMeters),
              let y = cellIndex(projected: projected.y, cellSizeMeters: cellSizeMeters) else {
            return nil
        }
        return PersonalHeatmapCellID(x: x, y: y)
    }

    /// Geographic bounds of a cell identified by grid indexes.
    public static func cellBounds(
        id: PersonalHeatmapCellID,
        cellSizeMeters: Double
    ) -> PersonalHeatmapCellBounds? {
        guard cellSizeMeters.isFinite, cellSizeMeters > 0 else { return nil }

        let minX = Double(id.x) * cellSizeMeters
        let maxX = Double(id.x + 1) * cellSizeMeters
        let minY = Double(id.y) * cellSizeMeters
        let maxY = Double(id.y + 1) * cellSizeMeters

        guard let sw = unproject(x: minX, y: minY),
              let ne = unproject(x: maxX, y: maxY) else {
            return nil
        }

        return PersonalHeatmapCellBounds(
            minLatitude: min(sw.latitude, ne.latitude),
            maxLatitude: max(sw.latitude, ne.latitude),
            minLongitude: min(sw.longitude, ne.longitude),
            maxLongitude: max(sw.longitude, ne.longitude)
        )
    }
}

// MARK: - Grid traversal (Amanatides–Woo / supercover)

/// Deterministic line-to-cell traversal over a fixed metric grid.
///
/// Visits every cell a projected line segment crosses without leaving holes.
/// Does **not** bridge route segments; callers must only pass same-segment
/// intervals.
public enum PersonalHeatmapGridTraversal {

    /// Maximum cells a single interval may visit. Bounds attacker-controlled
    /// huge jumps that slip past the projected-length guard.
    public static let defaultMaximumCellsPerInterval = 10_000

    /// Visit every grid cell crossed by the line from `start` to `end` in
    /// projected metres.
    ///
    /// - Parameters:
    ///   - start: Projected start (x, y) in metres.
    ///   - end: Projected end (x, y) in metres.
    ///   - cellSizeMeters: Positive finite cell edge length.
    ///   - maximumCells: Hard cap on visited cells for this interval.
    ///   - isCancelled: Cooperative cancellation; checked periodically.
    /// - Returns: Ordered unique cell IDs for this interval (start cell first).
    /// - Throws: `CancellationError` when cancelled.
    public static func cells(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        cellSizeMeters: Double,
        maximumCells: Int = defaultMaximumCellsPerInterval,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> [PersonalHeatmapCellID] {
        guard cellSizeMeters.isFinite, cellSizeMeters > 0,
              start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite,
              maximumCells >= 1 else {
            return []
        }

        if isCancelled() { throw CancellationError() }

        guard let startX = PersonalHeatmapProjection.cellIndex(projected: start.x, cellSizeMeters: cellSizeMeters),
              let startY = PersonalHeatmapProjection.cellIndex(projected: start.y, cellSizeMeters: cellSizeMeters) else {
            return []
        }

        // Zero-length or within the same cell: just the start cell.
        if start.x == end.x && start.y == end.y {
            return [PersonalHeatmapCellID(x: startX, y: startY)]
        }

        guard let endX = PersonalHeatmapProjection.cellIndex(projected: end.x, cellSizeMeters: cellSizeMeters),
              let endY = PersonalHeatmapProjection.cellIndex(projected: end.y, cellSizeMeters: cellSizeMeters) else {
            return []
        }

        if startX == endX && startY == endY {
            return [PersonalHeatmapCellID(x: startX, y: startY)]
        }

        // Amanatides–Woo grid traversal in 2D.
        var x = startX
        var y = startY

        let dx = end.x - start.x
        let dy = end.y - start.y

        let stepX: Int64 = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
        let stepY: Int64 = dy > 0 ? 1 : (dy < 0 ? -1 : 0)

        // Distance along the ray to cross one cell boundary, in parameter t ∈ [0,1].
        let tDeltaX: Double = stepX == 0 ? .infinity : abs(cellSizeMeters / dx)
        let tDeltaY: Double = stepY == 0 ? .infinity : abs(cellSizeMeters / dy)

        // Next vertical / horizontal grid-line positions.
        func nextBoundary(index: Int64, step: Int64, cellSize: Double) -> Double {
            if step > 0 {
                return Double(index + 1) * cellSize
            } else if step < 0 {
                return Double(index) * cellSize
            }
            return 0
        }

        var tMaxX: Double
        if stepX == 0 {
            tMaxX = .infinity
        } else {
            let boundary = nextBoundary(index: x, step: stepX, cellSize: cellSizeMeters)
            tMaxX = (boundary - start.x) / dx
            // Numerical safety: ensure non-negative
            if tMaxX < 0 { tMaxX = 0 }
        }

        var tMaxY: Double
        if stepY == 0 {
            tMaxY = .infinity
        } else {
            let boundary = nextBoundary(index: y, step: stepY, cellSize: cellSizeMeters)
            tMaxY = (boundary - start.y) / dy
            if tMaxY < 0 { tMaxY = 0 }
        }

        var result: [PersonalHeatmapCellID] = []
        result.reserveCapacity(min(maximumCells, 64))
        result.append(PersonalHeatmapCellID(x: x, y: y))

        // Walk until we reach the end cell. Use a hard iteration cap.
        var iterations = 0
        while (x != endX || y != endY) && iterations < maximumCells {
            iterations += 1
            if iterations % 256 == 0, isCancelled() {
                throw CancellationError()
            }

            // Exact corner: advance both axes in one step so we do not insert
            // an extra diagonal neighbour that the segment does not enter.
            if tMaxX == tMaxY {
                tMaxX += tDeltaX
                tMaxY += tDeltaY
                if stepX != 0 { x += stepX }
                if stepY != 0 { y += stepY }
            } else if tMaxX < tMaxY {
                tMaxX += tDeltaX
                if stepX != 0 { x += stepX }
            } else {
                tMaxY += tDeltaY
                if stepY != 0 { y += stepY }
            }

            // Stop if we overshoot the unit parameter beyond the segment.
            // Allow a tiny epsilon so the end cell is still included.
            let nextT = min(tMaxX, tMaxY)
            // When both are infinity we would loop forever; break.
            if !nextT.isFinite && (x != endX || y != endY) {
                // Axis-aligned residual: snap to end.
                x = endX
                y = endY
            }

            let cell = PersonalHeatmapCellID(x: x, y: y)
            if result.last != cell {
                result.append(cell)
            }

            // Safety: if parameter has clearly passed the end, force end cell.
            if tMaxX > 1.000_000_1 && tMaxY > 1.000_000_1 {
                if result.last != PersonalHeatmapCellID(x: endX, y: endY) {
                    result.append(PersonalHeatmapCellID(x: endX, y: endY))
                }
                break
            }
        }

        // Ensure end cell is present when the walk terminated early by cap.
        let endCell = PersonalHeatmapCellID(x: endX, y: endY)
        if result.last != endCell, result.count < maximumCells {
            result.append(endCell)
        }

        // De-duplicate while preserving order (corner cases can re-insert).
        var seen = Set<PersonalHeatmapCellID>()
        var unique: [PersonalHeatmapCellID] = []
        unique.reserveCapacity(result.count)
        for cell in result {
            if seen.insert(cell).inserted {
                unique.append(cell)
            }
        }
        return unique
    }
}
