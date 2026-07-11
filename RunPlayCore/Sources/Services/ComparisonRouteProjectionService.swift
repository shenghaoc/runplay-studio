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
        let primaryLats = validPrimary.map { $0.point.latitude }
        let primaryLons = validPrimary.map { $0.point.longitude }
        guard let minLat = primaryLats.min(), let maxLat = primaryLats.max(),
              let minLon = primaryLons.min(), let maxLon = primaryLons.max() else {
            return ComparisonRouteScene(
                primaryRoute: [], comparisonRoute: [],
                combinedBounds: (min: SIMD3<Double>(0, 0, 0), max: SIMD3<Double>(0, 0, 0)),
                warnings: existingWarnings + [.tooFewPoints]
            )
        }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        // Find elevation baseline from both routes combined
        let primaryAlts = validPrimary.compactMap { $0.point.altitudeMeters }.filter { $0.isFinite && !$0.isNaN }
        let comparisonAlts = validComparison.compactMap { $0.point.altitudeMeters }.filter { $0.isFinite && !$0.isNaN }
        let allAlts = primaryAlts + comparisonAlts
        let minAlt = allAlts.min() ?? 0

        // Project primary route
        let projectedPrimary = projectRoute(validPrimary, centerLat: centerLat, centerLon: centerLon, minAlt: minAlt)

        // Project comparison route using the same origin
        let projectedComparison = projectRoute(validComparison, centerLat: centerLat, centerLon: centerLon, minAlt: minAlt)

        // Compute combined bounds
        let combinedBounds = computeCombinedBounds(primary: projectedPrimary, comparison: projectedComparison)

        // Build warnings
        var warnings = existingWarnings
        if validComparison.isEmpty && !comparison.isEmpty {
            // Comparison had points but all were invalid
            warnings.append(.tooFewPoints)
        } else if validComparison.isEmpty {
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
        points.enumerated().compactMap { idx, point in
            guard GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude) else {
                return nil
            }
            return (index: idx, point: point)
        }
    }

    /// Project a route into local meter-space relative to the given center.
    private func projectRoute(
        _ indexedPoints: [(index: Int, point: RoutePoint)],
        centerLat: Double,
        centerLon: Double,
        minAlt: Double
    ) -> [RouteScenePoint] {
        guard !indexedPoints.isEmpty else { return [] }

        return indexedPoints.map { item in
            let point = item.point
            let (x, z) = latLonToMeters(
                lat: point.latitude,
                lon: point.longitude,
                centerLat: centerLat,
                centerLon: centerLon
            )

            let altitude = point.altitudeMeters ?? minAlt
            let y = (altitude - minAlt) * elevationExaggeration

            // Safety: replace any NaN/infinity with 0
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
        let allPoints = primary + comparison

        guard !allPoints.isEmpty else {
            return (SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 0, 0))
        }

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var minZ = Double.infinity, maxZ = -Double.infinity

        for p in allPoints {
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
