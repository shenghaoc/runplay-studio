import SceneKit
import XCTest
@testable import RunPlayStudio

final class SceneCameraControllerTests: XCTestCase {

    func testSetupCameraInstallsActivePointOfView() {
        let scene = SCNScene()
        let controller = SceneCameraController()

        let cameraNode = controller.setupCamera(in: scene, lookingAt: SCNVector3(10, 20, -30))

        guard let activeCameraNode = controller.activeCameraNode else {
            XCTFail("Expected active camera node after setup")
            return
        }
        XCTAssertTrue(activeCameraNode === cameraNode)
        XCTAssertNotNil(cameraNode.camera)
        XCTAssertTrue(scene.rootNode.childNodes.contains { $0 === cameraNode })
        assertFinite(cameraNode.position)
    }

    func testFitToRouteProducesFiniteCameraPosition() {
        let scene = SCNScene()
        let controller = SceneCameraController()
        let cameraNode = controller.setupCamera(in: scene, lookingAt: SCNVector3Zero)

        controller.fitToRoute(center: SCNVector3(100, 25, -75), extent: 1_000)

        XCTAssertGreaterThanOrEqual(controller.cameraDistance, controller.minDistance)
        XCTAssertLessThanOrEqual(controller.cameraDistance, controller.maxDistance)
        XCTAssertEqual(controller.cameraAngleX, -30)
        XCTAssertEqual(controller.cameraAngleY, 45)
        assertFinite(cameraNode.position)
    }

    func testFitToRouteHandlesInvalidBoundsSafely() {
        let scene = SCNScene()
        let controller = SceneCameraController()
        let cameraNode = controller.setupCamera(in: scene, lookingAt: SCNVector3Zero)

        controller.fitToRoute(
            center: SCNVector3(CGFloat.nan, CGFloat.infinity, -CGFloat.infinity),
            extent: CGFloat.nan
        )

        XCTAssertTrue(controller.cameraDistance.isFinite)
        XCTAssertGreaterThanOrEqual(controller.cameraDistance, controller.minDistance)
        XCTAssertLessThanOrEqual(controller.cameraDistance, controller.maxDistance)
        assertFinite(cameraNode.position)
    }

    func testFitToRouteHandlesFlatRouteExtent() {
        let scene = SCNScene()
        let controller = SceneCameraController()
        let cameraNode = controller.setupCamera(in: scene, lookingAt: SCNVector3(3, 0, 4))

        controller.fitToRoute(center: SCNVector3(3, 0, 4), extent: 0)

        XCTAssertTrue(controller.cameraDistance.isFinite)
        XCTAssertGreaterThanOrEqual(controller.cameraDistance, controller.minDistance)
        assertFinite(cameraNode.position)
    }

    func testFitToRouteClampsVeryLargeRouteExtent() {
        let scene = SCNScene()
        let controller = SceneCameraController()
        let cameraNode = controller.setupCamera(in: scene, lookingAt: SCNVector3Zero)

        controller.fitToRoute(center: SCNVector3(0, 500, 0), extent: 100_000)

        XCTAssertEqual(controller.cameraDistance, controller.maxDistance)
        assertFinite(cameraNode.position)
    }

    func testPresetViewsProduceFiniteCameraPositions() {
        let scene = SCNScene()
        let controller = SceneCameraController()
        let cameraNode = controller.setupCamera(in: scene, lookingAt: SCNVector3(50, 10, -20))
        controller.fitToRoute(center: SCNVector3(50, 10, -20), extent: 800)

        for preset in [CameraPreset.default, .topDown, .side, .front] {
            controller.setPresetView(preset)
            assertFinite(cameraNode.position)
        }
    }

    func testZoomRejectsNonFiniteDelta() {
        let scene = SCNScene()
        let controller = SceneCameraController()
        let cameraNode = controller.setupCamera(in: scene, lookingAt: SCNVector3Zero)

        controller.zoom(delta: CGFloat.infinity)

        XCTAssertTrue(controller.cameraDistance.isFinite)
        XCTAssertEqual(controller.cameraDistance, 500)
        assertFinite(cameraNode.position)
    }

    func testComparisonRouteBoundsCanDriveCameraFit() {
        let primary = createRoute(startLat: 37.7749, startLon: -122.4194, count: 20)
        let comparison = createRoute(startLat: 37.7752, startLon: -122.4198, count: 18)
        let comparisonScene = ComparisonRouteProjectionService().project(
            primary: primary,
            comparison: comparison
        )
        let builder = ComparisonSceneBuilder()
        let scene = builder.buildScene(from: comparisonScene)
        let bbox = builder.routeBoundingBox(for: comparisonScene)
        let controller = SceneCameraController()

        let cameraNode = controller.setupCamera(in: scene, lookingAt: bbox.center)
        controller.fitToRoute(center: bbox.center, extent: bbox.extent)

        XCTAssertTrue(comparisonScene.hasValidRoutes)
        XCTAssertTrue(bbox.center.x.isFinite)
        XCTAssertTrue(bbox.center.y.isFinite)
        XCTAssertTrue(bbox.center.z.isFinite)
        XCTAssertTrue(bbox.extent.isFinite)
        XCTAssertGreaterThan(bbox.extent, 0)
        XCTAssertTrue(controller.activeCameraNode === cameraNode)
        XCTAssertTrue(scene.rootNode.childNodes.contains { $0 === cameraNode })
        assertFinite(cameraNode.position)
    }

    // MARK: - Helpers

    private func createRoute(startLat: Double, startLon: Double, count: Int) -> [RoutePoint] {
        (0..<count).map { index in
            let fraction = Double(index) / Double(max(count - 1, 1))
            return RoutePoint(
                timestamp: Date().addingTimeInterval(Double(index) * 5),
                latitude: startLat + fraction * 0.01,
                longitude: startLon + fraction * 0.005,
                altitudeMeters: 10 + fraction * 40,
                distanceFromStartMeters: fraction * 5_000,
                elapsedSeconds: fraction * 1_500,
                paceSecondsPerKilometer: 300 + fraction * 20,
                heartRateBPM: 120 + fraction * 35
            )
        }
    }

    private func assertFinite(_ vector: SCNVector3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(vector.x.isFinite, "Expected finite x", file: file, line: line)
        XCTAssertTrue(vector.y.isFinite, "Expected finite y", file: file, line: line)
        XCTAssertTrue(vector.z.isFinite, "Expected finite z", file: file, line: line)
    }
}
