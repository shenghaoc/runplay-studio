import XCTest
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

    // MARK: - Helpers

    private func createPoint(lat: Double, lon: Double, alt: Double) -> RoutePoint {
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
