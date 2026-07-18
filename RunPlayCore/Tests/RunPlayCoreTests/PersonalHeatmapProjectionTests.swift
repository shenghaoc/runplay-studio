import XCTest
@testable import RunPlayCore

final class PersonalHeatmapProjectionTests: XCTestCase {

    // MARK: - Projection basics

    func testEquatorProjectionIsFiniteAndNearZeroY() {
        let projected = PersonalHeatmapProjection.project(latitude: 0, longitude: 0)
        XCTAssertNotNil(projected)
        XCTAssertEqual(projected!.x, 0, accuracy: 1e-6)
        XCTAssertEqual(projected!.y, 0, accuracy: 1e-6)
    }

    func testNorthernAndSouthernHemispheresHaveOppositeY() {
        let north = PersonalHeatmapProjection.project(latitude: 45, longitude: 10)!
        let south = PersonalHeatmapProjection.project(latitude: -45, longitude: 10)!
        XCTAssertGreaterThan(north.y, 0)
        XCTAssertLessThan(south.y, 0)
        XCTAssertEqual(north.x, south.x, accuracy: 1e-6)
        XCTAssertEqual(abs(north.y), abs(south.y), accuracy: 1e-3)
    }

    func testEasternAndWesternLongitudeHaveOppositeX() {
        let east = PersonalHeatmapProjection.project(latitude: 1, longitude: 100)!
        let west = PersonalHeatmapProjection.project(latitude: 1, longitude: -100)!
        XCTAssertGreaterThan(east.x, 0)
        XCTAssertLessThan(west.x, 0)
    }

    func testProjectionRoundTripWithinTolerance() {
        let samples: [(Double, Double)] = [
            (0, 0),
            (1.3, 103.8),
            (-33.86, 151.2),
            (51.5, -0.12),
            (64.1, -21.9),
            (-45.0, -70.0)
        ]
        for (lat, lon) in samples {
            let projected = PersonalHeatmapProjection.project(latitude: lat, longitude: lon)!
            let back = PersonalHeatmapProjection.unproject(x: projected.x, y: projected.y)!
            XCTAssertEqual(back.latitude, lat, accuracy: 1e-6, "lat round-trip \(lat)")
            XCTAssertEqual(back.longitude, lon, accuracy: 1e-6, "lon round-trip \(lon)")
        }
    }

    func testLatitudeClampingToMercatorRange() {
        let high = PersonalHeatmapProjection.project(latitude: 89.9, longitude: 0)!
        let clamped = PersonalHeatmapProjection.project(
            latitude: PersonalHeatmapProjection.maxLatitudeDegrees,
            longitude: 0
        )!
        XCTAssertEqual(high.y, clamped.y, accuracy: 1e-6)

        let low = PersonalHeatmapProjection.project(latitude: -89.9, longitude: 0)!
        let clampedLow = PersonalHeatmapProjection.project(
            latitude: -PersonalHeatmapProjection.maxLatitudeDegrees,
            longitude: 0
        )!
        XCTAssertEqual(low.y, clampedLow.y, accuracy: 1e-6)
    }

    func testLongitudeNormalization() {
        let a = PersonalHeatmapProjection.project(latitude: 0, longitude: 190)!
        let b = PersonalHeatmapProjection.project(latitude: 0, longitude: -170)!
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6)

