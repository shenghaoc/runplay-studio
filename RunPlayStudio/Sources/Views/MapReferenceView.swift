import SwiftUI
import MapKit

/// Displays the running route on a 2D MapKit view.
///
/// Shows the full route as a polyline with start/finish annotations
/// and optional current position marker.
struct MapReferenceView: View {
    let routePoints: [RoutePoint]
    var currentPointIndex: Int = 0
    var showAnnotations: Bool = true

    @State private var region: MKCoordinateRegion = MKCoordinateRegion()

    var body: some View {
        Map(coordinateRegion: $region, annotationItems: annotations) { annotation in
            MapAnnotation(coordinate: annotation.coordinate) {
                Circle()
                    .fill(annotation.color)
                    .frame(width: annotation.size, height: annotation.size)
                    .overlay(
                        Circle().stroke(.white, lineWidth: 2)
                    )
            }
        }
        .overlay(routeOverlay)
        .onAppear {
            calculateRegion()
        }
        .onChange(of: routePoints.count) { _ in
            calculateRegion()
        }
    }

    // MARK: - Annotations

    private var annotations: [MapAnnotation] {
        guard showAnnotations, !routePoints.isEmpty else { return [] }

        var items: [MapAnnotation] = []

        // Start
        if let first = routePoints.first {
            items.append(MapAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                color: .green,
                size: 12,
                label: "Start"
            ))
        }

        // Finish
        if let last = routePoints.last, routePoints.count > 1 {
            items.append(MapAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
                color: .red,
                size: 12,
                label: "Finish"
            ))
        }

        // Current position
        if currentPointIndex < routePoints.count {
            let point = routePoints[currentPointIndex]
            items.append(MapAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                color: .yellow,
                size: 10,
                label: "Current"
            ))
        }

        return items
    }

    // MARK: - Route Overlay

    @ViewBuilder
    private var routeOverlay: some View {
        if routePoints.count >= 2 {
            GeometryReader { geometry in
                Path { path in
                    let points = routePoints.map { point -> CGPoint in
                        let normalizedX = (point.longitude - region.center.longitude + region.span.longitudeDelta / 2) / region.span.longitudeDelta
                        let normalizedY = 1 - (point.latitude - region.center.latitude + region.span.latitudeDelta / 2) / region.span.latitudeDelta
                        return CGPoint(
                            x: normalizedX * geometry.size.width,
                            y: normalizedY * geometry.size.height
                        )
                    }

                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color.blue, lineWidth: 3)
            }
        }
    }

    // MARK: - Helpers

    private func calculateRegion() {
        guard !routePoints.isEmpty else { return }

        let lats = routePoints.map { $0.latitude }
        let lons = routePoints.map { $0.longitude }

        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLon = lons.min()!
        let maxLon = lons.max()!

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.2, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.2, 0.01)
        )

        region = MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Supporting Types

private struct MapAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let color: Color
    let size: CGFloat
    let label: String
}
