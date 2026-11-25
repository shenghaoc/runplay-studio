import Testing
@testable import RunPlayEngine

private let quietNaN = Double.nan
private let positiveInfinity = Double.infinity
private let negativeInfinity = -Double.infinity
private let latitudeJustAboveMaximum = 90.0.nextUp
private let latitudeJustBelowMinimum = (-90.0).nextDown
private let longitudeJustAboveMaximum = 180.0.nextUp
private let longitudeJustBelowMinimum = (-180.0).nextDown

private func within(_ value: Double, _ lower: Double, _ upper: Double) -> Bool {
    value.isFinite && value >= lower && value <= upper
}

private func closeTo(_ value: Double, _ expected: Double, _ tolerance: Double) -> Bool {
    value.isFinite && abs(value - expected) <= tolerance
}

private func valid(_ latitude: Double, _ longitude: Double) -> Bool {
    EngineGeodesy.isValidCoordinate(latitude: latitude, longitude: longitude)
}

private func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    EngineGeodesy.distanceMeters(latitude1: lat1, longitude1: lon1, latitude2: lat2, longitude2: lon2)
}

private func project(_ lat: Double, _ lon: Double, _ centerLat: Double, _ centerLon: Double) -> EngineLocalMeters {
    EngineGeodesy.projectToLocalMeters(latitude: lat, longitude: lon, centerLatitude: centerLat, centerLongitude: centerLon)
}

/// C++ standard-layout traits are ABI-specific; this is the Swift two-value equivalent.
@Test func testLocalMetersValueLayout() {
    #expect(MemoryLayout<EngineLocalMeters>.size == 2 * MemoryLayout<Double>.size)
}

@Test func run_coordinate_validation_tests() {
    #expect(valid(0.0, 0.0), "origin must be a valid coordinate")
    #expect(
        valid(1.352083, 103.819836),
        "an ordinary Singapore coordinate must be valid")
    #expect(
        valid(-33.8688, 151.2093),
        "a southern-eastern hemisphere coordinate must be valid")
    #expect(
        valid(37.7749, -122.4194),
        "a northern-western hemisphere coordinate must be valid")

    // Inclusive range boundaries.
    #expect(valid(-90.0, -180.0), "(-90, -180) must be inclusive")
    #expect(valid(90.0, 180.0), "(90, 180) must be inclusive")
    #expect(valid(-90.0, 180.0), "(-90, 180) must be inclusive")
    #expect(valid(90.0, -180.0), "(90, -180) must be inclusive")

    // Signed zero must behave exactly like positive zero.
    #expect(valid(-0.0, -0.0), "negative zero must be valid")
    #expect(valid(-0.0, 0.0), "negative zero latitude must be valid")
    #expect(valid(0.0, -0.0), "negative zero longitude must be valid")
    #expect((-0.0).sign == .minus, "the negative zero fixture must really be signed")

    // Just outside the inclusive ranges.
    #expect(
        !valid(latitudeJustBelowMinimum, 0.0),
        "latitude just below -90 must be rejected")
    #expect(
        !valid(latitudeJustAboveMaximum, 0.0),
        "latitude just above 90 must be rejected")
    #expect(
        !valid(0.0, longitudeJustBelowMinimum),
        "longitude just below -180 must be rejected")
    #expect(
        !valid(0.0, longitudeJustAboveMaximum),
        "longitude just above 180 must be rejected")
    #expect(!valid(91.0, 0.0), "latitude 91 must be rejected")
    #expect(!valid(-91.0, 0.0), "latitude -91 must be rejected")
    #expect(!valid(0.0, 181.0), "longitude 181 must be rejected")
    #expect(!valid(0.0, -181.0), "longitude -181 must be rejected")

    // Non-finite values in each field.
    #expect(!valid(quietNaN, 0.0), "NaN latitude must be rejected")
    #expect(!valid(0.0, quietNaN), "NaN longitude must be rejected")
    #expect(
        !valid(quietNaN, quietNaN),
        "NaN latitude and longitude must be rejected")
    #expect(
        !valid(positiveInfinity, 0.0),
        "positive infinity latitude must be rejected")
    #expect(
        !valid(negativeInfinity, 0.0),
        "negative infinity latitude must be rejected")
    #expect(
        !valid(0.0, positiveInfinity),
        "positive infinity longitude must be rejected")
    #expect(
        !valid(0.0, negativeInfinity),
        "negative infinity longitude must be rejected")
}

