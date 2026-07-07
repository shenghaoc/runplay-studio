import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class SplitCalculatorTests: XCTestCase {

    func testEmptyPointsReturnsNoSplits() {
        let workout = RunWorkout(routePoints: [])
        let splits = SplitCalculator.calculateSplits(from: workout)
        XCTAssertTrue(splits.isEmpty)
    }

    func testShortRunReturnsOneSplit() {
        let points = createPoints(distance: 500) // Less than 1km
        let workout = RunWorkout(routePoints: points)
        let splits = SplitCalculator.calculateSplits(from: workout)
        XCTAssertEqual(splits.count, 1) // Short run still gets 1 partial split
        XCTAssertEqual(splits[0].distanceMeters, 500, accuracy: 10)
    }

    func testOneKilometerRunReturnsOneSplit() {
        let points = createPoints(distance: 1000)
        let workout = RunWorkout(routePoints: points)
        let splits = SplitCalculator.calculateSplits(from: workout)

        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].splitIndex, 1)
        XCTAssertEqual(splits[0].distanceMeters, 1000, accuracy: 10)
    }

    func testFiveKilometerRunReturnsFiveSplits() {
        let points = createPoints(distance: 5000)
        let workout = RunWorkout(routePoints: points)
        let splits = SplitCalculator.calculateSplits(from: workout)

        XCTAssertGreaterThanOrEqual(splits.count, 4)
        XCTAssertLessThanOrEqual(splits.count, 6)

        for split in splits {
            XCTAssertGreaterThan(split.paceSecondsPerKilometer, 0)
            XCTAssertGreaterThan(split.elapsedSeconds, 0)
        }
    }

    func testSplitPaceCalculation() {
        // 5km in 1500 seconds = 5:00/km pace
        let points = createPoints(distance: 5000, totalSeconds: 1500)
        var workout = RunWorkout(routePoints: points)
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        let splits = workout.splits
        XCTAssertFalse(splits.isEmpty)

        // All splits should be roughly 5:00/km pace (300 seconds)
        for split in splits {
            XCTAssertEqual(split.paceSecondsPerKilometer, 300, accuracy: 50)
        }
    }

    // MARK: - Helpers

    private func createPoints(distance: Double, totalSeconds: Double? = nil) -> [RoutePoint] {
        let count = 100
        let seconds = totalSeconds ?? distance / 3.0 // Default ~3 m/s
        var points: [RoutePoint] = []
        let startDate = Date()

        for i in 0..<count {
            let fraction = Double(i) / Double(count - 1)
            let point = RoutePoint(
                timestamp: startDate.addingTimeInterval(fraction * seconds),
                latitude: 37.7749 + fraction * 0.05,
                longitude: -122.4194 + fraction * 0.05,
                altitudeMeters: 10,
                distanceFromStartMeters: fraction * distance,
                elapsedSeconds: fraction * seconds
            )
            points.append(point)
        }

        return points
    }
}
