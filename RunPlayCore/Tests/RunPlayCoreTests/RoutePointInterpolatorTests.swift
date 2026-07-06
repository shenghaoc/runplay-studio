import XCTest
@testable import RunPlayCore

final class RoutePointInterpolatorTests: XCTestCase {

    // MARK: - point(at:in:)

    func testPointAtStartReturnsFirstPoint() {
        let points = createPoints(count: 5, totalDistance: 1000)
        let result = RoutePointInterpolator.point(at: 0, in: points)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.distanceFromStartMeters, 0, accuracy: 0.001)
    }

    func testPointAtEndReturnsLastPoint() {
        let points = createPoints(count: 5, totalDistance: 1000)
        let result = RoutePointInterpolator.point(at: 1000, in: points)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.distanceFromStartMeters, 1000, accuracy: 0.001)
    }

    func testPointAtMidDistanceInterpolates() {
        let points = createPoints(count: 3, totalDistance: 1000)
        let result = RoutePointInterpolator.point(at: 500, in: points)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.distanceFromStartMeters, 500, accuracy: 0.001)
        XCTAssertEqual(result!.elapsedSeconds, 500, accuracy: 0.001)
    }

    func testPointBeyondEndClamps() {
        let points = createPoints(count: 3, totalDistance: 1000)
        let result = RoutePointInterpolator.point(at: 2000, in: points)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.distanceFromStartMeters, 1000, accuracy: 0.001)
    }

    func testPointBeforeStartClamps() {
        let points = createPoints(count: 3, totalDistance: 1000)
        let result = RoutePointInterpolator.point(at: -100, in: points)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.distanceFromStartMeters, 0, accuracy: 0.001)
    }

    func testPointWithEmptyArrayReturnsNil() {
        let result = RoutePointInterpolator.point(at: 500, in: [])
        XCTAssertNil(result)
    }

    func testPointWithSinglePointReturnsThatPoint() {
        let points = [makePoint(distance: 0, elapsed: 0)]
        let result = RoutePointInterpolator.point(at: 0, in: points)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.distanceFromStartMeters, 0)
    }

    func testPointWithNaNDistanceReturnsNil() {
        let points = createPoints(count: 3, totalDistance: 1000)
        let result = RoutePointInterpolator.point(at: .nan, in: points)
        XCTAssertNil(result)
    }

    // MARK: - firstIndex / lastIndex

    func testFirstIndexAtOrAfterFindsCorrectIndex() {
        let points = createPoints(count: 5, totalDistance: 1000)
        let index = RoutePointInterpolator.firstIndex(atOrAfter: 500, in: points)

        XCTAssertNotNil(index)
        XCTAssertEqual(index, 2) // 0, 250, 500, 750, 1000 → index 2 has distance 500
    }

    func testLastIndexAtOrBeforeFindsCorrectIndex() {
        let points = createPoints(count: 5, totalDistance: 1000)
        let index = RoutePointInterpolator.lastIndex(atOrBefore: 500, in: points)

        XCTAssertNotNil(index)
        XCTAssertEqual(index, 2)
    }

    func testFirstIndexBeyondEndReturnsNil() {
        let points = createPoints(count: 3, totalDistance: 1000)
        let index = RoutePointInterpolator.firstIndex(atOrAfter: 2000, in: points)
        XCTAssertNil(index)
    }

    // MARK: - averageHeartRate

    func testAverageHeartRateReturnsAverage() {
        var points = createPoints(count: 5, totalDistance: 1000)
        points[0] = makePoint(distance: 0, elapsed: 0, hr: 120)
        points[1] = makePoint(distance: 250, elapsed: 250, hr: 140)
        points[2] = makePoint(distance: 500, elapsed: 500, hr: 160)
        points[3] = makePoint(distance: 750, elapsed: 750, hr: 140)
        points[4] = makePoint(distance: 1000, elapsed: 1000, hr: 120)

        let avg = RoutePointInterpolator.averageHeartRate(in: points, from: 0, to: 1000)

        XCTAssertNotNil(avg)
        XCTAssertEqual(avg!, 136, accuracy: 0.1) // (120+140+160+140+120)/5 = 136
    }

    func testAverageHeartRateFiltersOutOfRange() {
        var points = createPoints(count: 3, totalDistance: 1000)
        points[0] = makePoint(distance: 0, elapsed: 0, hr: 10) // Below 30
        points[1] = makePoint(distance: 500, elapsed: 500, hr: 150)
        points[2] = makePoint(distance: 1000, elapsed: 1000, hr: 300) // Above 230

        let avg = RoutePointInterpolator.averageHeartRate(in: points, from: 0, to: 1000)

        XCTAssertNotNil(avg)
        XCTAssertEqual(avg!, 150, accuracy: 0.1)
    }

    func testAverageHeartRateWithNoValidHRReturnsNil() {
        let points = createPoints(count: 3, totalDistance: 1000)
        let avg = RoutePointInterpolator.averageHeartRate(in: points, from: 0, to: 1000)
        XCTAssertNil(avg)
    }

    // MARK: - elevationGain

    func testElevationGainComputesPositiveGain() {
        var points = createPoints(count: 3, totalDistance: 1000)
        points[0] = makePoint(distance: 0, elapsed: 0, altitude: 100)
        points[1] = makePoint(distance: 500, elapsed: 500, altitude: 150)
        points[2] = makePoint(distance: 1000, elapsed: 1000, altitude: 120)

        let gain = RoutePointInterpolator.elevationGain(in: points, from: 0, to: 1000)

        XCTAssertNotNil(gain)
        XCTAssertEqual(gain!, 50, accuracy: 0.1) // 100→150 = +50, 150→120 = -30 (not counted)
    }

    func testElevationGainWithNoAltitudeReturnsNil() {
        let points = createPoints(count: 3, totalDistance: 1000)
        let gain = RoutePointInterpolator.elevationGain(in: points, from: 0, to: 1000)
        XCTAssertNil(gain)
    }

    // MARK: - Helpers

    private func createPoints(count: Int, totalDistance: Double) -> [RoutePoint] {
        (0..<count).map { i in
            let fraction = Double(i) / Double(max(count - 1, 1))
            return makePoint(
                distance: fraction * totalDistance,
                elapsed: fraction * totalDistance
            )
        }
    }

    private func makePoint(distance: Double, elapsed: Double, altitude: Double? = nil, hr: Double? = nil) -> RoutePoint {
        RoutePoint(
            timestamp: Date(timeIntervalSince1970: elapsed),
            latitude: 37.7749 + distance * 0.00001,
            longitude: -122.4194 + distance * 0.00001,
            altitudeMeters: altitude,
            distanceFromStartMeters: distance,
            elapsedSeconds: elapsed,
            heartRateBPM: hr
        )
    }
}
