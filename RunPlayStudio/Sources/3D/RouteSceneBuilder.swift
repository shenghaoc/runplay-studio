import Foundation
import RunPlayCore
import SceneKit
import RunPlayCore

/// Builds a SceneKit scene for 3D route visualization.
///
/// Creates a stylized 3D route with:
/// - Route polyline as connected tubes (skipping zero-length segments)
/// - Start marker (green sphere with label)
/// - Finish marker (red sphere with label)
/// - Current position marker (yellow cone indicating direction)
/// - Optional kilometer markers
/// - Adaptive ground grid
class RouteSceneBuilder {

    // MARK: - Configuration

    var routeColor: NSColor = .systemBlue
    var routeRadius: CGFloat = 0.8
    var startMarkerColor: NSColor = .systemGreen
    var finishMarkerColor: NSColor = .systemRed
    var currentMarkerColor: NSColor = .systemYellow
    var markerRadius: CGFloat = 2.0
    var showKilometerMarkers: Bool = true { didSet { updateKmMarkerVisibility() } }
    var showGroundGrid: Bool = true { didSet { updateGridVisibility() } }
    var colorMode: RouteColorMode = .singleColor

    /// The coloring service for computing segment colors.
    let coloringService = RouteColoringService()

    // MARK: - Scene Elements (for toggling)

    private var routeNode: SCNNode?
    private var startNode: SCNNode?
    private var finishNode: SCNNode?
    private var currentNode: SCNNode?
    private var kmMarkersNode: SCNNode?
    private var gridNode: SCNNode?
    private var segmentHighlightNode: SCNNode?
    private var scenePoints: [RouteScenePoint] = []

    // Minimum segment length to render (meters) - avoids degenerate geometry
    private let minSegmentLength: Float = 0.01

    // MARK: - Build Scene

    /// Build a complete 3D scene from scene points.
    func buildScene(from points: [RouteScenePoint]) -> SCNScene {
        self.scenePoints = points

        let scene = SCNScene()

        // Background
        scene.background.contents = NSColor.windowBackgroundColor

        // Lighting
        setupLighting(in: scene)

        // Ground grid
        let grid = createGroundGrid(points: points)
        gridNode = grid
        grid.isHidden = !showGroundGrid
        scene.rootNode.addChildNode(grid)

        // Route
        if !points.isEmpty {
            let route = createRoute(from: points)
            routeNode = route
            scene.rootNode.addChildNode(route)

            // Start marker
            let start = createStartMarker(at: points.first!)
            startNode = start
            scene.rootNode.addChildNode(start)

            // Finish marker
            let finish = createFinishMarker(at: points.last!)
            finishNode = finish
            scene.rootNode.addChildNode(finish)

            // Current position marker
            let current = createCurrentMarker(at: points.first!, direction: calculateDirection(at: 0))
            currentNode = current
            scene.rootNode.addChildNode(current)

            // Kilometer markers
            let kmMarkers = createKilometerMarkers(from: points)
            kmMarkersNode = kmMarkers
            kmMarkers.isHidden = !showKilometerMarkers
            scene.rootNode.addChildNode(kmMarkers)
        }

        return scene
    }

    /// Update the current position marker.
    func updateCurrentPosition(to point: RouteScenePoint) {
        guard let marker = currentNode else { return }

        // Position above route surface
        let position = SCNVector3(point.xMeters, point.yMeters + markerRadius * 2, point.zMeters)
        marker.position = position

        // Update direction if we have a source index
        if let index = scenePoints.firstIndex(where: { $0.id == point.id }) {
            let direction = calculateDirection(at: index)
            updateMarkerDirection(marker: marker, direction: direction)
        }
    }

