// Keep imported C++ declarations confined to the internal Interop layer.
internal import RunPlayEngineCpp

/// Pure-Swift projection of the C++ `runplay::LocalMeters` value.
///
/// Converting immediately keeps every imported C++ type out of the adapter's
/// own result and out of any `RunPlayCore` signature.
struct RunPlayLocalMeters: Equatable, Sendable {
    let xMeters: Double
    let zMeters: Double
}

/// Internal, parity-only adapter over the C++23 geodesy primitives.
///
/// This adapter exists solely so tests can compare the C++ kernel against the
/// production Swift `GeoDistance` implementation. It is deliberately unused by
/// production code and carries no feature flag, engine selector, or logging.
///
/// Production route processing must not call these scalar functions. Every
/// caller of `GeoDistance` runs inside a per-point loop, and routing those
/// loops through Swift-to-C++ scalar calls would create exactly the per-element
/// language-boundary crossing the repository forbids. The C++ primitives are
/// instead intended for use *inside* C++ once a complete route operation
/// migrates behind one bulk call, so no additional boundary crossing occurs.
///
/// `GeoDistance` remains the production implementation and the parity oracle
/// until that migration lands.
enum RunPlayGeodesyBridge {
    /// Mirrors `GeoDistance.isValidCoordinate(lat:lon:)`.
    static func isValidCoordinate(
        latitude: Double,
        longitude: Double
    ) -> Bool {
        runplay.is_valid_coordinate(latitude, longitude)
    }

    /// Mirrors `GeoDistance.distanceMeters(fromLat:lon:toLat:lon:)`.
    static func distanceMeters(
        latitude1: Double,
        longitude1: Double,
        latitude2: Double,
        longitude2: Double
    ) -> Double {
        runplay.haversine_distance_meters(
            latitude1,
            longitude1,
            latitude2,
            longitude2
        )
    }

    /// Mirrors `GeoDistance.latLonToMeters(lat:lon:centerLat:centerLon:)`.
    static func projectToLocalMeters(
        latitude: Double,
        longitude: Double,
        centerLatitude: Double,
        centerLongitude: Double
    ) -> RunPlayLocalMeters {
        projectNative(
            latitude: latitude,
            longitude: longitude,
            centerLatitude: centerLatitude,
            centerLongitude: centerLongitude
        )
    }

    /// Keeping the imported value in this nested call ensures the temporary C++
    /// `LocalMeters` is destroyed before the pure-Swift result returns.
    private static func projectNative(
        latitude: Double,
        longitude: Double,
        centerLatitude: Double,
        centerLongitude: Double
    ) -> RunPlayLocalMeters {
        let native = runplay.project_lat_lon_to_local_meters(
            latitude,
            longitude,
            centerLatitude,
            centerLongitude
        )
        return RunPlayLocalMeters(
            xMeters: native.x_meters,
            zMeters: native.z_meters
        )
    }
}
