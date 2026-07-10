import AppKit
import MapKit
import RunPlayCore

enum RouteMapLoadState {
    case loading
    case ready
    case unavailable
}

/// Pure geometry describing the Apple Maps snapshot and its SceneKit plane.
struct RouteMapSnapshotLayout {
    let mapRect: MKMapRect
    let projectionOriginLatitude: Double
    let projectionOriginLongitude: Double
    let planeCenterX: CGFloat
    let planeCenterZ: CGFloat
    let planeWidthMeters: CGFloat
    let planeHeightMeters: CGFloat

    static func make(
        routeGroups: [[RoutePoint]],
        projectionOrigin originPoints: [RoutePoint]
    ) -> RouteMapSnapshotLayout? {
        let allCoordinates = routeGroups
            .flatMap { $0 }
            .filter { GeoDistance.isValidCoordinate(lat: $0.latitude, lon: $0.longitude) }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard !allCoordinates.isEmpty else { return nil }

        let validOriginPoints = originPoints.filter {
            GeoDistance.isValidCoordinate(lat: $0.latitude, lon: $0.longitude)
        }
        let originCoordinates = validOriginPoints.isEmpty
            ? allCoordinates
            : validOriginPoints.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }

        guard let minOriginLat = originCoordinates.map(\.latitude).min(),
              let maxOriginLat = originCoordinates.map(\.latitude).max(),
              let minOriginLon = originCoordinates.map(\.longitude).min(),
              let maxOriginLon = originCoordinates.map(\.longitude).max() else {
            return nil
        }
        let originLatitude = (minOriginLat + maxOriginLat) / 2
        let originLongitude = (minOriginLon + maxOriginLon) / 2

        let mapPoints = allCoordinates.map(MKMapPoint.init)
        guard let minX = mapPoints.map(\.x).min(),
              let maxX = mapPoints.map(\.x).max(),
              let minY = mapPoints.map(\.y).min(),
              let maxY = mapPoints.map(\.y).max() else {
            return nil
        }

        let metersPerMapPoint = max(MKMetersPerMapPointAtLatitude(originLatitude), 0.000_001)
        let minimumSpanMapPoints = 500 / metersPerMapPoint
        let contentWidth = max(maxX - minX, minimumSpanMapPoints)
        let contentHeight = max(maxY - minY, minimumSpanMapPoints)
        let paddedSide = max(contentWidth, contentHeight) * 1.35
        let centerMapPoint = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let mapRect = MKMapRect(
            x: centerMapPoint.x - paddedSide / 2,
            y: centerMapPoint.y - paddedSide / 2,
            width: paddedSide,
            height: paddedSide
        )

        let topLeft = MKMapPoint(x: mapRect.origin.x, y: mapRect.origin.y).coordinate
        let bottomRight = MKMapPoint(x: mapRect.maxX, y: mapRect.maxY).coordinate
        let mapCenter = MKMapPoint(x: mapRect.midX, y: mapRect.midY).coordinate

        let centerMeters = GeoDistance.latLonToMeters(
            lat: mapCenter.latitude,
            lon: mapCenter.longitude,
            centerLat: originLatitude,
            centerLon: originLongitude
        )
        let leftMeters = GeoDistance.latLonToMeters(
            lat: mapCenter.latitude,
            lon: topLeft.longitude,
            centerLat: originLatitude,
            centerLon: originLongitude
        )
        let rightMeters = GeoDistance.latLonToMeters(
            lat: mapCenter.latitude,
            lon: bottomRight.longitude,
            centerLat: originLatitude,
            centerLon: originLongitude
        )
        let northMeters = GeoDistance.latLonToMeters(
            lat: topLeft.latitude,
            lon: mapCenter.longitude,
            centerLat: originLatitude,
            centerLon: originLongitude
        )
        let southMeters = GeoDistance.latLonToMeters(
            lat: bottomRight.latitude,
            lon: mapCenter.longitude,
            centerLat: originLatitude,
            centerLon: originLongitude
        )

