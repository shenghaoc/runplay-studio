import SwiftUI
import RunPlayCore
import MapKit
import RunPlayCore

/// Map view showing two routes overlaid for comparison.
struct ComparisonMapView: View {
    let primaryPoints: [RoutePoint]
    let comparisonPoints: [RoutePoint]

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            if primaryCoordinates.count >= 2 {
                MapPolyline(coordinates: primaryCoordinates)
                    .stroke(.blue, lineWidth: 3)
            }

            if comparisonCoordinates.count >= 2 {
                MapPolyline(coordinates: comparisonCoordinates)
                    .stroke(.red, lineWidth: 3)
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
        .overlay(alignment: .topLeading) {
            routeLegend
        }
        .onAppear {
            updatePosition()
        }
        .onChange(of: primaryPoints) { _, _ in
            updatePosition()
        }
        .onChange(of: comparisonPoints) { _, _ in
            updatePosition()
        }
    }

    // MARK: - Annotations

    private var mapAnnotations: [RouteMapAnnotation] {
        var items: [RouteMapAnnotation] = []

        // Primary start
        if let first = primaryCoordinates.first {
            items.append(RouteMapAnnotation(
                coordinate: first,
                color: .blue,
                size: 10,
                label: "P Start"
            ))
        }

        // Primary finish
        if let last = primaryCoordinates.last {
            items.append(RouteMapAnnotation(
                coordinate: last,
                color: .blue,
                size: 10,
                label: "P End"
            ))
        }

        // Comparison start
        if let first = comparisonCoordinates.first {
            items.append(RouteMapAnnotation(
                coordinate: first,
                color: .red,
                size: 10,
                label: "C Start"
            ))
        }

        // Comparison finish
        if let last = comparisonCoordinates.last {
            items.append(RouteMapAnnotation(
                coordinate: last,
                color: .red,
                size: 10,
                label: "C End"
            ))
        }

        return items
    }

    private var primaryCoordinates: [CLLocationCoordinate2D] {
        coordinates(from: primaryPoints)
    }

    private var comparisonCoordinates: [CLLocationCoordinate2D] {
        coordinates(from: comparisonPoints)
    }

    private var routeLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: .blue, label: "Primary run")
            legendRow(color: .red, label: "Comparison run")
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

    private func updatePosition() {
        guard let region = mapRegion() else {
            position = .automatic
            return
        }

        position = .region(region)
    }

    private func mapRegion() -> MKCoordinateRegion? {
        let allCoordinates = primaryCoordinates + comparisonCoordinates
        guard !allCoordinates.isEmpty else { return nil }

        let lats = allCoordinates.map { $0.latitude }
        let lons = allCoordinates.map { $0.longitude }

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

    private func coordinates(from points: [RoutePoint]) -> [CLLocationCoordinate2D] {
        points.compactMap { point in
            guard point.latitude.isFinite, point.longitude.isFinite else { return nil }
            guard abs(point.latitude) <= 90, abs(point.longitude) <= 180 else { return nil }
            return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
    }
}
