import AppKit
import CoreGraphics
import Foundation
import RunPlayCore

/// Composites route lines and endpoint markers onto a basemap image.
///
/// Does not bridge separate `RouteMapLine` values. Does not draw replay/current
/// markers. Unit tests inject a synthetic coordinate converter and blank basemap
/// so they do not depend on Apple map tiles.
public enum MapSnapshotOverlayComposer: Sendable {
    public static let defaultLineWidth: CGFloat = 5
    public static let markerRadius: CGFloat = 10
    public static let markerBorderWidth: CGFloat = 2.5

    /// Draw routes and markers into a new image of the basemap’s pixel size.
    public static func compose(
        basemap: CGImage,
        routes: [RouteMapLine],
        markers: [RouteMapMarker],
        converter: any MapCoordinateConverting,
        lineWidth: CGFloat = defaultLineWidth,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> WorkoutMapSnapshotResult {
        if isCancelled() { throw WorkoutMapSnapshotError.cancelled }

        let width = basemap.width
        let height = basemap.height
        guard width > 0, height > 0 else {
            throw WorkoutMapSnapshotError.compositionFailed("Basemap has zero size")
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw WorkoutMapSnapshotError.compositionFailed("Could not create graphics context")
        }

        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high

        // MapKit snapshot points and this CGContext both use a bottom-left origin.
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(basemap, in: bounds)

        var containsNoData = false

        for route in routes {
            if isCancelled() { throw WorkoutMapSnapshotError.cancelled }
            guard route.coordinates.count >= 2 else { continue }

            if case .metric(_, .noData) = route.style {
                containsNoData = true
            }

            context.saveGState()
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(lineWidth)
            let color = nsColor(for: route.style)
            context.setStrokeColor(color.cgColor)

            let path = CGMutablePath()
            var isFirst = true
            // ⚡ Bolt: Use an inline loop to build the path, avoiding map and flatMap
            // which cause intermediate O(N) array allocations during map drawing.
            for coordinate in route.coordinates {
                let point = converter.point(for: coordinate)
                if isFirst {
                    path.move(to: point)
                    isFirst = false
                } else {
                    path.addLine(to: point)
                }
            }
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }

        for marker in markers {
            if isCancelled() { throw WorkoutMapSnapshotError.cancelled }
            // Export never includes live replay markers.
            guard marker.style == .start || marker.style == .finish else { continue }

            let point = converter.point(for: marker.coordinate)
            // Skip markers that fall completely outside the image.
            if point.x < -markerRadius || point.y < -markerRadius
                || point.x > CGFloat(width) + markerRadius
                || point.y > CGFloat(height) + markerRadius {
                continue
            }

            let fill = markerFillColor(marker.style)
            let border = NSColor.white

            context.saveGState()
            let diameter = markerRadius * 2
            let rect = CGRect(
                x: point.x - markerRadius,
                y: point.y - markerRadius,
                width: diameter,
                height: diameter
            )
            context.setFillColor(fill.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(border.cgColor)
            context.setLineWidth(markerBorderWidth)
            context.strokeEllipse(in: rect)

            // Core Text uses the same bottom-left coordinate system here.
            let font = NSFont.systemFont(ofSize: 11, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: marker.style.glyph, attributes: attrs)
            )
            let bounds = CTLineGetBoundsWithOptions(line, [])
            context.textPosition = CGPoint(
                x: point.x - bounds.midX,
                y: point.y - bounds.midY
            )
            CTLineDraw(line, context)
            context.restoreGState()
        }

        guard let image = context.makeImage() else {
            throw WorkoutMapSnapshotError.compositionFailed("Could not finalize composited image")
        }
        return WorkoutMapSnapshotResult(cgImage: image, containsNoDataLines: containsNoData)
    }

    // MARK: - Colors

    private static func nsColor(for style: RouteMapLineStyle) -> NSColor {
        switch style {
        case .primary:
            return RouteMetricPalette.nsColor(hex: 0x0A84FF, alpha: 1)
        case .comparison:
            return RouteMetricPalette.nsColor(hex: 0xFF9F0A, alpha: 1)
        case .metric(let mode, let bucket):
            return RouteMetricPalette.nsColor(mode: mode, bucket: bucket)
        }
    }

    private static func markerFillColor(_ style: RouteMapMarkerStyle) -> NSColor {
        switch style {
        case .start:
            return RouteMetricPalette.nsColor(hex: 0x30D158, alpha: 1)
        case .finish:
            return RouteMetricPalette.nsColor(hex: 0xFF453A, alpha: 1)
        case .current, .primaryCurrent, .comparisonCurrent:
            return RouteMetricPalette.nsColor(hex: 0xFFD60A, alpha: 1)
        }
    }
}

/// Linear projector for tests: maps lat/lon into a fixed image via simple scaling.
public struct LinearMapCoordinateConverter: MapCoordinateConverting, Sendable {
    public let minLatitude: Double
    public let maxLatitude: Double
    public let minLongitude: Double
    public let maxLongitude: Double
    public let size: CGSize

    public init(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double,
        size: CGSize
    ) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
        self.size = size
    }

    public init(routes: [RouteMapLine], size: CGSize) {
        var minLat = Double.infinity
        var maxLat = -Double.infinity
        var minLon = Double.infinity
        var maxLon = -Double.infinity
        var hasCoords = false

        // ⚡ Bolt: Used a manual loop instead of chained .flatMap().map().min() to
        // eliminate multiple intermediate O(N) array allocations per instantiation.
        for route in routes {
            for coordinate in route.coordinates {
                hasCoords = true
                if coordinate.latitude < minLat { minLat = coordinate.latitude }
                if coordinate.latitude > maxLat { maxLat = coordinate.latitude }
                if coordinate.longitude < minLon { minLon = coordinate.longitude }
                if coordinate.longitude > maxLon { maxLon = coordinate.longitude }
            }
        }

        self.minLatitude = hasCoords ? minLat : 0
        self.maxLatitude = hasCoords ? maxLat : 1
        self.minLongitude = hasCoords ? minLon : 0
        self.maxLongitude = hasCoords ? maxLon : 1
        self.size = size
    }

    public func point(for coordinate: RouteMapCoordinate) -> CGPoint {
        let latSpan = max(maxLatitude - minLatitude, 0.000_001)
        let lonSpan = max(maxLongitude - minLongitude, 0.000_001)
        let x = CGFloat((coordinate.longitude - minLongitude) / lonSpan) * size.width
        // Match AppKit snapshot points: north (higher latitude) is larger y.
        let y = CGFloat((coordinate.latitude - minLatitude) / latSpan) * size.height
        return CGPoint(x: x, y: y)
    }
}
