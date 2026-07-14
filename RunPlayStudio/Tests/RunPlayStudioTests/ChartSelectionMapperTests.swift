import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class ChartSelectionMapperTests: XCTestCase {

    // MARK: - Distance Mapping

    func testDistanceForChartPositionNormalCase() throws {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: 2.5,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(try XCTUnwrap(distance), 2500, accuracy: 0.1)
    }

    func testDistanceForChartPositionAtStart() throws {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: 0,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(try XCTUnwrap(distance), 0, accuracy: 0.1)
    }

    func testDistanceForChartPositionAtEnd() throws {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: 5,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(try XCTUnwrap(distance), 5000, accuracy: 0.1)
    }

    func testDistanceForChartPositionClampsBeforeStart() throws {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: -1,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(try XCTUnwrap(distance), 0, accuracy: 0.1)
    }

    func testDistanceForChartPositionClampsAfterEnd() throws {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: 10,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(try XCTUnwrap(distance), 5000, accuracy: 0.1)
    }

    func testDistanceForChartPositionHandlesNaN() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: Double.nan,
            totalDistanceMeters: 5000
        )
        XCTAssertNil(distance)
    }

    func testDistanceForChartPositionHandlesInfinity() {
        let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: Double.infinity,
            totalDistanceMeters: 5000
        )
        XCTAssertNil(distance)
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

        XCTAssertNil(index, "NaN distance should return nil")
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

    func testRoutePointIndexForInvalidChartPositionReturnsNil() {
        let points = createSamplePoints(count: 50, totalDistance: 5000)
        let index = ChartSelectionMapper.routePointIndex(forChartPositionKm: Double.nan, in: points)

        XCTAssertNil(index)
    }

    func testElevationChartDataKeepsDistanceAlignmentAndBreaksAtGaps() {
        let start = Date()
        let points = [
            RoutePoint(timestamp: start, latitude: 1, longitude: 103, altitudeMeters: 100, distanceFromStartMeters: 0, elapsedSeconds: 0, routeSegmentIndex: 0),
            RoutePoint(timestamp: start, latitude: 1, longitude: 103, altitudeMeters: nil, distanceFromStartMeters: 10, elapsedSeconds: 1, routeSegmentIndex: 0),
            RoutePoint(timestamp: start, latitude: 1, longitude: 103, altitudeMeters: 102, distanceFromStartMeters: 20, elapsedSeconds: 2, routeSegmentIndex: 0),
            RoutePoint(timestamp: start, latitude: 1, longitude: 103, altitudeMeters: 200, distanceFromStartMeters: 20, elapsedSeconds: 3, routeSegmentIndex: 1),
            RoutePoint(timestamp: start, latitude: 1, longitude: 103, altitudeMeters: 201, distanceFromStartMeters: 30, elapsedSeconds: 4, routeSegmentIndex: 1)
        ]
        let profile = ElevationProfile(routePoints: points)

        let data = MetricChartDataBuilder.build(
            routePoints: points,
            values: MetricChartDataBuilder.elevationValues(
                routePoints: points,
                profile: profile
            )
        )

        XCTAssertEqual(data.map(\.id), [0, 2, 3, 4])
        XCTAssertEqual(data.map(\.distanceKm), [0, 0.02, 0.02, 0.03])
        XCTAssertEqual(data.map(\.seriesID), [1, 2, 3, 3])
    }

    func testElevationChartRejectsStaleProfileAlignment() {
        let points = createSamplePoints(count: 3, totalDistance: 100)
        let stalePoints = createSamplePoints(count: 3, totalDistance: 100)
        let staleProfile = ElevationProfile(routePoints: stalePoints)

        let values = MetricChartDataBuilder.elevationValues(
            routePoints: points,
            profile: staleProfile
        )
        let data = MetricChartDataBuilder.build(routePoints: points, values: values)

        XCTAssertEqual(values.count, points.count)
        XCTAssertTrue(values.allSatisfy { $0 == nil })
        XCTAssertTrue(data.isEmpty)
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
