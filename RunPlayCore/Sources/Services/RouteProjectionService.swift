import Foundation

/// Converts route latitude/longitude coordinates into local meter-space for 3D rendering.
///
/// Uses a local tangent plane projection centered on the route midpoint.
/// The Y axis represents elevation with configurable exaggeration.
public struct RouteProjectionService: Sendable {

    public init() {}

    /// Elevation exaggeration factor. 1.0 = true scale, 2.0 = double elevation.
    public var elevationExaggeration: Double = 2.0

    /// Convert an array of RoutePoints into RouteScenePoints for 3D rendering.
    ///
    /// This compatibility entrypoint derives the same corrected elevation
    /// profile used by workout analysis. Call the profile-taking overload when
    /// a shared analysis context already owns the profile.
    public func project(_ points: [RoutePoint]) -> [RouteScenePoint] {
        project(points, elevationProfile: ElevationProfile(routePoints: points))
    }

    /// Convert route points into local 3D coordinates using an elevation
    /// profile aligned one-to-one with `points`.
    ///
    /// Handles edge cases:
    /// - Empty arrays return empty results
    /// - Repeated coordinates are preserved (not collapsed)
    /// - Missing or non-meaningful corrected elevation stays on the baseline
    /// - NaN/infinite coordinates are filtered out
    /// - Source indices preserve the original array position after filtering
    ///
    /// Profile samples are accepted only when their route-point identity,
    /// distance, and segment still match the source point. A stale or
    /// misaligned profile therefore cannot attach elevation to the wrong
    /// geometry.
    public func project(
        _ points: [RoutePoint],
        elevationProfile: ElevationProfile
    ) -> [RouteScenePoint] {
        guard !points.isEmpty else { return [] }

        // Filter out points with invalid coordinates, preserving original indices
        // ⚡ Bolt: Inline loop avoids closure overhead from .enumerated().compactMap { ... }.
        var validIndexedPoints: [(index: Int, point: RoutePoint)] = []
        validIndexedPoints.reserveCapacity(points.count)
        for i in points.indices {
            let point = points[i]
            if GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude) {
                validIndexedPoints.append((index: i, point: point))
            }
        }

        guard !validIndexedPoints.isEmpty else { return [] }

        // Find route center (midpoint of bounding box)
        // ⚡ Bolt: Inline min/max tracking avoids intermediate O(N) array allocations
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for item in validIndexedPoints {
            let lat = item.point.latitude
            let lon = item.point.longitude
            if lat < minLat { minLat = lat }
            if lat > maxLat { maxLat = lat }
            if lon < minLon { minLon = lon }
            if lon > maxLon { maxLon = lon }
        }
        guard minLat.isFinite, maxLat.isFinite, minLon.isFinite, maxLon.isFinite else { return [] }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        // Find the corrected elevation baseline from renderable points only.
        // A non-meaningful or misaligned profile yields no values and keeps the
        // route flat rather than inventing an elevation range from raw data.
        // ⚡ Bolt: Inline min tracking avoids an intermediate O(N) altitude array.
        var minAltOpt: Double?
        for item in validIndexedPoints {
            if let altitude = correctedAltitude(
                for: item.point,
                atSourceIndex: item.index,
                elevationProfile: elevationProfile
            ) {
                minAltOpt = min(minAltOpt ?? .infinity, altitude)
            }
        }
        let minAlt = minAltOpt ?? 0

        // ⚡ Bolt: Inline loop avoids intermediate mapped array allocations.
        var projected: [RouteScenePoint] = []
        projected.reserveCapacity(validIndexedPoints.count)

        for item in validIndexedPoints {
            let point = item.point
            let (x, z) = latLonToMeters(
                lat: point.latitude,
                lon: point.longitude,
                centerLat: centerLat,
                centerLon: centerLon
            )

            let correctedAltitude = correctedAltitude(
                for: point,
                atSourceIndex: item.index,
                elevationProfile: elevationProfile
            )
            let y: Double
            if let alt = correctedAltitude {
                y = (alt - minAlt) * elevationExaggeration
            } else {
                y = 0
            }

            // Final safety check - replace any NaN/infinity with 0
            let safeX = x.isFinite ? x : 0
            let safeY = y.isFinite ? y : 0
            let safeZ = z.isFinite ? z : 0

            projected.append(RouteScenePoint(
                id: point.id,
                xMeters: safeX,
                yMeters: safeY,
                zMeters: safeZ,
                sourceIndex: item.index,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                heartRateBPM: point.heartRateBPM,
                routeSegmentIndex: point.routeSegmentIndex
            ))
        }

        return projected
    }

    private func correctedAltitude(
        for point: RoutePoint,
        atSourceIndex index: Int,
        elevationProfile: ElevationProfile
    ) -> Double? {
        guard elevationProfile.hasMeaningfulElevation,
              elevationProfile.samples.indices.contains(index)
        else {
            return nil
        }

        let sample = elevationProfile.samples[index]
        guard sample.routePointID == point.id,
              sample.distanceFromStartMeters == point.distanceFromStartMeters,
              sample.routeSegmentIndex == point.routeSegmentIndex,
              let altitude = sample.correctedAltitudeMeters,
              altitude.isFinite
        else {
            return nil
        }
        return altitude
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
