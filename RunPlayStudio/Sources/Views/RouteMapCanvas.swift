import MapKit
import RunPlayCore
import RunPlayPlatform
import SwiftUI

private extension RouteMapLineStyle {
    var swiftUIColor: Color {
        switch self {
        case .primary: return .blue
        case .comparison: return .orange
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
                        .stroke(route.style.swiftUIColor, lineWidth: 4)
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
                    updatePitch(nextMode, animated: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help(displayMode == .threeD ? "Switch to 2D" : "Switch to 3D")
                .accessibilityLabel(displayMode == .threeD ? "Switch to 2D" : "Switch to 3D")
                MapZoomStepper(scope: mapScope)
                    .controlSize(.regular)
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
