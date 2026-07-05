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

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            if routeCoordinates.count >= 2 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(.blue, lineWidth: 3)
            }

            ForEach(mapAnnotations) { item in
                Annotation(item.label, coordinate: item.coordinate) {
                    Circle()
                        .fill(item.color)
                        .frame(width: item.size, height: item.size)
                        .overlay(
                            Circle().stroke(.white, lineWidth: 2)
                        )
                        .accessibilityLabel(item.label)
                }
            }
        }
        .onAppear {
            updatePosition()
        }
        .onChange(of: routePoints) { _, _ in
            updatePosition()
        }
    }

    // MARK: - Annotations

    private var mapAnnotations: [RouteMapAnnotation] {
        guard showAnnotations, !routePoints.isEmpty else { return [] }

        var items: [RouteMapAnnotation] = []

        // Start
        if let first = routeCoordinates.first {
            items.append(RouteMapAnnotation(
                coordinate: first,
                color: .green,
                size: 12,
                label: "Start"
            ))
        }

        // Finish
        if let last = routeCoordinates.last, routeCoordinates.count > 1 {
            items.append(RouteMapAnnotation(
                coordinate: last,
                color: .red,
                size: 12,
                label: "Finish"
            ))
        }

        // Current position
        if currentPointIndex < routePoints.count,
           let coordinate = coordinate(from: routePoints[currentPointIndex]) {
            items.append(RouteMapAnnotation(
                coordinate: coordinate,
                color: .yellow,
                size: 10,
                label: "Current"
            ))
        }

        return items
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        routePoints.compactMap(coordinate)
    }

    // MARK: - Helpers

    private func updatePosition() {
        guard let region = mapRegion() else {
            position = .automatic
            return
        }

        position = .region(region)
    }

    private func mapRegion() -> MKCoordinateRegion? {
        guard !routeCoordinates.isEmpty else { return nil }

        let lats = routeCoordinates.map { $0.latitude }
        let lons = routeCoordinates.map { $0.longitude }

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

        return MKCoordinateRegion(center: center, span: span)
    }

    private func coordinate(from point: RoutePoint) -> CLLocationCoordinate2D? {
        guard point.latitude.isFinite, point.longitude.isFinite else { return nil }
        guard abs(point.latitude) <= 90, abs(point.longitude) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
}

// MARK: - Supporting Types

struct RouteMapAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let color: Color
    let size: CGFloat
    let label: String
}
