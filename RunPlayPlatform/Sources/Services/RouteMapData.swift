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
public struct RouteMapCoordinate: Hashable, Sendable {
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
///
/// Metric styles are palette-independent tokens. Comparison routes must never
/// use `.metric` — primary/comparison identity takes precedence.
public enum RouteMapLineStyle: Hashable, Sendable {
    case primary
    case comparison
    case metric(mode: WorkoutRouteColorMode, bucket: RouteMetricColorBucket)
}

/// A route line for map display.
public struct RouteMapLine: Identifiable, Hashable, Sendable {
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

/// A filled map area (heatmap cell polygon) for MapKit presentation.
///
/// Core owns cell aggregation; Platform converts Core cells into ordered
/// polygon coordinates without importing SwiftUI.
public struct RouteMapArea: Identifiable, Hashable, Sendable {
    public let id: String
    /// Closed polygon ring in counter-clockwise order (SW → SE → NE → NW → SW).
    public let coordinates: [RouteMapCoordinate]
    /// Visual intensity in `0...1` from distinct-workout log normalization.
    public let normalizedIntensity: Double
    /// Distinct included workouts whose route traversed this cell.
    public let workoutCount: Int

    public init(
        id: String,
        coordinates: [RouteMapCoordinate],
        normalizedIntensity: Double,
        workoutCount: Int
    ) {
        self.id = id
        self.coordinates = coordinates
        self.normalizedIntensity = normalizedIntensity
        self.workoutCount = workoutCount
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
    /// Build a single route line. Multi-segment input deliberately returns an
    /// empty line so this compatibility API cannot bridge a recording gap;
    /// callers rendering a workout route should use `segmentedRoutes`.
    public static func route(
        id: String,
        points: [RoutePoint],
        style: RouteMapLineStyle
    ) -> RouteMapLine {
        let segmentIndexes = Set(points.map(\.routeSegmentIndex))
        guard segmentIndexes.count <= 1 else {
            return RouteMapLine(id: id, coordinates: [], style: style)
        }
        return RouteMapLine(
            id: id,
            coordinates: points.compactMap(RouteMapCoordinate.init),
            style: style
        )
    }

    /// Produce one `RouteMapLine` per route segment so the map never draws a
    /// polyline across a GPS gap.
    public static func segmentedRoutes(
        idPrefix: String,
        points: [RoutePoint],
        style: RouteMapLineStyle
    ) -> [RouteMapLine] {
        guard !points.isEmpty else { return [] }

        var lines: [RouteMapLine] = []
        var currentSegment: Int = points[0].routeSegmentIndex
        var currentCoords: [RouteMapCoordinate] = []

        for point in points {
            if point.routeSegmentIndex != currentSegment {
                if !currentCoords.isEmpty {
                    lines.append(RouteMapLine(
                        id: "\(idPrefix)-seg-\(currentSegment)",
                        coordinates: currentCoords,
                        style: style
                    ))
                }
                currentSegment = point.routeSegmentIndex
                currentCoords = []
            }
            if let coord = RouteMapCoordinate(point) {
                currentCoords.append(coord)
            }
        }

        if !currentCoords.isEmpty {
            lines.append(RouteMapLine(
                id: "\(idPrefix)-seg-\(currentSegment)",
                coordinates: currentCoords,
                style: style
            ))
        }

        return lines
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
        mapRect(routes: routes, areas: [])
    }

    /// Map rect from routes and/or filled areas. Empty content returns `nil`.
    ///
    /// Preserves the existing minimum span and world clamping used by route-only
    /// fitting. Antimeridian-spanning content is handled conservatively by MapKit
    /// point union (may expand near the dateline rather than wrapping).
    public static func mapRect(
        routes: [RouteMapLine] = [],
        areas: [RouteMapArea] = []
    ) -> MKMapRect? {
        // Pre-size once; avoid flatMap + array concatenation intermediates on
        // large heatmap area lists (up to the rendered-cell budget × ring size).
        var coordinateCount = 0
        for route in routes { coordinateCount += route.coordinates.count }
        for area in areas { coordinateCount += area.coordinates.count }
        guard coordinateCount > 0 else { return nil }

        var rect = MKMapRect.null
        var latitudeSum = 0.0
        var latitudeCount = 0

        func accumulate(_ coordinates: [RouteMapCoordinate]) {
            for coordinate in coordinates {
                let point = MKMapPoint(coordinate.mapKitCoordinate)
                let pointRect = MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
                rect = rect.isNull ? pointRect : rect.union(pointRect)
                latitudeSum += coordinate.latitude
                latitudeCount += 1
            }
        }

        for route in routes { accumulate(route.coordinates) }
        for area in areas { accumulate(area.coordinates) }
        guard latitudeCount > 0, !rect.isNull else { return nil }

        let latitude = latitudeSum / Double(latitudeCount)
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
        cameraPlan(routes: routes, areas: [])
    }

    public static func cameraPlan(
        routes: [RouteMapLine] = [],
        areas: [RouteMapArea] = []
    ) -> RouteMapCameraPlan? {
        guard let rect = mapRect(routes: routes, areas: areas) else { return nil }
        let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let metersPerMapPoint = max(MKMetersPerMapPointAtLatitude(center.latitude), 0.000_001)
        let widthMeters = rect.width * metersPerMapPoint
        let heightMeters = rect.height * metersPerMapPoint
        let distance = max(max(widthMeters, heightMeters) * 2.25, 900)
        return RouteMapCameraPlan(center: center, distance: distance)
    }

    /// Convert Core heatmap cells into stable Platform map areas.
    public static func areas(from snapshot: PersonalHeatmapSnapshot) -> [RouteMapArea] {
        snapshot.cells.compactMap { cell in
            let coords = cell.bounds.polygonCoordinates.compactMap {
                RouteMapCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            }
            guard coords.count >= 4 else { return nil }
            return RouteMapArea(
                id: "heatmap-\(cell.id.x)-\(cell.id.y)",
                coordinates: coords,
                normalizedIntensity: cell.normalizedIntensity,
                workoutCount: cell.workoutCount
            )
        }
    }
}