    /// Highlight a segment on the 3D route.
    ///
    /// Creates a highlight tube above the route for the given distance range.
    /// Returns a node that should be added to the scene.
    @discardableResult
    func highlightSegment(_ segment: SegmentHighlight, in scene: SCNScene) -> SCNNode? {
        // Remove previous highlight
        segmentHighlightNode?.removeFromParentNode()
        segmentHighlightNode = nil

        guard !scenePoints.isEmpty else { return nil }

        // Find scene points within the segment distance range
        let startDist = segment.startDistanceMeters
        let endDist = segment.endDistanceMeters

        var segmentPoints: [RouteScenePoint] = []
        for point in scenePoints {
            if point.distanceFromStartMeters >= startDist && point.distanceFromStartMeters <= endDist {
                segmentPoints.append(point)
            }
        }

        guard segmentPoints.count >= 2 else { return nil }

        // Create highlight tube above the route
        let highlightNode = SCNNode()
        let highlightColor = segmentHighlightColor(for: segment.type)
        let highlightRadius: CGFloat = routeRadius * 1.8
        let yOffset: CGFloat = 1.5 // Above the route

        for i in 0..<(segmentPoints.count - 1) {
            let from = segmentPoints[i]
            let to = segmentPoints[i + 1]

            let start = SCNVector3(from.xMeters, from.yMeters + yOffset, from.zMeters)
            let end = SCNVector3(to.xMeters, to.yMeters + yOffset, to.zMeters)

            let dx = end.x - start.x
            let dy = end.y - start.y
            let dz = end.z - start.z
            let length = sqrt(dx*dx + dy*dy + dz*dz)
            guard length >= CGFloat(minSegmentLength) else { continue }

            let tube = createTube(from: start, to: end, radius: highlightRadius, color: highlightColor)
            highlightNode.addChildNode(tube)
        }

        // Add start marker for segment
        if let firstPoint = segmentPoints.first {
            let startMarker = createSegmentMarker(at: firstPoint, color: highlightColor, label: "S")
            highlightNode.addChildNode(startMarker)
        }

        // Add end marker for segment
        if let lastPoint = segmentPoints.last {
            let endMarker = createSegmentMarker(at: lastPoint, color: highlightColor, label: "E")
            highlightNode.addChildNode(endMarker)
        }

        scene.rootNode.addChildNode(highlightNode)
        segmentHighlightNode = highlightNode

        return highlightNode
    }

    /// Remove segment highlight from the scene.
    func clearSegmentHighlight() {
        segmentHighlightNode?.removeFromParentNode()
        segmentHighlightNode = nil
    }

    // MARK: - Segment Highlight Helpers

    private func segmentHighlightColor(for type: SegmentType) -> NSColor {
        switch type {
        case .fastest400m, .fastest1km: return NSColor.systemBlue.withAlphaComponent(0.7)
        case .slowest1km: return NSColor.systemRed.withAlphaComponent(0.7)
        case .biggestClimb: return NSColor.systemOrange.withAlphaComponent(0.7)
        case .biggestDescent: return NSColor.systemPurple.withAlphaComponent(0.7)
        case .slowdown: return NSColor.systemYellow.withAlphaComponent(0.7)
        case .custom: return NSColor.systemGray.withAlphaComponent(0.7)
        }
    }

    private func createSegmentMarker(at point: RouteScenePoint, color: NSColor, label: String) -> SCNNode {
        let parent = SCNNode()

        // Sphere
        let sphere = SCNSphere(radius: markerRadius * 0.8)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .blinn
        parent.addChildNode(SCNNode(geometry: sphere))

        // Label
        let text = SCNText(string: label, extrusionDepth: 0.3)
        text.font = NSFont.boldSystemFont(ofSize: 2)
        text.firstMaterial?.diffuse.contents = NSColor.white
        text.firstMaterial?.lightingModel = .constant
        let textNode = SCNNode(geometry: text)
        textNode.position = SCNVector3(0, markerRadius * 1.5, 0)
        parent.addChildNode(textNode)

        parent.position = SCNVector3(point.xMeters, point.yMeters + markerRadius * 1.5, point.zMeters)
        return parent
    }

