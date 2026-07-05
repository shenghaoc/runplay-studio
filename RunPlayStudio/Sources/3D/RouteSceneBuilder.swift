import Foundation
import SceneKit

/// Builds a SceneKit scene for 3D route visualization.
///
/// Creates a stylized 3D route with:
/// - Route polyline as connected tubes
/// - Start marker (green sphere)
/// - Finish marker (red sphere)
/// - Current position marker (yellow sphere)
/// - Optional kilometer markers
/// - Ground grid plane
class RouteSceneBuilder {

    // MARK: - Configuration

    var routeColor: NSColor = .systemBlue
    var routeRadius: CGFloat = 0.8
    var startMarkerColor: NSColor = .systemGreen
    var finishMarkerColor: NSColor = .systemRed
    var currentMarkerColor: NSColor = .systemYellow
    var markerRadius: CGFloat = 2.0
    var showKilometerMarkers: Bool = true
    var showGroundGrid: Bool = true

    // MARK: - Scene Elements

    private var routeNode: SCNNode?
    private var startNode: SCNNode?
    private var finishNode: SCNNode?
    private var currentNode: SCNNode?
    private var kmMarkerNodes: [SCNNode] = []

    // MARK: - Build Scene

    /// Build a complete 3D scene from scene points.
    func buildScene(from points: [RouteScenePoint]) -> SCNScene {
        let scene = SCNScene()

        // Background
        scene.background.contents = NSColor.windowBackgroundColor

        // Lighting
        setupLighting(in: scene)

        // Ground grid
        if showGroundGrid {
            let grid = createGroundGrid(boundingBox: RouteProjectionService().boundingBox(of: points))
            scene.rootNode.addChildNode(grid)
        }

        // Route
        if !points.isEmpty {
            let route = createRoute(from: points)
            routeNode = route
            scene.rootNode.addChildNode(route)

            // Start marker
            let start = createMarker(at: points.first!, color: startMarkerColor, radius: markerRadius)
            startNode = start
            scene.rootNode.addChildNode(start)

            // Finish marker
            let finish = createMarker(at: points.last!, color: finishMarkerColor, radius: markerRadius)
            finishNode = finish
            scene.rootNode.addChildNode(finish)

            // Current position marker
            let current = createMarker(at: points.first!, color: currentMarkerColor, radius: markerRadius * 1.2)
            currentNode = current
            scene.rootNode.addChildNode(current)

            // Kilometer markers
            if showKilometerMarkers {
                let kmMarkers = createKilometerMarkers(from: points)
                kmMarkerNodes = kmMarkers
                kmMarkers.forEach { scene.rootNode.addChildNode($0) }
            }
        }

        return scene
    }

    /// Update the current position marker.
    func updateCurrentPosition(to point: RouteScenePoint) {
        let position = SCNVector3(point.xMeters, point.yMeters + markerRadius, point.zMeters)
        currentNode?.position = position
    }

    // MARK: - Private Builders

    private func setupLighting(in scene: SCNScene) {
        // Ambient light
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.6, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Directional light (sun)
        let directional = SCNLight()
        directional.type = .directional
        directional.color = NSColor(white: 0.8, alpha: 1.0)
        directional.intensity = 1000
        let dirNode = SCNNode()
        dirNode.light = directional
        dirNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(dirNode)

        // Point light above route
        let point = SCNLight()
        point.type = .omni
        point.color = NSColor(white: 0.5, alpha: 1.0)
        point.intensity = 500
        let pointNode = SCNNode()
        pointNode.light = point
        pointNode.position = SCNVector3(0, 200, 0)
        scene.rootNode.addChildNode(pointNode)
    }

    private func createRoute(from points: [RouteScenePoint]) -> SCNNode {
        let parent = SCNNode()

        guard points.count >= 2 else { return parent }

        // Create tubes between consecutive points
        for i in 0..<(points.count - 1) {
            let from = points[i]
            let to = points[i + 1]

            let start = SCNVector3(from.xMeters, from.yMeters, from.zMeters)
            let end = SCNVector3(to.xMeters, to.yMeters, to.zMeters)

            let tube = createTube(from: start, to: end, radius: routeRadius, color: routeColor)
            parent.addChildNode(tube)
        }

        return parent
    }

    private func createTube(from start: SCNVector3, to end: SCNVector3, radius: CGFloat, color: NSColor) -> SCNNode {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        let distance = sqrt(dx*dx + dy*dy + dz*dz)

        let tube = SCNCylinder(radius: radius, height: CGFloat(distance))
        tube.radialSegmentCount = 8
        tube.firstMaterial?.diffuse.contents = color
        tube.firstMaterial?.lightingModel = .blinn

        let node = SCNNode(geometry: tube)
        node.position = SCNVector3(
            (start.x + end.x) / 2,
            (start.y + end.y) / 2,
            (start.z + end.z) / 2
        )

        // Orient tube to point from start to end
        let dir = SCNVector3(dx, dy, dz)
        let up = SCNVector3(0, 1, 0)
        let right = cross(dir, up)
        let adjustedUp = cross(right, dir)

        let lookAt = SCNMatrix4MakeLookAt(
            0, 0, 0,
            CGFloat(dir.x), CGFloat(dir.y), CGFloat(dir.z),
            CGFloat(adjustedUp.x), CGFloat(adjustedUp.y), CGFloat(adjustedUp.z)
        )
        node.transform = SCNMatrix4Mult(lookAt, node.transform)

        return node
    }

