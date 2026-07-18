import XCTest
@testable import RunPlayCore

final class PersonalHeatmapBuilderTests: XCTestCase {

    private let builder = PersonalHeatmapBuilder()
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func point(
        lat: Double,
        lon: Double,
        distance: Double = 0,
        elapsed: Double = 0,
        segment: Int = 0,
        date: Date? = nil
    ) -> RoutePoint {
        RoutePoint(
            timestamp: date ?? origin.addingTimeInterval(elapsed),
            latitude: lat,
            longitude: lon,
            distanceFromStartMeters: distance,
            elapsedSeconds: elapsed,
            routeSegmentIndex: segment
        )
    }

    private func workout(
        name: String = "Run",
        points: [RoutePoint],
        startDate: Date? = nil,
        distanceMeters: Double? = nil
    ) -> RunWorkout {
        let distance = distanceMeters ?? (points.last?.distanceFromStartMeters ?? 0)
        return RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: startDate),
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: distance, totalElapsedSeconds: points.last?.elapsedSeconds ?? 0)
        )
    }

    private func eastWestLine(startLon: Double, endLon: Double, lat: Double = 1.3, steps: Int = 10, segment: Int = 0) -> [RoutePoint] {
        (0...steps).map { i in
            let t = Double(i) / Double(steps)
            let lon = startLon + (endLon - startLon) * t
            return point(lat: lat, lon: lon, distance: t * 1_000, elapsed: t * 300, segment: segment)
        }
    }

    // MARK: - Distinct workout counting

    func testOneWorkoutContributesOncePerCellEvenWithLoops() throws {
        // Loop through the same area five times.
        var points: [RoutePoint] = []
        for loop in 0..<5 {
            let base = eastWestLine(startLon: 103.80, endLon: 103.81, steps: 5)
            for (i, p) in base.enumerated() {
                var copy = p
                copy.elapsedSeconds = Double(loop * 100 + i)
                copy.distanceFromStartMeters = Double(loop * 200 + i * 40)
                points.append(copy)
            }
        }
        let w = workout(points: points, startDate: origin, distanceMeters: 1_000)
        let snapshot = try builder.build(
            workouts: [w],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertFalse(snapshot.cells.isEmpty)
        XCTAssertEqual(snapshot.statistics.maximumOverlap, 1)
        XCTAssertTrue(snapshot.cells.allSatisfy { $0.workoutCount == 1 })
    }

    func testTwoWorkoutsProduceCountTwoOnOverlap() throws {
        let line = eastWestLine(startLon: 103.80, endLon: 103.805, steps: 8)
        let w1 = workout(name: "A", points: line, startDate: origin, distanceMeters: 500)
        let w2 = workout(name: "B", points: line, startDate: origin.addingTimeInterval(86_400), distanceMeters: 500)
        let snapshot = try builder.build(
            workouts: [w1, w2],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 2)
        XCTAssertEqual(snapshot.statistics.maximumOverlap, 2)
        XCTAssertTrue(snapshot.cells.contains { $0.workoutCount == 2 })
    }

    func testDifferentSamplingFrequenciesProduceSameCells() throws {
        // Dense 1 Hz-like sampling of the same corridor.
        let dense = eastWestLine(startLon: 103.80, endLon: 103.81, steps: 40)
        // Sparse sampling of the same corridor.
        let sparse = eastWestLine(startLon: 103.80, endLon: 103.81, steps: 4)
        let denseWorkout = workout(name: "Dense", points: dense, startDate: origin)
        let sparseWorkout = workout(name: "Sparse", points: sparse, startDate: origin)

        let denseOnly = try builder.build(
            workouts: [denseWorkout],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        let sparseOnly = try builder.build(
            workouts: [sparseWorkout],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )

        let denseIDs = Set(denseOnly.cells.map(\.id))
        let sparseIDs = Set(sparseOnly.cells.map(\.id))
        // Sparse must not invent cells outside the dense corridor set significantly;
        // both should cover essentially the same cells for a straight line.
        XCTAssertEqual(denseIDs, sparseIDs)
    }

    func testStationaryDuplicatePointsDoNotInflateIntensity() throws {
        let p = point(lat: 1.3, lon: 103.8)
        let duplicates = Array(repeating: p, count: 100)
        // Give each a unique elapsed so they are distinct points at same location.
        let points = duplicates.enumerated().map { i, pt in
            point(lat: pt.latitude, lon: pt.longitude, elapsed: Double(i))
        }
        let w = workout(points: points, startDate: origin)
        let snapshot = try builder.build(
            workouts: [w],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertEqual(snapshot.cells.count, 1)
        XCTAssertEqual(snapshot.cells.first?.workoutCount, 1)
    }

    // MARK: - Segment gaps

    func testRouteSegmentsAreNotBridged() throws {
        // Two segments far apart — no corridor between them.
        let seg0 = [
            point(lat: 1.30, lon: 103.80, distance: 0, elapsed: 0, segment: 0),
            point(lat: 1.30, lon: 103.801, distance: 100, elapsed: 30, segment: 0)
        ]
        let seg1 = [
            point(lat: 1.40, lon: 103.90, distance: 100, elapsed: 600, segment: 1),
            point(lat: 1.40, lon: 103.901, distance: 200, elapsed: 630, segment: 1)
        ]
        let w = workout(points: seg0 + seg1, startDate: origin, distanceMeters: 200)
        let snapshot = try builder.build(
            workouts: [w],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )

        // Cells should only exist near the two short segments, not along the gap.
        let midLat = 1.35
        let midLon = 103.85
        let midCell = PersonalHeatmapProjection.cellID(latitude: midLat, longitude: midLon, cellSizeMeters: 50)!
        XCTAssertFalse(snapshot.cells.contains { $0.id == midCell })
        XCTAssertGreaterThanOrEqual(snapshot.cells.count, 2)
    }

    // MARK: - One-point and invalid

    func testOnePointWorkoutContributesOneCell() throws {
        let w = workout(points: [point(lat: 1.3, lon: 103.8)], startDate: origin)
        let snapshot = try builder.build(
            workouts: [w],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertEqual(snapshot.cells.count, 1)
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 1)
    }

    func testInvalidCoordinatesIgnoredSafely() throws {
        let points = [
            point(lat: .nan, lon: 103.8),
            point(lat: 1.3, lon: 103.8, distance: 0, elapsed: 0),
            point(lat: 1.3, lon: 103.801, distance: 100, elapsed: 30)
        ]
        let w = workout(points: points, startDate: origin)
        let snapshot = try builder.build(
            workouts: [w],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertFalse(snapshot.cells.isEmpty)
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 1)
    }

    func testEmptyLibrary() throws {
        let snapshot = try builder.build(
            workouts: [],
            configuration: PersonalHeatmapConfiguration()
        )
        XCTAssertTrue(snapshot.cells.isEmpty)
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 0)
    }

    func testNoRouteWorkoutExcluded() throws {
        let w = workout(points: [], startDate: origin)
        let snapshot = try builder.build(
            workouts: [w],
            configuration: PersonalHeatmapConfiguration()
        )
        XCTAssertEqual(snapshot.statistics.excludedNoRouteWorkoutCount, 1)
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 0)
    }

    // MARK: - Date filters

    func testDateFilterExcludesOutsideRange() throws {
        let line = eastWestLine(startLon: 103.80, endLon: 103.81, steps: 4)
        let inside = workout(name: "In", points: line, startDate: origin)
        let outside = workout(
            name: "Out",
            points: line,
            startDate: origin.addingTimeInterval(-10 * 86_400)
        )
        let filter = PersonalHeatmapDateFilter.range(
            start: origin.addingTimeInterval(-86_400),
            end: origin.addingTimeInterval(86_400)
        )
        let snapshot = try builder.build(
            workouts: [inside, outside],
            configuration: PersonalHeatmapConfiguration(dateFilter: filter, cellSizeMeters: 50)
        )
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 1)
    }

    func testAllTimeIncludesUndatedWorkouts() throws {
        let line = eastWestLine(startLon: 103.80, endLon: 103.81, steps: 4)
        // No metadata start date; points still have timestamps but we set metadata nil
        // and use points — trustworthyDate falls back to first point timestamp.
        // For a truly undated case: empty startDate and we rely on point timestamps
        // still providing a date. Create points and nil startDate — still has point date.
        // Policy: undated means no metadata.startDate AND we treat first point as fallback.
        // So "undated" exclusion happens when filter is ranged AND no date at all.
        // For all-time, workout with only point timestamps is included.
        let undatedMeta = workout(name: "Undated", points: line, startDate: nil)
        let snapshot = try builder.build(
            workouts: [undatedMeta],
            configuration: PersonalHeatmapConfiguration(dateFilter: .allTime, cellSizeMeters: 50)
        )
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 1)
    }

    func testDateFilteredModeExcludesWhenNoTrustworthyDate() throws {
        // Workout with empty route and no startDate cannot contribute.
        // Workout with points always has point timestamps as fallback.
        // The only no-date case for a GPS workout is unusual; we test empty points
        // go to no-route rather than undated when all-time.
        let empty = workout(name: "Empty", points: [], startDate: nil)
        let filter = PersonalHeatmapDateFilter.range(start: origin, end: origin.addingTimeInterval(86_400))
        let snapshot = try builder.build(
            workouts: [empty],
            configuration: PersonalHeatmapConfiguration(dateFilter: filter)
        )
        // Empty route with no date: date filter may count as undated before no-route.
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 0)
        XCTAssertGreaterThanOrEqual(
            snapshot.statistics.excludedUndatedWorkoutCount + snapshot.statistics.excludedNoRouteWorkoutCount,
            1
        )
    }

    func testLastDaysAndCurrentYearHelpers() {
        let cal = Calendar(identifier: .gregorian)
        let last30 = PersonalHeatmapDateFilter.lastDays(30, now: origin, calendar: cal)
        if case .range(let start, let end) = last30 {
            XCTAssertEqual(end, origin)
            XCTAssertLessThan(start, end)
        } else {
            XCTFail("expected range")
        }
        let year = PersonalHeatmapDateFilter.currentCalendarYear(now: origin, calendar: cal)
        if case .range(let start, let end) = year {
            XCTAssertLessThanOrEqual(start, end)
            XCTAssertEqual(cal.component(.year, from: start), cal.component(.year, from: origin))
        } else {
            XCTFail("expected range")
        }
    }

    // MARK: - Minimum repeat and intensity

    func testMinimumRepeatFilter() throws {
        let line = eastWestLine(startLon: 103.80, endLon: 103.805, steps: 6)
        let shared = line
        let unique = eastWestLine(startLon: 103.82, endLon: 103.825, steps: 4)
        let w1 = workout(name: "A", points: shared, startDate: origin)
        let w2 = workout(name: "B", points: shared + unique, startDate: origin.addingTimeInterval(100))

        let all = try builder.build(
            workouts: [w1, w2],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50, minimumWorkoutCount: 1)
        )
        let repeated = try builder.build(
            workouts: [w1, w2],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50, minimumWorkoutCount: 2)
        )
        XCTAssertGreaterThan(all.cells.count, repeated.cells.count)
        XCTAssertTrue(repeated.cells.allSatisfy { $0.workoutCount >= 2 })
        // Max overlap statistic uses aggregated (pre-filter) maximum.
        XCTAssertEqual(all.statistics.maximumOverlap, repeated.statistics.maximumOverlap)
    }

    func testLogIntensityNormalization() throws {
        let line = eastWestLine(startLon: 103.80, endLon: 103.805, steps: 4)
        let workouts = (0..<5).map { i in
            workout(name: "W\(i)", points: line, startDate: origin.addingTimeInterval(Double(i) * 1000))
        }
        let snapshot = try builder.build(
            workouts: workouts,
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertFalse(snapshot.cells.isEmpty)
        for cell in snapshot.cells {
            XCTAssertGreaterThanOrEqual(cell.normalizedIntensity, 0)
            XCTAssertLessThanOrEqual(cell.normalizedIntensity, 1)
        }
        // Max count maps to 1.
        if let maxCell = snapshot.cells.max(by: { $0.workoutCount < $1.workoutCount }) {
            XCTAssertEqual(maxCell.normalizedIntensity, 1, accuracy: 1e-9)
        }
        // Count 1 remains visible ( > 0 ).
        // Build a single-workout case.
        let single = try builder.build(
            workouts: [workouts[0]],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertTrue(single.cells.allSatisfy { $0.normalizedIntensity == 1 })
    }

    func testDeterministicOrdering() throws {
        let line = eastWestLine(startLon: 103.80, endLon: 103.81, steps: 10)
        let workouts = [
            workout(name: "A", points: line, startDate: origin),
            workout(name: "B", points: line, startDate: origin.addingTimeInterval(100))
        ]
        let a = try builder.build(workouts: workouts, configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50))
        let b = try builder.build(workouts: workouts, configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50))
        XCTAssertEqual(a.cells.map(\.id), b.cells.map(\.id))
        XCTAssertEqual(a.cells.map(\.workoutCount), b.cells.map(\.workoutCount))
        // Sorted by cell ID.
        XCTAssertEqual(a.cells.map(\.id), a.cells.map(\.id).sorted())
    }

    // MARK: - Adaptive coarsening

    func testAdaptiveCoarseningWhenBudgetExceeded() throws {
        // Many unique short routes spread out → many cells at fine resolution.
        var workouts: [RunWorkout] = []
        for i in 0..<80 {
            let lon = 103.0 + Double(i) * 0.02
            let pts = eastWestLine(startLon: lon, endLon: lon + 0.01, lat: 1.0 + Double(i) * 0.01, steps: 5)
            workouts.append(workout(name: "R\(i)", points: pts, startDate: origin, distanceMeters: 500))
        }
        let snapshot = try builder.build(
            workouts: workouts,
            configuration: PersonalHeatmapConfiguration(
                cellSizeMeters: 25,
                minimumWorkoutCount: 1,
                maximumRenderedCellCount: 50
            )
        )
        XCTAssertLessThanOrEqual(snapshot.cells.count, 50)
        XCTAssertTrue(snapshot.statistics.resolutionWasAdjusted)
        XCTAssertGreaterThan(snapshot.statistics.effectiveCellSizeMeters, 25)
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 80)
        XCTAssertGreaterThan(snapshot.diagnostics.adaptiveResolutionRetries, 0)
    }

    // MARK: - Distance and diagnostics

    func testTotalDistanceUsesSummaryNotCellCount() throws {
        let line = eastWestLine(startLon: 103.80, endLon: 103.81, steps: 4)
        let w1 = workout(name: "A", points: line, startDate: origin, distanceMeters: 1_234)
        let w2 = workout(name: "B", points: line, startDate: origin, distanceMeters: 2_000)
        let snapshot = try builder.build(
            workouts: [w1, w2],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertEqual(snapshot.statistics.totalDistanceMeters, 3_234, accuracy: 0.001)
    }

    func testDiagnosticsPopulated() throws {
        let line = eastWestLine(startLon: 103.80, endLon: 103.81, steps: 4)
        let w = workout(points: line, startDate: origin)
        let empty = workout(points: [], startDate: origin)
        let snapshot = try builder.build(
            workouts: [w, empty],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        XCTAssertEqual(snapshot.diagnostics.totalCandidateWorkouts, 2)
        XCTAssertEqual(snapshot.diagnostics.includedWorkouts, 1)
        XCTAssertEqual(snapshot.diagnostics.excludedNoRouteWorkouts, 1)
        XCTAssertEqual(snapshot.diagnostics.renderedCellCount, snapshot.cells.count)
        XCTAssertGreaterThanOrEqual(snapshot.diagnostics.aggregatedCellCount, snapshot.cells.count)
    }

    // MARK: - Cancellation

    func testCancellationThrowsCancellationError() {
        let line = eastWestLine(startLon: 103.80, endLon: 103.85, steps: 50)
        let workouts = (0..<20).map { i in
            workout(name: "W\(i)", points: line, startDate: origin.addingTimeInterval(Double(i)))
        }
        XCTAssertThrowsError(
            try builder.build(
                workouts: workouts,
                configuration: PersonalHeatmapConfiguration(cellSizeMeters: 25),
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Malformed intervals

    func testHugeJumpSkippedAsInvalidInterval() throws {
        let points = [
            point(lat: 1.0, lon: 100.0, distance: 0, elapsed: 0),
            // ~thousands of km jump
            point(lat: 50.0, lon: 10.0, distance: 100, elapsed: 10)
        ]
        let w = workout(points: points, startDate: origin)
        let snapshot = try builder.build(
            workouts: [w],
            configuration: PersonalHeatmapConfiguration(
                cellSizeMeters: 50,
                maximumIntervalMeters: 5_000
            )
        )
        // No corridor of cells between continents; may have 0 rendered if only
        // the jump exists and is skipped — single-point cells not added without
        // zero-length handling on each endpoint... actually zero endpoints alone
        // aren't visited unless traversal or single-point path. With 2 points
        // and invalid jump, visited stays empty.
        XCTAssertGreaterThanOrEqual(snapshot.diagnostics.invalidRouteIntervalsSkipped, 1)
        XCTAssertTrue(snapshot.cells.isEmpty || snapshot.cells.count < 100)
    }

    // MARK: - Large library (algorithmic, no wall-clock)

    func testLargeLibraryCompletesWithBoundedCells() throws {
        // 1_000 workouts × ~1_000 points = ~1_000_000 points.
        // Use repeated routes for most workouts plus some unique ones.
        let sharedLine = eastWestLine(startLon: 103.80, endLon: 103.82, steps: 999)
        XCTAssertEqual(sharedLine.count, 1_000)

        var workouts: [RunWorkout] = []
        workouts.reserveCapacity(1_000)
        for i in 0..<900 {
            workouts.append(workout(
                name: "Shared-\(i)",
                points: sharedLine,
                startDate: origin.addingTimeInterval(Double(i) * 100),
                distanceMeters: 2_000
            ))
        }
        for i in 0..<100 {
            let lon = 104.0 + Double(i) * 0.01
            let unique = eastWestLine(startLon: lon, endLon: lon + 0.02, steps: 999)
            workouts.append(workout(
                name: "Unique-\(i)",
                points: unique,
                startDate: origin.addingTimeInterval(Double(900 + i) * 100),
                distanceMeters: 2_000
            ))
        }

        let totalPoints = workouts.reduce(0) { $0 + $1.routePoints.count }
        XCTAssertGreaterThanOrEqual(totalPoints, 1_000_000)

        let snapshot = try builder.build(
            workouts: workouts,
            configuration: PersonalHeatmapConfiguration(
                cellSizeMeters: 50,
                minimumWorkoutCount: 1,
                maximumRenderedCellCount: 5_000
            )
        )

        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 1_000)
        XCTAssertLessThanOrEqual(snapshot.cells.count, 5_000)
        XCTAssertGreaterThan(snapshot.statistics.maximumOverlap, 1)
        // Determinism: rebuild and compare.
        let again = try builder.build(
            workouts: workouts,
            configuration: PersonalHeatmapConfiguration(
                cellSizeMeters: 50,
                minimumWorkoutCount: 1,
                maximumRenderedCellCount: 5_000
            )
        )
        XCTAssertEqual(snapshot.cells.map(\.id), again.cells.map(\.id))
        XCTAssertEqual(snapshot.cells.map(\.workoutCount), again.cells.map(\.workoutCount))
    }

    func testManyRouteSegmentsDoNotBridge() throws {
        var points: [RoutePoint] = []
        for seg in 0..<20 {
            let lon = 103.8 + Double(seg) * 0.05
            points.append(point(lat: 1.3, lon: lon, distance: Double(seg * 2) * 100, elapsed: Double(seg * 2) * 30, segment: seg))
            points.append(point(lat: 1.3, lon: lon + 0.001, distance: Double(seg * 2 + 1) * 100, elapsed: Double(seg * 2 + 1) * 30, segment: seg))
        }
        let w = workout(points: points, startDate: origin, distanceMeters: 4_000)
        let snapshot = try builder.build(
            workouts: [w],
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )
        // Should have cells near each short segment, not a continuous corridor of ~20*0.05° length.
        XCTAssertLessThan(snapshot.cells.count, 200)
        XCTAssertGreaterThanOrEqual(snapshot.cells.count, 20)
    }
}
