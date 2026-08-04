import AppKit
import CoreGraphics
import Foundation
import MapKit
import RunPlayCore

// MARK: - Pixel identity

/// Pixel position for one route point in the prepared static map image.
///
/// Coordinates use the same bottom-left origin as MapKit snapshot conversion
/// and Core Graphics contexts used by the frame renderer.
public struct WorkoutVideoRoutePixel: Hashable, Sendable {
    public let routePointID: UUID
    public let routePointIndex: Int
    public let routeSegmentIndex: Int
    public let point: CGPoint

    public init(
        routePointID: UUID,
        routePointIndex: Int,
        routeSegmentIndex: Int,
        point: CGPoint
    ) {
        self.routePointID = routePointID
        self.routePointIndex = routePointIndex
        self.routeSegmentIndex = routeSegmentIndex
        self.point = point
    }
}

// MARK: - Request / result

/// Request for a static video basemap plus per-point pixel mapping.
public struct WorkoutVideoMapPreparationRequest: Sendable {
    public let size: CGSize
    public let appearance: WorkoutMapSnapshotAppearance
    public let routes: [RouteMapLine]
    public let markers: [RouteMapMarker]
    public let routePoints: [RoutePoint]
    public let lineWidth: CGFloat
    public let cacheKey: WorkoutMapSnapshotCacheKey?

    public init(
        size: CGSize,
        appearance: WorkoutMapSnapshotAppearance,
        routes: [RouteMapLine],
        markers: [RouteMapMarker],
        routePoints: [RoutePoint],
        lineWidth: CGFloat = 5,
        cacheKey: WorkoutMapSnapshotCacheKey? = nil
    ) {
        self.size = size
        self.appearance = appearance
        self.routes = routes
        self.markers = markers
        self.routePoints = routePoints
        self.lineWidth = lineWidth
        self.cacheKey = cacheKey
    }
}

/// Static map preparation for video: basemap with route overlays and pixels.
public struct WorkoutVideoMapPreparation: @unchecked Sendable {
    public let staticMapImage: CGImage
    /// One entry per source route point index; `nil` when coordinate invalid.
    public let routePointPixels: [WorkoutVideoRoutePixel?]
    public let containsNoDataLines: Bool
    public let effectiveRouteColorMode: WorkoutRouteColorMode
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        staticMapImage: CGImage,
        routePointPixels: [WorkoutVideoRoutePixel?],
        containsNoDataLines: Bool,
        effectiveRouteColorMode: WorkoutRouteColorMode
    ) {
        self.staticMapImage = staticMapImage
        self.routePointPixels = routePointPixels
        self.containsNoDataLines = containsNoDataLines
        self.effectiveRouteColorMode = effectiveRouteColorMode
        self.pixelWidth = staticMapImage.width
        self.pixelHeight = staticMapImage.height
    }

    /// Returns a copy with effective route-colour mode filled by the orchestrator.
    public func withEffectiveRouteColorMode(_ mode: WorkoutRouteColorMode) -> WorkoutVideoMapPreparation {
        WorkoutVideoMapPreparation(
            staticMapImage: staticMapImage,
            routePointPixels: routePointPixels,
            containsNoDataLines: containsNoDataLines,
            effectiveRouteColorMode: mode
        )
    }

    /// Resolve a marker pixel for the given sample without crossing segments.
    ///
    /// Search order: exact index → backward in same segment → forward in same
    /// segment. Returns `nil` when no valid pixel exists in the segment.
    public func markerPixel(for sample: WorkoutVideoFrameSample) -> CGPoint? {
        Self.markerPixel(
            routePointIndex: sample.routePointIndex,
            routeSegmentIndex: sample.routeSegmentIndex,
            pixels: routePointPixels
        )
    }

    /// First non-nil pixel without allocating a compacted copy of `pixels`.
    public static func firstNonNilPixel(in pixels: [WorkoutVideoRoutePixel?]) -> WorkoutVideoRoutePixel? {
        for case let pixel? in pixels {
            return pixel
        }
        return nil
    }

    /// Last non-nil pixel without allocating a compacted copy of `pixels`.
    public static func lastNonNilPixel(in pixels: [WorkoutVideoRoutePixel?]) -> WorkoutVideoRoutePixel? {
        for case let pixel? in pixels.reversed() {
            return pixel
        }
        return nil
    }

    public static func markerPixel(
        routePointIndex: Int,
        routeSegmentIndex: Int,
        pixels: [WorkoutVideoRoutePixel?]
    ) -> CGPoint? {
        guard !pixels.isEmpty else { return nil }
        let index = min(max(0, routePointIndex), pixels.count - 1)

        if let exact = pixels[index],
           exact.routeSegmentIndex == routeSegmentIndex {
            return exact.point
        }

        // Backward within the same segment.
        var backward = index - 1
        while backward >= 0 {
            if let pixel = pixels[backward] {
                if pixel.routeSegmentIndex != routeSegmentIndex { break }
                return pixel.point
            }
            backward -= 1
        }

        // Forward within the same segment.
        var forward = index + 1
        while forward < pixels.count {
            if let pixel = pixels[forward] {
                if pixel.routeSegmentIndex != routeSegmentIndex { break }
                return pixel.point
            }
            forward += 1
        }

        return nil
    }
}

