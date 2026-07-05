import XCTest
@testable import RunPlayStudio

final class ChartSelectionMapperTests: XCTestCase {

    // MARK: - Distance Mapping

    func testDistanceForChartPositionNormalCase() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: 2.5,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(distance, 2500, accuracy: 0.1)
    }

    func testDistanceForChartPositionAtStart() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: 0,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(distance, 0, accuracy: 0.1)
    }

    func testDistanceForChartPositionAtEnd() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: 5,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(distance, 5000, accuracy: 0.1)
    }

    func testDistanceForChartPositionClampsBeforeStart() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: -1,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(distance, 0, accuracy: 0.1)
    }

    func testDistanceForChartPositionClampsAfterEnd() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: 10,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(distance, 5000, accuracy: 0.1)
    }

    func testDistanceForChartPositionHandlesNaN() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: Double.nan,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(distance, 0, accuracy: 0.1)
    }

    func testDistanceForChartPositionHandlesInfinity() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: Double.infinity,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(distance, 0, accuracy: 0.1)
    }

    // MARK: - Route Point by Distance

    func testNearestRoutePointByDistanceNormalCase() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.nearestRoutePointIndex(forDistance: 2500, in: points)

        XCTAssertNotNil(index)
        if let idx = index {
            XCTAssertEqual(points[idx].distanceFromStartMeters, 2500, accuracy: 110)
        }
    }

    func testNearestRoutePointByDistanceAtStart() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.nearestRoutePointIndex(forDistance: 0, in: points)

        XCTAssertNotNil(index)
        XCTAssertEqual(index, 0)
    }

    func testNearestRoutePointByDistanceAtEnd() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.nearestRoutePointIndex(forDistance: 5000, in: points)

        XCTAssertNotNil(index)
        if let idx = index {
            XCTAssertEqual(points[idx].distanceFromStartMeters, 5000, accuracy: 110)
        }
    }

    func testNearestRoutePointByDistanceEmptyArray() {
        let index = ChartSelectionMapper.nearestRoutePointIndex(forDistance: 1000, in: [])
        XCTAssertNil(index)
    }

    func testNearestRoutePointByDistanceHandlesNaN() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.nearestRoutePointIndex(forDistance: Double.nan, in: points)

        XCTAssertNotNil(index)
        XCTAssertEqual(index, 0)
    }

    // MARK: - Route Point by Elapsed Time

    func testNearestRoutePointByTimeNormalCase() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.nearestRoutePointIndex(forElapsedTime: 500, in: points)

        XCTAssertNotNil(index)
        if let idx = index {
            XCTAssertEqual(points[idx].elapsedSeconds, 500, accuracy: 25)
        }
    }

    func testNearestRoutePointByTimeAtStart() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.nearestRoutePointIndex(forElapsedTime: 0, in: points)

        XCTAssertNotNil(index)
        XCTAssertEqual(index, 0)
    }

    func testNearestRoutePointByTimeEmptyArray() {
        let index = ChartSelectionMapper.nearestRoutePointIndex(forElapsedTime: 100, in: [])
        XCTAssertNil(index)
    }

    // MARK: - Chart Position to Route Point

    func testRoutePointIndexForChartPosition() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.routePointIndex(forChartPositionKm: 2.5, in: points)

        XCTAssertNotNil(index)
        if let idx = index {
            XCTAssertEqual(points[idx].distanceFromStartMeters, 2500, accuracy: 110)
        }
    }

    func testRoutePointIndexForChartPositionAtStart() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.routePointIndex(forChartPositionKm: 0, in: points)

        XCTAssertNotNil(index)
        XCTAssertEqual(index, 0)
    }

    func testRoutePointIndexForChartPositionAtEnd() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.routePointIndex(forChartPositionKm: 5, in: points)

        XCTAssertNotNil(index)
    }

    // MARK: - Helpers

    private func createSamplePoints(count: Int, totalDistance: Double) -> [RoutePoint] {
        (0..<count).map { i in
            let fraction = Double(i) / Double(count - 1)
            return RoutePoint(
                timestamp: Date(),
                latitude: 37.7749 + fraction * 0.01,
                longitude: -122.4194,
                altitudeMeters: 10 + fraction * 20,
                distanceFromStartMeters: fraction * totalDistance,
                elapsedSeconds: fraction * totalDistance / 3.0 // ~3 m/s pace
            )
        }
    }
}
