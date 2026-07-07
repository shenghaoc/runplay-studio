import Foundation
import RunPlayCore
import SceneKit

/// Controls the camera for the 3D route scene.
///
/// Provides orbit, pan, and zoom functionality with a reset capability.
///
/// Camera angle convention:
/// - `cameraAngleX`: elevation angle in degrees. Positive = camera above target (looking down).
///   Range: 1° (nearly horizontal) to 89° (nearly straight down).
/// - `cameraAngleY`: azimuth angle in degrees. 0° = front, 90° = right side, etc.
class SceneCameraController: ObservableObject {

    // MARK: - Published State

    @Published var cameraDistance: CGFloat = 500
    @Published var cameraAngleX: CGFloat = 30  // degrees, positive = above
    @Published var cameraAngleY: CGFloat = 45  // degrees, azimuth
    @Published private(set) var activeCameraNode: SCNNode?

    // MARK: - Configuration

    let minDistance: CGFloat = 50
    let maxDistance: CGFloat = 2000
    let minAngleX: CGFloat = 1    // nearly horizontal
    let maxAngleX: CGFloat = 89   // nearly straight down

    // MARK: - Camera Node

    private var cameraNode: SCNNode?
    private var targetPoint: SCNVector3 = SCNVector3(0, 0, 0)

    /// Set up camera in a scene.
    @discardableResult
    func setupCamera(in scene: SCNScene, lookingAt center: SCNVector3) -> SCNNode {
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 60

        let node = SCNNode()
        node.camera = camera
        scene.rootNode.addChildNode(node)
        cameraNode = node
        activeCameraNode = node
        targetPoint = center

        updateCameraPosition(lookingAt: center)
        return node
    }

    /// Update camera position based on current angles and distance.
    func updateCameraPosition(lookingAt target: SCNVector3) {
        guard let camera = cameraNode else { return }
        targetPoint = Self.finiteVector(target, fallback: targetPoint)

        let angleXRad = cameraAngleX * .pi / 180
        let angleYRad = cameraAngleY * .pi / 180

        let safeDistance = Self.clampFinite(
            cameraDistance,
            min: minDistance,
            max: maxDistance,
            fallback: minDistance
        )
        cameraDistance = safeDistance

        let target = targetPoint
        // Positive angleX => camera above target
        let x = target.x + safeDistance * cos(angleXRad) * sin(angleYRad)
        let y = target.y + safeDistance * sin(angleXRad)
        let z = target.z + safeDistance * cos(angleXRad) * cos(angleYRad)

        camera.position = SCNVector3(x, y, z)
        camera.look(at: target)
    }

    /// Orbit by delta angles.
    func orbit(deltaX: CGFloat, deltaY: CGFloat) {
        cameraAngleY += deltaX
        // Negate deltaY so dragging up increases elevation (camera goes higher)
        cameraAngleX = max(minAngleX, min(maxAngleX, cameraAngleX - deltaY))
        updateCameraPosition(lookingAt: targetPoint)
    }

    /// Zoom by delta (positive = zoom in).
    func zoom(delta: CGFloat) {
        let safeDelta = delta.isFinite ? delta : 0
        cameraDistance = Self.clampFinite(
            cameraDistance - safeDelta,
            min: minDistance,
            max: maxDistance,
            fallback: minDistance
        )
        updateCameraPosition(lookingAt: targetPoint)
    }

    /// Reset camera to default position.
    func reset() {
        cameraDistance = 500
        cameraAngleX = 30
        cameraAngleY = 45
        updateCameraPosition(lookingAt: targetPoint)
    }

    /// Fit camera to show the entire route.
    func fitToRoute(center: SCNVector3, extent: CGFloat) {
        let safeCenter = Self.finiteVector(center, fallback: SCNVector3(0, 0, 0))
        let safeExtent = Self.clampFinite(extent, min: minDistance, max: maxDistance, fallback: minDistance)
        let fov = Self.clampFinite(
            CGFloat(cameraNode?.camera?.fieldOfView ?? 60),
            min: 10,
            max: 120,
            fallback: 60
        )
        let fovRad = fov * .pi / 180
        let distance = safeExtent / (2 * tan(fovRad / 2)) * 1.35

        targetPoint = safeCenter
        cameraDistance = Self.clampFinite(distance, min: minDistance, max: maxDistance, fallback: minDistance)
        cameraAngleX = 30
        cameraAngleY = 45

        updateCameraPosition(lookingAt: safeCenter)
    }

    /// Focus camera on a specific route point.
    func focusOn(point: RouteScenePoint, distance: CGFloat = 200) {
        let target = SCNVector3(point.xMeters, point.yMeters, point.zMeters)
        cameraDistance = Self.clampFinite(distance, min: minDistance, max: maxDistance, fallback: 200)
        updateCameraPosition(lookingAt: target)
    }

    /// Set preset view angles.
    func setPresetView(_ preset: CameraPreset) {
        switch preset {
        case .default:
            cameraAngleX = 30
            cameraAngleY = 45
        case .topDown:
            cameraAngleX = 85  // Nearly straight down
            cameraAngleY = 0
        case .side:
            cameraAngleX = 5   // Nearly horizontal, low angle
            cameraAngleY = 90  // Right side (perpendicular to route)
        case .front:
            cameraAngleX = 10  // Slightly above
            cameraAngleY = 0   // Front (along route direction)
        }
        updateCameraPosition(lookingAt: targetPoint)
    }

    // MARK: - Helpers

    private static func finiteVector(_ vector: SCNVector3, fallback: SCNVector3) -> SCNVector3 {
        guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
            return fallback
        }
        return vector
    }

    private static func clampFinite(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return max(minValue, min(maxValue, value))
    }
}

enum CameraPreset {
    case `default`
    case topDown
    case side
    case front
}