// MARK: - Protocol

/// Prepares one static map image and route-point pixel mapping for video export.
public protocol WorkoutVideoMapPreparing: Sendable {
    func prepare(
        request: WorkoutVideoMapPreparationRequest
    ) async throws -> WorkoutVideoMapPreparation
}

// MARK: - MapKit preparer

/// MapKit-backed preparer: one snapshot, overlay composition, pixel capture.
public struct MapKitWorkoutVideoMapPreparer: WorkoutVideoMapPreparing, Sendable {
    public init() {}

    public func prepare(
        request: WorkoutVideoMapPreparationRequest
    ) async throws -> WorkoutVideoMapPreparation {
        try Task.checkCancellation()

        guard request.routes.contains(where: { !$0.coordinates.isEmpty })
            || !request.markers.isEmpty else {
            throw WorkoutMapSnapshotError.emptyRoute
        }

        let size = request.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            throw WorkoutMapSnapshotError.invalidRegion
        }

        guard let mapRect = MapSnapshotRegionPlanner.planMapRect(
            routes: request.routes,
            markers: request.markers,
            imageSize: size
        ) else {
            throw WorkoutMapSnapshotError.invalidRegion
        }

        let snapshotRequest = WorkoutMapSnapshotRequest(
            size: size,
            appearance: request.appearance,
            routes: request.routes,
            markers: request.markers,
            lineWidth: request.lineWidth,
            cacheKey: request.cacheKey
        )
        let options = MapKitWorkoutMapSnapshotter.makeSnapshotOptions(
            request: snapshotRequest,
            mapRect: mapRect
        )

        let holder = MapKitSnapshotterSession<WorkoutVideoMapPreparation>(
            options: options
        ) { snapshot, isCancelled in
            let basemap = try WorkoutMapSnapshotImageNormalizer.normalizedCGImage(
                from: snapshot.image,
                targetSize: request.size
            )
            let converter = ImmediateCoordinateConverter(snapshot: snapshot)

            var pixels: [WorkoutVideoRoutePixel?] = []
            pixels.reserveCapacity(request.routePoints.count)
            for (index, point) in request.routePoints.enumerated() {
                if isCancelled() { throw CancellationError() }
                if let coord = RouteMapCoordinate(point) {
                    pixels.append(
                        WorkoutVideoRoutePixel(
                            routePointID: point.id,
                            routePointIndex: index,
                            routeSegmentIndex: point.routeSegmentIndex,
                            point: converter.point(for: coord)
                        )
                    )
                } else {
                    pixels.append(nil)
                }
            }

            let composed = try MapSnapshotOverlayComposer.compose(
                basemap: basemap,
                routes: request.routes,
                markers: request.markers,
                converter: converter,
                lineWidth: request.lineWidth,
                isCancelled: isCancelled
            )
            return WorkoutVideoMapPreparation(
                staticMapImage: composed.cgImage,
                routePointPixels: pixels,
                containsNoDataLines: composed.containsNoDataLines,
                effectiveRouteColorMode: .solid
            )
        }
        do {
            return try await withTaskCancellationHandler {
                try await holder.start()
            } onCancel: {
                holder.cancel()
            }
        } catch is CancellationError {
            throw WorkoutMapSnapshotError.cancelled
        }
    }
}

