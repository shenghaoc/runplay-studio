import Foundation
import RunPlayCore
import MapKit


/// Display mode for the route map (2D vs 3D).
public enum RouteMapDisplayMode: String, CaseIterable, Hashable {
    case twoD = "2D"
    case threeD = "3D"

    public var cameraPitch: Double {
        switch self {
        case .twoD: return 0
        case .threeD: return 58
        }
    }
}

/// A validated coordinate for map display.
public struct RouteMapCoordinate: Hashable {
    public let latitude: Double
    public let longitude: Double

    public init?(latitude: Double, longitude: Double) {
        guard GeoDistance.isValidCoordinate(lat: latitude, lon: longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    public init?(_ point: RoutePoint) {
        self.init(latitude: point.latitude, longitude: point.longitude)
    }

    public var mapKitCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Line style for route display.
public enum RouteMapLineStyle: Hashable {
    case primary
    case comparison
}

/// A route line for map display.
public struct RouteMapLine: Identifiable, Hashable {
    public let id: String
    public let coordinates: [RouteMapCoordinate]
    public let style: RouteMapLineStyle

    public init(id: String, coordinates: [RouteMapCoordinate], style: RouteMapLineStyle) {
        self.id = id
        self.coordinates = coordinates
        self.style = style
    }
}

/// Marker style for map annotations.
public enum RouteMapMarkerStyle: Hashable {
    case start
    case finish
    case current
    case primaryCurrent
    case comparisonCurrent

    public var glyph: String {
        switch self {
        case .start: return "S"
        case .finish: return "F"
        case .current: return "●"
        case .primaryCurrent: return "P"
        case .comparisonCurrent: return "C"
        }
    }
}

/// A marker annotation for the map.
public struct RouteMapMarker: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let coordinate: RouteMapCoordinate
    public let style: RouteMapMarkerStyle

    public init(id: String, title: String, coordinate: RouteMapCoordinate, style: RouteMapMarkerStyle) {
        self.id = id
        self.title = title
        self.coordinate = coordinate
        self.style = style
    }
}

/// Camera plan for map positioning.
public struct RouteMapCameraPlan {
    public let center: CLLocationCoordinate2D
    public let distance: CLLocationDistance

    public init(center: CLLocationCoordinate2D, distance: CLLocationDistance) {
        self.center = center
        self.distance = distance
    }
}

/// Helpers for building map content from route data.
public enum RouteMapContent {
    public static func route(
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

    public static func endpointMarkers(
        points: [RoutePoint],
        idPrefix: String,
        startTitle: String = "Start",
        finishTitle: String = "Finish"
    ) -> [RouteMapMarker] {
        let coordinates = points.compactMap(RouteMapCoordinate.init)
        guard let first = coordinates.first else { return [] }

        var markers = [
            RouteMapMarker(
                id: "\(idPrefix)-start",
                title: startTitle,
                coordinate: first,
                style: .start
            )
        ]

        if let last = coordinates.last, coordinates.count > 1 {
            markers.append(
                RouteMapMarker(
                    id: "\(idPrefix)-finish",
                    title: finishTitle,
                    coordinate: last,
                    style: .finish
                )
            )
        }
        return markers
    }

    public static func currentMarker(
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

    public static func marker(
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

    public static func mapRect(for routes: [RouteMapLine]) -> MKMapRect? {
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

    public static func cameraPlan(for routes: [RouteMapLine]) -> RouteMapCameraPlan? {
        guard let rect = mapRect(for: routes) else { return nil }
        let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let metersPerMapPoint = max(MKMetersPerMapPointAtLatitude(center.latitude), 0.000_001)
        let widthMeters = rect.width * metersPerMapPoint
        let heightMeters = rect.height * metersPerMapPoint
        let distance = max(max(widthMeters, heightMeters) * 2.25, 900)
        return RouteMapCameraPlan(center: center, distance: distance)
    }
}