    private func createMarker(at point: RouteScenePoint, color: NSColor, radius: CGFloat) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .blinn

        let node = SCNNode(geometry: sphere)
        node.position = SCNVector3(point.xMeters, point.yMeters + radius, point.zMeters)

        // Add glow effect
        let glow = SCNSphere(radius: radius * 1.3)
        glow.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.3)
        glow.firstMaterial?.lightingModel = .constant
        let glowNode = SCNNode(geometry: glow)
        node.addChildNode(glowNode)

        return node
    }

    private func createKilometerMarkers(from points: [RouteScenePoint]) -> [SCNNode] {
        var markers: [SCNNode] = []
        var nextKm: Double = 1000

        for point in points {
            if point.distanceFromStartMeters >= nextKm {
                let marker = createKmLabel(at: point, km: Int(nextKm / 1000))
                markers.append(marker)
                nextKm += 1000
            }
        }

        return markers
    }

    private func createKmLabel(at point: RouteScenePoint, km: Int) -> SCNNode {
        let text = SCNText(string: "\(km)k", extrusionDepth: 0.5)
        text.font = NSFont.boldSystemFont(ofSize: 3)
        text.firstMaterial?.diffuse.contents = NSColor.labelColor

        let node = SCNNode(geometry: text)
        node.position = SCNVector3(point.xMeters, point.yMeters + 5, point.zMeters)
        node.scale = SCNVector3(1, 1, 1)

        // Add a small sphere below the text
        let dot = SCNSphere(radius: 1.0)
        dot.firstMaterial?.diffuse.contents = NSColor.systemOrange
        let dotNode = SCNNode(geometry: dot)
        dotNode.position = SCNVector3(0, -2, 0)
        node.addChildNode(dotNode)

        return node
    }

    private func createGroundGrid(boundingBox: (min: SIMD3<Double>, max: SIMD3<Double>)) -> SCNNode {
        let parent = SCNNode()
        let gridSize: Float = 500
        let gridSpacing: Float = 50
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.3)

        let center = SCNVector3(
            Float((boundingBox.min.x + boundingBox.max.x) / 2),
            Float(boundingBox.min.y) - 1,
            Float((boundingBox.min.z + boundingBox.max.z) / 2)
        )

        // Create grid lines along X
        var i: Float = -gridSize
        while i <= gridSize {
            let line = createLine(
                from: SCNVector3(center.x + i, center.y, center.z - gridSize),
                to: SCNVector3(center.x + i, center.y, center.z + gridSize),
                color: gridColor
            )
            parent.addChildNode(line)
            i += gridSpacing
        }

        // Create grid lines along Z
        i = -gridSize
        while i <= gridSize {
            let line = createLine(
                from: SCNVector3(center.x - gridSize, center.y, center.z + i),
                to: SCNVector3(center.x + gridSize, center.y, center.z + i),
                color: gridColor
            )
            parent.addChildNode(line)
            i += gridSpacing
        }

        return parent
    }

    private func createLine(from start: SCNVector3, to end: SCNVector3, color: NSColor) -> SCNNode {
        let indices: [Int32] = [0, 1]
        let source = SCNGeometrySource(vertices: [start, end])
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)

        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.diffuse.contents = color

        return SCNNode(geometry: geometry)
    }

    private func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }

    private func SCNMatrix4MakeLookAt(
        _ eyeX: CGFloat, _ eyeY: CGFloat, _ eyeZ: CGFloat,
        _ centerX: CGFloat, _ centerY: CGFloat, _ centerZ: CGFloat,
        _ upX: CGFloat, _ upY: CGFloat, _ upZ: CGFloat
    ) -> SCNMatrix4 {
        var lookAt = SCNMatrix4MakeLookAt(
            SCNVector3(eyeX, eyeY, eyeZ),
            SCNVector3(centerX, centerY, centerZ),
            SCNVector3(upX, upY, upZ)
        )
        return lookAt
    }
}

// Helper extension for SCNMatrix4MakeLookAt with individual components
private extension SCNMatrix4 {
    init(eyeX: CGFloat, eyeY: CGFloat, eyeZ: CGFloat,
         centerX: CGFloat, centerY: CGFloat, centerZ: CGFloat,
         upX: CGFloat, upY: CGFloat, upZ: CGFloat) {
        self = SCNMatrix4MakeLookAt(
            SCNVector3(eyeX, eyeY, eyeZ),
            SCNVector3(centerX, centerY, centerZ),
            SCNVector3(upX, upY, upZ)
        )
    }
}
