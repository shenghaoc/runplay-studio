import AppKit
import CoreGraphics
import Foundation
import MapKit
import RunPlayCore

// MARK: - Models

/// Static combined map for comparison video with per-workout pixel maps.
public struct ComparisonVideoMapPreparation: @unchecked Sendable {
    public let staticMapImage: CGImage
    public let primaryPixelMap: ComparisonVideoRoutePixelMap
    public let comparisonPixelMap: ComparisonVideoRoutePixelMap
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let routesAreWidelySeparated: Bool

    public init(
        staticMapImage: CGImage,
        primaryPixelMap: ComparisonVideoRoutePixelMap,
        comparisonPixelMap: ComparisonVideoRoutePixelMap,
        routesAreWidelySeparated: Bool = false
    ) {
        self.staticMapImage = staticMapImage
        self.primaryPixelMap = primaryPixelMap
        self.comparisonPixelMap = comparisonPixelMap
        self.pixelWidth = staticMapImage.width
        self.pixelHeight = staticMapImage.height
        self.routesAreWidelySeparated = routesAreWidelySeparated
    }
}

/// Request for a combined two-route comparison basemap.
public struct ComparisonVideoMapPreparationRequest: Sendable {
    public let size: CGSize
    public let appearance: WorkoutMapSnapshotAppearance
    public let primaryRoutePoints: [RoutePoint]
    public let comparisonRoutePoints: [RoutePoint]
    public let lineWidth: CGFloat
    public let cacheKey: WorkoutMapSnapshotCacheKey?

    public init(
        size: CGSize,
        appearance: WorkoutMapSnapshotAppearance,
        primaryRoutePoints: [RoutePoint],
        comparisonRoutePoints: [RoutePoint],
        lineWidth: CGFloat = 5,
        cacheKey: WorkoutMapSnapshotCacheKey? = nil
    ) {
        self.size = size
        self.appearance = appearance
        self.primaryRoutePoints = primaryRoutePoints
        self.comparisonRoutePoints = comparisonRoutePoints
        self.lineWidth = lineWidth
        self.cacheKey = cacheKey
    }
}

public protocol ComparisonVideoMapPreparing: Sendable {
    func prepare(
        request: ComparisonVideoMapPreparationRequest
    ) async throws -> ComparisonVideoMapPreparation
}

// MARK: - MapKit preparer

/// One MapKit snapshot for both comparison routes; no moving markers.
public struct MapKitComparisonVideoMapPreparer: ComparisonVideoMapPreparing, Sendable {
    public init() {}

    public func prepare(
        request: ComparisonVideoMapPreparationRequest
    ) async throws -> ComparisonVideoMapPreparation {
        try Task.checkCancellation()

        let primaryLines = RouteMapContent.segmentedRoutes(
            idPrefix: "comparison-video-primary",
            points: request.primaryRoutePoints,
            style: .primary
        )
        let comparisonLines = RouteMapContent.segmentedRoutes(
            idPrefix: "comparison-video-comparison",
            points: request.comparisonRoutePoints,
            style: .comparison
        )
        let routes = primaryLines + comparisonLines
        guard routes.contains(where: { !$0.coordinates.isEmpty }) else {
            throw WorkoutMapSnapshotError.emptyRoute
        }

        let size = request.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            throw WorkoutMapSnapshotError.invalidRegion
        }

        // No endpoint markers: P/C identity is drawn by the frame renderer.
        let markers: [RouteMapMarker] = []

        guard let mapRect = MapSnapshotRegionPlanner.planMapRect(
            routes: routes,
            markers: markers,
            imageSize: size
        ) else {
            throw WorkoutMapSnapshotError.invalidRegion
        }

        let widelySeparated = Self.routesAreWidelySeparated(
            primary: request.primaryRoutePoints,
            comparison: request.comparisonRoutePoints
        )

        let snapshotRequest = WorkoutMapSnapshotRequest(
            size: size,
            appearance: request.appearance,
            routes: routes,
            markers: markers,
            lineWidth: request.lineWidth,
            cacheKey: request.cacheKey
        )
        let options = MapKitWorkoutMapSnapshotter.makeSnapshotOptions(
            request: snapshotRequest,
            mapRect: mapRect
        )

        let holder = MapKitSnapshotterSession<ComparisonVideoMapPreparation>(
            options: options
        ) { snapshot, isCancelled in
            let basemap = try WorkoutMapSnapshotImageNormalizer.normalizedCGImage(
                from: snapshot.image,
                targetSize: request.size
            )
            let converter = ImmediateCoordinateConverter(snapshot: snapshot)

            let primaryPixels = try Self.pixelMap(
                points: request.primaryRoutePoints,
                converter: converter,
                isCancelled: isCancelled
            )
            let comparisonPixels = try Self.pixelMap(
                points: request.comparisonRoutePoints,
                converter: converter,
                isCancelled: isCancelled
            )

            let composed = try MapSnapshotOverlayComposer.compose(
                basemap: basemap,
                routes: routes,
                markers: markers,
                converter: converter,
                lineWidth: request.lineWidth,
                isCancelled: isCancelled
            )
            return ComparisonVideoMapPreparation(
                staticMapImage: composed.cgImage,
                primaryPixelMap: primaryPixels,
                comparisonPixelMap: comparisonPixels,
                routesAreWidelySeparated: widelySeparated
            )
        }

