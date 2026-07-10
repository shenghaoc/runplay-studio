import AppKit
import SceneKit

/// A rendered map image positioned in the same local meter-space as a route.
struct RouteMapOverlay {
    static let nodeName = "route-map-overlay"

    let image: NSImage
    let centerX: CGFloat
    let centerZ: CGFloat
    let widthMeters: CGFloat
    let heightMeters: CGFloat

    func makeSceneNode(groundY: CGFloat) -> SCNNode {
        let plane = SCNPlane(
            width: max(widthMeters, 1),
            height: max(heightMeters, 1)
        )
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.lightingModel = .constant
        material.isDoubleSided = true
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.name = Self.nodeName
        node.position = SCNVector3(centerX, groundY, centerZ)
        // SCNPlane is vertical by default. Rotate it onto X/Z so image north
        // (the top of an Apple Maps snapshot) points toward positive Z.
        node.eulerAngles.x = CGFloat.pi / 2
        node.castsShadow = false
        node.renderingOrder = -100
        return node
    }
}
