#include "RunPlayEngineCpp/Geodesy.hpp"
#include "TestSupport.hpp"

#include <cmath>
#include <limits>
#include <type_traits>

namespace {

using runplay::LocalMeters;
using runplay::haversine_distance_meters;
using runplay::is_valid_coordinate;
using runplay::project_lat_lon_to_local_meters;

constexpr double quiet_nan = std::numeric_limits<double>::quiet_NaN();
constexpr double positive_infinity = std::numeric_limits<double>::infinity();
constexpr double negative_infinity = -std::numeric_limits<double>::infinity();

/// Smallest representable step away from a range boundary, so "just outside"
/// cases stay adjacent to the inclusive limit instead of overshooting it.
const double latitude_just_above_maximum = std::nextafter(90.0, 100.0);
const double latitude_just_below_minimum = std::nextafter(-90.0, -100.0);
const double longitude_just_above_maximum = std::nextafter(180.0, 200.0);
const double longitude_just_below_minimum = std::nextafter(-180.0, -200.0);

[[nodiscard]]
bool within(double value, double lower, double upper) noexcept {
    return std::isfinite(value) && value >= lower && value <= upper;
}

[[nodiscard]]
bool close_to(double value, double expected, double tolerance) noexcept {
    return std::isfinite(value) && std::abs(value - expected) <= tolerance;
}

// The engine boundary must stay callable from Swift without exception support.
static_assert(noexcept(runplay::is_valid_coordinate(0.0, 0.0)));
static_assert(noexcept(runplay::haversine_distance_meters(0.0, 0.0, 0.0, 0.0)));
static_assert(noexcept(runplay::project_lat_lon_to_local_meters(0.0, 0.0, 0.0, 0.0)));

// LocalMeters must stay an allocation-free value with a predictable layout.
static_assert(std::is_standard_layout_v<LocalMeters>);
static_assert(std::is_trivially_copyable_v<LocalMeters>);
static_assert(std::is_nothrow_copy_constructible_v<LocalMeters>);
static_assert(std::is_nothrow_move_constructible_v<LocalMeters>);
static_assert(std::is_trivially_destructible_v<LocalMeters>);
static_assert(!std::is_polymorphic_v<LocalMeters>);
static_assert(sizeof(LocalMeters) == 2u * sizeof(double));
static_assert(std::is_same_v<decltype(LocalMeters::x_meters), double>);
static_assert(std::is_same_v<decltype(LocalMeters::z_meters), double>);

void run_coordinate_validation_tests() {
    expect(is_valid_coordinate(0.0, 0.0), "origin must be a valid coordinate");
    expect(
        is_valid_coordinate(1.352083, 103.819836),
        "an ordinary Singapore coordinate must be valid");
    expect(
        is_valid_coordinate(-33.8688, 151.2093),
        "a southern-eastern hemisphere coordinate must be valid");
    expect(
        is_valid_coordinate(37.7749, -122.4194),
        "a northern-western hemisphere coordinate must be valid");

    // Inclusive range boundaries.
    expect(is_valid_coordinate(-90.0, -180.0), "(-90, -180) must be inclusive");
    expect(is_valid_coordinate(90.0, 180.0), "(90, 180) must be inclusive");
    expect(is_valid_coordinate(-90.0, 180.0), "(-90, 180) must be inclusive");
    expect(is_valid_coordinate(90.0, -180.0), "(90, -180) must be inclusive");

    // Signed zero must behave exactly like positive zero.
    expect(is_valid_coordinate(-0.0, -0.0), "negative zero must be valid");
    expect(is_valid_coordinate(-0.0, 0.0), "negative zero latitude must be valid");
    expect(is_valid_coordinate(0.0, -0.0), "negative zero longitude must be valid");
    expect(std::signbit(-0.0), "the negative zero fixture must really be signed");

    // Just outside the inclusive ranges.
    expect(
        !is_valid_coordinate(latitude_just_below_minimum, 0.0),
        "latitude just below -90 must be rejected");
    expect(
        !is_valid_coordinate(latitude_just_above_maximum, 0.0),
        "latitude just above 90 must be rejected");
    expect(
        !is_valid_coordinate(0.0, longitude_just_below_minimum),
        "longitude just below -180 must be rejected");
    expect(
        !is_valid_coordinate(0.0, longitude_just_above_maximum),
        "longitude just above 180 must be rejected");
    expect(!is_valid_coordinate(91.0, 0.0), "latitude 91 must be rejected");
    expect(!is_valid_coordinate(-91.0, 0.0), "latitude -91 must be rejected");
    expect(!is_valid_coordinate(0.0, 181.0), "longitude 181 must be rejected");
    expect(!is_valid_coordinate(0.0, -181.0), "longitude -181 must be rejected");

    // Non-finite values in each field.
    expect(!is_valid_coordinate(quiet_nan, 0.0), "NaN latitude must be rejected");
    expect(!is_valid_coordinate(0.0, quiet_nan), "NaN longitude must be rejected");
    expect(
        !is_valid_coordinate(quiet_nan, quiet_nan),
        "NaN latitude and longitude must be rejected");
    expect(
        !is_valid_coordinate(positive_infinity, 0.0),
        "positive infinity latitude must be rejected");
    expect(
        !is_valid_coordinate(negative_infinity, 0.0),
        "negative infinity latitude must be rejected");
    expect(
        !is_valid_coordinate(0.0, positive_infinity),
        "positive infinity longitude must be rejected");
    expect(
        !is_valid_coordinate(0.0, negative_infinity),
        "negative infinity longitude must be rejected");
}

void run_distance_tests() {
    // Identical coordinates.
    expect(
        haversine_distance_meters(37.7749, -122.4194, 37.7749, -122.4194) == 0.0,
        "distance between identical coordinates must be exactly zero");
    expect(
        haversine_distance_meters(0.0, 0.0, 0.0, 0.0) == 0.0,
        "distance between two origins must be exactly zero");

    // Symmetry.
    const double forward =
        haversine_distance_meters(37.7749, -122.4194, 34.0522, -118.2437);
    const double reverse =
        haversine_distance_meters(34.0522, -118.2437, 37.7749, -122.4194);
    expect(forward == reverse, "distance must be symmetric in its arguments");

    // One degree of arc on a 6,371 km sphere is 2*pi*R/360 ~= 111,195 m.
    expect(
        within(haversine_distance_meters(0.0, 0.0, 1.0, 0.0), 111'100.0, 111'300.0),
        "one degree of latitude at the equator must be about 111.2 km");
    expect(
        within(haversine_distance_meters(0.0, 0.0, 0.0, 1.0), 111'100.0, 111'300.0),
        "one degree of longitude at the equator must be about 111.2 km");

    // Independent published great-circle references, not engine output.
    expect(
        within(
            haversine_distance_meters(1.352083, 103.819836, 1.353083, 103.820836),
            156.0,
            159.0),
        "a Singapore-local 0.001 degree diagonal step must be about 157 m");
    expect(
        within(
            haversine_distance_meters(37.7749, -122.4194, 34.0522, -118.2437),
            555'000.0,
            565'000.0),
        "San Francisco to Los Angeles must be about 559 km");
    expect(
        within(
            haversine_distance_meters(-33.8688, 151.2093, -37.8136, 144.9631),
            705'000.0,
            720'000.0),
        "Sydney to Melbourne must be about 713 km");
    expect(
        within(
            haversine_distance_meters(40.7128, -74.0060, 51.5074, -0.1278),
            5'555'000.0,
            5'585'000.0),
        "New York to London must be about 5,570 km");

    // Crossing the antimeridian. The formula squares sin(dLon / 2), so a
    // 359.999 degree raw delta collapses to the true 0.001 degree separation
    // without any explicit longitude wrapping.
    expect(
        within(
            haversine_distance_meters(0.0, 179.9995, 0.0, -179.9995),
            111.0,
            111.4),
        "a 0.001 degree antimeridian crossing must be about 111 m, not the long way");
    expect(
        within(
            haversine_distance_meters(-17.0, 179.5, -17.0, -179.5),
            106'000.0,
            106'700.0),
        "a one degree antimeridian crossing at 17S must be about 106 km");

    // Pole boundaries.
    expect(
        within(haversine_distance_meters(90.0, 0.0, 89.0, 0.0), 111'100.0, 111'300.0),
        "one degree south of the north pole must be about 111.2 km");
    expect(
        within(haversine_distance_meters(-90.0, 0.0, -89.0, 0.0), 111'100.0, 111'300.0),
        "one degree north of the south pole must be about 111.2 km");
    const double across_north_pole = haversine_distance_meters(90.0, 45.0, 90.0, -135.0);
    expect(
        std::isfinite(across_north_pole) && across_north_pole >= 0.0
            && across_north_pole < 1.0e-6,
        "two longitudes at the north pole must describe the same location");

    // Antipodal points. Half the circumference of a 6,371 km sphere is
    // pi * R ~= 20,015,087 m.
    expect(
        within(
            haversine_distance_meters(0.0, 0.0, 0.0, 180.0),
            20'015'080.0,
            20'015'095.0),
        "equatorial antipodes must be half the circumference apart");
    expect(
        within(
            haversine_distance_meters(45.0, 0.0, -45.0, 180.0),
            20'015'080.0,
            20'015'095.0),
        "mid-latitude antipodes must be half the circumference apart");
    expect(
        within(
            haversine_distance_meters(90.0, 0.0, -90.0, 0.0),
            20'015'080.0,
            20'015'095.0),
        "pole to pole must be half the circumference apart");

    // Preserved limitation, not an improvement target: for some exactly
    // antipodal pairs the rounded haversine term exceeds 1, so sqrt(1 - a)
    // is NaN. The production Swift implementation returns NaN for the same
    // input, and the Swift parity tests assert that both agree.
    expect(
        std::isnan(haversine_distance_meters(12.0, 34.0, -12.0, -146.0)),
        "an exactly antipodal pair must reproduce the Swift NaN result");

    // Nearly antipodal points stay finite and just under half the circumference.
    const double nearly_antipodal = haversine_distance_meters(0.0, 0.0, 0.0001, 180.0);
    expect(
        within(nearly_antipodal, 20'015'070.0, 20'015'086.0),
        "a nearly antipodal pair must stay just under half the circumference");
    expect(
        within(
            haversine_distance_meters(0.0, 0.0, 0.0, 179.999),
            20'014'970.0,
            20'015'086.0),
        "a longitude-only near-antipodal pair must stay finite");

    // A tiny coordinate delta must remain strictly positive and sub-millimetre.
    const double tiny_step = haversine_distance_meters(1.35, 103.8, 1.350000001, 103.8);
    expect(
        std::isfinite(tiny_step) && tiny_step > 0.0 && tiny_step < 0.001,
        "a 1e-9 degree latitude step must be a positive sub-millimetre distance");

    // Invalid inputs return exactly positive zero.
    expect(
        haversine_distance_meters(91.0, 0.0, 0.0, 0.0) == 0.0,
        "an out-of-range first latitude must return zero");
    expect(
        haversine_distance_meters(0.0, 0.0, 0.0, 181.0) == 0.0,
        "an out-of-range second longitude must return zero");
    expect(
        haversine_distance_meters(0.0, 181.0, 0.0, 0.0) == 0.0,
        "an out-of-range first longitude must return zero");
    expect(
        haversine_distance_meters(0.0, 0.0, -91.0, 0.0) == 0.0,
        "an out-of-range second latitude must return zero");
    expect(
        haversine_distance_meters(quiet_nan, 0.0, 0.0, 0.0) == 0.0,
        "a NaN first latitude must return zero");
    expect(
        haversine_distance_meters(0.0, 0.0, 0.0, quiet_nan) == 0.0,
        "a NaN second longitude must return zero");
    expect(
        haversine_distance_meters(positive_infinity, 0.0, 0.0, 0.0) == 0.0,
        "a positive infinity latitude must return zero");
    expect(
        haversine_distance_meters(0.0, negative_infinity, 0.0, 0.0) == 0.0,
        "a negative infinity longitude must return zero");
    expect(
        !std::signbit(haversine_distance_meters(91.0, 0.0, 0.0, 0.0)),
        "the invalid-input result must be positive zero");
}

void run_projection_tests() {
    // The centre projects to the origin.
    const LocalMeters center = project_lat_lon_to_local_meters(1.35, 103.8, 1.35, 103.8);
    expect(center.x_meters == 0.0, "the centre must project to x = 0");
    expect(center.z_meters == 0.0, "the centre must project to z = 0");

    // Directional signs.
    expect(
        project_lat_lon_to_local_meters(1.35, 103.81, 1.35, 103.8).x_meters > 0.0,
        "a point east of the centre must have positive x");
    expect(
        project_lat_lon_to_local_meters(1.35, 103.79, 1.35, 103.8).x_meters < 0.0,
        "a point west of the centre must have negative x");
    expect(
        project_lat_lon_to_local_meters(1.36, 103.8, 1.35, 103.8).z_meters > 0.0,
        "a point north of the centre must have positive z");
    expect(
        project_lat_lon_to_local_meters(1.34, 103.8, 1.35, 103.8).z_meters < 0.0,
        "a point south of the centre must have negative z");

    // Axis isolation.
    const LocalMeters latitude_only =
        project_lat_lon_to_local_meters(1.36, 103.8, 1.35, 103.8);
    expect(
        latitude_only.x_meters == 0.0,
        "an unchanged longitude must produce exactly zero x");
    expect(latitude_only.z_meters != 0.0, "a changed latitude must produce non-zero z");
    const LocalMeters longitude_only =
        project_lat_lon_to_local_meters(1.35, 103.81, 1.35, 103.8);
    expect(
        longitude_only.z_meters == 0.0,
        "an unchanged latitude must produce exactly zero z");
    expect(longitude_only.x_meters != 0.0, "a changed longitude must produce non-zero x");

    // Equatorial centre: cos(0) is exactly 1, so the coefficients reduce to
    // 111412.84 - 93.5 m per degree of longitude and
    // 111132.92 - 559.82 + 1.175 m per degree of latitude.
    const LocalMeters equatorial =
        project_lat_lon_to_local_meters(0.001, 0.001, 0.0, 0.0);
    expect(
        close_to(equatorial.x_meters, 0.001 * (111412.84 - 93.5), 1.0e-6),
        "an equatorial centre must use the documented longitude coefficients");
    expect(
        close_to(equatorial.z_meters, 0.001 * (111132.92 - 559.82 + 1.175), 1.0e-6),
        "an equatorial centre must use the documented latitude coefficients");

    // Singapore-scale values near the equator.
    const LocalMeters singapore =
        project_lat_lon_to_local_meters(1.353083, 103.820836, 1.352083, 103.819836);
    expect(
        within(singapore.x_meters, 111.0, 111.5),
        "a 0.001 degree Singapore longitude step must be about 111.3 m");
    expect(
        within(singapore.z_meters, 110.3, 110.8),
        "a 0.001 degree Singapore latitude step must be about 110.6 m");

    // High-latitude centre: meridians converge while the metres per degree of
    // latitude grows toward the poles.
    const LocalMeters high_latitude =
        project_lat_lon_to_local_meters(71.001, 25.001, 71.0, 25.0);
    expect(
        within(high_latitude.x_meters, 36.0, 36.7),
        "a 0.001 degree longitude step at 71N must be about 36.4 m");
    expect(
        within(high_latitude.z_meters, 111.3, 111.8),
        "a 0.001 degree latitude step at 71N must be about 111.6 m");
    expect(
        high_latitude.x_meters < singapore.x_meters,
        "longitude spacing must shrink toward the pole");
    expect(
        high_latitude.z_meters > singapore.z_meters,
        "latitude spacing must grow toward the pole");

    // Non-finite inputs propagate instead of being silently repaired.
    const LocalMeters nan_latitude =
        project_lat_lon_to_local_meters(quiet_nan, 0.0, 0.0, 0.0);
    expect(std::isnan(nan_latitude.z_meters), "a NaN latitude must propagate into z");
    expect(
        nan_latitude.x_meters == 0.0,
        "a NaN latitude must leave an unchanged longitude at zero x");
    const LocalMeters infinite_longitude =
        project_lat_lon_to_local_meters(0.0, positive_infinity, 0.0, 0.0);
    expect(
        std::isinf(infinite_longitude.x_meters) && infinite_longitude.x_meters > 0.0,
        "a positive infinity longitude must propagate into positive infinite x");
    const LocalMeters infinite_center_longitude =
        project_lat_lon_to_local_meters(0.0, 0.0, 0.0, positive_infinity);
    expect(
        std::isinf(infinite_center_longitude.x_meters)
            && infinite_center_longitude.x_meters < 0.0,
        "an infinite centre longitude must propagate into negative infinite x");
    const LocalMeters nan_center =
        project_lat_lon_to_local_meters(1.0, 1.0, quiet_nan, 0.0);
    expect(
        std::isnan(nan_center.x_meters) && std::isnan(nan_center.z_meters),
        "a NaN centre latitude must poison both projected axes");

    // Out-of-range inputs are projected, not validated or clamped.
    const LocalMeters unvalidated =
        project_lat_lon_to_local_meters(1000.0, 4000.0, 0.0, 0.0);
    expect(
        std::isfinite(unvalidated.x_meters) && unvalidated.x_meters > 0.0,
        "the projection must not validate or clamp an out-of-range longitude");
    expect(
        std::isfinite(unvalidated.z_meters) && unvalidated.z_meters > 0.0,
        "the projection must not validate or clamp an out-of-range latitude");

    // Antimeridian-adjacent centres are not wrapped: the raw longitude delta is
    // used exactly as supplied.
    const LocalMeters unwrapped =
        project_lat_lon_to_local_meters(0.0, -179.9995, 0.0, 179.9995);
    expect(
        unwrapped.x_meters < -39'000'000.0,
        "the projection must not wrap longitude across the antimeridian");
}

}  // namespace

void run_geodesy_tests() {
    run_coordinate_validation_tests();
    run_distance_tests();
    run_projection_tests();
}
