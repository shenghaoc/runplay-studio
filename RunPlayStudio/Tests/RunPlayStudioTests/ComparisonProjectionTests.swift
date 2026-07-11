import XCTest
import RunPlayCore
import RunPlayPlatform
@testable import RunPlayStudio

final class ComparisonProjectionTests: XCTestCase {

    let service = ComparisonRouteProjectionService()

    // MARK: - Basic Projection

    func testSharedProjectionReturnsFiniteCoordinates() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 20)

        let result = service.project(primary: primary, comparison: comparison)

        for point in result.primaryRoute {
            XCTAssertTrue(point.xMeters.isFinite, "Primary x should be finite")
            XCTAssertTrue(point.yMeters.isFinite, "Primary y should be finite")
            XCTAssertTrue(point.zMeters.isFinite, "Primary z should be finite")
            XCTAssertFalse(point.xMeters.isNaN, "Primary x should not be NaN")
            XCTAssertFalse(point.yMeters.isNaN, "Primary y should not be NaN")
            XCTAssertFalse(point.zMeters.isNaN, "Primary z should not be NaN")
        }

        for point in result.comparisonRoute {
            XCTAssertTrue(point.xMeters.isFinite, "Comparison x should be finite")
            XCTAssertTrue(point.yMeters.isFinite, "Comparison y should be finite")
            XCTAssertTrue(point.zMeters.isFinite, "Comparison z should be finite")
            XCTAssertFalse(point.xMeters.isNaN, "Comparison x should not be NaN")
            XCTAssertFalse(point.yMeters.isNaN, "Comparison y should not be NaN")
            XCTAssertFalse(point.zMeters.isNaN, "Comparison z should not be NaN")
        }
    }

    func testPrimaryAndComparisonUseSameOrigin() {
        // Both routes start at the same location — their first points should
        // project to the same coordinates since they share the same origin.
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 10)
        let comparison = createRoute(startLat: 37.7749, startLon: -122.4194, count: 10)

        let result = service.project(primary: primary, comparison: comparison)

        // First points of each route at same lat/lon should be at the same x/z
        XCTAssertEqual(result.primaryRoute[0].xMeters, result.comparisonRoute[0].xMeters, accuracy: 0.01,
                       "Same-location points should share x coordinate")
        XCTAssertEqual(result.primaryRoute[0].zMeters, result.comparisonRoute[0].zMeters, accuracy: 0.01,
                       "Same-location points should share z coordinate")
    }

    func testCombinedBoundsIncludeBothRoutes() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7800, startLon: -122.4200, count: 20)

        let result = service.project(primary: primary, comparison: comparison)

        // Combined bounds should encompass all points
        for point in result.primaryRoute {
            XCTAssertGreaterThanOrEqual(point.xMeters, result.combinedBounds.min.x - 0.01)
            XCTAssertLessThanOrEqual(point.xMeters, result.combinedBounds.max.x + 0.01)
            XCTAssertGreaterThanOrEqual(point.zMeters, result.combinedBounds.min.z - 0.01)
            XCTAssertLessThanOrEqual(point.zMeters, result.combinedBounds.max.z + 0.01)
        }

        for point in result.comparisonRoute {
            XCTAssertGreaterThanOrEqual(point.xMeters, result.combinedBounds.min.x - 0.01)
            XCTAssertLessThanOrEqual(point.xMeters, result.combinedBounds.max.x + 0.01)
            XCTAssertGreaterThanOrEqual(point.zMeters, result.combinedBounds.min.z - 0.01)
            XCTAssertLessThanOrEqual(point.zMeters, result.combinedBounds.max.z + 0.01)
        }
    }

    // MARK: - Different Route Lengths

    func testDifferentRouteLengthsDoNotCrash() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 100)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 10)

        let result = service.project(primary: primary, comparison: comparison)

        XCTAssertEqual(result.primaryRoute.count, 100)
        XCTAssertEqual(result.comparisonRoute.count, 10)
        XCTAssertTrue(result.hasValidRoutes)
    }

    func testVeryDifferentRouteLengthsDoNotCrash() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 500)
        let comparison = createRoute(startLat: 37.7800, startLon: -122.4200, count: 3)

        let result = service.project(primary: primary, comparison: comparison)

        XCTAssertEqual(result.primaryRoute.count, 500)
        XCTAssertEqual(result.comparisonRoute.count, 3)
    }

    // MARK: - Empty/Invalid Routes

    func testEmptyPrimaryReturnsWarning() {
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 10)

        let result = service.project(primary: [], comparison: comparison)

        XCTAssertTrue(result.primaryRoute.isEmpty)
        XCTAssertTrue(result.warnings.contains(.tooFewPoints))
        XCTAssertFalse(result.hasPrimaryRoute)
    }

    func testEmptyComparisonReturnsWarning() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 10)

        let result = service.project(primary: primary, comparison: [])

        XCTAssertTrue(result.comparisonRoute.isEmpty)
        XCTAssertTrue(result.warnings.contains(.tooFewPoints))
        XCTAssertTrue(result.hasPrimaryRoute)
        XCTAssertFalse(result.hasComparisonRoute)
    }

    func testBothEmptyReturnsWarning() {
        let result = service.project(primary: [], comparison: [])

        XCTAssertTrue(result.primaryRoute.isEmpty)
        XCTAssertTrue(result.comparisonRoute.isEmpty)
        XCTAssertTrue(result.warnings.contains(.tooFewPoints))
        XCTAssertFalse(result.hasValidRoutes)
    }

    func testSinglePointRouteProjects() {
        let primary = [createPoint(lat: 37.7749, lon: -122.4194, alt: 10)]
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 10)

        let result = service.project(primary: primary, comparison: comparison)

        XCTAssertEqual(result.primaryRoute.count, 1)
        XCTAssertFalse(result.hasPrimaryRoute) // Need >= 2 for polyline
        XCTAssertTrue(result.hasComparisonRoute)
    }

    // MARK: - Elevation Exaggeration

    func testElevationExaggerationAppliesConsistently() {
        var svc = ComparisonRouteProjectionService()
        svc.elevationExaggeration = 3.0

        let primary = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7750, lon: -122.4193, alt: 30)
        ]
        let comparison = [
            createPoint(lat: 37.7751, lon: -122.4195, alt: 10),
            createPoint(lat: 37.7752, lon: -122.4194, alt: 50)
        ]

        let result = svc.project(primary: primary, comparison: comparison)

        // Primary: 20m elevation diff * 3x = 60m
        let primaryDiff = result.primaryRoute[1].yMeters - result.primaryRoute[0].yMeters
        XCTAssertEqual(primaryDiff, 60, accuracy: 1)

        // Comparison: 40m elevation diff * 3x = 120m
        let compDiff = result.comparisonRoute[1].yMeters - result.comparisonRoute[0].yMeters
        XCTAssertEqual(compDiff, 120, accuracy: 1)
    }

    func testElevationExaggeration1x() {
        var svc = ComparisonRouteProjectionService()
        svc.elevationExaggeration = 1.0

        let primary = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: 37.7750, lon: -122.4193, alt: 30)
        ]
        let comparison = [
            createPoint(lat: 37.7751, lon: -122.4195, alt: 10),
            createPoint(lat: 37.7752, lon: -122.4194, alt: 50)
        ]

        let result = svc.project(primary: primary, comparison: comparison)

        let primaryDiff = result.primaryRoute[1].yMeters - result.primaryRoute[0].yMeters
        XCTAssertEqual(primaryDiff, 20, accuracy: 1)

        let compDiff = result.comparisonRoute[1].yMeters - result.comparisonRoute[0].yMeters
        XCTAssertEqual(compDiff, 40, accuracy: 1)
    }

    // MARK: - Warnings Passthrough

    func testExistingWarningsPassthrough() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 10)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 10)

        let result = service.project(
            primary: primary,
            comparison: comparison,
            existingWarnings: [.differentDistances, .differentRouteShape]
        )

        XCTAssertTrue(result.warnings.contains(.differentDistances))
        XCTAssertTrue(result.warnings.contains(.differentRouteShape))
    }

    // MARK: - NaN/Invalid Coordinates

    func testNaNCoordinatesFiltered() {
        let primary = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: 10),
            createPoint(lat: Double.nan, lon: -122.4193, alt: 15),
            createPoint(lat: 37.7751, lon: -122.4192, alt: 20)
        ]
        let comparison = [
            createPoint(lat: 37.7752, lon: -122.4195, alt: 10),
            createPoint(lat: 37.7753, lon: Double.infinity, alt: 15),
            createPoint(lat: 37.7754, lon: -122.4193, alt: 20)
        ]

        let result = service.project(primary: primary, comparison: comparison)

        // Should filter out invalid points
        XCTAssertEqual(result.primaryRoute.count, 2)
        XCTAssertEqual(result.comparisonRoute.count, 2)

        // All remaining should be finite
        for point in result.primaryRoute + result.comparisonRoute {
            XCTAssertTrue(point.xMeters.isFinite)
            XCTAssertTrue(point.yMeters.isFinite)
            XCTAssertTrue(point.zMeters.isFinite)
        }
    }

    func testNoNaNInProjectedCoordinates() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 30)
        let comparison = createRoute(startLat: 37.7800, startLon: -122.4200, count: 25)

        let result = service.project(primary: primary, comparison: comparison)

        let allPoints = result.primaryRoute + result.comparisonRoute
        for point in allPoints {
            XCTAssertFalse(point.xMeters.isNaN, "xMeters should not be NaN")
            XCTAssertFalse(point.yMeters.isNaN, "yMeters should not be NaN")
            XCTAssertFalse(point.zMeters.isNaN, "zMeters should not be NaN")
        }
    }

    // MARK: - Missing Elevation

    func testMissingElevationHandled() {
        let primary = [
            createPoint(lat: 37.7749, lon: -122.4194, alt: nil),
            createPoint(lat: 37.7750, lon: -122.4193, alt: nil)
        ]
        let comparison = [
            createPoint(lat: 37.7751, lon: -122.4195, alt: nil),
            createPoint(lat: 37.7752, lon: -122.4194, alt: nil)
        ]

        let result = service.project(primary: primary, comparison: comparison)

        // All y values should be 0 (no elevation data)
        for point in result.primaryRoute + result.comparisonRoute {
            XCTAssertEqual(point.yMeters, 0, accuracy: 0.01)
        }
    }

    // MARK: - ComparisonRouteScene Model

    func testHasValidRoutes() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 10)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 10)

        let result = service.project(primary: primary, comparison: comparison)

        XCTAssertTrue(result.hasValidRoutes)
        XCTAssertTrue(result.hasPrimaryRoute)
        XCTAssertTrue(result.hasComparisonRoute)
    }

    func testMaxExtentIsFinite() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7800, startLon: -122.4200, count: 15)

        let result = service.project(primary: primary, comparison: comparison)

        XCTAssertTrue(result.maxExtent.isFinite)
        XCTAssertGreaterThan(result.maxExtent, 0)
    }

    func testCenterIsFinite() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7800, startLon: -122.4200, count: 15)

        let result = service.project(primary: primary, comparison: comparison)

        XCTAssertTrue(result.center.x.isFinite)
        XCTAssertTrue(result.center.y.isFinite)
        XCTAssertTrue(result.center.z.isFinite)
    }

    // MARK: - Demo Fixtures

    func testDemoComparisonFixturesProduceScene() throws {
        let primary = try loadFixture("sample_run.json")
        let comparison = try loadFixture("fixtures/comparison_park_run.json")

        let result = service.project(primary: primary.routePoints, comparison: comparison.routePoints)

        XCTAssertTrue(result.hasPrimaryRoute)
        XCTAssertTrue(result.hasComparisonRoute)
        XCTAssertTrue(result.hasValidRoutes)
        XCTAssertTrue(result.maxExtent.isFinite)
        XCTAssertTrue(result.center.x.isFinite)

        // All projected points should be finite
        for point in result.primaryRoute + result.comparisonRoute {
            XCTAssertTrue(point.xMeters.isFinite)
            XCTAssertTrue(point.yMeters.isFinite)
            XCTAssertTrue(point.zMeters.isFinite)
        }
    }

    // MARK: - Scene Builder Integration

    func testComparisonSceneBuilderProducesScene() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 15)

        let comparisonScene = service.project(primary: primary, comparison: comparison)
        let builder = ComparisonSceneBuilder()
        let scene = builder.buildScene(from: comparisonScene)

        // Scene should have child nodes (routes, markers, grid, legend)
        XCTAssertGreaterThan(scene.rootNode.childNodes.count, 0)
    }

    func testComparisonSceneBuilderBoundingBox() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 15)

        let comparisonScene = service.project(primary: primary, comparison: comparison)
        let builder = ComparisonSceneBuilder()
        let bbox = builder.routeBoundingBox(for: comparisonScene)

        XCTAssertTrue(bbox.center.x.isFinite)
        XCTAssertTrue(bbox.center.y.isFinite)
        XCTAssertTrue(bbox.center.z.isFinite)
        XCTAssertTrue(bbox.extent.isFinite)
        XCTAssertGreaterThan(bbox.extent, 0)
    }

    func testComparisonSceneBuilderTogglesGridAfterBuild() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 15)

        let comparisonScene = service.project(primary: primary, comparison: comparison)
        let builder = ComparisonSceneBuilder()
        let scene = builder.buildScene(from: comparisonScene)

        XCTAssertFalse(scene.rootNode.childNodes.contains { $0.isHidden })

        builder.showGroundGrid = false

        XCTAssertTrue(scene.rootNode.childNodes.contains { $0.isHidden })
    }

    func testComparisonSceneBuilderDistanceMarkers() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 15)

        let comparisonScene = service.project(primary: primary, comparison: comparison)
        let builder = ComparisonSceneBuilder()
        let scene = builder.buildScene(from: comparisonScene)
        let baseCount = scene.rootNode.childNodes.count

        let primaryPoint = comparisonScene.primaryRoute[5]
        let comparisonPoint = comparisonScene.comparisonRoute[3]

        builder.updateDistanceMarkers(in: scene, primaryPoint: primaryPoint, comparisonPoint: comparisonPoint)

        // Should add 2 marker nodes
        XCTAssertEqual(scene.rootNode.childNodes.count, baseCount + 2)
    }

    func testComparisonSceneBuilderDistanceMarkersNil() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 15)

        let comparisonScene = service.project(primary: primary, comparison: comparison)
        let builder = ComparisonSceneBuilder()
        let scene = builder.buildScene(from: comparisonScene)
        let baseCount = scene.rootNode.childNodes.count

        builder.updateDistanceMarkers(in: scene, primaryPoint: nil, comparisonPoint: nil)

        // No markers added
        XCTAssertEqual(scene.rootNode.childNodes.count, baseCount)
    }

    func testComparisonSceneBuilderDistanceMarkersUpdate() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7750, startLon: -122.4195, count: 15)

        let comparisonScene = service.project(primary: primary, comparison: comparison)
        let builder = ComparisonSceneBuilder()
        let scene = builder.buildScene(from: comparisonScene)

        // First update
        builder.updateDistanceMarkers(
            in: scene,
            primaryPoint: comparisonScene.primaryRoute[3],
            comparisonPoint: comparisonScene.comparisonRoute[2]
        )
        let countAfterFirst = scene.rootNode.childNodes.count

        // Second update should replace markers, not add more
        builder.updateDistanceMarkers(
            in: scene,
            primaryPoint: comparisonScene.primaryRoute[10],
            comparisonPoint: comparisonScene.comparisonRoute[8]
        )
        XCTAssertEqual(scene.rootNode.childNodes.count, countAfterFirst)
    }

    // MARK: - Helpers

    private func createRoute(startLat: Double, startLon: Double, count: Int) -> [RoutePoint] {
        (0..<count).map { i in
            let fraction = Double(i) / Double(max(count - 1, 1))
            return RoutePoint(
                timestamp: Date().addingTimeInterval(Double(i) * 5),
                latitude: startLat + fraction * 0.01,
                longitude: startLon + fraction * 0.005,
                altitudeMeters: 10 + fraction * 30,
                distanceFromStartMeters: fraction * 5000,
                elapsedSeconds: fraction * 1500,
                heartRateBPM: 120 + fraction * 40
            )
        }
    }

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

    private func loadFixture(_ path: String) throws -> RunWorkout {
        let testFile = URL(fileURLWithPath: #filePath)
        let url = testFile
            .deletingLastPathComponent()  // ComparisonProjectionTests
            .deletingLastPathComponent()  // RunPlayStudioTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Resources")
            .appendingPathComponent(path)
        return try JSONWorkoutImporter().importWorkout(from: url)
    }
}