        let c = PersonalHeatmapProjection.project(latitude: 0, longitude: -190)!
        let d = PersonalHeatmapProjection.project(latitude: 0, longitude: 170)!
        XCTAssertEqual(c.x, d.x, accuracy: 1e-6)
    }

    func testNonFiniteInputRejected() {
        XCTAssertNil(PersonalHeatmapProjection.project(latitude: .nan, longitude: 0))
        XCTAssertNil(PersonalHeatmapProjection.project(latitude: 0, longitude: .infinity))
        XCTAssertNil(PersonalHeatmapProjection.unproject(x: .nan, y: 0))
    }

    // MARK: - Cell IDs

    func testDeterministicCellIDs() {
        let a = PersonalHeatmapProjection.cellID(latitude: 1.3, longitude: 103.8, cellSizeMeters: 50)!
        let b = PersonalHeatmapProjection.cellID(latitude: 1.3, longitude: 103.8, cellSizeMeters: 50)!
        XCTAssertEqual(a, b)
    }

    func testNegativeCellIndexesInWesternSouthernHemisphere() {
        let west = PersonalHeatmapProjection.cellID(latitude: 0, longitude: -100, cellSizeMeters: 50)!
        let south = PersonalHeatmapProjection.cellID(latitude: -40, longitude: 0, cellSizeMeters: 50)!
        XCTAssertLessThan(west.x, 0)
        XCTAssertLessThan(south.y, 0)
    }

    func testCellBoundaryCoordinatesStayWithinCell() {
        let cellSize: Double = 50
        let id = PersonalHeatmapProjection.cellID(latitude: 1.3, longitude: 103.8, cellSizeMeters: cellSize)!
        let bounds = PersonalHeatmapProjection.cellBounds(id: id, cellSizeMeters: cellSize)!

        // Corners project back into same or adjacent boundary-safe cell for SW interior.
        let midLat = (bounds.minLatitude + bounds.maxLatitude) / 2
        let midLon = (bounds.minLongitude + bounds.maxLongitude) / 2
        let midID = PersonalHeatmapProjection.cellID(latitude: midLat, longitude: midLon, cellSizeMeters: cellSize)!
        XCTAssertEqual(midID, id)
    }

    func testOverflowSafetyForExtremeProjectedValues() {
        // Extremely large projected values should not crash; may return nil.
        let huge = PersonalHeatmapProjection.cellIndex(projected: 1e300, cellSizeMeters: 50)
        // Either nil or a finite Int64 is acceptable; must not trap.
        if let value = huge {
            XCTAssertTrue(value == Int64.max || value == Int64.min || abs(value) < Int64.max)
        }
        XCTAssertNil(PersonalHeatmapProjection.cellIndex(projected: 0, cellSizeMeters: 0))
        XCTAssertNil(PersonalHeatmapProjection.cellIndex(projected: 0, cellSizeMeters: -10))
        XCTAssertNil(PersonalHeatmapProjection.cellIndex(projected: .nan, cellSizeMeters: 50))
    }

    // MARK: - Grid traversal

    func testZeroLengthIntervalReturnsOneCell() throws {
        let start = (x: 100.0, y: 200.0)
        let cells = try PersonalHeatmapGridTraversal.cells(
            from: start, to: start, cellSizeMeters: 50
        )
        XCTAssertEqual(cells.count, 1)
    }

    func testHorizontalLineVisitsAllCrossedCells() throws {
        let start = (x: 0.0, y: 25.0)
        let end = (x: 250.0, y: 25.0)
        let cells = try PersonalHeatmapGridTraversal.cells(
            from: start, to: end, cellSizeMeters: 50
        )
        // From 0 to 250 with 50 m cells: x indices 0,1,2,3,4,5
        XCTAssertEqual(Set(cells).count, cells.count, "no duplicates")
        XCTAssertGreaterThanOrEqual(cells.count, 5)
        XCTAssertEqual(cells.first?.y, cells.last?.y)
    }

    func testVerticalLineVisitsAllCrossedCells() throws {
        let start = (x: 25.0, y: 0.0)
        let end = (x: 25.0, y: 250.0)
        let cells = try PersonalHeatmapGridTraversal.cells(
            from: start, to: end, cellSizeMeters: 50
        )
        XCTAssertEqual(Set(cells).count, cells.count)
        XCTAssertGreaterThanOrEqual(cells.count, 5)
    }

    func testDiagonalLineHasNoDuplicates() throws {
        let start = (x: 0.0, y: 0.0)
        let end = (x: 200.0, y: 200.0)
        let cells = try PersonalHeatmapGridTraversal.cells(
            from: start, to: end, cellSizeMeters: 50
        )
        XCTAssertEqual(Set(cells).count, cells.count)
        XCTAssertGreaterThan(cells.count, 1)
    }

    func testReverseDirectionReachesSameCellSet() throws {
        let a = (x: 10.0, y: 10.0)
        let b = (x: 310.0, y: 160.0)
        let forward = try Set(PersonalHeatmapGridTraversal.cells(from: a, to: b, cellSizeMeters: 50))
        let reverse = try Set(PersonalHeatmapGridTraversal.cells(from: b, to: a, cellSizeMeters: 50))
        XCTAssertEqual(forward, reverse)
    }

    func testExactCornerCrossingDoesNotLoopInfinitely() throws {
        // Line from cell interior through exact grid corner.
        let start = (x: 25.0, y: 25.0)
        let end = (x: 75.0, y: 75.0)
        let cells = try PersonalHeatmapGridTraversal.cells(
            from: start, to: end, cellSizeMeters: 50
        )
        XCTAssertFalse(cells.isEmpty)
        XCTAssertLessThan(cells.count, 20)
        XCTAssertEqual(Set(cells).count, cells.count)
    }

    func testBoundaryTraversalStaysBounded() throws {
        let start = (x: 0.0, y: 0.0)
        let end = (x: 100.0, y: 0.0)
        let cells = try PersonalHeatmapGridTraversal.cells(
            from: start, to: end, cellSizeMeters: 50
        )
        XCTAssertGreaterThanOrEqual(cells.count, 2)
        XCTAssertEqual(Set(cells).count, cells.count)
    }

    func testLongIntervalIsBoundedByMaximumCells() throws {
        let start = (x: 0.0, y: 0.0)
        let end = (x: 1_000_000.0, y: 0.0)
        let cells = try PersonalHeatmapGridTraversal.cells(
            from: start, to: end, cellSizeMeters: 10, maximumCells: 100
        )
        XCTAssertLessThanOrEqual(cells.count, 101)
    }

    func testCancellationDuringTraversal() {
        let start = (x: 0.0, y: 0.0)
        let end = (x: 100_000.0, y: 0.0)
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let counter = Counter()
        XCTAssertThrowsError(
            try PersonalHeatmapGridTraversal.cells(
                from: start,
                to: end,
                cellSizeMeters: 1,
                maximumCells: 50_000,
                isCancelled: {
                    counter.increment() > 2
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testOneCellInterval() throws {
        let start = (x: 10.0, y: 10.0)
        let end = (x: 40.0, y: 40.0)
        let cells = try PersonalHeatmapGridTraversal.cells(
            from: start, to: end, cellSizeMeters: 50
        )
        XCTAssertEqual(cells.count, 1)
    }
}