    /// Get the bounding box for camera fitting.
    var routeBoundingBox: (center: SCNVector3, extent: CGFloat) {
        let projection = RouteProjectionService()
        let bbox = projection.boundingBox(of: scenePoints)
        let center = SCNVector3(
            (CGFloat(bbox.min.x) + CGFloat(bbox.max.x)) / 2,
            (CGFloat(bbox.min.y) + CGFloat(bbox.max.y)) / 2,
            (CGFloat(bbox.min.z) + CGFloat(bbox.max.z)) / 2
        )
        let extent = CGFloat(projection.maxExtent(of: scenePoints))
        return (center, extent)
    }

    // MARK: - Visibility Toggles

    private func updateGridVisibility() {
        gridNode?.isHidden = !showGroundGrid
    }

    private func updateKmMarkerVisibility() {
        kmMarkersNode?.isHidden = !showKilometerMarkers
    }

    // MARK: - Direction Calculation

    private func calculateDirection(at index: Int) -> simd_float3 {
        guard scenePoints.count >= 2 else { return simd_float3(0, 0, 1) }

        // Use a window of points to smooth direction
        let lookAhead = min(3, scenePoints.count - index - 1)
        guard lookAhead > 0 else {
            // At the end, use previous direction
            let prev = scenePoints[max(0, index - 1)]
            let curr = scenePoints[index]
            let dx = Float(curr.xMeters - prev.xMeters)
            let dz = Float(curr.zMeters - prev.zMeters)
            let len = sqrt(dx * dx + dz * dz)
            return len > 0 ? simd_float3(dx / len, 0, dz / len) : simd_float3(0, 0, 1)
        }

        let curr = scenePoints[index]
        let next = scenePoints[index + lookAhead]
        let dx = Float(next.xMeters - curr.xMeters)
        let dz = Float(next.zMeters - curr.zMeters)
        let len = sqrt(dx * dx + dz * dz)
        return len > 0 ? simd_float3(dx / len, 0, dz / len) : simd_float3(0, 0, 1)
    }

    // MARK: - Private Builders

    private func setupLighting(in scene: SCNScene) {
        // Ambient light for base visibility
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.5, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Key light (directional, angled from above-left)
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor(white: 0.9, alpha: 1.0)
        keyLight.intensity = 800
        keyLight.castsShadow = true
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(keyNode)

        // Fill light (softer, from opposite side)
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.color = NSColor(white: 0.4, alpha: 1.0)
        fillLight.intensity = 300
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fillNode)

        // Top light for the route
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

    private func createRoute(from points: [RouteScenePoint]) -> SCNNode {
        let parent = SCNNode()

        guard points.count >= 2 else { return parent }

        // Compute segment colors based on color mode
        let segmentColors = coloringService.computeSegmentColors(
            points: points,
            mode: colorMode,
            defaultColor: routeColor
        )

        // Create tubes between consecutive points, skipping zero-length segments
        for i in 0..<(points.count - 1) {
            let from = points[i]
            let to = points[i + 1]

            let start = SCNVector3(from.xMeters, from.yMeters, from.zMeters)
            let end = SCNVector3(to.xMeters, to.yMeters, to.zMeters)

            // Skip zero-length or degenerate segments
            let dx = end.x - start.x
            let dy = end.y - start.y
            let dz = end.z - start.z
            let length = sqrt(dx*dx + dy*dy + dz*dz)
            guard length >= CGFloat(minSegmentLength) else { continue }

            let color = i < segmentColors.count ? segmentColors[i] : routeColor
            let tube = createTube(from: start, to: end, radius: routeRadius, color: color)
            parent.addChildNode(tube)
        }

        return parent
    }

