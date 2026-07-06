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

        XCTAssertGreaterThan(workout.summary.elevationGainMeters, 0)
        XCTAssertEqual(workout.summary.elevationLossMeters, 0, accuracy: 0.1)
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
