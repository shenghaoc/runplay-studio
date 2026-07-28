import Foundation

/// Platform-neutral geographic distance calculation using the Haversine formula.
///
/// Replaces CoreLocation's `CLLocation.distance(from:)` for use in the
/// platform-neutral RunPlayCore target.
public enum GeoDistance {

    /// Earth's approximate spherical mean radius in meters.
    public static let earthRadiusMeters: Double = 6_371_000.0

    /// Valid heart rate range for filtering outliers (30-230 bpm).
    ///
    /// Deprecated: Use `MetricValidation.validHeartRateRange` instead.
    @available(*, deprecated, renamed: "MetricValidation.validHeartRateRange")
    public static let validHeartRateRange: ClosedRange<Double> = 30...230

    /// Calculate the great-circle distance between two coordinates in meters.
    ///
    /// Uses the Haversine formula, accurate for all distances on Earth.
    /// Returns 0 if either coordinate pair is invalid.
    ///
    /// - Parameters:
    ///   - lat1: Latitude of point 1 in degrees.
    ///   - lon1: Longitude of point 1 in degrees.
    ///   - lat2: Latitude of point 2 in degrees.
    ///   - lon2: Longitude of point 2 in degrees.
    /// - Returns: Distance in meters.
    public static func distanceMeters(
        fromLat lat1: Double, lon lon1: Double,
        toLat lat2: Double, lon lon2: Double
    ) -> Double {
        guard isValidCoordinate(lat: lat1, lon: lon1),
              isValidCoordinate(lat: lat2, lon: lon2) else {
            return 0
        }

        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let lat1Rad = lat1 * .pi / 180
        let lat2Rad = lat2 * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1Rad) * cos(lat2Rad) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadiusMeters * c
    }

    /// Validate that a coordinate is finite and within valid geographic ranges.
    ///
    /// - Parameters:
    ///   - lat: Latitude in degrees (valid: -90...90).
    ///   - lon: Longitude in degrees (valid: -180...180).
    /// - Returns: `true` if the coordinate is valid.
    public static func isValidCoordinate(lat: Double, lon: Double) -> Bool {
        lat.isFinite && lon.isFinite &&
        lat >= -90 && lat <= 90 &&
        lon >= -180 && lon <= 180
    }

    /// Convert latitude/longitude to local meter coordinates relative to a center point.
    ///
    /// Uses a simple equirectangular approximation, accurate for routes < 100km.
    /// This is the shared implementation used by both `RouteProjectionService`
    /// and `ComparisonRouteProjectionService`.
    ///
    /// - Parameters:
    ///   - lat: Latitude in degrees.
    ///   - lon: Longitude in degrees.
    ///   - centerLat: Center latitude in degrees.
    ///   - centerLon: Center longitude in degrees.
    /// - Returns: (x, z) coordinates in meters.
    public static func latLonToMeters(
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
}
