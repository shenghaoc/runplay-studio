#if DEBUG
import Foundation
import XCTest
@testable import RunPlayCore

/// Proves exactly one native C++ call per production operation for every
/// production caller, plus zero-call coverage for corrected-elevation
/// finalization and solid mode (covered in
/// `RouteMetricScaleBucketParityTests.testNativeCallCountsByMode`).
///
/// Counts come from `NativeCallObserver.observing`, which binds a fresh tally to
/// a task-local for the duration of the closure. Each assertion therefore sees
/// only the native calls made by its own operation — a concurrently running test
/// cannot contribute to the total. The observer exists only in DEBUG builds, so
/// this whole file is DEBUG-gated too.
final class NativeCallCardinalityTests: XCTestCase {
    private let processor = RouteQualityProcessor()

    func testRouteQualityProcessorCallsQualityAndElevationExactlyOnce() throws {
        let points = makeStraightLinePoints(count: 120)

        let (_, counts) = try NativeCallObserver.observing {
            try processor.process(points, sortByTimestamp: false)
        }

        XCTAssertEqual(counts.routeQuality, 1)
        XCTAssertEqual(counts.elevationProfile, 1)
    }

    func testElevationProfileBuildCallsNativeExactlyOnce() throws {
        let points = makeStraightLinePoints(count: 64)

        let (_, counts) = try NativeCallObserver.observing {
            try ElevationProfile.build(
                routePoints: points,
                policy: .runningDefault,
                isCancelled: { false }
            )
        }

        XCTAssertEqual(counts.elevationProfile, 1)
    }

    func testSegmentDetectorCallsNativeExactlyOnce() throws {
        let workout = HotspotProfilingFixtures.makeWorkout(options: .init(
            pointCount: 400,
            segmentCount: 2,
            stationaryWindows: true,
            seed: 1_103,
            name: "segment-cardinality"
        ))
        // Context construction builds an elevation profile through a different
        // bridge; keeping it outside the scope isolates the segment count.
        let context = WorkoutAnalysisContext(workout: workout)

        let (highlights, counts) = try NativeCallObserver.observing {
            try SegmentDetector.detectSegments(
                from: workout,
                context: context,
                policy: .runningDefault,
                isCancelled: { false }
            )
        }

        XCTAssertEqual(counts.segmentDetection, 1)
        XCTAssertFalse(highlights.isEmpty)
    }

    func testConstrainedDTWAlignerCallsNativeOncePerAlignmentAttempt() throws {
        let workout = makeAlignmentWorkout(distanceMeters: 4_000, step: 20)

        let (snapshot, counts) = try NativeCallObserver.observing {
            try ConstrainedDynamicTimeWarpingAligner().align(
                primary: workout,
                comparison: workout,
                primaryContext: WorkoutAnalysisContext(workout: workout),
                comparisonContext: WorkoutAnalysisContext(workout: workout)
            )
        }

        XCTAssertEqual(counts.routeAlignmentDtw, 1)
        guard case .available = snapshot.availability else {
            return XCTFail("Expected an available alignment")
        }
    }

