import AppKit
import MapKit
import RunPlayCore
import SceneKit
import XCTest

@testable import RunPlayStudio

final class RouteMapSnapshotServiceTests: XCTestCase {

    func testLayoutCoversEveryRouteCoordinateInLocalMeterSpace() throws {
        let route = [
            makePoint(latitude: 37.7749, longitude: -122.4194),
            makePoint(latitude: 37.7849, longitude: -122.4094),
            makePoint(latitude: 37.7790, longitude: -122.4310)
        ]

        let layout = try XCTUnwrap(
            RouteMapSnapshotLayout.make(
                routeGroups: [route],
                projectionOrigin: route
            )
        )

        for point in route {
            let meters = GeoDistance.latLonToMeters(
                lat: point.latitude,
                lon: point.longitude,
                centerLat: layout.projectionOriginLatitude,
                centerLon: layout.projectionOriginLongitude
            )
            XCTAssertGreaterThanOrEqual(
                CGFloat(meters.x),
                layout.planeCenterX - layout.planeWidthMeters / 2
            )
            XCTAssertLessThanOrEqual(
                CGFloat(meters.x),
                layout.planeCenterX + layout.planeWidthMeters / 2
            )
            XCTAssertGreaterThanOrEqual(
                CGFloat(meters.z),
                layout.planeCenterZ - layout.planeHeightMeters / 2
            )
            XCTAssertLessThanOrEqual(
                CGFloat(meters.z),
                layout.planeCenterZ + layout.planeHeightMeters / 2
            )
        }
    }

    func testLayoutUsesMinimumMapAreaForTinyRoutes() throws {
        let route = [
            makePoint(latitude: 37.7749, longitude: -122.4194),
            makePoint(latitude: 37.77491, longitude: -122.41939)
        ]

        let layout = try XCTUnwrap(
            RouteMapSnapshotLayout.make(
                routeGroups: [route],
                projectionOrigin: route
            )
        )

        XCTAssertGreaterThanOrEqual(layout.planeWidthMeters, 500)
        XCTAssertGreaterThanOrEqual(layout.planeHeightMeters, 500)
    }

    func testComparisonLayoutUsesPrimaryProjectionOriginAndCoversBothRoutes() throws {
        let primary = [
            makePoint(latitude: 37.7749, longitude: -122.4194),
            makePoint(latitude: 37.7849, longitude: -122.4094)
        ]
        let comparison = [
            makePoint(latitude: 37.7700, longitude: -122.4300),
            makePoint(latitude: 37.7900, longitude: -122.4000)
        ]

        let layout = try XCTUnwrap(
            RouteMapSnapshotLayout.make(
                routeGroups: [primary, comparison],
                projectionOrigin: primary
            )
        )

        XCTAssertEqual(layout.projectionOriginLatitude, 37.7799, accuracy: 0.000_001)
        XCTAssertEqual(layout.projectionOriginLongitude, -122.4144, accuracy: 0.000_001)

        for point in primary + comparison {
            let meters = GeoDistance.latLonToMeters(
                lat: point.latitude,
                lon: point.longitude,
                centerLat: layout.projectionOriginLatitude,
                centerLon: layout.projectionOriginLongitude
            )
            XCTAssertLessThanOrEqual(
                abs(CGFloat(meters.x) - layout.planeCenterX),
                layout.planeWidthMeters / 2
            )
            XCTAssertLessThanOrEqual(
                abs(CGFloat(meters.z) - layout.planeCenterZ),
                layout.planeHeightMeters / 2
            )
        }
    }

    func testLayoutRejectsInvalidCoordinates() {
        let invalid = [
            makePoint(latitude: .nan, longitude: -122.4),
            makePoint(latitude: 37.7, longitude: .infinity)
        ]

        XCTAssertNil(
            RouteMapSnapshotLayout.make(
                routeGroups: [invalid],
                projectionOrigin: invalid
            )
        )
    }

    func testOverlayBuildsHorizontalNamedMapPlane() throws {
        let overlay = RouteMapOverlay(
            image: NSImage(size: NSSize(width: 100, height: 100)),
            centerX: 20,
            centerZ: -30,
            widthMeters: 800,
            heightMeters: 900
        )

        let node = overlay.makeSceneNode(groundY: -2)
        let plane = try XCTUnwrap(node.geometry as? SCNPlane)

        XCTAssertEqual(node.name, RouteMapOverlay.nodeName)
        XCTAssertEqual(node.position.x, 20)
        XCTAssertEqual(node.position.y, -2)
        XCTAssertEqual(node.position.z, -30)
        XCTAssertEqual(node.eulerAngles.x, CGFloat.pi / 2, accuracy: 0.000_1)
        XCTAssertEqual(plane.width, 800)
        XCTAssertEqual(plane.height, 900)
        XCTAssertEqual(plane.firstMaterial?.lightingModel, .constant)
    }

    private func makePoint(latitude: Double, longitude: Double) -> RoutePoint {
        RoutePoint(
            timestamp: Date(),
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: 10
        )
    }
}
