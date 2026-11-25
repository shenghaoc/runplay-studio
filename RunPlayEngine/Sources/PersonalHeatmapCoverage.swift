#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The status failures per-workout heatmap coverage can report with a borrowed
/// input span and an engine-owned result.
///
/// The engine returns exactly the cells it found, so there is no buffer or
/// capacity failure. `invalidInputContract` is kept from the former C++ status
/// set; the kernel never throws it.
package enum PersonalHeatmapCoverageError: Error, Equatable {
    case invalidConfiguration
    case invalidInputContract
    case internalFailure
}

package struct PersonalHeatmapRouteSample: Sendable {
    package var latitude: Double
    package var longitude: Double
    package var routeSegmentIndex: Int64

    package init(latitude: Double = 0, longitude: Double = 0, routeSegmentIndex: Int64 = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.routeSegmentIndex = routeSegmentIndex
    }
}

package struct PersonalHeatmapCellIndex: Sendable, Equatable {
    package var x: Int64
    package var y: Int64

    package init(x: Int64 = 0, y: Int64 = 0) {
        self.x = x
        self.y = y
    }
}

package struct PersonalHeatmapCoverageResult: Sendable {
    package var validProjectedPointCount: UInt64 = 0
    package var effectiveSegmentCount: UInt64 = 0
    package var invalidIntervalCount: UInt64 = 0
    /// De-duplicated cells, strictly ascending by `(y, x)`.
    package var cells: [PersonalHeatmapCellIndex] = []

    package init() {}
}

