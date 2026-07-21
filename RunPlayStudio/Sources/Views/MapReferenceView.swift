import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Displays a route on one Apple Maps surface with an in-map 2D/3D control.
///
/// Uses pill-shaped overlays and subtle material backgrounds
/// for map controls that don't compete with the route visualization.
struct MapReferenceView: View {
    let routePoints: [RoutePoint]
    var currentPointIndex: Int = 0
    var showAnnotations: Bool = true

    @State private var displayMode: RouteMapDisplayMode = .twoD
    @State private var fitRequest = 0

    private var routes: [RouteMapLine] {
        RouteMapContent.segmentedRoutes(idPrefix: "route", points: routePoints, style: .primary)
    }

    private var markers: [RouteMapMarker] {
        guard showAnnotations else { return [] }
        var markers = RouteMapContent.endpointMarkers(points: routePoints, idPrefix: "route")
        if let current = RouteMapContent.currentMarker(points: routePoints, index: currentPointIndex) {
            markers.append(current)
        }
        return markers
    }

    var body: some View {
        RouteMapCanvas(
            displayMode: $displayMode,
            routes: routes,
            markers: markers,
            fitRequest: fitRequest,
            controlBottomInset: 0
        )
        .overlay(alignment: .topLeading) {
            mapModeBadge
        }
        .overlay(alignment: .topTrailing) {
            Button {
                fitRequest += 1
            } label: {
                Label("Fit Route", systemImage: "viewfinder")
                    .font(AppDesign.Typography.compactMetric)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Zoom and center the map to show the full route")
            .padding()
        }
    }

    private var mapModeBadge: some View {
        MapModeBadge(displayMode: displayMode)
        .padding(.horizontal, AppDesign.Spacing.medium)
        .padding(.vertical, AppDesign.Spacing.small)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .padding()
    }
}
