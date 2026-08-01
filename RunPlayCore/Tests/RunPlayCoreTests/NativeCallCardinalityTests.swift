import Foundation
import XCTest
@testable import RunPlayCore

/// Proves exactly one native C++ call per production operation for every
/// production caller, plus zero-call coverage for corrected-elevation
/// finalization and solid mode (covered in
/// `RouteMetricScaleBucketParityTests.testNativeCallCountsByMode`).
///
/// Counters are bridge-local and reset before each assertion, so ordering and
/// parallelism within this class cannot pollute the counts.
final class NativeCallCardinalityTests: XCTestCase {
    private let processor = RouteQualityProcessor()

    func testRouteQualityProcessorCallsQualityAndElevationExactlyOnce() throws {
        let points = makeStraightLinePoints(count: 120)

        RunPlayRouteQualityBridge.resetNativeInvocationCountForTests()
        RunPlayElevationProfileBridge.resetNativeInvocationCountForTests()

        _ = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(RunPlayRouteQualityBridge.nativeInvocationCount, 1)
        XCTAssertEqual(RunPlayElevationProfileBridge.nativeInvocationCount, 1)
    }

    func testElevationProfileBuildCallsNativeExactlyOnce() throws {
        let points = makeStraightLinePoints(count: 64)

        RunPlayElevationProfileBridge.resetNativeInvocationCountForTests()

        _ = try ElevationProfile.build(
            routePoints: points,
            policy: .runningDefault,
            isCancelled: { false }
        )

        XCTAssertEqual(RunPlayElevationProfileBridge.nativeInvocationCount, 1)
    }

    func testSegmentDetectorCallsNativeExactlyOnce() throws {
        let workout = HotspotProfilingFixtures.makeWorkout(options: .init(
            pointCount: 400,
            segmentCount: 2,
            stationaryWindows: true,
            seed: 1_103,
            name: "segment-cardinality"
        ))
        // Context construction builds an elevation profile through the same
        // bridge; the segment counter is unaffected.
        let context = WorkoutAnalysisContext(workout: workout)

        RunPlaySegmentDetectorBridge.resetNativeInvocationCountForTests()

        let highlights = try SegmentDetector.detectSegments(
            from: workout,
            context: context,
            policy: .runningDefault,
            isCancelled: { false }
        )

        XCTAssertEqual(RunPlaySegmentDetectorBridge.nativeInvocationCount, 1)
        XCTAssertFalse(highlights.isEmpty)
    }

    func testConstrainedDTWAlignerCallsNativeOncePerAlignmentAttempt() throws {
        let workout = makeAlignmentWorkout(distanceMeters: 4_000, step: 20)

        RunPlayRouteAlignmentDtwBridge.resetNativeInvocationCountForTests()

        let snapshot = try ConstrainedDynamicTimeWarpingAligner().align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout)
        )

        XCTAssertEqual(RunPlayRouteAlignmentDtwBridge.nativeInvocationCount, 1)
        guard case .available = snapshot.availability else {
            return XCTFail("Expected an available alignment")
        }
    }

    func testPersonalHeatmapBuilderCallsNativeOncePerWorkoutPerAttempt() throws {
        let line = makeHeatmapLineWorkouts(count: 3)
        let builder = PersonalHeatmapBuilder()

        RunPlayPersonalHeatmapCoverageBridge.resetNativeInvocationCountForTests()

        let snapshot = try builder.build(
            workouts: line,
            configuration: PersonalHeatmapConfiguration(cellSizeMeters: 50)
        )

        // Three non-empty workouts in a single adaptive pass: one native
        // coverage call each.
        XCTAssertEqual(RunPlayPersonalHeatmapCoverageBridge.nativeInvocationCount, 3)
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 3)
        XCTAssertEqual(snapshot.diagnostics.adaptiveResolutionRetries, 0)
    }

    func testEmptyRouteCallsNoNativeElevationOrQuality() throws {
        RunPlayRouteQualityBridge.resetNativeInvocationCountForTests()
        RunPlayElevationProfileBridge.resetNativeInvocationCountForTests()

        _ = try processor.process([], sortByTimestamp: false)

        XCTAssertEqual(RunPlayRouteQualityBridge.nativeInvocationCount, 0)
        XCTAssertEqual(RunPlayElevationProfileBridge.nativeInvocationCount, 0)
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