package enum PersonalHeatmapCoverage {
    package static let maximumLatitudeDegrees = 85.05112878
    package static let defaultMaximumCellsPerInterval = 10_000

    private static let halfWorldMeters = Double.pi * EngineGeodesy.earthRadiusMeters

    private struct ProjectedSample {
        var x: Double
        var y: Double
        var effectiveSegment: UInt64
    }

    /// C++ `std::max(a, b)` is `(a < b) ? b : a`; `std::min(a, b)` is `(b < a) ? b : a`.
    @inline(__always)
    private static func cppMax(_ a: Double, _ b: Double) -> Double { a < b ? b : a }

    @inline(__always)
    private static func cppMin(_ a: Double, _ b: Double) -> Double { b < a ? b : a }

    private static func project(latitude: Double, longitude: Double) -> (x: Double, y: Double)? {
        guard EngineGeodesy.isValidCoordinate(latitude: latitude, longitude: longitude) else { return nil }

        let lat = cppMin(cppMax(latitude, -maximumLatitudeDegrees), maximumLatitudeDegrees)
        // The coordinate is finite and within ±180, so the finite guard of the
        // C++ normalizer never returns early.
        var lon = fmod(longitude, 360.0)
        if lon <= -180.0 {
            lon += 360.0
        } else if lon > 180.0 {
            lon -= 360.0
        }

        // Keep the operation order: (lat * pi) / 180, then radius multiplications.
        let latRad = lat * Double.pi / 180.0
        let lonRad = lon * Double.pi / 180.0
        let radius = EngineGeodesy.earthRadiusMeters

        let x = radius * lonRad
        let y = radius * log(tan(Double.pi / 4.0 + latRad / 2.0))
        if !x.isFinite || !y.isFinite { return nil }
        return (x, y)
    }

    /// Returns `nil` for a nonfinite input, a nonpositive cell size, or a
    /// quotient outside `Int64`. A quotient of exactly 2^63 passes the C++ range
    /// check and then converts out of range, which is undefined behaviour there;
    /// it needs a cell size below 2.2e-12 m. Swift rejects it instead of trapping.
    private static func cellIndex(_ projected: Double, _ cellSizeMeters: Double) -> Int64? {
        if !projected.isFinite || !cellSizeMeters.isFinite || cellSizeMeters <= 0.0 { return nil }
        let clamped = cppMin(cppMax(projected, -halfWorldMeters), halfWorldMeters)
        let quotient = (clamped / cellSizeMeters).rounded(.down)
        if !quotient.isFinite || quotient < -9_223_372_036_854_775_808.0
            || quotient >= 9_223_372_036_854_775_808.0 {
            return nil
        }
        return Int64(quotient)
    }

    /// Open-addressing set of cells. Insertion order does not matter: the result
    /// is sorted by `(y, x)` before it leaves the kernel.
    private struct CellSet {
        private struct Slot {
            var x: Int64 = 0
            var y: Int64 = 0
            var used: Bool = false
        }

        private var slots: [Slot]
        private var mask: Int
        private(set) var count = 0

        init(minimumCapacity: Int) {
            var capacity = 64
            while capacity < minimumCapacity * 2 { capacity <<= 1 }
            slots = [Slot](repeating: Slot(), count: capacity)
            mask = capacity - 1
        }

        @inline(__always)
        private static func slot(_ x: Int64, _ y: Int64) -> Int {
            // Same split-mix combination the C++ hash uses, finished with a
            // xor-shift so low bits depend on every input bit.
            let ux = UInt64(bitPattern: x)
            let uy = UInt64(bitPattern: y)
            var h = ux ^ (uy &+ 0x9e37_79b9_7f4a_7c15 &+ (ux << 6) &+ (ux >> 2))
            h = (h ^ (h >> 32)) &* 0xd6e8_feb8_6659_fd93
            h ^= h >> 32
            return Int(truncatingIfNeeded: h)
        }

        mutating func insert(x: Int64, y: Int64) {
            var index = Self.slot(x, y) & mask
            while slots[index].used {
                if slots[index].x == x && slots[index].y == y { return }
                index = (index + 1) & mask
            }
            slots[index] = Slot(x: x, y: y, used: true)
            count += 1
            if count * 2 > slots.count { grow() }
        }

        private mutating func grow() {
            let old = slots
            slots = [Slot](repeating: Slot(), count: old.count * 2)
            mask = slots.count - 1
            for slot in old where slot.used {
                var index = Self.slot(slot.x, slot.y) & mask
                while slots[index].used { index = (index + 1) & mask }
                slots[index] = slot
            }
        }

        func sortedCells() -> [PersonalHeatmapCellIndex] {
            var cells: [PersonalHeatmapCellIndex] = []
            cells.reserveCapacity(count)
            for slot in slots where slot.used {
                cells.append(PersonalHeatmapCellIndex(x: slot.x, y: slot.y))
            }
            cells.sort { lhs, rhs in
                if lhs.y != rhs.y { return lhs.y < rhs.y }
                return lhs.x < rhs.x
            }
            return cells
        }
    }

    private static func supercoverGridTraversal(
        start: ProjectedSample, end: ProjectedSample, cellSizeMeters: Double,
        maximumCells: UInt, visited: inout CellSet
    ) {
        // #lizard forgives(cyclomatic_complexity): one ordered operation, the
        // supercover walk of the C++ kernel, whose cell cursor, boundary
        // distances and produced-cell count advance together.
        if maximumCells < 1 { return }

        guard let startX = cellIndex(start.x, cellSizeMeters),
              let startY = cellIndex(start.y, cellSizeMeters) else { return }

        if start.x == end.x && start.y == end.y {
            visited.insert(x: startX, y: startY)
            return
        }

        guard let endX = cellIndex(end.x, cellSizeMeters),
              let endY = cellIndex(end.y, cellSizeMeters) else { return }

        if startX == endX && startY == endY {
            visited.insert(x: startX, y: startY)
            return
        }

        var x = startX
        var y = startY

        let dx = end.x - start.x
        let dy = end.y - start.y

        let stepX: Int64 = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
        let stepY: Int64 = dy > 0 ? 1 : (dy < 0 ? -1 : 0)

        let tDeltaX = stepX == 0 ? Double.infinity : abs(cellSizeMeters / dx)
        let tDeltaY = stepY == 0 ? Double.infinity : abs(cellSizeMeters / dy)

        // `index` is at most 2^63 - 1024 (the largest double below 2^63), so
        // `index + 1` cannot overflow.
        func nextBoundary(_ index: Int64, _ step: Int64, _ cellSize: Double) -> Double {
            if step > 0 {
                return Double(index + 1) * cellSize
            } else if step < 0 {
                return Double(index) * cellSize
            }
            return 0.0
        }

        var tMaxX = 0.0
        if stepX == 0 {
            tMaxX = Double.infinity
        } else {
            let boundary = nextBoundary(x, stepX, cellSizeMeters)
            tMaxX = (boundary - start.x) / dx
            if tMaxX < 0.0 { tMaxX = 0.0 }
        }

        var tMaxY = 0.0
        if stepY == 0 {
            tMaxY = Double.infinity
        } else {
            let boundary = nextBoundary(y, stepY, cellSizeMeters)
            tMaxY = (boundary - start.y) / dy
            if tMaxY < 0.0 { tMaxY = 0.0 }
        }

        // Every cell appended to the interval is inserted into the visited set
        // when the interval ends, so inserting as they are produced is
        // equivalent. `lastX`/`lastY` mirror `interval_cells.back()` and `produced`
        // mirrors `interval_cells.size()`.
        var lastX = x
        var lastY = y
        var produced: UInt = 1
        visited.insert(x: x, y: y)

        var iterations: UInt = 0
        while (x != endX || y != endY) && iterations < maximumCells {
            iterations += 1

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

            let nextT = cppMin(tMaxX, tMaxY)
            if !nextT.isFinite && (x != endX || y != endY) {
                x = endX
                y = endY
            }

            if lastX != x || lastY != y {
                visited.insert(x: x, y: y)
                lastX = x
                lastY = y
                produced += 1
            }

            if tMaxX > 1.0000001 && tMaxY > 1.0000001 {
                if lastX != endX || lastY != endY {
                    visited.insert(x: endX, y: endY)
                    lastX = endX
                    lastY = endY
                    produced += 1
                }
                break
            }
        }

        if (lastX != endX || lastY != endY) && produced < maximumCells {
            visited.insert(x: endX, y: endY)
        }
    }

    /// Per-workout coverage: Web Mercator projection, grid-cell quantization,
    /// effective-segment gap breaking, supercover traversal, de-duplication and
    /// deterministic ordering, in one bulk call.
    package static func compute(
        samples: Span<PersonalHeatmapRouteSample>,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: UInt
    ) throws(PersonalHeatmapCoverageError) -> PersonalHeatmapCoverageResult {
        if !cellSizeMeters.isFinite || cellSizeMeters <= 0.0
            || !maximumIntervalMeters.isFinite || maximumIntervalMeters <= 0.0
            || maximumCellsPerInterval < 1 {
            throw .invalidConfiguration
        }
        var result = PersonalHeatmapCoverageResult()
        let sampleCount = samples.count
        if sampleCount == 0 { return result }

        let (projected, effectiveSegment) = projectSamples(samples)

        result.validProjectedPointCount = UInt64(projected.count)
        result.effectiveSegmentCount = effectiveSegment

        var visited = CellSet(minimumCapacity: min(projected.count * 2, 4096))

        for point in projected {
            if let x = cellIndex(point.x, cellSizeMeters), let y = cellIndex(point.y, cellSizeMeters) {
                visited.insert(x: x, y: y)
            }
        }

        result.invalidIntervalCount = coverIntervals(
            projected, cellSizeMeters: cellSizeMeters, maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval, visited: &visited
        )

        result.cells = visited.sortedCells()
        return result
    }

    /// Projects every valid coordinate and numbers its effective segment: a
    /// new segment starts at the first point, after an unprojectable point, and
    /// where the source segment changes. Returns the points and the last
    /// effective segment number.
    private static func projectSamples(
        _ samples: Span<PersonalHeatmapRouteSample>
    ) -> (projected: [ProjectedSample], effectiveSegment: UInt64) {
        let sampleCount = samples.count
        var projected: [ProjectedSample] = []
        projected.reserveCapacity(sampleCount)

        var effectiveSegment: UInt64 = 0
        var previousSourceSegment: Int64 = 0
        var requiresNewSegment = true

        for index in 0..<sampleCount {
            let sample = samples[index]
            guard let point = project(latitude: sample.latitude, longitude: sample.longitude) else {
                requiresNewSegment = true
                continue
            }
            if requiresNewSegment || previousSourceSegment != sample.routeSegmentIndex {
                effectiveSegment += 1
            }
            projected.append(ProjectedSample(x: point.x, y: point.y, effectiveSegment: effectiveSegment))
            previousSourceSegment = sample.routeSegmentIndex
            requiresNewSegment = false
        }
        return (projected, effectiveSegment)
    }

    /// Covers each interval between consecutive points of one effective segment:
    /// a zero-length interval covers its point's cell, an interval longer than
    /// `maximumIntervalMeters` covers nothing, and any other interval is traversed.
    /// Returns the number of intervals that were too long.
    private static func coverIntervals(
        _ projected: [ProjectedSample], cellSizeMeters: Double, maximumIntervalMeters: Double,
        maximumCellsPerInterval: UInt, visited: inout CellSet
    ) -> UInt64 {
        var invalidIntervalCount: UInt64 = 0
        if projected.count > 1 {
            for index in 0..<(projected.count - 1) {
                let a = projected[index]
                let b = projected[index + 1]
                if a.effectiveSegment != b.effectiveSegment { continue }

                let dx = b.x - a.x
                let dy = b.y - a.y
                // Two roundings, as in the C++ source; no fused multiply-add.
                let dxSquared = dx * dx
                let dySquared = dy * dy
                let length = (dxSquared + dySquared).squareRoot()

                if length == 0.0 {
                    if let x = cellIndex(a.x, cellSizeMeters), let y = cellIndex(a.y, cellSizeMeters) {
                        visited.insert(x: x, y: y)
                    }
                    continue
                }
                if length > maximumIntervalMeters {
                    invalidIntervalCount += 1
                    continue
                }
                supercoverGridTraversal(
                    start: a, end: b, cellSizeMeters: cellSizeMeters,
                    maximumCells: maximumCellsPerInterval, visited: &visited
                )
            }
        }
        return invalidIntervalCount
    }
}
