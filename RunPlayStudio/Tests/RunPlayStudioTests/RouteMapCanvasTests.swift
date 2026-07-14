import MapKit
import RunPlayCore
import RunPlayPlatform
import XCTest
@testable import RunPlayStudio

final class RouteMapCanvasTests: XCTestCase {
    func testRouteFiltersInvalidCoordinates() {
        let points = [
            makePoint(latitude: 1.30, longitude: 103.80, distance: 0),
            makePoint(latitude: .nan, longitude: 103.81, distance: 100),
            makePoint(latitude: 1.31, longitude: 181, distance: 200),
            makePoint(latitude: 1.32, longitude: 103.82, distance: 300)
        ]

        let route = RouteMapContent.route(id: "route", points: points, style: .primary)

        XCTAssertEqual(route.coordinates.count, 2)
        XCTAssertEqual(route.coordinates.first?.latitude, 1.30)
        XCTAssertEqual(route.coordinates.last?.longitude, 103.82)
    }

    func testNormalizedMapGeometryExcludesRejectedTeleport() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            RoutePoint(timestamp: start, latitude: 1, longitude: 103, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: start.addingTimeInterval(10), latitude: 1.009, longitude: 103, distanceFromStartMeters: 0, elapsedSeconds: 10),
            RoutePoint(timestamp: start.addingTimeInterval(20), latitude: 1.000_18, longitude: 103, distanceFromStartMeters: 0, elapsedSeconds: 20)
        ]
        let normalized = try RouteQualityProcessor().process(points).routePoints

        let routes = RouteMapContent.segmentedRoutes(
            idPrefix: "normalized",
            points: normalized,
            style: .primary
        )

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].coordinates.count, 2)
        XCTAssertLessThan(routes[0].coordinates.map(\.latitude).max() ?? .infinity, 1.001)
    }

    func testInferredGapProducesDisconnectedMapLines() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [0.0, 20, 520, 540, 560].enumerated().map { index, metres in
            RoutePoint(
                timestamp: start.addingTimeInterval(Double(index) * 10),
                latitude: 1 + metres / 111_132,
                longitude: 103,
                distanceFromStartMeters: 0,
                elapsedSeconds: Double(index) * 10
            )
        }
        let normalized = try RouteQualityProcessor().process(points).routePoints

        let routes = RouteMapContent.segmentedRoutes(
            idPrefix: "gap",
            points: normalized,
            style: .primary
        )

        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes.map { $0.coordinates.count }, [2, 3])
    }

    func testSingleLineCompatibilityRouteRefusesToBridgeSegments() {
        var first = makePoint(latitude: 1.30, longitude: 103.80, distance: 0)
        var resumed = makePoint(latitude: 1.40, longitude: 103.90, distance: 0)
        first.routeSegmentIndex = 0
        resumed.routeSegmentIndex = 1

        let route = RouteMapContent.route(
            id: "unsafe-gap",
            points: [first, resumed],
            style: .primary
        )

        XCTAssertTrue(route.coordinates.isEmpty)
    }

    func testEndpointMarkersUseFirstAndLastValidCoordinates() {
        let points = [
            makePoint(latitude: .nan, longitude: 103.79, distance: 0),
            makePoint(latitude: 1.30, longitude: 103.80, distance: 100),
            makePoint(latitude: 1.31, longitude: 103.81, distance: 200)
        ]

        let markers = RouteMapContent.endpointMarkers(points: points, idPrefix: "test")

        XCTAssertEqual(markers.map(\.id), ["test-start", "test-finish"])
        XCTAssertEqual(markers.first?.coordinate.latitude, 1.30)
        XCTAssertEqual(markers.last?.coordinate.latitude, 1.31)
    }

    func testCurrentMarkerRejectsInvalidIndexAndCoordinate() {
        let points = [
            makePoint(latitude: 1.30, longitude: 103.80, distance: 0),
            makePoint(latitude: .infinity, longitude: 103.81, distance: 100)
        ]

        XCTAssertNotNil(RouteMapContent.currentMarker(points: points, index: 0))
        XCTAssertNil(RouteMapContent.currentMarker(points: points, index: 1))
        XCTAssertNil(RouteMapContent.currentMarker(points: points, index: 2))
        XCTAssertNil(RouteMapContent.currentMarker(points: points, index: -1))
    }

    func testDistanceMarkerUsesInterpolatedRouteCoordinate() throws {
        let points = [
            makePoint(latitude: 1.30, longitude: 103.80, distance: 0),
            makePoint(latitude: 1.32, longitude: 103.84, distance: 1_000)
        ]

        let marker = try XCTUnwrap(RouteMapContent.marker(
            points: points,
            distance: 250,
            id: "selected",
            title: "Selected",
            style: .primaryCurrent
        ))

        XCTAssertEqual(marker.coordinate.latitude, 1.305, accuracy: 0.000_001)
        XCTAssertEqual(marker.coordinate.longitude, 103.81, accuracy: 0.000_001)
    }

    func testMapRectProvidesMinimumVisibleAreaForTinyRoute() throws {
        let route = RouteMapContent.route(
            id: "tiny",
            points: [makePoint(latitude: 1.30, longitude: 103.80, distance: 0)],
            style: .primary
        )

        let rect = try XCTUnwrap(RouteMapContent.mapRect(for: [route]))
        let widthMeters = rect.width * MKMetersPerMapPointAtLatitude(1.30)
        let heightMeters = rect.height * MKMetersPerMapPointAtLatitude(1.30)

        XCTAssertEqual(widthMeters, 400, accuracy: 1)
        XCTAssertEqual(heightMeters, 400, accuracy: 1)
    }

    func testMapRectClampsMinimumSpanAtWorldBoundaries() throws {
        let northwestRoute = RouteMapContent.route(
            id: "northwest",
            points: [makePoint(latitude: 85.051_128_78, longitude: -180, distance: 0)],
            style: .primary
        )
        let southeastRoute = RouteMapContent.route(
            id: "southeast",
            points: [makePoint(latitude: -85.051_128_78, longitude: 180, distance: 0)],
            style: .primary
        )

        assertWithinWorld(try XCTUnwrap(RouteMapContent.mapRect(for: [northwestRoute])))
        assertWithinWorld(try XCTUnwrap(RouteMapContent.mapRect(for: [southeastRoute])))
    }

    func testThreeDModeUsesPitchedCamera() {
        XCTAssertEqual(RouteMapDisplayMode.twoD.cameraPitch, 0)
        XCTAssertGreaterThan(RouteMapDisplayMode.threeD.cameraPitch, 45)
    }

    func testCameraPlanCentersAndFramesRoute() throws {
        let route = RouteMapContent.route(
            id: "route",
            points: [
                makePoint(latitude: 1.30, longitude: 103.80, distance: 0),
                makePoint(latitude: 1.32, longitude: 103.84, distance: 1_000)
            ],
            style: .primary
        )

        let plan = try XCTUnwrap(RouteMapContent.cameraPlan(for: [route]))

        XCTAssertEqual(plan.center.latitude, 1.31, accuracy: 0.001)
        XCTAssertEqual(plan.center.longitude, 103.82, accuracy: 0.001)
        XCTAssertGreaterThan(plan.distance, 1_000)
    }

    private func makePoint(
        latitude: Double,
        longitude: Double,
        distance: Double
    ) -> RoutePoint {
        RoutePoint(
            timestamp: Date(timeIntervalSince1970: distance),
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: 10,
            distanceFromStartMeters: distance,
            elapsedSeconds: distance / 3,
            speedMetersPerSecond: 3,
            paceSecondsPerKilometer: 333,
            heartRateBPM: 140,
            cadence: 170,
            horizontalAccuracy: 5
        )
    }

    private func assertWithinWorld(
        _ rect: MKMapRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(rect.minX, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, MKMapSize.world.width, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, MKMapSize.world.height, file: file, line: line)
    }
}
