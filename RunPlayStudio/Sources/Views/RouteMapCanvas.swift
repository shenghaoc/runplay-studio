import MapKit
import RunPlayCore
import RunPlayPlatform
import SwiftUI

private extension RouteMapLineStyle {
    var swiftUIColor: Color {
        switch self {
        case .primary:
            return AppDesign.primaryBlue
        case .comparison:
            return AppDesign.comparisonOrange
        case .metric(let mode, let bucket):
            return AppDesign.RouteMetric.color(mode: mode, bucket: bucket)
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .primary, .comparison:
            return 4
        case .metric(_, .noData):
            return 3.5
        case .metric:
            return 4
        }
    }
}

private extension RouteMapMarkerStyle {
    var swiftUIColor: Color {
        switch self {
        case .start: return .green
        case .finish: return .red
        case .current: return .yellow
        case .primaryCurrent: return .blue
        case .comparisonCurrent: return .orange
        }
    }
}

/// One SwiftUI Map surface whose 2D/3D control switches the same route between
/// flat 2D and realistic-elevation 3D presentations.
struct RouteMapCanvas: View {
    @Binding var displayMode: RouteMapDisplayMode
    let routes: [RouteMapLine]
    let markers: [RouteMapMarker]
    let areas: [RouteMapArea]
    let fitRequest: Int
    let controlBottomInset: CGFloat
    /// When set, applied on appear if the binding still has the default value.
    let defaultDisplayMode: RouteMapDisplayMode?
    /// When false, fit/pitch updates jump without animation (Reduce Motion).
    let animateCamera: Bool

    @State private var position: MapCameraPosition = .automatic
    @State private var currentCamera: MapCamera?
    @Namespace private var mapScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        displayMode: Binding<RouteMapDisplayMode>,
        routes: [RouteMapLine],
        markers: [RouteMapMarker],
        areas: [RouteMapArea] = [],
        fitRequest: Int,
        controlBottomInset: CGFloat,
        defaultDisplayMode: RouteMapDisplayMode? = nil,
        animateCamera: Bool = true
    ) {
        self._displayMode = displayMode
        self.routes = routes
        self.markers = markers
        self.areas = areas
        self.fitRequest = fitRequest
        self.controlBottomInset = controlBottomInset
        self.defaultDisplayMode = defaultDisplayMode
        self.animateCamera = animateCamera
    }

    private var shouldAnimateCamera: Bool {
        animateCamera && !reduceMotion
    }

    var body: some View {
        Map(position: $position, scope: mapScope) {
            // Render order: areas (heatmap) → routes → markers.
            ForEach(areas) { area in
                if area.coordinates.count >= 3 {
                    MapPolygon(coordinates: area.coordinates.map(\.mapKitCoordinate))
                        .foregroundStyle(heatmapFill(intensity: area.normalizedIntensity))
                        .stroke(Color.clear, lineWidth: 0)
                }
            }

            ForEach(routes) { route in
                if route.coordinates.count >= 2 {
                    MapPolyline(coordinates: route.coordinates.map(\.mapKitCoordinate))
                        .stroke(route.style.swiftUIColor, lineWidth: route.style.lineWidth)
                }
            }

            ForEach(markers) { marker in
                Annotation(marker.title, coordinate: marker.coordinate.mapKitCoordinate) {
                    ZStack {
                        Circle()
                            .fill(marker.style.swiftUIColor)
                            .frame(width: 20, height: 20)
                        Circle()
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 20, height: 20)
                        Text(marker.style.glyph)
                            .font(AppDesign.Typography.compactLabel.weight(.bold))
                            .foregroundStyle(marker.style == .current ? .black : .white)
                    }
                    .accessibilityLabel(marker.title)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapScope(mapScope)
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: AppDesign.Spacing.small) {
                Button(displayMode == .threeD ? "2D" : "3D") {
                    let nextMode: RouteMapDisplayMode = displayMode == .threeD ? .twoD : .threeD
                    displayMode = nextMode
                    updatePitch(nextMode, animated: shouldAnimateCamera)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help(displayMode == .threeD ? "Switch to 2D" : "Switch to 3D")
                .accessibilityLabel(displayMode == .threeD ? "Switch to 2D" : "Switch to 3D")
                .accessibilityValue(displayMode == .threeD ? "3D" : "2D")
                MapZoomStepper(scope: mapScope)
                    .controlSize(.regular)
                    .accessibilityLabel("Map zoom")
            }
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
            if let defaultDisplayMode {
                displayMode = defaultDisplayMode
            }
            fitContent(animated: false)
        }
        .onChange(of: routes) { oldRoutes, newRoutes in
            // Metric color swaps change line count/styles but not overall bounds.
            // Only re-fit when the geographic envelope changes (new workout / gap layout).
            let oldRect = RouteMapContent.mapRect(routes: oldRoutes, areas: areas)
            let newRect = RouteMapContent.mapRect(routes: newRoutes, areas: areas)
            if shouldRefit(from: oldRect, to: newRect) {
                fitContent(animated: false)
            }
        }
        .onChange(of: areas) { _, _ in
            fitContent(animated: false)
        }
        .onChange(of: fitRequest) { _, _ in
            fitContent(animated: shouldAnimateCamera)
        }
    }

    private func shouldRefit(from oldRect: MKMapRect?, to newRect: MKMapRect?) -> Bool {
        switch (oldRect, newRect) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case let (old?, new?):
            if old.isNull || new.isNull { return true }
            // Relative change in center or size beyond a small tolerance.
            let cx = abs(old.midX - new.midX) / max(old.width, 1)
            let cy = abs(old.midY - new.midY) / max(old.height, 1)
            let dw = abs(old.width - new.width) / max(old.width, 1)
            let dh = abs(old.height - new.height) / max(old.height, 1)
            return cx > 0.02 || cy > 0.02 || dw > 0.02 || dh > 0.02
        }
    }

    private func fitContent(animated: Bool) {
        guard let rect = RouteMapContent.mapRect(routes: routes, areas: areas) else {
            position = .automatic
            return
        }

        let newPosition: MapCameraPosition
        if displayMode == .threeD,
           let plan = RouteMapContent.cameraPlan(routes: routes, areas: areas) {
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
            fitContent(animated: animated)
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
