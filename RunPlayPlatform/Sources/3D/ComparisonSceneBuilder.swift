import Foundation
import RunPlayCore
import SceneKit


/// Builds a SceneKit scene for 3D route comparison visualization.
///
/// Renders two routes in the same 3D space with distinct colors and markers:
/// - Primary route (blue) with green start / red finish markers
/// - Comparison route (orange) with cyan start / magenta finish markers
/// - Shared ground grid sized for both routes
/// - Legend text identifying each route
public class ComparisonSceneBuilder {

    // MARK: - Configuration

    public var primaryRouteColor: NSColor = .systemBlue
    public var comparisonRouteColor: NSColor = .systemOrange
    public var routeRadius: CGFloat = 0.8
    public var markerRadius: CGFloat = 2.0
    public var showGroundGrid: Bool = true { didSet { updateGridVisibility() } }

    public init() {}

    // MARK: - Scene Elements

    private var gridNode: SCNNode?
    private var primaryRouteNode: SCNNode?
    private var comparisonRouteNode: SCNNode?
    private var primaryDistanceMarkerNode: SCNNode?
    private var comparisonDistanceMarkerNode: SCNNode?

    private let minSegmentLength: Float = 0.01

    // MARK: - Build Scene

    /// Build a complete 3D comparison scene from a `ComparisonRouteScene`.
    public func buildScene(from comparisonScene: ComparisonRouteScene) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.windowBackgroundColor

        setupLighting(in: scene)

        // Ground grid sized for combined bounds
        let grid = createGroundGrid(bounds: comparisonScene.combinedBounds)
        gridNode = grid
        grid.isHidden = !showGroundGrid
        scene.rootNode.addChildNode(grid)

        // Primary route
        if comparisonScene.hasPrimaryRoute {
            let primaryRoute = createRoute(from: comparisonScene.primaryRoute, color: primaryRouteColor)
            primaryRouteNode = primaryRoute
            scene.rootNode.addChildNode(primaryRoute)

            // Primary start marker
            if let firstPoint = comparisonScene.primaryRoute.first {
                let primaryStart = createStartMarker(at: firstPoint, color: .systemGreen, label: "P START")
                scene.rootNode.addChildNode(primaryStart)
            }

            // Primary finish marker
            if let lastPoint = comparisonScene.primaryRoute.last {
                let primaryFinish = createFinishMarker(at: lastPoint, color: .systemRed, label: "P FINISH")
                scene.rootNode.addChildNode(primaryFinish)
            }
        }

        // Comparison route
        if comparisonScene.hasComparisonRoute {
            let compRoute = createRoute(from: comparisonScene.comparisonRoute, color: comparisonRouteColor)
            comparisonRouteNode = compRoute
            scene.rootNode.addChildNode(compRoute)

            // Comparison start marker
            if let firstPoint = comparisonScene.comparisonRoute.first {
                let compStart = createStartMarker(at: firstPoint, color: .systemTeal, label: "C START")
                scene.rootNode.addChildNode(compStart)
            }

            // Comparison finish marker
            if let lastPoint = comparisonScene.comparisonRoute.last {
                let compFinish = createFinishMarker(at: lastPoint, color: .systemPurple, label: "C FINISH")
                scene.rootNode.addChildNode(compFinish)
            }
        }

        // Legend
        let legend = createLegendNode(comparisonScene: comparisonScene)
        scene.rootNode.addChildNode(legend)

