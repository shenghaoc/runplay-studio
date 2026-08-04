import Foundation

/// Projects two routes into a shared local coordinate system for 3D comparison.
///
/// Uses a single shared origin (center of the primary route's bounding box) so
/// both routes preserve their relative geographic positions when overlaid.
public struct ComparisonRouteProjectionService: Sendable {

    public init() {}

    /// Elevation exaggeration factor applied to both routes.
    public var elevationExaggeration: Double = 2.0

    /// Project primary and comparison routes into a shared coordinate space.
    ///
    /// The shared origin is the center of the primary route's bounding box.
    /// Both routes are projected relative to this origin so they maintain
    /// correct relative positioning in 3D space.
    ///
    /// Returns a `ComparisonRouteScene` with projected routes, combined bounds,
    /// and any applicable warnings.
    public func project(
        primary: [RoutePoint],
        comparison: [RoutePoint],
        existingWarnings: [ComparisonWarning] = []
    ) -> ComparisonRouteScene {
        project(
            primary: primary,
            comparison: comparison,
            primaryElevationProfile: ElevationProfile(routePoints: primary),
            comparisonElevationProfile: ElevationProfile(routePoints: comparison),
            existingWarnings: existingWarnings
        )
    }

    /// Project two routes using corrected elevation profiles aligned one-to-one
    /// with their corresponding route-point arrays.
    ///
    /// Both routes share the minimum meaningful corrected altitude as their
    /// baseline. A non-meaningful or stale profile leaves only that route flat
    /// instead of deriving a misleading scale from raw altitude.
    public func project(
        primary: [RoutePoint],
        comparison: [RoutePoint],
        primaryElevationProfile: ElevationProfile,
        comparisonElevationProfile: ElevationProfile,
        existingWarnings: [ComparisonWarning] = []
    ) -> ComparisonRouteScene {
        // Filter valid points for both routes, preserving original indices
        let validPrimary = filterValidWithIndices(primary)
        let validComparison = filterValidWithIndices(comparison)

        // Handle empty primary
        guard !validPrimary.isEmpty else {
            return ComparisonRouteScene(
                primaryRoute: [],
                comparisonRoute: [],
                combinedBounds: (min: SIMD3<Double>(0, 0, 0), max: SIMD3<Double>(0, 0, 0)),
                warnings: existingWarnings + [.tooFewPoints]
            )
        }

        // Compute shared origin from primary route center
        // ⚡ Bolt: Inline min/max tracking avoids intermediate O(N) array allocations
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for item in validPrimary {
            let lat = item.point.latitude
            let lon = item.point.longitude
            if lat < minLat { minLat = lat }
            if lat > maxLat { maxLat = lat }
            if lon < minLon { minLon = lon }
            if lon > maxLon { maxLon = lon }
        }
        guard minLat.isFinite, maxLat.isFinite, minLon.isFinite, maxLon.isFinite else {
            return ComparisonRouteScene(
                primaryRoute: [], comparisonRoute: [],
                combinedBounds: (min: SIMD3<Double>(0, 0, 0), max: SIMD3<Double>(0, 0, 0)),
                warnings: existingWarnings + [.tooFewPoints]
            )
        }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        // Find a shared baseline from corrected, aligned elevation only.
        // ⚡ Bolt: Inline min tracking avoids intermediate O(N) altitude arrays.
        var minAltOpt: Double?
        for item in validPrimary {
            if let altitude = correctedAltitude(
                for: item.point,
                atSourceIndex: item.index,
                elevationProfile: primaryElevationProfile
            ) {
                minAltOpt = min(minAltOpt ?? .infinity, altitude)
            }
        }
        for item in validComparison {
            if let altitude = correctedAltitude(
                for: item.point,
                atSourceIndex: item.index,
                elevationProfile: comparisonElevationProfile
            ) {
                minAltOpt = min(minAltOpt ?? .infinity, altitude)
            }
        }
        let minAlt = minAltOpt ?? 0

        // Project primary route
        let projectedPrimary = projectRoute(
            validPrimary,
            centerLat: centerLat,
            centerLon: centerLon,
            minAlt: minAlt,
            elevationProfile: primaryElevationProfile
        )

        // Project comparison route using the same origin
        let projectedComparison = projectRoute(
            validComparison,
            centerLat: centerLat,
            centerLon: centerLon,
            minAlt: minAlt,
            elevationProfile: comparisonElevationProfile
        )

        // Compute combined bounds
        let combinedBounds = computeCombinedBounds(primary: projectedPrimary, comparison: projectedComparison)

        // Build warnings
        var warnings = existingWarnings
        if validComparison.isEmpty {
            warnings.append(.tooFewPoints)
        }

        return ComparisonRouteScene(
            primaryRoute: projectedPrimary,
            comparisonRoute: projectedComparison,
            combinedBounds: combinedBounds,
            warnings: warnings
        )
    }

    // MARK: - Private Helpers

    /// Filter out points with invalid coordinates, preserving original indices.
    private func filterValidWithIndices(_ points: [RoutePoint]) -> [(index: Int, point: RoutePoint)] {
        // ⚡ Bolt: Inline loop avoids closure overhead from .enumerated().compactMap { ... }.
        var valid: [(index: Int, point: RoutePoint)] = []
        valid.reserveCapacity(points.count)
        for i in points.indices {
            let point = points[i]
            if GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude) {
                valid.append((index: i, point: point))
            }
        }
        return valid
    }

    /// Project a route into local meter-space relative to the given center.
    private func projectRoute(
        _ indexedPoints: [(index: Int, point: RoutePoint)],
        centerLat: Double,
        centerLon: Double,
        minAlt: Double,
        elevationProfile: ElevationProfile
    ) -> [RouteScenePoint] {
        guard !indexedPoints.isEmpty else { return [] }

        // ⚡ Bolt: Inline loop avoids .map closure overhead while building the projected array.
        var projected: [RouteScenePoint] = []
        projected.reserveCapacity(indexedPoints.count)

        for item in indexedPoints {
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

            // Safety: replace any NaN/infinity with 0
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

    /// Convert latitude/longitude to local meter coordinates.
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

    /// Compute the combined bounding box of both projected routes.
    private func computeCombinedBounds(
        primary: [RouteScenePoint],
        comparison: [RouteScenePoint]
    ) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        // ⚡ Bolt: Sequential iteration avoids the `primary + comparison` array allocation
        guard !primary.isEmpty || !comparison.isEmpty else {
            return (SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 0, 0))
        }

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var minZ = Double.infinity, maxZ = -Double.infinity

        for p in primary {
            guard p.xMeters.isFinite && p.yMeters.isFinite && p.zMeters.isFinite else { continue }
            minX = min(minX, p.xMeters)
            maxX = max(maxX, p.xMeters)
            minY = min(minY, p.yMeters)
            maxY = max(maxY, p.yMeters)
            minZ = min(minZ, p.zMeters)
            maxZ = max(maxZ, p.zMeters)
        }
        for p in comparison {
            guard p.xMeters.isFinite && p.yMeters.isFinite && p.zMeters.isFinite else { continue }
            minX = min(minX, p.xMeters)
            maxX = max(maxX, p.xMeters)
            minY = min(minY, p.yMeters)
            maxY = max(maxY, p.yMeters)
            minZ = min(minZ, p.zMeters)
            maxZ = max(maxZ, p.zMeters)
        }

        guard minX.isFinite && maxX.isFinite else {
            return (SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 0, 0))
        }

        return (
            SIMD3<Double>(minX, minY, minZ),
            SIMD3<Double>(maxX, maxY, maxZ)
        )
    }
}