@Test func run_distance_tests() {
    // Identical coordinates.
    #expect(
        distance(37.7749, -122.4194, 37.7749, -122.4194) == 0.0,
        "distance between identical coordinates must be exactly zero")
    #expect(
        distance(0.0, 0.0, 0.0, 0.0) == 0.0,
        "distance between two origins must be exactly zero")

    // Symmetry.
    let forward =
        distance(37.7749, -122.4194, 34.0522, -118.2437)
    let reverse =
        distance(34.0522, -118.2437, 37.7749, -122.4194)
    #expect(forward == reverse, "distance must be symmetric in its arguments")

    // One degree of arc on a 6,371 km sphere is 2*pi*R/360 ~= 111,195 m.
    #expect(
        within(distance(0.0, 0.0, 1.0, 0.0), 111_100.0, 111_300.0),
        "one degree of latitude at the equator must be about 111.2 km")
    #expect(
        within(distance(0.0, 0.0, 0.0, 1.0), 111_100.0, 111_300.0),
        "one degree of longitude at the equator must be about 111.2 km")

    // Independent published great-circle references, not engine output.
    #expect(
        within(
            distance(1.352083, 103.819836, 1.353083, 103.820836),
            156.0,
            159.0),
        "a Singapore-local 0.001 degree diagonal step must be about 157 m")
    #expect(
        within(
            distance(37.7749, -122.4194, 34.0522, -118.2437),
            555_000.0,
            565_000.0),
        "San Francisco to Los Angeles must be about 559 km")
    #expect(
        within(
            distance(-33.8688, 151.2093, -37.8136, 144.9631),
            705_000.0,
            720_000.0),
        "Sydney to Melbourne must be about 713 km")
    #expect(
        within(
            distance(40.7128, -74.0060, 51.5074, -0.1278),
            5_555_000.0,
            5_585_000.0),
        "New York to London must be about 5,570 km")

    // Crossing the antimeridian. The formula squares sin(dLon / 2), so a
    // 359.999 degree raw delta collapses to the true 0.001 degree separation
    // without any explicit longitude wrapping.
    #expect(
        within(
            distance(0.0, 179.9995, 0.0, -179.9995),
            111.0,
            111.4),
        "a 0.001 degree antimeridian crossing must be about 111 m, not the long way")
    #expect(
        within(
            distance(-17.0, 179.5, -17.0, -179.5),
            106_000.0,
            106_700.0),
        "a one degree antimeridian crossing at 17S must be about 106 km")

    // Pole boundaries.
    #expect(
        within(distance(90.0, 0.0, 89.0, 0.0), 111_100.0, 111_300.0),
        "one degree south of the north pole must be about 111.2 km")
    #expect(
        within(distance(-90.0, 0.0, -89.0, 0.0), 111_100.0, 111_300.0),
        "one degree north of the south pole must be about 111.2 km")
    let acrossNorthPole = distance(90.0, 45.0, 90.0, -135.0)
    #expect(
        (acrossNorthPole).isFinite && acrossNorthPole >= 0.0
            && acrossNorthPole < 1.0e-6,
        "two longitudes at the north pole must describe the same location")

    // Antipodal points. Half the circumference of a 6,371 km sphere is
    // pi * R ~= 20,015,087 m.
    #expect(
        within(
            distance(0.0, 0.0, 0.0, 180.0),
            20_015_080.0,
            20_015_095.0),
        "equatorial antipodes must be half the circumference apart")
    #expect(
        within(
            distance(45.0, 0.0, -45.0, 180.0),
            20_015_080.0,
            20_015_095.0),
        "mid-latitude antipodes must be half the circumference apart")
    #expect(
        within(
            distance(90.0, 0.0, -90.0, 0.0),
            20_015_080.0,
            20_015_095.0),
        "pole to pole must be half the circumference apart")

    // Preserved limitation, not an improvement target: for some exactly
    // antipodal pairs the rounded haversine term exceeds 1, so sqrt(1 - a)
    // is NaN. The production Swift implementation returns NaN for the same
    // input, and the Swift parity tests assert that both agree.
    #expect(
        (distance(12.0, 34.0, -12.0, -146.0)).isNaN,
        "an exactly antipodal pair must reproduce the Swift NaN result")

    // Nearly antipodal points stay finite and just under half the circumference.
    let nearlyAntipodal = distance(0.0, 0.0, 0.0001, 180.0)
    #expect(
        within(nearlyAntipodal, 20_015_070.0, 20_015_086.0),
        "a nearly antipodal pair must stay just under half the circumference")
    #expect(
        within(
            distance(0.0, 0.0, 0.0, 179.999),
            20_014_970.0,
            20_015_086.0),
        "a longitude-only near-antipodal pair must stay finite")

    // A tiny coordinate delta must remain strictly positive and sub-millimetre.
    let tinyStep = distance(1.35, 103.8, 1.350000001, 103.8)
    #expect(
        (tinyStep).isFinite && tinyStep > 0.0 && tinyStep < 0.001,
        "a 1e-9 degree latitude step must be a positive sub-millimetre distance")

    // Invalid inputs return exactly positive zero.
    #expect(
        distance(91.0, 0.0, 0.0, 0.0) == 0.0,
        "an out-of-range first latitude must return zero")
    #expect(
        distance(0.0, 0.0, 0.0, 181.0) == 0.0,
        "an out-of-range second longitude must return zero")
    #expect(
        distance(0.0, 181.0, 0.0, 0.0) == 0.0,
        "an out-of-range first longitude must return zero")
    #expect(
        distance(0.0, 0.0, -91.0, 0.0) == 0.0,
        "an out-of-range second latitude must return zero")
    #expect(
        distance(quietNaN, 0.0, 0.0, 0.0) == 0.0,
        "a NaN first latitude must return zero")
    #expect(
        distance(0.0, 0.0, 0.0, quietNaN) == 0.0,
        "a NaN second longitude must return zero")
    #expect(
        distance(positiveInfinity, 0.0, 0.0, 0.0) == 0.0,
        "a positive infinity latitude must return zero")
    #expect(
        distance(0.0, negativeInfinity, 0.0, 0.0) == 0.0,
        "a negative infinity longitude must return zero")
    #expect(
        (distance(91.0, 0.0, 0.0, 0.0)).sign == .plus,
        "the invalid-input result must be positive zero")
}

