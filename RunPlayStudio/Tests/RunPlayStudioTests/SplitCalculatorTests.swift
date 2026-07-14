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

    func testUninterruptedOnePointFiveKilometersHasOneFullAndOnePartialSplit() {
        let workout = RunWorkout(routePoints: createPoints(distance: 1_500, totalSeconds: 450))

        let splits = SplitCalculator.calculateSplits(from: workout)

        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].distanceMeters, 1_000, accuracy: 0.001)
        XCTAssertEqual(splits[1].distanceMeters, 500, accuracy: 0.001)
        XCTAssertEqual(splits[0].activeSeconds, splits[0].elapsedSeconds, accuracy: 0.001)
        XCTAssertEqual(splits[1].activeSeconds, splits[1].elapsedSeconds, accuracy: 0.001)
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

    func testPauseExactlyAtOneKilometerUsesStopAndResumeBoundary() {
        let start = Date()
        let workout = RunWorkout(routePoints: [
            RoutePoint(timestamp: start, latitude: 37.7749, longitude: -122.4194, distanceFromStartMeters: 0, elapsedSeconds: 0, routeSegmentIndex: 0),
            RoutePoint(timestamp: start.addingTimeInterval(300), latitude: 37.7839, longitude: -122.4194, distanceFromStartMeters: 1_000, elapsedSeconds: 300, routeSegmentIndex: 0),
            RoutePoint(timestamp: start.addingTimeInterval(3_600), latitude: 37.9000, longitude: -122.3000, distanceFromStartMeters: 1_000, elapsedSeconds: 3_600, routeSegmentIndex: 1),
            RoutePoint(timestamp: start.addingTimeInterval(3_900), latitude: 37.9090, longitude: -122.3000, distanceFromStartMeters: 2_000, elapsedSeconds: 3_900, routeSegmentIndex: 1)
        ])

        let splits = SplitCalculator.calculateSplits(from: workout)

        XCTAssertEqual(splits.count, 2)
        for split in splits {
            XCTAssertEqual(split.elapsedSeconds, 300, accuracy: 0.001)
            XCTAssertEqual(split.activeSeconds, 300, accuracy: 0.001)
            XCTAssertEqual(split.paceSecondsPerKilometer, 300, accuracy: 0.001)
        }
    }

    func testPauseAtSixHundredMetersDoesNotResetGlobalSplits() {
        let start = Date()
        let workout = RunWorkout(routePoints: [
            routePoint(start: start, time: 0, distance: 0, segment: 0),
            routePoint(start: start, time: 180, distance: 600, segment: 0),
            routePoint(start: start, time: 3_180, distance: 600, segment: 1),
            routePoint(start: start, time: 3_300, distance: 1_000, segment: 1),
            routePoint(start: start, time: 3_420, distance: 1_400, segment: 1)
        ])

        let splits = SplitCalculator.calculateSplits(from: workout)

        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].startDistanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(splits[0].endDistanceMeters, 1_000, accuracy: 0.001)
        XCTAssertEqual(splits[0].elapsedSeconds, 3_300, accuracy: 0.001)
        XCTAssertEqual(splits[0].activeSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(splits[0].paceSecondsPerKilometer, 300, accuracy: 0.001)
        XCTAssertEqual(splits[0].elapsedPaceSecondsPerKilometer, 3_300, accuracy: 0.001)
        XCTAssertEqual(splits[1].distanceMeters, 400, accuracy: 0.001)
        XCTAssertEqual(splits[1].activeSeconds, 120, accuracy: 0.001)
    }

    func testSeveralPausesWithinOneKilometerAggregateMetricsWithoutCrossGapElevation() {
        let start = Date()
        let workout = RunWorkout(routePoints: [
            routePoint(start: start, time: 0, distance: 0, segment: 0, altitude: 10, heartRate: 100),
            routePoint(start: start, time: 100, distance: 300, segment: 0, altitude: 20, heartRate: 110),
            routePoint(start: start, time: 200, distance: 300, segment: 1, altitude: 100, heartRate: 120),
            routePoint(start: start, time: 300, distance: 600, segment: 1, altitude: 105, heartRate: 130),
            routePoint(start: start, time: 500, distance: 600, segment: 2, altitude: 0, heartRate: 140),
            routePoint(start: start, time: 600, distance: 1_000, segment: 2, altitude: 3, heartRate: 150)
        ])

        let split = SplitCalculator.calculateSplits(from: workout).first

        XCTAssertEqual(split?.elapsedSeconds ?? -1, 600, accuracy: 0.001)
        XCTAssertEqual(split?.activeSeconds ?? -1, 300, accuracy: 0.001)
        XCTAssertEqual(split?.elevationGainMeters ?? -1, 18, accuracy: 0.001)
        XCTAssertEqual(split?.averageHeartRateBPM ?? -1, 125, accuracy: 0.001)
    }

    func testFlatNoisySplitUsesCorrectedElevationGain() {
        let start = Date()
        let jitter = [-1.0, 0, 1, 0]
        let points = (0...100).map { index in
            routePoint(
                start: start,
                time: Double(index) * 3,
                distance: Double(index) * 10,
                segment: 0,
                altitude: 100 + jitter[index % jitter.count]
            )
        }
        let workout = RunWorkout(routePoints: points)

        let split = SplitCalculator.calculateSplits(from: workout).first

        XCTAssertEqual(split?.elevationGainMeters ?? -1, 0, accuracy: 1)
    }

    func testFinalSplitIncludesTerminalSameSegmentStationaryTime() {
        let start = Date()
        let workout = RunWorkout(routePoints: [
            routePoint(start: start, time: 0, distance: 0, segment: 0),
            routePoint(start: start, time: 300, distance: 1_000, segment: 0),
            routePoint(start: start, time: 400, distance: 1_000, segment: 0)
        ])

        let split = SplitCalculator.calculateSplits(from: workout).first

        XCTAssertEqual(split?.elapsedSeconds ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(split?.activeSeconds ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(split?.paceSecondsPerKilometer ?? -1, 400, accuracy: 0.001)
    }

    func testImplausiblyHugeDistanceDoesNotAllocateUnboundedSplits() {
        let start = Date()
        let workout = RunWorkout(routePoints: [
            routePoint(start: start, time: 0, distance: 0, segment: 0),
            routePoint(start: start, time: 100, distance: 1_000_000_000, segment: 0)
        ])

        XCTAssertTrue(SplitCalculator.calculateSplits(from: workout).isEmpty)
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

    private func routePoint(
        start: Date,
        time: Double,
        distance: Double,
        segment: Int,
        altitude: Double = 10,
        heartRate: Double? = nil
    ) -> RoutePoint {
        RoutePoint(
            timestamp: start.addingTimeInterval(time),
            latitude: 1 + (distance / 100_000),
            longitude: 1,
            altitudeMeters: altitude,
            distanceFromStartMeters: distance,
            elapsedSeconds: time,
            heartRateBPM: heartRate,
            routeSegmentIndex: segment
        )
    }
}
