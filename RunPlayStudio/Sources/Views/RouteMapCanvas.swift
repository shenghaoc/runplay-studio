import MapKit
import RunPlayCore
import SwiftUI

enum RouteMapDisplayMode: String, CaseIterable, Hashable {
    case twoD = "2D"
    case threeD = "3D"

    var cameraPitch: Double {
        switch self {
        case .twoD: return 0
        case .threeD: return 58
        }
    }
}

struct RouteMapCoordinate: Hashable {
    let latitude: Double
    let longitude: Double

    init?(latitude: Double, longitude: Double) {
        guard GeoDistance.isValidCoordinate(lat: latitude, lon: longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    init?(_ point: RoutePoint) {
        self.init(latitude: point.latitude, longitude: point.longitude)
    }

    var mapKitCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RouteMapLineStyle: Hashable {
    case primary
    case comparison

    var color: Color {
        switch self {
        case .primary: return .blue
        case .comparison: return .orange
        }
    }
}

struct RouteMapLine: Identifiable, Hashable {
    let id: String
    let coordinates: [RouteMapCoordinate]
    let style: RouteMapLineStyle
}

enum RouteMapMarkerStyle: Hashable {
    case start
    case finish
    case current
    case primaryCurrent
    case comparisonCurrent

    var color: Color {
        switch self {
        case .start: return .green
        case .finish: return .red
        case .current: return .yellow
        case .primaryCurrent: return .blue
        case .comparisonCurrent: return .orange
        }
    }

    var glyph: String {
        switch self {
        case .start: return "S"
        case .finish: return "F"
        case .current: return "●"
        case .primaryCurrent: return "P"
        case .comparisonCurrent: return "C"
        }
    }
}

struct RouteMapMarker: Identifiable, Hashable {
    let id: String
    let title: String
    let coordinate: RouteMapCoordinate
    let style: RouteMapMarkerStyle
}

struct RouteMapCameraPlan {
    let center: CLLocationCoordinate2D
    let distance: CLLocationDistance
}

enum RouteMapContent {
    static func route(
        id: String,
        points: [RoutePoint],
        style: RouteMapLineStyle
    ) -> RouteMapLine {
        RouteMapLine(
            id: id,
            coordinates: points.compactMap(RouteMapCoordinate.init),
            style: style
        )
    }

    static func endpointMarkers(points: [RoutePoint], idPrefix: String) -> [RouteMapMarker] {
        let coordinates = points.compactMap(RouteMapCoordinate.init)
        guard let first = coordinates.first else { return [] }

        var markers = [
            RouteMapMarker(
                id: "\(idPrefix)-start",
                title: "Start",
                coordinate: first,
                style: .start
            )
        ]

        if let last = coordinates.last, coordinates.count > 1 {
            markers.append(
                RouteMapMarker(
                    id: "\(idPrefix)-finish",
                    title: "Finish",
                    coordinate: last,
                    style: .finish
                )
            )
        }
        return markers
    }

    static func currentMarker(
        points: [RoutePoint],
        index: Int,
        id: String = "current",
        title: String = "Current position",
        style: RouteMapMarkerStyle = .current
    ) -> RouteMapMarker? {
        guard points.indices.contains(index), let coordinate = RouteMapCoordinate(points[index]) else {
            return nil
        }
        return RouteMapMarker(id: id, title: title, coordinate: coordinate, style: style)
    }

    static func marker(
        points: [RoutePoint],
        distance: Double,
        id: String,
        title: String,
        style: RouteMapMarkerStyle
    ) -> RouteMapMarker? {
        guard let point = RoutePointInterpolator.point(at: distance, in: points),
              let coordinate = RouteMapCoordinate(point) else {
            return nil
        }
        return RouteMapMarker(id: id, title: title, coordinate: coordinate, style: style)
    }

    static func mapRect(for routes: [RouteMapLine]) -> MKMapRect? {
        let coordinates = routes.flatMap(\.coordinates)
        guard let first = coordinates.first else { return nil }

        let firstPoint = MKMapPoint(first.mapKitCoordinate)
        var rect = MKMapRect(x: firstPoint.x, y: firstPoint.y, width: 1, height: 1)
        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate.mapKitCoordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }

        let latitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
        let metersPerMapPoint = max(MKMetersPerMapPointAtLatitude(latitude), 0.000_001)
        let minimumSpan = 400 / metersPerMapPoint
        let width = min(max(rect.width, minimumSpan), MKMapSize.world.width)
        let height = min(max(rect.height, minimumSpan), MKMapSize.world.height)
        let x = max(0, min(rect.midX - width / 2, MKMapSize.world.width - width))
        let y = max(0, min(rect.midY - height / 2, MKMapSize.world.height - height))
        return MKMapRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    static func cameraPlan(for routes: [RouteMapLine]) -> RouteMapCameraPlan? {
        guard let rect = mapRect(for: routes) else { return nil }
        let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let metersPerMapPoint = max(MKMetersPerMapPointAtLatitude(center.latitude), 0.000_001)
        let widthMeters = rect.width * metersPerMapPoint
        let heightMeters = rect.height * metersPerMapPoint
        let distance = max(max(widthMeters, heightMeters) * 2.25, 900)
        return RouteMapCameraPlan(center: center, distance: distance)
    }
}

/// One SwiftUI Map surface whose 2D/3D control switches the same route between
/// flat 2D and realistic-elevation 3D presentations.
struct RouteMapCanvas: View {
    @Binding var displayMode: RouteMapDisplayMode
    let routes: [RouteMapLine]
    let markers: [RouteMapMarker]
    let fitRequest: Int
    let controlBottomInset: CGFloat

    @State private var position: MapCameraPosition = .automatic
    @State private var currentCamera: MapCamera?
    @Namespace private var mapScope

    var body: some View {
        Map(position: $position, scope: mapScope) {
            ForEach(routes) { route in
                if route.coordinates.count >= 2 {
                    MapPolyline(coordinates: route.coordinates.map(\.mapKitCoordinate))
                        .stroke(route.style.color, lineWidth: 4)
                }
            }

            ForEach(markers) { marker in
                Annotation(marker.title, coordinate: marker.coordinate.mapKitCoordinate) {
                    ZStack {
                        Circle()
                            .fill(marker.style.color)
                            .frame(width: 20, height: 20)
                        Circle()
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 20, height: 20)
                        Text(marker.style.glyph)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(marker.style == .current ? .black : .white)
                    }
                    .accessibilityLabel(marker.title)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapScope(mapScope)
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 8) {
                Button(displayMode == .threeD ? "2D" : "3D") {
                    let nextMode: RouteMapDisplayMode = displayMode == .threeD ? .twoD : .threeD
                    displayMode = nextMode
                    updatePitch(nextMode, animated: true)
                }
                .buttonStyle(.borderedProminent)
                .help(displayMode == .threeD ? "Switch to 2D" : "Switch to 3D")
                .accessibilityLabel(displayMode == .threeD ? "Show in 2D" : "Show in 3D")
                MapZoomStepper(scope: mapScope)
            }
            .controlSize(.small)
            .padding()
            .padding(.bottom, controlBottomInset)
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            currentCamera = context.camera
            let newMode: RouteMapDisplayMode = context.camera.pitch >= 10 ? .threeD : .twoD
            if displayMode != newMode {
                displayMode = newMode
            }
        }
        .onAppear {
            fitRoutes(animated: false)
        }
        .onChange(of: routes) { _, _ in
            fitRoutes(animated: false)
        }
        .onChange(of: fitRequest) { _, _ in
            fitRoutes(animated: true)
        }
    }

    private func fitRoutes(animated: Bool) {
        guard let rect = RouteMapContent.mapRect(for: routes) else {
            position = .automatic
            return
        }

        let newPosition: MapCameraPosition
        if displayMode == .threeD,
           let plan = RouteMapContent.cameraPlan(for: routes) {
            newPosition = .camera(MapCamera(
                centerCoordinate: plan.center,
                distance: plan.distance,
                heading: 0,
                pitch: displayMode.cameraPitch
            ))
        } else {
            newPosition = .rect(rect)
        }

        if animated {
            withAnimation { position = newPosition }
        } else {
            position = newPosition
        }
    }

    private func updatePitch(_ mode: RouteMapDisplayMode, animated: Bool) {
        guard let camera = currentCamera else {
            fitRoutes(animated: animated)
            return
        }
        guard abs(camera.pitch - mode.cameraPitch) >= 1 else { return }

        let newPosition = MapCameraPosition.camera(MapCamera(
            centerCoordinate: camera.centerCoordinate,
            distance: camera.distance,
            heading: camera.heading,
            pitch: mode.cameraPitch
        ))
        if animated {
            withAnimation { position = newPosition }
        } else {
            position = newPosition
        }
    }
}
