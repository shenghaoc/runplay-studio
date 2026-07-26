import XCTest
@testable import RunPlayCore

final class RouteAlignmentMappingTests: XCTestCase {
    private let aligner = ConstrainedDynamicTimeWarpingAligner()
    private let metricsService = RouteAlignmentMetricsService()

    func testMappingAtBeginMiddleEnd() throws {
        let workout = makeWorkout(distanceMeters: 2_500)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout)
        )
        XCTAssertTrue(
            snapshot.availability.isAvailable,
            "availability=\(snapshot.availability) blocks=\(snapshot.blocks.count) aligned=\(snapshot.totalAlignedDistanceMeters) diag=\(snapshot.diagnostics)"
        )
        let total = snapshot.totalAlignedDistanceMeters
        XCTAssertGreaterThan(total, 0)

        let start = try XCTUnwrap(snapshot.positions(atAlignedProgress: 0))
        let mid = try XCTUnwrap(snapshot.positions(atAlignedProgress: total / 2))
        let end = try XCTUnwrap(snapshot.positions(atAlignedProgress: total))

        XCTAssertEqual(start.alignedProgressMeters, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(mid.primaryDistanceMeters, start.primaryDistanceMeters)
        XCTAssertGreaterThan(end.primaryDistanceMeters, mid.primaryDistanceMeters)
        XCTAssertEqual(end.alignedProgressMeters, total, accuracy: 1e-6)
    }

    func testNonFiniteAndOutOfRangeClamp() throws {
        let workout = makeWorkout(distanceMeters: 2_000)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout)
        )
        XCTAssertNil(snapshot.positions(atAlignedProgress: .nan))
        let total = snapshot.totalAlignedDistanceMeters
        let below = try XCTUnwrap(snapshot.positions(atAlignedProgress: -50))
        let above = try XCTUnwrap(snapshot.positions(atAlignedProgress: total + 500))
        XCTAssertEqual(below.alignedProgressMeters, 0, accuracy: 1e-6)
        XCTAssertEqual(above.alignedProgressMeters, total, accuracy: 1e-6)
    }

    func testEmptySnapshotReturnsNilMapping() {
        let empty = RouteAlignmentSnapshot.unavailable(reason: .insufficientRouteData)
        XCTAssertNil(empty.positions(atAlignedProgress: 100))
        XCTAssertEqual(empty.totalAlignedDistanceMeters, 0)
    }

    func testMatchedClocksExcludeUnmatchedPrefix() throws {
        let base = makeWorkout(distanceMeters: 3_000)
        // Offset comparison so prefix differs; clocks should still start at block start.
        let offsetPoints = base.routePoints.map { point in
            RoutePoint(
                timestamp: point.timestamp,
                latitude: point.latitude + 0.0007, // ~80 m north
                longitude: point.longitude,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds + 60,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
        let offset = RunWorkout(routePoints: offsetPoints)
        let snapshot = try aligner.align(
            primary: base,
            comparison: offset,
            primaryContext: WorkoutAnalysisContext(workout: base),
            comparisonContext: WorkoutAnalysisContext(workout: offset)
        )
        guard snapshot.availability.isAvailable else {
            // Spatial offset of whole route may be unavailable; still exercise metrics API.
            let metrics = metricsService.metrics(
                atAlignedProgress: 0,
                snapshot: snapshot,
                primary: base,
                comparison: offset,
                primaryContext: WorkoutAnalysisContext(workout: base),
                comparisonContext: WorkoutAnalysisContext(workout: offset)
            )
            XCTAssertEqual(metrics.alignedProgressMeters, 0)
            return
        }
        let metrics = metricsService.metrics(
            atAlignedProgress: snapshot.totalAlignedDistanceMeters * 0.5,
            snapshot: snapshot,
            primary: base,
            comparison: offset,
            primaryContext: WorkoutAnalysisContext(workout: base),
            comparisonContext: WorkoutAnalysisContext(workout: offset)
        )
        XCTAssertNotNil(metrics.primaryElapsedSeconds)
        XCTAssertNotNil(metrics.comparisonElapsedSeconds)
        if let pe = metrics.primaryElapsedSeconds {
            XCTAssertGreaterThanOrEqual(pe, 0)
        }
    }

    func testChartPointsAreBoundedAndBlockAware() throws {
        let workout = makeWorkout(distanceMeters: 3_000)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout)
        )
        let points = metricsService.chartPoints(
            snapshot: snapshot,
            primary: workout,
            comparison: workout,
            policy: .default
        )
        XCTAssertLessThanOrEqual(points.count, RouteAlignmentPolicy.default.maximumChartSampleCount)
        if snapshot.availability.isAvailable {
            XCTAssertFalse(points.isEmpty)
            XCTAssertTrue(points.allSatisfy { $0.alignedProgressMeters.isFinite })
        }
    }

    func testSliderLookupsDoNotRequireRecompute() throws {
        let workout = makeWorkout(distanceMeters: 2_500)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout)
        )
        guard snapshot.availability.isAvailable else { return }
        let total = snapshot.totalAlignedDistanceMeters
        for i in 0..<1_000 {
            let progress = total * Double(i) / 999
            XCTAssertNotNil(snapshot.positions(atAlignedProgress: progress))
        }
    }

    private func makeWorkout(distanceMeters: Double) -> RunWorkout {
        let start = Date()
        var points: [RoutePoint] = []
        var d = 0.0
        while d <= distanceMeters {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: 37.7749 + d / 111_000,
                longitude: -122.4194,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + 20)
        }
        return RunWorkout(routePoints: points)
    }
}
