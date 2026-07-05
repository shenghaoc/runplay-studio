import Foundation
import SceneKit

/// Controls the camera for the 3D route scene.
///
/// Provides orbit, pan, and zoom functionality with a reset capability.
class SceneCameraController: ObservableObject {

    // MARK: - Published State

    @Published var cameraDistance: Float = 500
    @Published var cameraAngleX: Float = -30 // degrees
    @Published var cameraAngleY: Float = 45  // degrees

    // MARK: - Configuration

    let minDistance: Float = 50
    let maxDistance: Float = 2000
    let minAngleX: Float = -89
    let maxAngleX: Float = -1

    // MARK: - Camera Node

    private var cameraNode: SCNNode?

    /// Set up camera in a scene.
    func setupCamera(in scene: SCNScene, lookingAt center: SCNVector3) {
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 60

        let node = SCNNode()
        node.camera = camera
        scene.rootNode.addChildNode(node)
        cameraNode = node

        updateCameraPosition(lookingAt: center)
    }

    /// Update camera position based on current angles and distance.
    func updateCameraPosition(lookingAt target: SCNVector3) {
        guard let camera = cameraNode else { return }

        let angleXRad = cameraAngleX * .pi / 180
        let angleYRad = cameraAngleY * .pi / 180

        let x = target.x + cameraDistance * cos(angleXRad) * sin(angleYRad)
        let y = target.y + cameraDistance * sin(angleXRad)
        let z = target.z + cameraDistance * cos(angleXRad) * cos(angleYRad)

        camera.position = SCNVector3(x, y, z)
        camera.look(at: target)
    }

    /// Orbit by delta angles.
    func orbit(deltaX: Float, deltaY: Float) {
        cameraAngleY += deltaX
        cameraAngleX = max(minAngleX, min(maxAngleX, cameraAngleX + deltaY))
    }

    /// Zoom by delta (positive = zoom in).
    func zoom(delta: Float) {
        cameraDistance = max(minDistance, min(maxDistance, cameraDistance - delta))
    }

    /// Reset camera to default position.
    func reset() {
        cameraDistance = 500
        cameraAngleX = -30
        cameraAngleY = 45
    }

    /// Focus camera on a specific route point.
    func focusOn(point: RouteScenePoint, distance: Float = 200) {
        cameraDistance = distance
        updateCameraPosition(lookingAt: SCNVector3(Float(point.xMeters), Float(point.yMeters), Float(point.zMeters)))
    }
}