        let widthMeters = abs(rightMeters.x - leftMeters.x)
        let heightMeters = abs(northMeters.z - southMeters.z)
        guard centerMeters.x.isFinite,
              centerMeters.z.isFinite,
              widthMeters.isFinite,
              heightMeters.isFinite,
              widthMeters > 0,
              heightMeters > 0 else {
            return nil
        }

        return RouteMapSnapshotLayout(
            mapRect: mapRect,
            projectionOriginLatitude: originLatitude,
            projectionOriginLongitude: originLongitude,
            planeCenterX: CGFloat(centerMeters.x),
            planeCenterZ: CGFloat(centerMeters.z),
            planeWidthMeters: CGFloat(widthMeters),
            planeHeightMeters: CGFloat(heightMeters)
        )
    }

    var cacheKey: NSString {
        NSString(
            format: "%.3f:%.3f:%.3f:%.3f:%.6f:%.6f",
            mapRect.origin.x,
            mapRect.origin.y,
            mapRect.size.width,
            mapRect.size.height,
            projectionOriginLatitude,
            projectionOriginLongitude
        )
    }

    func makeOverlay(image: NSImage) -> RouteMapOverlay {
        RouteMapOverlay(
            image: image,
            centerX: planeCenterX,
            centerZ: planeCenterZ,
            widthMeters: planeWidthMeters,
            heightMeters: planeHeightMeters
        )
    }
}

enum RouteMapSnapshotError: LocalizedError {
    case noValidCoordinates
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .noValidCoordinates:
            return "The route has no valid coordinates for a map."
        case .snapshotFailed:
            return "Apple Maps could not render this route area."
        }
    }
}

@MainActor
final class RouteMapSnapshotService {
    private final class CacheEntry: NSObject {
        let overlay: RouteMapOverlay

        init(overlay: RouteMapOverlay) {
            self.overlay = overlay
        }
    }

    private let cache = NSCache<NSString, CacheEntry>()
    private var activeSnapshotter: MKMapSnapshotter?
    private var activeRequestID: UUID?

    func snapshot(
        routeGroups: [[RoutePoint]],
        projectionOrigin: [RoutePoint],
        completion: @escaping (Result<RouteMapOverlay, Error>) -> Void
    ) {
        cancel()

        guard let layout = RouteMapSnapshotLayout.make(
            routeGroups: routeGroups,
            projectionOrigin: projectionOrigin
        ) else {
            completion(.failure(RouteMapSnapshotError.noValidCoordinates))
            return
        }

        if let cached = cache.object(forKey: layout.cacheKey) {
            completion(.success(cached.overlay))
            return
        }

        let options = MKMapSnapshotter.Options()
        options.mapRect = layout.mapRect
        options.size = NSSize(width: 1_536, height: 1_536)
        options.appearance = NSApp.effectiveAppearance

        let configuration = MKStandardMapConfiguration(
            elevationStyle: .flat,
            emphasisStyle: .default
        )
        configuration.pointOfInterestFilter = .includingAll
        options.preferredConfiguration = configuration

        let requestID = UUID()
        let snapshotter = MKMapSnapshotter(options: options)
        activeRequestID = requestID
        activeSnapshotter = snapshotter

        snapshotter.start { [weak self] snapshot, error in
            guard let self, self.activeRequestID == requestID else { return }
            self.activeSnapshotter = nil
            self.activeRequestID = nil

            guard error == nil, let image = snapshot?.image else {
                completion(.failure(error ?? RouteMapSnapshotError.snapshotFailed))
                return
            }

            let overlay = layout.makeOverlay(image: image)
            self.cache.setObject(CacheEntry(overlay: overlay), forKey: layout.cacheKey)
            completion(.success(overlay))
        }
    }

    func cancel() {
        activeSnapshotter?.cancel()
        activeSnapshotter = nil
        activeRequestID = nil
    }
}
