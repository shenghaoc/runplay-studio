import Foundation
import SceneKit

/// Controls the camera for the 3D route scene.
///
/// Provides orbit, pan, and zoom functionality with a reset capability.
class SceneCameraController: ObservableObject {

    // MARK: - Published State

    @Published var cameraDistance: CGFloat = 500
    @Published var cameraAngleX: CGFloat = -30 // degrees
    @Published var cameraAngleY: CGFloat = 45  // degrees

    // MARK: - Configuration

    let minDistance: CGFloat = 50
    let maxDistance: CGFloat = 2000
    let minAngleX: CGFloat = -89
    let maxAngleX: CGFloat = -1

    // MARK: - Camera Node

    private var cameraNode: SCNNode?
    private var targetPoint: SCNVector3 = SCNVector3(0, 0, 0)

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
        targetPoint = center

        updateCameraPosition(lookingAt: center)
    }

    /// Update camera position based on current angles and distance.
    func updateCameraPosition(lookingAt target: SCNVector3) {
        guard let camera = cameraNode else { return }
        targetPoint = target

        let angleXRad = cameraAngleX * .pi / 180
        let angleYRad = cameraAngleY * .pi / 180

        let x = target.x + cameraDistance * cos(angleXRad) * sin(angleYRad)
        let y = target.y + cameraDistance * sin(angleXRad)
        let z = target.z + cameraDistance * cos(angleXRad) * cos(angleYRad)

        camera.position = SCNVector3(x, y, z)
        camera.look(at: target)
    }

    /// Orbit by delta angles.
    func orbit(deltaX: CGFloat, deltaY: CGFloat) {
        cameraAngleY += deltaX
        cameraAngleX = max(minAngleX, min(maxAngleX, cameraAngleX + deltaY))
        updateCameraPosition(lookingAt: targetPoint)
    }

    /// Zoom by delta (positive = zoom in).
    func zoom(delta: CGFloat) {
        cameraDistance = max(minDistance, min(maxDistance, cameraDistance - delta))
        updateCameraPosition(lookingAt: targetPoint)
    }

    /// Reset camera to default position.
    func reset() {
        cameraDistance = 500
        cameraAngleX = -30
        cameraAngleY = 45
        updateCameraPosition(lookingAt: targetPoint)
    }

    /// Fit camera to show the entire route.
    func fitToRoute(center: SCNVector3, extent: CGFloat) {
        // Calculate distance needed to see the entire route
        let fov = cameraNode?.camera?.fieldOfView ?? 60
        let fovRad = fov * .pi / 180
        let distance = extent / (2 * tan(fovRad / 2)) * 1.2 // 20% margin

        targetPoint = center
        cameraDistance = max(minDistance, min(maxDistance, distance))
        cameraAngleX = -30
        cameraAngleY = 45

        updateCameraPosition(lookingAt: center)
    }

    /// Focus camera on a specific route point.
    func focusOn(point: RouteScenePoint, distance: CGFloat = 200) {
        let target = SCNVector3(point.xMeters, point.yMeters, point.zMeters)
        cameraDistance = distance
        updateCameraPosition(lookingAt: target)
    }

    /// Set preset view angles.
    func setPresetView(_ preset: CameraPreset) {
        switch preset {
        case .default:
            cameraAngleX = -30
            cameraAngleY = 45
        case .topDown:
            cameraAngleX = -89
            cameraAngleY = 0
        case .side:
            cameraAngleX = -5
            cameraAngleY = 0
        case .front:
            cameraAngleX = -10
            cameraAngleY = 90
        }
        updateCameraPosition(lookingAt: targetPoint)
    }
}

enum CameraPreset {
    case `default`
    case topDown
    case side
    case front
}
