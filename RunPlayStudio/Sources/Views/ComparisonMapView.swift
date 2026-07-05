import SwiftUI
import MapKit

/// Map view showing two routes overlaid for comparison.
struct ComparisonMapView: View {
    let primaryPoints: [RoutePoint]
    let comparisonPoints: [RoutePoint]

    @State private var region: MKCoordinateRegion = MKCoordinateRegion()

    var body: some View {
        Map(coordinateRegion: $region, annotationItems: mapAnnotations) { item in
            MapAnnotation(coordinate: item.coordinate) {
                Circle()
                    .fill(item.color)
                    .frame(width: item.size, height: item.size)
                    .overlay(
                        Circle().stroke(.white, lineWidth: 2)
                    )
            }
        }
        .overlay(routeOverlays)
        .overlay(alignment: .topLeading) {
            routeLegend
        }
        .onAppear {
            calculateRegion()
        }
    }

    // MARK: - Annotations

    private var mapAnnotations: [RouteMapAnnotation] {
        var items: [RouteMapAnnotation] = []

        // Primary start
        if let first = primaryPoints.first {
            items.append(RouteMapAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                color: .blue,
                size: 10,
                label: "P Start"
            ))
        }

        // Primary finish
        if let last = primaryPoints.last {
            items.append(RouteMapAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
                color: .blue,
                size: 10,
                label: "P End"
            ))
        }

        // Comparison start
        if let first = comparisonPoints.first {
            items.append(RouteMapAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                color: .red,
                size: 10,
                label: "C Start"
            ))
        }

        // Comparison finish
        if let last = comparisonPoints.last {
            items.append(RouteMapAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
                color: .red,
                size: 10,
                label: "C End"
            ))
        }

        return items
    }

    // MARK: - Route Overlays

    @ViewBuilder
    private var routeOverlays: some View {
        // Primary route
        routeOverlay(points: primaryPoints, color: .blue)

        // Comparison route
        routeOverlay(points: comparisonPoints, color: .red)
    }

    private func routeOverlay(points: [RoutePoint], color: Color) -> some View {
        Group {
            if points.count >= 2 {
                GeometryReader { geometry in
                    Path { path in
                        let screenPoints = points.map { point -> CGPoint in
                            let normalizedX = (point.longitude - region.center.longitude + region.span.longitudeDelta / 2) / region.span.longitudeDelta
                            let normalizedY = 1 - (point.latitude - region.center.latitude + region.span.latitudeDelta / 2) / region.span.latitudeDelta
                            return CGPoint(
                                x: normalizedX * geometry.size.width,
                                y: normalizedY * geometry.size.height
                            )
                        }

                        guard let first = screenPoints.first else { return }
                        path.move(to: first)
                        for point in screenPoints.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(color, lineWidth: 3)
                }
            }
        }
    }

    private var routeLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: .blue, label: "Primary")
            legendRow(color: .red, label: "Comparison")
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding()
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 18, height: 4)
            Text(label)
        }
    }

    // MARK: - Helpers

    private func calculateRegion() {
        let allPoints = primaryPoints + comparisonPoints
        guard !allPoints.isEmpty else { return }

        let lats = allPoints.map { $0.latitude }
        let lons = allPoints.map { $0.longitude }

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