@Test func run_projection_tests() {
    // The centre projects to the origin.
    let center = project(1.35, 103.8, 1.35, 103.8)
    #expect(center.xMeters == 0.0, "the centre must project to x = 0")
    #expect(center.zMeters == 0.0, "the centre must project to z = 0")

    // Directional signs.
    #expect(
        project(1.35, 103.81, 1.35, 103.8).xMeters > 0.0,
        "a point east of the centre must have positive x")
    #expect(
        project(1.35, 103.79, 1.35, 103.8).xMeters < 0.0,
        "a point west of the centre must have negative x")
    #expect(
        project(1.36, 103.8, 1.35, 103.8).zMeters > 0.0,
        "a point north of the centre must have positive z")
    #expect(
        project(1.34, 103.8, 1.35, 103.8).zMeters < 0.0,
        "a point south of the centre must have negative z")

    // Axis isolation.
    let latitudeOnly =
        project(1.36, 103.8, 1.35, 103.8)
    #expect(
        latitudeOnly.xMeters == 0.0,
        "an unchanged longitude must produce exactly zero x")
    #expect(latitudeOnly.zMeters != 0.0, "a changed latitude must produce non-zero z")
    let longitudeOnly =
        project(1.35, 103.81, 1.35, 103.8)
    #expect(
        longitudeOnly.zMeters == 0.0,
        "an unchanged latitude must produce exactly zero z")
    #expect(longitudeOnly.xMeters != 0.0, "a changed longitude must produce non-zero x")

    // Equatorial centre: cos(0) is exactly 1, so the coefficients reduce to
    // 111412.84 - 93.5 m per degree of longitude and
    // 111132.92 - 559.82 + 1.175 m per degree of latitude.
    let equatorial =
        project(0.001, 0.001, 0.0, 0.0)
    #expect(
        closeTo(equatorial.xMeters, 0.001 * (111412.84 - 93.5), 1.0e-6),
        "an equatorial centre must use the documented longitude coefficients")
    #expect(
        closeTo(equatorial.zMeters, 0.001 * (111132.92 - 559.82 + 1.175), 1.0e-6),
        "an equatorial centre must use the documented latitude coefficients")

    // Singapore-scale values near the equator.
    let singapore =
        project(1.353083, 103.820836, 1.352083, 103.819836)
    #expect(
        within(singapore.xMeters, 111.0, 111.5),
        "a 0.001 degree Singapore longitude step must be about 111.3 m")
    #expect(
        within(singapore.zMeters, 110.3, 110.8),
        "a 0.001 degree Singapore latitude step must be about 110.6 m")

    // High-latitude centre: meridians converge while the metres per degree of
    // latitude grows toward the poles.
    let highLatitude =
        project(71.001, 25.001, 71.0, 25.0)
    #expect(
        within(highLatitude.xMeters, 36.0, 36.7),
        "a 0.001 degree longitude step at 71N must be about 36.4 m")
    #expect(
        within(highLatitude.zMeters, 111.3, 111.8),
        "a 0.001 degree latitude step at 71N must be about 111.6 m")
    #expect(
        highLatitude.xMeters < singapore.xMeters,
        "longitude spacing must shrink toward the pole")
    #expect(
        highLatitude.zMeters > singapore.zMeters,
        "latitude spacing must grow toward the pole")

    // Non-finite inputs propagate instead of being silently repaired.
    let nanLatitude =
        project(quietNaN, 0.0, 0.0, 0.0)
    #expect((nanLatitude.zMeters).isNaN, "a NaN latitude must propagate into z")
    #expect(
        nanLatitude.xMeters == 0.0,
        "a NaN latitude must leave an unchanged longitude at zero x")
    let infiniteLongitude =
        project(0.0, positiveInfinity, 0.0, 0.0)
    #expect(
        (infiniteLongitude.xMeters).isInfinite && infiniteLongitude.xMeters > 0.0,
        "a positive infinity longitude must propagate into positive infinite x")
    let infiniteCenterLongitude =
        project(0.0, 0.0, 0.0, positiveInfinity)
    #expect(
        (infiniteCenterLongitude.xMeters).isInfinite
            && infiniteCenterLongitude.xMeters < 0.0,
        "an infinite centre longitude must propagate into negative infinite x")
    let nanCenter =
        project(1.0, 1.0, quietNaN, 0.0)
    #expect(
        (nanCenter.xMeters).isNaN && (nanCenter.zMeters).isNaN,
        "a NaN centre latitude must poison both projected axes")

    // Out-of-range inputs are projected, not validated or clamped.
    let unvalidated =
        project(1000.0, 4000.0, 0.0, 0.0)
    #expect(
        (unvalidated.xMeters).isFinite && unvalidated.xMeters > 0.0,
        "the projection must not validate or clamp an out-of-range longitude")
    #expect(
        (unvalidated.zMeters).isFinite && unvalidated.zMeters > 0.0,
        "the projection must not validate or clamp an out-of-range latitude")

    // Antimeridian-adjacent centres are not wrapped: the raw longitude delta is
    // used exactly as supplied.
    let unwrapped =
        project(0.0, -179.9995, 0.0, 179.9995)
    #expect(
        unwrapped.xMeters < -39_000_000.0,
        "the projection must not wrap longitude across the antimeridian")
}