    private func createTube(from start: SCNVector3, to end: SCNVector3, radius: CGFloat, color: NSColor) -> SCNNode {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        let distance = sqrt(dx*dx + dy*dy + dz*dz)

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

        // Orient cylinder (default Y-axis) to align with start→end direction
        let dir = simd_float3(Float(dx), Float(dy), Float(dz))
        let len = simd_length(dir)
        guard len > 0 else { return node }

        let dirNorm = dir / len
        let yAxis = simd_float3(0, 1, 0)
        let dotProduct = simd_dot(yAxis, dirNorm)

        if dotProduct > 0.999 {
            // Already aligned with Y
        } else if dotProduct < -0.999 {
            // Opposite direction - rotate 180° around X
            node.eulerAngles = SCNVector3(Float.pi, 0, 0)
        } else {
            let axis = simd_cross(yAxis, dirNorm)
            let angle = acos(min(1.0, max(-1.0, dotProduct)))
            node.rotation = SCNVector4(CGFloat(axis.x), CGFloat(axis.y), CGFloat(axis.z), CGFloat(angle))
        }

        return node
    }

    // MARK: - Markers

    private func createStartMarker(at point: RouteScenePoint) -> SCNNode {
        let parent = SCNNode()

        // Green sphere
        let sphere = SCNSphere(radius: markerRadius * 1.5)
        sphere.firstMaterial?.diffuse.contents = startMarkerColor
        sphere.firstMaterial?.lightingModel = .blinn
        sphere.firstMaterial?.specular.contents = NSColor.white
        parent.addChildNode(SCNNode(geometry: sphere))

        // Glow
        let glow = SCNSphere(radius: markerRadius * 2.0)
        glow.firstMaterial?.diffuse.contents = startMarkerColor.withAlphaComponent(0.2)
        glow.firstMaterial?.lightingModel = .constant
        parent.addChildNode(SCNNode(geometry: glow))

        // Label
        let label = createTextSprite("START", color: startMarkerColor, fontSize: 2.5)
        label.position = SCNVector3(0, markerRadius * 3, 0)
        parent.addChildNode(label)

        parent.position = SCNVector3(point.xMeters, point.yMeters + markerRadius * 1.5, point.zMeters)
        return parent
    }

    private func createFinishMarker(at point: RouteScenePoint) -> SCNNode {
        let parent = SCNNode()

        // Red sphere
        let sphere = SCNSphere(radius: markerRadius * 1.5)
        sphere.firstMaterial?.diffuse.contents = finishMarkerColor
        sphere.firstMaterial?.lightingModel = .blinn
        sphere.firstMaterial?.specular.contents = NSColor.white
        parent.addChildNode(SCNNode(geometry: sphere))

        // Glow
        let glow = SCNSphere(radius: markerRadius * 2.0)
        glow.firstMaterial?.diffuse.contents = finishMarkerColor.withAlphaComponent(0.2)
        glow.firstMaterial?.lightingModel = .constant
        parent.addChildNode(SCNNode(geometry: glow))

        // Label
        let label = createTextSprite("FINISH", color: finishMarkerColor, fontSize: 2.5)
        label.position = SCNVector3(0, markerRadius * 3, 0)
        parent.addChildNode(label)

        parent.position = SCNVector3(point.xMeters, point.yMeters + markerRadius * 1.5, point.zMeters)
        return parent
    }

    private func createCurrentMarker(at point: RouteScenePoint, direction: simd_float3) -> SCNNode {
        let parent = SCNNode()

        // Cone pointing in direction of travel
        let cone = SCNCone(topRadius: 0, bottomRadius: markerRadius * 1.2, height: markerRadius * 3)
        cone.firstMaterial?.diffuse.contents = currentMarkerColor
        cone.firstMaterial?.lightingModel = .blinn
        cone.firstMaterial?.specular.contents = NSColor.white
        cone.firstMaterial?.emission.contents = currentMarkerColor.withAlphaComponent(0.3)

        let coneNode = SCNNode(geometry: cone)
        // Default cone points up (Y), rotate to point forward
        coneNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        parent.addChildNode(coneNode)

        // Glow ring
        let ring = SCNTorus(ringRadius: markerRadius * 1.5, pipeRadius: 0.3)
        ring.firstMaterial?.diffuse.contents = currentMarkerColor.withAlphaComponent(0.5)
        ring.firstMaterial?.lightingModel = .constant
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        parent.addChildNode(ringNode)

        // Set initial direction
        updateMarkerDirection(marker: parent, direction: direction)

        parent.position = SCNVector3(point.xMeters, point.yMeters + markerRadius * 2, point.zMeters)
        return parent
    }

