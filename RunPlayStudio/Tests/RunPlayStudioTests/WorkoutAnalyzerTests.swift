import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class WorkoutAnalyzerTests: XCTestCase {

    func testCalculateSummaryEmptyPoints() {
        let workout = RunWorkout(routePoints: [])
        var mutableWorkout = workout
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&mutableWorkout)

        XCTAssertEqual(mutableWorkout.summary.totalDistanceMeters, 0)
        XCTAssertEqual(mutableWorkout.summary.totalElapsedSeconds, 0)
    }

    func testCalculateSummaryWithPoints() {
        let points = createSamplePoints(count: 100, totalDistance: 5000, totalSeconds: 1500)
        var workout = RunWorkout(routePoints: points)
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        XCTAssertEqual(workout.summary.totalDistanceMeters, 5000, accuracy: 10)
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 1500, accuracy: 1)
        XCTAssertEqual(workout.summary.totalActiveSeconds, 1500, accuracy: 1)
        XCTAssertEqual(workout.summary.totalPausedSeconds, 0, accuracy: 1)
        XCTAssertGreaterThan(workout.summary.averagePaceSecondsPerKilometer, 0)
        XCTAssertGreaterThan(workout.summary.averageSpeedMetersPerSecond, 0)
    }

    func testElevationCalculation() {
        var points = createSamplePoints(count: 50, totalDistance: 1000, totalSeconds: 300)
        // Add altitude data
        for i in 0..<points.count {
            points[i].altitudeMeters = Double(i) * 2 // 0m to 98m
        }

        var workout = RunWorkout(routePoints: points)
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        XCTAssertEqual(workout.summary.elevationGainMeters, 98, accuracy: 3)
        XCTAssertEqual(workout.summary.elevationLossMeters, 0, accuracy: 0.1)
    }

    func testFlatAltitudeJitterDoesNotInflateSummaryGainOrLoss() {
        var points = createSamplePoints(count: 101, totalDistance: 1_000, totalSeconds: 300)
        let jitter = [-1.0, 0, 1, 0]
        for index in points.indices {
            points[index].altitudeMeters = 100 + jitter[index % jitter.count]
        }
        var workout = RunWorkout(routePoints: points)

        WorkoutAnalyzer().analyze(&workout)

        XCTAssertEqual(workout.summary.elevationGainMeters, 0, accuracy: 1)
        XCTAssertEqual(workout.summary.elevationLossMeters, 0, accuracy: 1)
    }

    func testNoAltitudeIsRetainedAsUnavailableQualityWarning() throws {
        var points = createSamplePoints(count: 10, totalDistance: 100, totalSeconds: 30)
        for index in points.indices {
            points[index].altitudeMeters = nil
        }
        var workout = RunWorkout(routePoints: points)

        try WorkoutAnalyzer().normalizeAndAnalyze(
            &workout,
            distancePolicy: .useSuppliedDistancesWhenValid
        )

        XCTAssertEqual(workout.summary.elevationGainMeters, 0)
        XCTAssertTrue(workout.analysisWarnings.contains(.insufficientReliableElevation))
    }

    func testHeartRateSummary() {
        var points = createSamplePoints(count: 50, totalDistance: 1000, totalSeconds: 300)
        for i in 0..<points.count {
            points[i].heartRateBPM = 120 + Double(i % 20) // 120-139 bpm
        }

        var workout = RunWorkout(routePoints: points)
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        XCTAssertNotNil(workout.summary.averageHeartRateBPM)
        XCTAssertNotNil(workout.summary.maxHeartRateBPM)
        XCTAssertGreaterThanOrEqual(workout.summary.averageHeartRateBPM!, 120)
        XCTAssertLessThanOrEqual(workout.summary.averageHeartRateBPM!, 140)
    }

    func testSummarySeparatesElapsedActiveAndPausedTime() {
        let start = Date()
        let points = [
            RoutePoint(timestamp: start, latitude: 37.7749, longitude: -122.4194, distanceFromStartMeters: 0, elapsedSeconds: 0, routeSegmentIndex: 0),
            RoutePoint(timestamp: start.addingTimeInterval(300), latitude: 37.7839, longitude: -122.4194, distanceFromStartMeters: 1_000, elapsedSeconds: 300, routeSegmentIndex: 0),
            RoutePoint(timestamp: start.addingTimeInterval(3_600), latitude: 37.9000, longitude: -122.3000, distanceFromStartMeters: 1_000, elapsedSeconds: 3_600, routeSegmentIndex: 1),
            RoutePoint(timestamp: start.addingTimeInterval(3_900), latitude: 37.9090, longitude: -122.3000, distanceFromStartMeters: 2_000, elapsedSeconds: 3_900, routeSegmentIndex: 1)
        ]
        var workout = RunWorkout(routePoints: points)

        WorkoutAnalyzer().analyze(&workout)

        XCTAssertEqual(workout.summary.totalElapsedSeconds, 3_900, accuracy: 0.001)
        XCTAssertEqual(workout.summary.totalActiveSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(workout.summary.totalPausedSeconds, 3_300, accuracy: 0.001)
        XCTAssertEqual(workout.summary.averagePaceSecondsPerKilometer, 300, accuracy: 0.001)
        XCTAssertEqual(workout.summary.elapsedPaceSecondsPerKilometer, 1_950, accuracy: 0.001)
        let replay = PlaybackEngine()
        replay.load(workout)
        XCTAssertEqual(replay.state.totalDuration, workout.summary.totalElapsedSeconds, accuracy: 0.001)
        XCTAssertEqual(workout.analysisVersion, RunWorkout.currentAnalysisVersion)
    }

    // MARK: - Helpers

    private func createSamplePoints(count: Int, totalDistance: Double, totalSeconds: Double) -> [RoutePoint] {
        var points: [RoutePoint] = []
        let startDate = Date()

        for i in 0..<count {
            let fraction = Double(i) / Double(count - 1)
            let point = RoutePoint(
                timestamp: startDate.addingTimeInterval(fraction * totalSeconds),
                latitude: 37.7749 + fraction * 0.01,
                longitude: -122.4194 + fraction * 0.01,
                altitudeMeters: 10 + sin(fraction * .pi * 2) * 5,
                distanceFromStartMeters: fraction * totalDistance,
                elapsedSeconds: fraction * totalSeconds
            )
            points.append(point)
        }

        return points
    }
}