    func testPersonalHeatmapBuilderCallsNativeOncePerWorkoutInASinglePass() throws {
        let line = makeHeatmapLineWorkouts(count: 3)
        let builder = PersonalHeatmapBuilder()

        let (snapshot, counts) = try NativeCallObserver.observing {
            try builder.build(
                workouts: line,
                configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
            )
        }

        // Three non-empty workouts, one adaptive pass: one coverage call each.
        XCTAssertEqual(snapshot.diagnostics.adaptiveResolutionRetries, 0)
        XCTAssertEqual(counts.personalHeatmapCoverage, 3)
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 3)
    }

    /// The single-pass test above cannot distinguish "once per workout per
    /// attempt" from "once per workout, ever". A tight `maximumRenderedCellCount`
    /// with a fine starting cell size forces the builder to coarsen and re-run
    /// the whole aggregation, so the rule is checked against a real retry count.
    ///
    /// The exact rule is *not* one call per workout per attempt. The coverage
    /// boundary is capacity-negotiated: when the caller-owned output buffer is
    /// too small, C++ writes nothing, reports `required_cell_count`, and Swift
    /// reallocates and calls once more. That renegotiation is bounded to a
    /// single extra call (the bridge does not loop), so per workout per attempt
    /// the count is 1 normally and 2 after a capacity retry.
    func testPersonalHeatmapBuilderCallsNativeOncePerWorkoutPerAdaptiveAttemptPlusCapacityRetries() throws {
        let workoutCount = 3
        let line = makeHeatmapLineWorkouts(count: workoutCount)
        let builder = PersonalHeatmapBuilder()

        let (snapshot, counts) = try NativeCallObserver.observing {
            try builder.build(
                workouts: line,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 5,
                    minimumWorkoutCount: 1,
                    maximumRenderedCellCount: 8
                )
            )
        }

        let retries = snapshot.diagnostics.adaptiveResolutionRetries
        XCTAssertGreaterThan(retries, 0, "expected the adaptive loop to coarsen at least once")

        let attempts = retries + 1
        let calls = counts.personalHeatmapCoverage

        // Lower bound: every workout is visited exactly once per attempt.
        XCTAssertGreaterThanOrEqual(
            calls,
            workoutCount * attempts,
            "each workout must be covered on every adaptive attempt"
        )
        // Upper bound: at most one capacity renegotiation per workout per attempt.
        XCTAssertLessThanOrEqual(
            calls,
            workoutCount * attempts * 2,
            "capacity renegotiation must not loop beyond a single extra call"
        )
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, workoutCount)
    }

    func testEmptyRouteCallsNoNativeElevationOrQuality() throws {
        let (_, counts) = try NativeCallObserver.observing {
            try processor.process([], sortByTimestamp: false)
        }

        XCTAssertEqual(counts.routeQuality, 0)
        XCTAssertEqual(counts.elevationProfile, 0)
    }

    /// Guards the isolation property the scoping is there to provide: native
    /// work performed outside a scope must not appear inside one.
    func testObservationScopeExcludesWorkDoneOutsideIt() throws {
        let points = makeStraightLinePoints(count: 64)

        _ = try processor.process(points, sortByTimestamp: false)

        let (_, counts) = try NativeCallObserver.observing {
            try ElevationProfile.build(
                routePoints: points,
                policy: .runningDefault,
                isCancelled: { false }
            )
        }

        XCTAssertEqual(counts.elevationProfile, 1)
        XCTAssertEqual(counts.routeQuality, 0, "work before the scope must not be counted")
    }

    // MARK: - Helpers

    private func makeStraightLinePoints(count: Int) -> [RoutePoint] {
        (0..<count).map { index in
            RoutePoint(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 10),
                latitude: 35.6812 + Double(index) * 0.0001,
                longitude: 139.7671,
                distanceFromStartMeters: Double(index) * 10,
                elapsedSeconds: Double(index) * 10,
                paceSecondsPerKilometer: 300,
                horizontalAccuracy: 5,
                routeSegmentIndex: 0
            )
        }
    }

    private func makeAlignmentWorkout(distanceMeters: Double, step: Double) -> RunWorkout {
        let start = Date()
        var points: [RoutePoint] = []
        var d = 0.0
        while d <= distanceMeters {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: 37.77 + d / 111_000,
                longitude: -122.42,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + step)
        }
        return RunWorkout(routePoints: points)
    }

    private func makeHeatmapLineWorkouts(count: Int) -> [RunWorkout] {
        let origin = Date(timeIntervalSinceReferenceDate: 700_000_000)
        return (0..<count).map { index in
            let points = (0...12).map { i in
                let t = Double(i) / 12
                return RoutePoint(
                    timestamp: origin.addingTimeInterval(Double(index) * 86_400 + t * 300),
                    latitude: 1.3 + Double(index) * 0.01,
                    longitude: 103.80 + t * 0.01,
                    distanceFromStartMeters: t * 1_000,
                    elapsedSeconds: t * 300,
                    routeSegmentIndex: 0
                )
            }
            return RunWorkout(routePoints: points)
        }
    }
}
#endif