    private func updateMarkerDirection(marker: SCNNode, direction: simd_float3) {
        // Rotate marker to face direction of travel
        guard simd_length(direction) > 0 else { return }
        let angle = atan2(direction.x, direction.z)
        marker.eulerAngles = SCNVector3(0, angle, 0)
    }

    private func createTextSprite(_ text: String, color: NSColor, fontSize: CGFloat) -> SCNNode {
        let textGeometry = SCNText(string: text, extrusionDepth: 0.5)
        textGeometry.font = NSFont.boldSystemFont(ofSize: fontSize)
        textGeometry.firstMaterial?.diffuse.contents = color
        textGeometry.firstMaterial?.lightingModel = .constant
        textGeometry.flatness = 0.1

        let textNode = SCNNode(geometry: textGeometry)
        // Center the text
        let (min, max) = textGeometry.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            (max.x - min.x) / 2 + min.x,
            (max.y - min.y) / 2 + min.y,
            (max.z - min.z) / 2 + min.z
        )

        return textNode
    }

    // MARK: - Kilometer Markers

    private func createKilometerMarkers(from points: [RouteScenePoint]) -> SCNNode {
        let parent = SCNNode()
        var nextKm: Double = 1000

        for point in points {
            if point.distanceFromStartMeters >= nextKm {
                let marker = createKmMarker(at: point, km: Int(nextKm / 1000))
                parent.addChildNode(marker)
                nextKm += 1000
            }
        }

        return parent
    }

    private func createKmMarker(at point: RouteScenePoint, km: Int) -> SCNNode {
        let parent = SCNNode()

        // Pole
        let pole = SCNCylinder(radius: 0.3, height: 8)
        pole.firstMaterial?.diffuse.contents = NSColor.systemOrange
        pole.firstMaterial?.lightingModel = .blinn
        let poleNode = SCNNode(geometry: pole)
        poleNode.position = SCNVector3(0, 4, 0)
        parent.addChildNode(poleNode)

        // Sphere on top
        let sphere = SCNSphere(radius: 1.5)
        sphere.firstMaterial?.diffuse.contents = NSColor.systemOrange
        sphere.firstMaterial?.lightingModel = .blinn
        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.position = SCNVector3(0, 9, 0)
        parent.addChildNode(sphereNode)

        // Distance label
        let label = createTextSprite("\(km) km", color: .white, fontSize: 2.0)
        label.position = SCNVector3(0, 12, 0)
        parent.addChildNode(label)

        parent.position = SCNVector3(point.xMeters, point.yMeters, point.zMeters)
        return parent
    }

    // MARK: - Ground Grid

    private func createGroundGrid(points: [RouteScenePoint]) -> SCNNode {
        let parent = SCNNode()

        let projection = RouteProjectionService()
        let bbox = projection.boundingBox(of: points)
        let extent = projection.maxExtent(of: points)

        // Adaptive grid: spacing based on route extent
        let gridSpacing: CGFloat
        if extent < 500 {
            gridSpacing = 50
        } else if extent < 2000 {
            gridSpacing = 100
        } else {
            gridSpacing = 200
        }

        let gridSize = CGFloat(extent) * 0.8 // Slightly larger than route
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.3)

        let center = SCNVector3(
            (CGFloat(bbox.min.x) + CGFloat(bbox.max.x)) / 2,
            CGFloat(bbox.min.y) - 1,
            (CGFloat(bbox.min.z) + CGFloat(bbox.max.z)) / 2
        )

        // Create grid lines along X
        var i: CGFloat = -gridSize
        while i <= gridSize {
            let x = center.x + i
            let from = SCNVector3(x, center.y, center.z - gridSize)
            let to = SCNVector3(x, center.y, center.z + gridSize)
            let line = createLine(from: from, to: to, color: gridColor)
            parent.addChildNode(line)
            i += gridSpacing
        }

        // Create grid lines along Z
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
