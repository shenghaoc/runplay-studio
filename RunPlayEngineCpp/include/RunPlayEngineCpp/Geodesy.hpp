#pragma once

#include <type_traits>

namespace runplay {

/// Earth mean radius in metres.
///
/// This value must stay identical to the Swift `GeoDistance.earthRadiusMeters`
/// constant. It is a spherical mean radius, not a WGS-84 equatorial or polar
/// radius and not an ellipsoid parameter. Replacing it would change every
/// distance RunPlay Studio has ever reported for an existing workout.
inline constexpr double earth_radius_meters = 6'371'000.0;

/// Planar offset in metres relative to a projection centre.
///
/// The public boundary returns this named value rather than a pair or tuple so
/// the Swift adapter reads two documented fields instead of positional
/// elements. It is an allocation-free aggregate with no pointers, references,
/// virtual methods, or bases.
struct LocalMeters final {
    double x_meters;
    double z_meters;
};

static_assert(std::is_standard_layout_v<LocalMeters>);
static_assert(std::is_trivially_copyable_v<LocalMeters>);
static_assert(std::is_nothrow_copy_constructible_v<LocalMeters>);

/// Reports whether a coordinate is finite and inside the inclusive geographic
/// ranges accepted by RunPlay Studio.
///
/// Latitude must be within -90...90 and longitude within -180...180, both
/// inclusive. Positive and negative zero are accepted; NaN and both infinities
/// are rejected.
[[nodiscard]]
bool is_valid_coordinate(double latitude, double longitude) noexcept;

/// Great-circle distance in metres between two coordinates given in degrees.
///
/// Returns positive zero when either coordinate pair fails
/// `is_valid_coordinate`. Otherwise applies the Haversine formula against
/// `earth_radius_meters` using the same operation order as the Swift
/// implementation, so results stay bit-comparable on a given platform. Performs
/// no allocation and no longitude normalisation.
[[nodiscard]]
double haversine_distance_meters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2
) noexcept;

/// Projects a coordinate into local metres relative to a centre coordinate.
///
/// Uses the existing equirectangular approximation with its published
/// metres-per-degree coefficients, including its limitations: inputs are not
/// validated or clamped, longitude is not wrapped across the antimeridian, and
/// non-finite inputs propagate into the result instead of being repaired. The
/// approximation is intended for routes shorter than about 100 km.
[[nodiscard]]
LocalMeters project_lat_lon_to_local_meters(
    double latitude,
    double longitude,
    double center_latitude,
    double center_longitude
) noexcept;

}  // namespace runplay