        return scene
    }

    // MARK: - Bounding Box

    /// Get the bounding box for camera fitting from a comparison scene.
    public func routeBoundingBox(for comparisonScene: ComparisonRouteScene) -> (center: SCNVector3, extent: CGFloat) {
        let center = SCNVector3(
            CGFloat(comparisonScene.center.x),
            CGFloat(comparisonScene.center.y),
            CGFloat(comparisonScene.center.z)
        )
        let extent = CGFloat(comparisonScene.maxExtent)
        return (center, extent)
    }

    // MARK: - Visibility Toggles

    private func updateGridVisibility() {
        gridNode?.isHidden = !showGroundGrid
    }

    // MARK: - Distance Markers

    public var primaryDistanceMarkerColor: NSColor = .systemBlue
    public var comparisonDistanceMarkerColor: NSColor = .systemOrange
    public var distanceMarkerRadius: CGFloat = 1.5

    /// Update the distance markers in the scene at the given interpolated points.
    ///
    /// Removes any existing distance markers and adds new ones.
    /// Pass `nil` for a point to hide that marker.
    public func updateDistanceMarkers(
        in scene: SCNScene,
        primaryPoint: RouteScenePoint?,
        comparisonPoint: RouteScenePoint?
    ) {
        primaryDistanceMarkerNode?.removeFromParentNode()
        comparisonDistanceMarkerNode?.removeFromParentNode()
        primaryDistanceMarkerNode = nil
        comparisonDistanceMarkerNode = nil

        if let point = primaryPoint {
            let marker = createDistanceMarker(
                at: point,
                color: primaryDistanceMarkerColor,
                label: "P \(formatDistanceLabel(point.distanceFromStartMeters))"
            )
            primaryDistanceMarkerNode = marker
            scene.rootNode.addChildNode(marker)
        }

        if let point = comparisonPoint {
            let marker = createDistanceMarker(
                at: point,
                color: comparisonDistanceMarkerColor,
                label: "C \(formatDistanceLabel(point.distanceFromStartMeters))"
            )
            comparisonDistanceMarkerNode = marker
            scene.rootNode.addChildNode(marker)
        }
    }

    private func createDistanceMarker(at point: RouteScenePoint, color: NSColor, label: String) -> SCNNode {
        let parent = SCNNode()

        let sphere = SCNSphere(radius: distanceMarkerRadius)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .blinn
        sphere.firstMaterial?.specular.contents = NSColor.white
        parent.addChildNode(SCNNode(geometry: sphere))

        let glow = SCNSphere(radius: distanceMarkerRadius * 1.8)
        glow.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.3)
        glow.firstMaterial?.lightingModel = .constant
        parent.addChildNode(SCNNode(geometry: glow))

        let text = createTextSprite(label, color: color, fontSize: 2.0)
        text.position = SCNVector3(0, distanceMarkerRadius * 3, 0)
        parent.addChildNode(text)

        parent.position = SCNVector3(
            point.xMeters,
            point.yMeters + distanceMarkerRadius * 2,
            point.zMeters
        )
        return parent
    }

    private func formatDistanceLabel(_ meters: Double) -> String {
        String(format: "%.2f km", meters / 1000)
    }

    // MARK: - Lighting

    private func setupLighting(in scene: SCNScene) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.5, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor(white: 0.9, alpha: 1.0)
        keyLight.intensity = 800
        keyLight.castsShadow = true
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(keyNode)

        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.color = NSColor(white: 0.4, alpha: 1.0)
        fillLight.intensity = 300
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fillNode)

        let topLight = SCNLight()
        topLight.type = .omni
        topLight.color = NSColor(white: 0.3, alpha: 1.0)
        topLight.intensity = 400
        topLight.zFar = 2000
        let topNode = SCNNode()
        topNode.light = topLight
        topNode.position = SCNVector3(0, 300, 0)
        scene.rootNode.addChildNode(topNode)
    }

    // MARK: - Route Geometry

    private func createRoute(from points: [RouteScenePoint], color: NSColor) -> SCNNode {
        let parent = SCNNode()
        guard points.count >= 2 else { return parent }

        for i in 0..<(points.count - 1) {
            let from = points[i]
            let to = points[i + 1]

            // Don't draw a tube connecting two different route segments.
            guard from.routeSegmentIndex == to.routeSegmentIndex else { continue }

            let start = SCNVector3(from.xMeters, from.yMeters, from.zMeters)
            let end = SCNVector3(to.xMeters, to.yMeters, to.zMeters)

            let dx = end.x - start.x
            let dy = end.y - start.y
            let dz = end.z - start.z
            let length = sqrt(dx * dx + dy * dy + dz * dz)
            guard length >= CGFloat(minSegmentLength) else { continue }

            let tube = createTube(from: start, to: end, radius: routeRadius, color: color)
            parent.addChildNode(tube)
        }

        return parent
    }

    private func createTube(from start: SCNVector3, to end: SCNVector3, radius: CGFloat, color: NSColor) -> SCNNode {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        let distance = sqrt(dx * dx + dy * dy + dz * dz)

        guard distance > 0 else { return SCNNode() }

        let tube = SCNCylinder(radius: radius, height: distance)
        tube.radialSegmentCount = 8
        tube.firstMaterial?.diffuse.contents = color
        tube.firstMaterial?.lightingModel = .blinn
        tube.firstMaterial?.specular.contents = NSColor(white: 0.3, alpha: 1.0)

        let node = SCNNode(geometry: tube)
        node.position = SCNVector3(
            (start.x + end.x) / 2,
            (start.y + end.y) / 2,
            (start.z + end.z) / 2
        )

        let dir = simd_float3(Float(dx), Float(dy), Float(dz))
        let len = simd_length(dir)
        guard len > 0 else { return node }

        let dirNorm = dir / len
        let yAxis = simd_float3(0, 1, 0)
        let dotProduct = simd_dot(yAxis, dirNorm)

        if dotProduct > 0.999 {
            // Already aligned with Y
        } else if dotProduct < -0.999 {
            node.eulerAngles = SCNVector3(Float.pi, 0, 0)
        } else {
            let axis = simd_cross(yAxis, dirNorm)
            let angle = acos(min(1.0, max(-1.0, dotProduct)))
            node.rotation = SCNVector4(CGFloat(axis.x), CGFloat(axis.y), CGFloat(axis.z), CGFloat(angle))
        }

        return node
    }

    // MARK: - Markers

    private func createStartMarker(at point: RouteScenePoint, color: NSColor, label: String) -> SCNNode {
        let parent = SCNNode()

        let sphere = SCNSphere(radius: markerRadius * 1.5)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .blinn
        sphere.firstMaterial?.specular.contents = NSColor.white
        parent.addChildNode(SCNNode(geometry: sphere))

        let glow = SCNSphere(radius: markerRadius * 2.0)
        glow.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.2)
        glow.firstMaterial?.lightingModel = .constant
        parent.addChildNode(SCNNode(geometry: glow))

        let text = createTextSprite(label, color: color, fontSize: 2.0)
        text.position = SCNVector3(0, markerRadius * 3, 0)
        parent.addChildNode(text)

        parent.position = SCNVector3(point.xMeters, point.yMeters + markerRadius * 1.5, point.zMeters)
        return parent
    }

    private func createFinishMarker(at point: RouteScenePoint, color: NSColor, label: String) -> SCNNode {
        let parent = SCNNode()

        let sphere = SCNSphere(radius: markerRadius * 1.5)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .blinn
        sphere.firstMaterial?.specular.contents = NSColor.white
        parent.addChildNode(SCNNode(geometry: sphere))

        let glow = SCNSphere(radius: markerRadius * 2.0)
        glow.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.2)
        glow.firstMaterial?.lightingModel = .constant
        parent.addChildNode(SCNNode(geometry: glow))

        let text = createTextSprite(label, color: color, fontSize: 2.0)
        text.position = SCNVector3(0, markerRadius * 3, 0)
        parent.addChildNode(text)

        parent.position = SCNVector3(point.xMeters, point.yMeters + markerRadius * 1.5, point.zMeters)
        return parent
    }

    // MARK: - Legend

    private func createLegendNode(comparisonScene: ComparisonRouteScene) -> SCNNode {
        let parent = SCNNode()

        // Place legend above and to the side of the combined center
        let legendX = CGFloat(comparisonScene.combinedBounds.max.x) + 30
        let legendY = CGFloat(comparisonScene.combinedBounds.max.y) + 20
        let legendZ = CGFloat(comparisonScene.center.z)

        // Primary route label
        let primaryLabel = createTextSprite("Primary", color: primaryRouteColor, fontSize: 2.5)
        primaryLabel.position = SCNVector3(legendX, legendY, legendZ)
        parent.addChildNode(primaryLabel)

        // Primary color swatch
        let primarySwatch = SCNSphere(radius: 1.5)
        primarySwatch.firstMaterial?.diffuse.contents = primaryRouteColor
        primarySwatch.firstMaterial?.lightingModel = .constant
        let primarySwatchNode = SCNNode(geometry: primarySwatch)
        primarySwatchNode.position = SCNVector3(legendX - 10, legendY, legendZ)
        parent.addChildNode(primarySwatchNode)

        // Comparison route label
        let compLabel = createTextSprite("Comparison", color: comparisonRouteColor, fontSize: 2.5)
        compLabel.position = SCNVector3(legendX, legendY - 8, legendZ)
        parent.addChildNode(compLabel)

        // Comparison color swatch
        let compSwatch = SCNSphere(radius: 1.5)
        compSwatch.firstMaterial?.diffuse.contents = comparisonRouteColor
        compSwatch.firstMaterial?.lightingModel = .constant
        let compSwatchNode = SCNNode(geometry: compSwatch)
        compSwatchNode.position = SCNVector3(legendX - 10, legendY - 8, legendZ)
        parent.addChildNode(compSwatchNode)

        return parent
    }

    // MARK: - Text

    private func createTextSprite(_ text: String, color: NSColor, fontSize: CGFloat) -> SCNNode {
        let textGeometry = SCNText(string: text, extrusionDepth: 0.5)
        textGeometry.font = NSFont.boldSystemFont(ofSize: fontSize)
        textGeometry.firstMaterial?.diffuse.contents = color
        textGeometry.firstMaterial?.lightingModel = .constant
        textGeometry.flatness = 0.1

        let textNode = SCNNode(geometry: textGeometry)
        let (min, max) = textGeometry.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            (max.x - min.x) / 2 + min.x,
            (max.y - min.y) / 2 + min.y,
            (max.z - min.z) / 2 + min.z
        )

        return textNode
    }

    // MARK: - Ground Grid

    private func createGroundGrid(bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) -> SCNNode {
        let parent = SCNNode()

        let extent = max(
            bounds.max.x - bounds.min.x,
            bounds.max.z - bounds.min.z,
            100
        )

        let gridSpacing: CGFloat
        if extent < 500 {
            gridSpacing = 50
        } else if extent < 2000 {
            gridSpacing = 100
        } else {
            gridSpacing = 200
        }

        let gridSize = CGFloat(extent) * 0.8
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.3)

        let center = SCNVector3(
            CGFloat((bounds.min.x + bounds.max.x) / 2),
            CGFloat(bounds.min.y) - 1,
            CGFloat((bounds.min.z + bounds.max.z) / 2)
        )

        var i: CGFloat = -gridSize
        while i <= gridSize {
            let x = center.x + i
            let from = SCNVector3(x, center.y, center.z - gridSize)
            let to = SCNVector3(x, center.y, center.z + gridSize)
            let line = createLine(from: from, to: to, color: gridColor)
            parent.addChildNode(line)
            i += gridSpacing
        }

        i = -gridSize
        while i <= gridSize {
            let z = center.z + i
            let from = SCNVector3(center.x - gridSize, center.y, z)
            let to = SCNVector3(center.x + gridSize, center.y, z)
            let line = createLine(from: from, to: to, color: gridColor)
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
}