// MARK: - Synthetic preparer (tests)

/// Deterministic preparer that draws a blank basemap and maps points linearly.
#if DEBUG
struct SyntheticWorkoutVideoMapPreparer: WorkoutVideoMapPreparing, Sendable {
    let fillColor: NSColor

    init(fillColor: NSColor = NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.2, alpha: 1)) {
        self.fillColor = fillColor
    }

    func prepare(
        request: WorkoutVideoMapPreparationRequest
    ) async throws -> WorkoutVideoMapPreparation {
        try Task.checkCancellation()
        let width = max(1, Int(request.size.width.rounded()))
        let height = max(1, Int(request.size.height.rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WorkoutMapSnapshotError.compositionFailed(
                "Could not create the sRGB color space"
            )
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WorkoutMapSnapshotError.compositionFailed("Could not create synthetic basemap")
        }

        context.setFillColor(fillColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Simple linear layout of valid coordinates across the canvas.
        // ⚡ Bolt: Count valids with an inline loop instead of materializing a compactMapped pairs array.
        var validPointsCount = 0
        for point in request.routePoints {
            if RouteMapCoordinate(point) != nil {
                validPointsCount += 1
            }
        }

        var pixels: [WorkoutVideoRoutePixel?] = Array(repeating: nil, count: request.routePoints.count)
        if validPointsCount > 0 {
            var order = 0
            for (index, point) in request.routePoints.enumerated() {
                if RouteMapCoordinate(point) != nil {
                    try Task.checkCancellation()
                    let t = validPointsCount == 1 ? 0.5 : Double(order) / Double(validPointsCount - 1)
                    let x = 40 + t * Double(width - 80)
                    let y = Double(height) * 0.5
                    pixels[index] = WorkoutVideoRoutePixel(
                        routePointID: point.id,
                        routePointIndex: index,
                        routeSegmentIndex: point.routeSegmentIndex,
                        point: CGPoint(x: x, y: y)
                    )
                    order += 1
                }
            }
        }

        // Draw route polyline through known pixels.
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(request.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        var started = false
        for pixel in pixels {
            guard let pixel else { continue }
            if !started {
                context.move(to: pixel.point)
                started = true
            } else {
                context.addLine(to: pixel.point)
            }
        }
        if started {
            context.strokePath()
        }

        // Start / finish markers.
        // ⚡ Bolt: Scan for first/last non-nil instead of compactMap({ $0 }).first/last (full array).
        if let first = WorkoutVideoMapPreparation.firstNonNilPixel(in: pixels) {
            context.setFillColor(NSColor.systemGreen.cgColor)
            context.fillEllipse(in: CGRect(x: first.point.x - 8, y: first.point.y - 8, width: 16, height: 16))
        }
        if let last = WorkoutVideoMapPreparation.lastNonNilPixel(in: pixels) {
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(x: last.point.x - 8, y: last.point.y - 8, width: 16, height: 16))
        }

        guard let image = context.makeImage() else {
            throw WorkoutMapSnapshotError.compositionFailed("Could not finalize synthetic basemap")
        }

        return WorkoutVideoMapPreparation(
            staticMapImage: image,
            routePointPixels: pixels,
            containsNoDataLines: false,
            effectiveRouteColorMode: .solid
        )
    }
}
#endif
