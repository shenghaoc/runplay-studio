import Foundation
import MapKit
import RunPlayCore

/// Plans a padded, aspect-correct map rect for static summary-card snapshots.
///
/// Antimeridian-spanning content uses the same conservative MapKit point-union
/// behavior as `RouteMapContent.mapRect` (may expand near the dateline rather
/// than wrapping). Invalid coordinates are already filtered by
/// `RouteMapCoordinate` construction.
public enum MapSnapshotRegionPlanner: Sendable {
    /// Bump when padding/aspect/clamp rules change so map caches invalidate.
    public static let version = 1

    /// Outer padding as a fraction of the larger route span (before aspect fix).
    public static let paddingFraction: Double = 0.14

    /// Extra bottom fraction reserved so MapKit attribution is less likely to
    /// collide with route endpoints near the lower edge.
    public static let attributionSafeBottomFraction: Double = 0.08

    /// Minimum geographic span in meters (matches live map fitting floor).
    public static let minimumSpanMeters: Double = 400

    /// Plan a snapshot map rect for the given routes/markers and image size.
    public static func planMapRect(
        routes: [RouteMapLine],
        markers: [RouteMapMarker] = [],
        imageSize: CGSize
    ) -> MKMapRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        var lines = routes
        // Include marker coordinates so start/finish are never cropped when
        // slightly outside polyline bounds (e.g. single-point segments).
        if !markers.isEmpty {
            let markerCoords = markers.map(\.coordinate)
            if !markerCoords.isEmpty {
                lines.append(
                    RouteMapLine(
                        id: "planner-markers",
                        coordinates: markerCoords,
                        style: .primary
                    )
                )
            }
        }

        guard var rect = RouteMapContent.mapRect(for: lines), !rect.isNull, rect.size.width > 0 || rect.size.height > 0 else {
            return nil
        }

        // Proportional outer padding.
        let padX = max(rect.size.width * paddingFraction, 1)
        let padY = max(rect.size.height * paddingFraction, 1)
        rect = rect.insetBy(dx: -padX, dy: -padY)

        // Extra bottom padding for attribution safety (map Y grows downward in MKMapRect).
        let bottomPad = rect.size.height * attributionSafeBottomFraction
        rect = MKMapRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height + bottomPad
        )

        // Expand the shorter dimension to match the image aspect ratio.
        let imageAspect = Double(imageSize.width) / Double(imageSize.height)
        let mapAspect = rect.size.width / max(rect.size.height, 1)
        if mapAspect < imageAspect {
            // Too tall/narrow — expand width.
            let targetWidth = rect.size.height * imageAspect
            rect = MKMapRect(
                x: rect.midX - targetWidth / 2,
                y: rect.origin.y,
                width: targetWidth,
                height: rect.size.height
            )
        } else if mapAspect > imageAspect {
            // Too wide — expand height.
            let targetHeight = rect.size.width / imageAspect
            rect = MKMapRect(
                x: rect.origin.x,
                y: rect.midY - targetHeight / 2,
                width: rect.size.width,
                height: targetHeight
            )
        }

        // Clamp before using center latitude so meter-per-map-point is well-defined.
        rect = clampToWorld(rect)

        // Ensure minimum span in meters at the center latitude.
        let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let metersPerMapPoint = max(MKMetersPerMapPointAtLatitude(center.latitude), 0.000_001)
        let minimumSpan = minimumSpanMeters / metersPerMapPoint
        if rect.size.width < minimumSpan || rect.size.height < minimumSpan {
            let width = max(rect.size.width, minimumSpan)
            let height = max(rect.size.height, minimumSpan)
            // Re-apply aspect after minimum span.
            var w = width
            var h = height
            let aspect = w / max(h, 1)
            if aspect < imageAspect {
                w = h * imageAspect
            } else if aspect > imageAspect {
                h = w / imageAspect
            }
            rect = MKMapRect(
                x: rect.midX - w / 2,
                y: rect.midY - h / 2,
                width: w,
                height: h
            )
            rect = clampToWorld(rect)
        }

        return rect
    }

    /// Clamp a map rect so it stays inside the MapKit world.
    public static func clampToWorld(_ rect: MKMapRect) -> MKMapRect {
        let world = MKMapRect.world
        var width = min(max(rect.size.width, 1), world.size.width)
        var height = min(max(rect.size.height, 1), world.size.height)
        var x = rect.origin.x
        var y = rect.origin.y
        if x < world.origin.x { x = world.origin.x }
        if y < world.origin.y { y = world.origin.y }
        if x + width > world.origin.x + world.size.width {
            x = world.origin.x + world.size.width - width
        }
        if y + height > world.origin.y + world.size.height {
            y = world.origin.y + world.size.height - height
        }
        // Final safety if width/height still overflow after origin fix.
        width = min(width, world.size.width)
        height = min(height, world.size.height)
        return MKMapRect(x: x, y: y, width: width, height: height)
    }
}