        do {
            return try await withTaskCancellationHandler {
                try await holder.start()
            } onCancel: {
                holder.cancel()
            }
        } catch is CancellationError {
            throw ComparisonVideoExportError.cancelled
        } catch let error as WorkoutMapSnapshotError {
            if error == .cancelled {
                throw ComparisonVideoExportError.cancelled
            }
            throw ComparisonVideoExportError.mapPreparationFailed(error.localizedDescription)
        } catch let error as ComparisonVideoExportError {
            throw error
        } catch {
            throw ComparisonVideoExportError.mapPreparationFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func pixelMap(
        points: [RoutePoint],
        converter: ImmediateCoordinateConverter,
        isCancelled: () -> Bool
    ) throws -> ComparisonVideoRoutePixelMap {
        var samples: [ComparisonVideoPixelSample] = []
        samples.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            if isCancelled() { throw CancellationError() }
            guard let coord = RouteMapCoordinate(point) else { continue }
            samples.append(
                ComparisonVideoPixelSample(
                    routePointID: point.id,
                    routePointIndex: index,
                    routeSegmentIndex: point.routeSegmentIndex,
                    distanceMeters: point.distanceFromStartMeters,
                    point: converter.point(for: coord)
                )
            )
        }
        return ComparisonVideoRoutePixelMap(samples: samples)
    }

    /// True when route centroids are more than ~50 km apart (wide basemap).
    private static func routesAreWidelySeparated(
        primary: [RoutePoint],
        comparison: [RoutePoint]
    ) -> Bool {
        guard let p = centroid(primary), let c = centroid(comparison) else { return false }
        let metres = GeoDistance.distanceMeters(
            fromLat: p.latitude,
            lon: p.longitude,
            toLat: c.latitude,
            lon: c.longitude
        )
        return metres.isFinite && metres > 50_000
    }

    private static func centroid(_ points: [RoutePoint]) -> (latitude: Double, longitude: Double)? {
        var lat = 0.0
        var lon = 0.0
        var count = 0
        for point in points {
            guard GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude) else {
                continue
            }
            lat += point.latitude
            lon += point.longitude
            count += 1
        }
        guard count > 0 else { return nil }
        return (lat / Double(count), lon / Double(count))
    }
}

// MARK: - Synthetic preparer (tests)

/// Deterministic linear projector for unit tests — no MapKit network.
public struct SyntheticComparisonVideoMapPreparer: ComparisonVideoMapPreparing, Sendable {
    public init() {}

    public func prepare(
        request: ComparisonVideoMapPreparationRequest
    ) async throws -> ComparisonVideoMapPreparation {
        try Task.checkCancellation()
        let width = max(2, Int(request.size.width.rounded()))
        let height = max(2, Int(request.size.height.rounded()))

        let allPoints = request.primaryRoutePoints + request.comparisonRoutePoints
        let coords = allPoints.compactMap(RouteMapCoordinate.init)
        guard !coords.isEmpty else {
            throw WorkoutMapSnapshotError.emptyRoute
        }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0
        let converter = LinearMapCoordinateConverter(
            minLatitude: minLat == maxLat ? minLat - 0.001 : minLat,
            maxLatitude: minLat == maxLat ? maxLat + 0.001 : maxLat,
            minLongitude: minLon == maxLon ? minLon - 0.001 : minLon,
            maxLongitude: minLon == maxLon ? maxLon + 0.001 : maxLon,
            size: CGSize(width: width, height: height)
        )

        let primaryLines = RouteMapContent.segmentedRoutes(
            idPrefix: "syn-p",
            points: request.primaryRoutePoints,
            style: .primary
        )
        let comparisonLines = RouteMapContent.segmentedRoutes(
            idPrefix: "syn-c",
            points: request.comparisonRoutePoints,
            style: .comparison
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ComparisonVideoExportError.mapPreparationFailed("Could not create synthetic context")
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let basemap = context.makeImage() else {
            throw ComparisonVideoExportError.mapPreparationFailed(
                "Could not create synthetic basemap image"
            )
        }
        let composed = try MapSnapshotOverlayComposer.compose(
            basemap: basemap,
            routes: primaryLines + comparisonLines,
            markers: [],
            converter: converter,
            lineWidth: request.lineWidth,
            isCancelled: { Task.isCancelled }
        )

        func map(_ points: [RoutePoint]) -> ComparisonVideoRoutePixelMap {
            var samples: [ComparisonVideoPixelSample] = []
            for (index, point) in points.enumerated() {
                guard let coord = RouteMapCoordinate(point) else { continue }
                samples.append(
                    ComparisonVideoPixelSample(
                        routePointID: point.id,
                        routePointIndex: index,
                        routeSegmentIndex: point.routeSegmentIndex,
                        distanceMeters: point.distanceFromStartMeters,
                        point: converter.point(for: coord)
                    )
                )
            }
            return ComparisonVideoRoutePixelMap(samples: samples)
        }

        return ComparisonVideoMapPreparation(
            staticMapImage: composed.cgImage,
            primaryPixelMap: map(request.primaryRoutePoints),
            comparisonPixelMap: map(request.comparisonRoutePoints),
            routesAreWidelySeparated: false
        )
    }
}
