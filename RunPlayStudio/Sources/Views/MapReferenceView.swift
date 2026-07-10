import RunPlayCore
import SwiftUI

/// Displays a route on one Apple Maps surface with an in-map 2D/3D control.
struct MapReferenceView: View {
    let routePoints: [RoutePoint]
    var currentPointIndex: Int = 0
    var showAnnotations: Bool = true

    @State private var displayMode: RouteMapDisplayMode = .twoD
    @State private var fitRequest = 0

    private var route: RouteMapLine {
        RouteMapContent.route(id: "route", points: routePoints, style: .primary)
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
            routes: [route],
            markers: markers,
            fitRequest: fitRequest
        )
        .overlay(alignment: .topLeading) {
            mapBadge
        }
        .overlay(alignment: .topTrailing) {
            Button {
                fitRequest += 1
            } label: {
                Label("Fit Route", systemImage: "viewfinder")
            }
            .buttonStyle(.bordered)
            .padding()
        }
    }

    private var mapBadge: some View {
        Text(displayMode == .threeD ? "Apple Maps 3D" : "Apple Maps 2D")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding()
    }
}
