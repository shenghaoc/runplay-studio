import Foundation
import CoreLocation

/// Converts route latitude/longitude coordinates into local meter-space for 3D rendering.
///
/// Uses a local tangent plane projection centered on the route midpoint.
/// The Y axis represents elevation with configurable exaggeration.
struct RouteProjectionService {

    /// Elevation exaggeration factor. 1.0 = true scale, 2.0 = double elevation.
    var elevationExaggeration: Double = 2.0

    /// Convert an array of RoutePoints into RouteScenePoints for 3D rendering.
    func project(_ points: [RoutePoint]) -> [RouteScenePoint] {
        guard !points.isEmpty else { return [] }

        // Find route center (midpoint of bounding box)
        let lats = points.map { $0.latitude }
        let lons = points.map { $0.longitude }
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2

        // Find elevation range for scaling
        let altitudes = points.compactMap { $0.altitudeMeters }
        let minAlt = altitudes.min() ?? 0

        return points.enumerated().map { index, point in
            let (x, z) = latLonToMeters(
                lat: point.latitude,
                lon: point.longitude,
                centerLat: centerLat,
                centerLon: centerLon
            )

            let y = ((point.altitudeMeters ?? minAlt) - minAlt) * elevationExaggeration

            return RouteScenePoint(
                xMeters: x,
                yMeters: y,
                zMeters: z,
                sourceIndex: index,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                heartRateBPM: point.heartRateBPM
            )
        }
    }

    /// Convert latitude/longitude to local meter coordinates relative to a center point.
    ///
    /// Uses a simple equirectangular approximation, accurate for routes < 100km.
    func latLonToMeters(
        lat: Double,
        lon: Double,
        centerLat: Double,
        centerLon: Double
    ) -> (x: Double, z: Double) {
        let latRad = centerLat * .pi / 180

        // Meters per degree at this latitude
        let metersPerDegLat = 111132.92 - 559.82 * cos(2 * latRad) + 1.175 * cos(4 * latRad)
        let metersPerDegLon = 111412.84 * cos(latRad) - 93.5 * cos(3 * latRad)

        let x = (lon - centerLon) * metersPerDegLon
        let z = (lat - centerLat) * metersPerDegLat

        return (x, z)
    }

    /// Get the bounding box of projected points (for camera positioning).
    func boundingBox(of scenePoints: [RouteScenePoint]) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        guard !scenePoints.isEmpty else {
            return (SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 0, 0))
        }

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var minZ = Double.infinity, maxZ = -Double.infinity

        for p in scenePoints {
            minX = min(minX, p.xMeters)
            maxX = max(maxX, p.xMeters)
            minY = min(minY, p.yMeters)
            maxY = max(maxY, p.yMeters)
            minZ = min(minZ, p.zMeters)
            maxZ = max(maxZ, p.zMeters)
        }

        return (
            SIMD3<Double>(minX, minY, minZ),
            SIMD3<Double>(maxX, maxY, maxZ)
        )
    }
}
