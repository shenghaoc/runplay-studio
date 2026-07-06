import Foundation

/// Converts route latitude/longitude coordinates into local meter-space for 3D rendering.
///
/// Uses a local tangent plane projection centered on the route midpoint.
/// The Y axis represents elevation with configurable exaggeration.
public struct RouteProjectionService {

    public init() {}

    /// Elevation exaggeration factor. 1.0 = true scale, 2.0 = double elevation.
    public var elevationExaggeration: Double = 2.0

    /// Convert an array of RoutePoints into RouteScenePoints for 3D rendering.
    ///
    /// Handles edge cases:
    /// - Empty arrays return empty results
    /// - Repeated coordinates are preserved (not collapsed)
    /// - Missing altitude defaults to minimum altitude
    /// - NaN/infinite coordinates are filtered out
    /// - Source indices preserve the original array position after filtering
    public func project(_ points: [RoutePoint]) -> [RouteScenePoint] {
        guard !points.isEmpty else { return [] }

        // Filter out points with invalid coordinates, preserving original indices
        let validIndexedPoints: [(index: Int, point: RoutePoint)] = points.enumerated().compactMap { idx, point in
            guard GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude) else {
                return nil
            }
            return (index: idx, point: point)
        }

        guard !validIndexedPoints.isEmpty else { return [] }

        // Find route center (midpoint of bounding box)
        let lats = validIndexedPoints.map { $0.point.latitude }
        let lons = validIndexedPoints.map { $0.point.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        // Find elevation range for scaling
        let altitudes = validIndexedPoints.compactMap { $0.point.altitudeMeters }.filter { $0.isFinite && !$0.isNaN }
        let minAlt = altitudes.min() ?? 0

        return validIndexedPoints.map { item in
            let point = item.point
            let (x, z) = latLonToMeters(
                lat: point.latitude,
                lon: point.longitude,
                centerLat: centerLat,
                centerLon: centerLon
            )

            let altitude = point.altitudeMeters ?? minAlt
            let y = (altitude - minAlt) * elevationExaggeration

            // Final safety check - replace any NaN/infinity with 0
            let safeX = x.isFinite ? x : 0
            let safeY = y.isFinite ? y : 0
            let safeZ = z.isFinite ? z : 0

            return RouteScenePoint(
                xMeters: safeX,
                yMeters: safeY,
                zMeters: safeZ,
                sourceIndex: item.index,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                heartRateBPM: point.heartRateBPM
            )
        }
    }

    /// Convert latitude/longitude to local meter coordinates relative to a center point.
    ///
    /// Delegates to `GeoDistance.latLonToMeters` for the equirectangular approximation.
    public func latLonToMeters(
        lat: Double,
        lon: Double,
        centerLat: Double,
        centerLon: Double
    ) -> (x: Double, z: Double) {
        GeoDistance.latLonToMeters(lat: lat, lon: lon, centerLat: centerLat, centerLon: centerLon)
    }

    /// Get the bounding box of projected points (for camera positioning).
    public func boundingBox(of scenePoints: [RouteScenePoint]) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        guard !scenePoints.isEmpty else {
            return (SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 0, 0))
        }

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var minZ = Double.infinity, maxZ = -Double.infinity

        for p in scenePoints {
            guard p.xMeters.isFinite && p.yMeters.isFinite && p.zMeters.isFinite else { continue }
            minX = min(minX, p.xMeters)
            maxX = max(maxX, p.xMeters)
            minY = min(minY, p.yMeters)
            maxY = max(maxY, p.yMeters)
            minZ = min(minZ, p.zMeters)
            maxZ = max(maxZ, p.zMeters)
        }

        // Handle case where all values were infinite
        guard minX.isFinite && maxX.isFinite else {
            return (SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 0, 0))
        }

        return (
            SIMD3<Double>(minX, minY, minZ),
            SIMD3<Double>(maxX, maxY, maxZ)
        )
    }

    /// Calculate the maximum extent of the bounding box (for scaling grid/camera).
    public func maxExtent(of scenePoints: [RouteScenePoint]) -> Double {
        let bbox = boundingBox(of: scenePoints)
        let dx = bbox.max.x - bbox.min.x
        let dy = bbox.max.y - bbox.min.y
        let dz = bbox.max.z - bbox.min.z
        return max(dx, dy, dz, 100) // Minimum 100m extent
    }
}
