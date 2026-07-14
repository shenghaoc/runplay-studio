import XCTest
@testable import RunPlayCore

final class MovementClockInvariantTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testSummaryDerivesStoppedTimeFromActiveAndMovingClocks() {
        let summary = RunSummary(
            totalElapsedSeconds: 100,
            totalActiveSeconds: 80,
            totalMovingSeconds: 60,
            totalStoppedSeconds: 1_000
        )

        XCTAssertEqual(summary.totalStoppedSeconds, 20)
    }

    func testSplitDerivesStoppedTimeFromActiveAndMovingClocks() {
        let split = RunSplit(
            splitIndex: 1,
            elapsedSeconds: 100,
            activeSeconds: 80,
            movingSeconds: 60,
            stoppedSeconds: 1_000,
            paceSecondsPerKilometer: 300,
            startDistanceMeters: 0,
            endDistanceMeters: 1_000
        )

        XCTAssertEqual(split.stoppedSeconds, 20)
        XCTAssertEqual(split.movingPaceSecondsPerKilometer, 60)
    }

    func testSummaryDerivesMovingPaceAndSpeed() {
        let summary = RunSummary(
            totalDistanceMeters: 1_000,
            totalElapsedSeconds: 100,
            totalActiveSeconds: 100,
            totalMovingSeconds: 80,
            averagePaceSecondsPerKilometer: 100,
            averageSpeedMetersPerSecond: 10
        )

        XCTAssertEqual(summary.movingPaceSecondsPerKilometer, 80)
        XCTAssertEqual(summary.movingAverageSpeedMetersPerSecond, 12.5)
        XCTAssertEqual(summary.totalActiveSeconds, summary.totalMovingSeconds + summary.totalStoppedSeconds)
    }

    func testWorkoutCodableRoundTripsMovementDiagnostics() throws {
        var workout = RunWorkout()
        workout.movementDiagnostics = MovementDiagnostics(
            reliableIntervalCount: 12,
            stoppedIntervalCount: 3,
            uncertainIntervalCount: 2,
            usedConservativeFallback: false,
            analysedPointPairCount: 17
        )

        let decoded = try JSONDecoder().decode(RunWorkout.self, from: JSONEncoder().encode(workout))
        XCTAssertEqual(decoded.movementDiagnostics, workout.movementDiagnostics)
    }

    func testDefaultDistanceComparisonBuildsMovementProfiles() {
        let primary = RunWorkout(routePoints: points(distanceOffset: 0))
        let comparison = RunWorkout(routePoints: points(distanceOffset: 1))

        let metrics = WorkoutComparisonService().metricsAtDistance(
            300,
            primary: primary,
            comparison: comparison
        )

        XCTAssertNotNil(metrics.primaryMovingSeconds)
        XCTAssertNotNil(metrics.comparisonMovingSeconds)
        XCTAssertNotNil(metrics.primaryStoppedSeconds)
        XCTAssertNotNil(metrics.comparisonStoppedSeconds)
    }

    private func points(distanceOffset: Double) -> [RoutePoint] {
        (0..<12).map { index in
            RoutePoint(
                timestamp: start.addingTimeInterval(Double(index) * 5),
                latitude: 1 + Double(index) * 0.001,
                longitude: 1,
                distanceFromStartMeters: Double(index) * 100 + distanceOffset,
                elapsedSeconds: Double(index) * 5
            )
        }
    }
}
