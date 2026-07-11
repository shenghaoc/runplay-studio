import XCTest
import RunPlayCore
import RunPlayPlatform
import SceneKit
@testable import RunPlayStudio

final class RouteProjectionTests: XCTestCase {

    func testEmptyPointsReturnsEmpty() {
        let service = RouteProjectionService()
        let result = service.project([])
        XCTAssertTrue(result.isEmpty)
    }

    func testSinglePointProjects() {
        let service = RouteProjectionService()
        let points = [createPoint(lat: 37.7749, lon: -122.4194, alt: 10)]
        let result = service.project(points)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].xMeters, 0, accuracy: 0.1) // Center should be at origin
        XCTAssertEqual(result[0].zMeters, 0, accuracy: 0.1)
    }

    func testProjectionPreservesOrder() {
        let service = RouteProjectionService()
        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7750, lon: -122.4193, alt: 15),
            createPoint(lat: 37.7751, lon: -122.4192, alt: 20)
        ]
        let result = service.project(points)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].sourceIndex, 0)
        XCTAssertEqual(result[1].sourceIndex, 1)
        XCTAssertEqual(result[2].sourceIndex, 2)
    }

    func testElevationExaggeration() {
        var service = RouteProjectionService()
        service.elevationExaggeration = 3.0

        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7750, lon: -122.4193, alt: 30)
        ]
        let result = service.project(points)

        // Elevation difference: 20m, with 3x exaggeration = 60m
        XCTAssertEqual(result[1].yMeters - result[0].yMeters, 60, accuracy: 1)
    }

    func testBoundingBoxCalculation() {
        let service = RouteProjectionService()
        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7759, lon: -122.4184, alt: 50)
        ]
        let scenePoints = service.project(points)
        let bbox = service.boundingBox(of: scenePoints)

        XCTAssertLessThan(bbox.min.x, bbox.max.x)
        XCTAssertLessThan(bbox.min.y, bbox.max.y)
        XCTAssertLessThan(bbox.min.z, bbox.max.z)
    }

    func testLatLonToMetersAccuracy() {
        let service = RouteProjectionService()

        // Test known coordinates: ~1 degree latitude ≈ 111km
        let (x1, z1) = service.latLonToMeters(
            lat: 37.7749,
            lon: -122.4194,
            centerLat: 37.7749,
            centerLon: -122.4194
        )
        XCTAssertEqual(x1, 0, accuracy: 0.01)
        XCTAssertEqual(z1, 0, accuracy: 0.01)

        // 0.01 degrees latitude ≈ 1.1km
        let (_, z2) = service.latLonToMeters(
            lat: 37.7849,
            lon: -122.4194,
            centerLat: 37.7749,
            centerLon: -122.4194
        )
        XCTAssertEqual(z2, 1110, accuracy: 100)
    }

    func testProjectedPointsHaveFiniteValues() {
        let service = RouteProjectionService()
        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7759, lon: -122.4184, alt: 50),
            createPoint(lat: 37.7769, lon: -122.4174, alt: 30)
        ]
        let scenePoints = service.project(points)

        for point in scenePoints {
            XCTAssertTrue(point.xMeters.isFinite, "xMeters should be finite")
            XCTAssertTrue(point.yMeters.isFinite, "yMeters should be finite")
            XCTAssertTrue(point.zMeters.isFinite, "zMeters should be finite")
            XCTAssertFalse(point.xMeters.isNaN, "xMeters should not be NaN")
            XCTAssertFalse(point.yMeters.isNaN, "yMeters should not be NaN")
            XCTAssertFalse(point.zMeters.isNaN, "zMeters should not be NaN")
        }
    }

    func testRepeatedCoordinates() {
        let service = RouteProjectionService()
        // All same coordinates - should still produce valid output
        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10)
        ]
        let result = service.project(points)

        XCTAssertEqual(result.count, 3)
        // All points should project to same location (center)
        XCTAssertEqual(result[0].xMeters, 0, accuracy: 0.01)
        XCTAssertEqual(result[1].xMeters, 0, accuracy: 0.01)
        XCTAssertEqual(result[2].xMeters, 0, accuracy: 0.01)
    }

    func testMissingElevation() {
        let service = RouteProjectionService()
        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: nil),
            createPoint(lat: 37.7750, lon: -122.4193, alt: nil)
        ]
        let result = service.project(points)

        XCTAssertEqual(result.count, 2)
        // Should default to minAlt (0 when all nil), so y should be 0
        XCTAssertEqual(result[0].yMeters, 0, accuracy: 0.01)
        XCTAssertEqual(result[1].yMeters, 0, accuracy: 0.01)
    }

    func testNaNCoordinatesFiltered() {
        let service = RouteProjectionService()
        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: Double.nan, lon: -122.4193, alt: 15),
            createPoint(lat: 37.7751, lon: Double.infinity, alt: 20),
            createPoint(lat: 37.7752, lon: -122.4191, alt: 25)
        ]
        let result = service.project(points)

        // Should only have 2 valid points (first and last)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].xMeters.isFinite)
        XCTAssertTrue(result[1].xMeters.isFinite)
    }

    func testElevationExaggerationChangesYValues() {
        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7750, lon: -122.4193, alt: 50)
        ]

        var service1 = RouteProjectionService()
        service1.elevationExaggeration = 1.0
        let result1 = service1.project(points)

        var service2 = RouteProjectionService()
        service2.elevationExaggeration = 5.0
        let result2 = service2.project(points)

        // Y difference should be 5x greater with 5x exaggeration
        let diff1 = result1[1].yMeters - result1[0].yMeters
        let diff2 = result2[1].yMeters - result2[0].yMeters
        XCTAssertEqual(diff2 / diff1, 5.0, accuracy: 0.1)
    }

    func testMaxExtent() {
        let service = RouteProjectionService()
        let points = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7849, lon: -122.4094, alt: 50) // ~1.5km away
        ]
        let scenePoints = service.project(points)
        let extent = service.maxExtent(of: scenePoints)

        XCTAssertGreaterThan(extent, 1000) // Should be at least 1km
        XCTAssertTrue(extent.isFinite)
    }

    func testRouteSceneBuilderTogglesGridAndKilometerMarkersAfterBuild() {
        let scenePoints = [
            RouteScenePoint(xMeters: 0, yMeters: 0, zMeters: 0, sourceIndex: 0, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RouteScenePoint(xMeters: 500, yMeters: 0, zMeters: 0, sourceIndex: 1, distanceFromStartMeters: 1_000, elapsedSeconds: 300),
            RouteScenePoint(xMeters: 750, yMeters: 0, zMeters: 0, sourceIndex: 2, distanceFromStartMeters: 1_500, elapsedSeconds: 450)
        ]
        let builder = RouteSceneBuilder()
        let scene = builder.buildScene(from: scenePoints)

        XCTAssertFalse(scene.rootNode.childNodes.contains { $0.isHidden })

        builder.showGroundGrid = false
        builder.showKilometerMarkers = false

        let hiddenTopLevelNodes = scene.rootNode.childNodes.filter { $0.isHidden }
        XCTAssertGreaterThanOrEqual(hiddenTopLevelNodes.count, 2)
    }

    func testSegmentHighlightDoesNotBridgeRouteSegments() {
        let scenePoints = [
            RouteScenePoint(xMeters: 0, yMeters: 0, zMeters: 0, sourceIndex: 0, distanceFromStartMeters: 0, elapsedSeconds: 0, routeSegmentIndex: 0),
            RouteScenePoint(xMeters: 100, yMeters: 0, zMeters: 0, sourceIndex: 1, distanceFromStartMeters: 100, elapsedSeconds: 30, routeSegmentIndex: 0),
            RouteScenePoint(xMeters: 10_000, yMeters: 0, zMeters: 0, sourceIndex: 2, distanceFromStartMeters: 100, elapsedSeconds: 3_600, routeSegmentIndex: 1),
            RouteScenePoint(xMeters: 10_100, yMeters: 0, zMeters: 0, sourceIndex: 3, distanceFromStartMeters: 200, elapsedSeconds: 3_630, routeSegmentIndex: 1)
        ]
        let builder = RouteSceneBuilder()
        let scene = builder.buildScene(from: scenePoints)
        let highlight = SegmentHighlight(
            type: .custom,
            title: "Gap-safe highlight",
            subtitle: "",
            startDistanceMeters: 0,
            endDistanceMeters: 200,
            startElapsedSeconds: 0,
            endElapsedSeconds: 3_630,
            durationSeconds: 3_630,
            distanceMeters: 200,
            sourcePointRange: 0..<4
        )

        let highlightNode = builder.highlightSegment(highlight, in: scene)

        XCTAssertNotNil(highlightNode)
        let tubeCount = highlightNode?.childNodes.filter { $0.geometry is SCNCylinder }.count
        XCTAssertEqual(tubeCount, 2)
    }

    // MARK: - Helpers

    private func createPoint(lat: Double, lon: Double, alt: Double?) -> RoutePoint {
        RoutePoint(
            timestamp: Date(),
            latitude: lat,
            longitude: lon,
            altitudeMeters: alt,
            distanceFromStartMeters: 0,
            elapsedSeconds: 0
        )
    }
}
