import XCTest
@testable import RunPlayCore

final class RoutePointSanitizerTests: XCTestCase {

    func testNormalizeSortsFiltersAndKeepsMonotonicSeries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            point(start.addingTimeInterval(20), lat: 1.002, lon: 103.002, distance: 50, elapsed: 20),
            point(start.addingTimeInterval(10), lat: 1.001, lon: 103.001, distance: 100, elapsed: 10),
            point(start.addingTimeInterval(15), lat: 100, lon: 103.001, distance: 75, elapsed: 15)
        ]

        let normalized = RoutePointSanitizer.normalize(
            points,
            distancePolicy: .useSuppliedDistancesWhenValid
        )

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].elapsedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(normalized[1].elapsedSeconds, 10, accuracy: 0.001)
        XCTAssertGreaterThan(normalized[1].distanceFromStartMeters, normalized[0].distanceFromStartMeters)
    }

    func testSuppliedDistancesAreRebasedWhenCompleteAndMonotonic() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            point(start, lat: 1.0, lon: 103.0, distance: 50, elapsed: 0),
            point(start.addingTimeInterval(10), lat: 1.001, lon: 103.001, distance: 150, elapsed: 10)
        ]

        let normalized = RoutePointSanitizer.normalize(
            points,
            distancePolicy: .useSuppliedDistancesWhenValid
        )

        XCTAssertEqual(normalized[0].distanceFromStartMeters, 0, accuracy: 0.001)
        XCTAssertEqual(normalized[1].distanceFromStartMeters, 100, accuracy: 0.001)
    }

    func testSplitCalculationInterpolatesUnevenSamples() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            point(start, lat: 1.0, lon: 103.0, distance: 0, elapsed: 0),
            point(start.addingTimeInterval(90), lat: 1.001, lon: 103.001, distance: 300, elapsed: 90),
            point(start.addingTimeInterval(360), lat: 1.002, lon: 103.002, distance: 1_200, elapsed: 360)
        ]
        let workout = RunWorkout(routePoints: points)

        let splits = SplitCalculator.calculateSplits(from: workout)

        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].distanceMeters, 1_000, accuracy: 0.001)
        XCTAssertEqual(splits[0].elapsedSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(splits[1].distanceMeters, 200, accuracy: 0.001)
        XCTAssertEqual(splits[1].elapsedSeconds, 60, accuracy: 0.001)
    }

    func testHeartRateSmoothingPreservesPointAlignment() {
        let start = Date()
        let points = [
            point(start, lat: 1, lon: 103, distance: 0, elapsed: 0, heartRate: 120),
            point(start, lat: 1.001, lon: 103, distance: 100, elapsed: 30, heartRate: nil),
            point(start, lat: 1.002, lon: 103, distance: 200, elapsed: 60, heartRate: 140)
        ]

        let smoothed = MetricSmoother.smoothHeartRate(from: points, windowSize: 3)

        XCTAssertEqual(smoothed.count, points.count)
        XCTAssertNotNil(smoothed[0])
        XCTAssertNil(smoothed[1])
        XCTAssertNotNil(smoothed[2])
    }

    func testNormalizeDropsNegativeOptionalMetrics() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            RoutePoint(
                timestamp: start,
                latitude: 1,
                longitude: 103,
                altitudeMeters: -5,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0,
                speedMetersPerSecond: -1,
                paceSecondsPerKilometer: -300,
                heartRateBPM: 500,
                cadence: -80,
                horizontalAccuracy: -3
            )
        ]

        let normalized = RoutePointSanitizer.normalize(points)

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].altitudeMeters, -5)
        XCTAssertNil(normalized[0].speedMetersPerSecond)
        XCTAssertNil(normalized[0].paceSecondsPerKilometer)
        XCTAssertNil(normalized[0].heartRateBPM)
        XCTAssertNil(normalized[0].cadence)
        XCTAssertNil(normalized[0].horizontalAccuracy)
    }

    func testNormalizeAllowsZeroOptionalMetrics() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            RoutePoint(
                timestamp: start,
                latitude: 1,
                longitude: 103,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0,
                speedMetersPerSecond: 0,
                cadence: 0,
                horizontalAccuracy: 0
            )
        ]

        let normalized = RoutePointSanitizer.normalize(points)

        XCTAssertEqual(normalized[0].speedMetersPerSecond, 0)
        XCTAssertEqual(normalized[0].cadence, 0)
        XCTAssertEqual(normalized[0].horizontalAccuracy, 0)
    }

    private func point(
        _ timestamp: Date,
        lat: Double,
        lon: Double,
        distance: Double,
        elapsed: Double,
        heartRate: Double? = nil
    ) -> RoutePoint {
        RoutePoint(
            timestamp: timestamp,
            latitude: lat,
            longitude: lon,
            distanceFromStartMeters: distance,
            elapsedSeconds: elapsed,
            heartRateBPM: heartRate
        )
    }
}
