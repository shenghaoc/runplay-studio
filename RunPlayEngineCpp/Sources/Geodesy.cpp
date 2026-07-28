#include "RunPlayEngineCpp/Geodesy.hpp"

#include <cmath>
#include <numbers>

namespace runplay {
namespace {

/// Converts degrees to radians using the Swift operation order.
///
/// Swift evaluates `degrees * .pi / 180` left to right, so it multiplies before
/// dividing. Folding this into `degrees * (pi / 180)` would round differently
/// and break parity with the production Swift implementation.
[[nodiscard]]
constexpr double degrees_to_radians(double degrees) noexcept {
    return degrees * std::numbers::pi_v<double> / 180.0;
}

}  // namespace

bool is_valid_coordinate(double latitude, double longitude) noexcept {
    return std::isfinite(latitude) && std::isfinite(longitude)
        && latitude >= -90.0 && latitude <= 90.0
        && longitude >= -180.0 && longitude <= 180.0;
}

double haversine_distance_meters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2
) noexcept {
    if (!is_valid_coordinate(latitude1, longitude1)
        || !is_valid_coordinate(latitude2, longitude2)) {
        return 0.0;
    }

    const double delta_latitude_radians = degrees_to_radians(latitude2 - latitude1);
    const double delta_longitude_radians = degrees_to_radians(longitude2 - longitude1);
    const double latitude1_radians = degrees_to_radians(latitude1);
    const double latitude2_radians = degrees_to_radians(latitude2);

    // Each statement below holds at most one addition or subtraction, so
    // `-ffp-contract=on` cannot fuse a multiply-add across the expression. Swift
    // never contracts, and an FMA here would silently change the last bits of
    // `a` relative to the Swift reference implementation.
    const double half_delta_latitude_sine = std::sin(delta_latitude_radians / 2.0);
    const double half_delta_longitude_sine = std::sin(delta_longitude_radians / 2.0);
    const double latitude_cosine_product =
        std::cos(latitude1_radians) * std::cos(latitude2_radians);

    const double latitudinal_term =
        half_delta_latitude_sine * half_delta_latitude_sine;
    const double longitudinal_term = latitude_cosine_product
        * half_delta_longitude_sine * half_delta_longitude_sine;

    const double a = latitudinal_term + longitudinal_term;
    const double c = 2.0 * std::atan2(std::sqrt(a), std::sqrt(1.0 - a));

    return earth_radius_meters * c;
}

LocalMeters project_lat_lon_to_local_meters(
    double latitude,
    double longitude,
    double center_latitude,
    double center_longitude
) noexcept {
    const double center_latitude_radians = degrees_to_radians(center_latitude);

    // Split for the same no-contraction reason as the Haversine terms above.
    const double latitude_second_harmonic =
        559.82 * std::cos(2.0 * center_latitude_radians);
    const double latitude_fourth_harmonic =
        1.175 * std::cos(4.0 * center_latitude_radians);
    const double meters_per_degree_latitude_base = 111132.92 - latitude_second_harmonic;
    const double meters_per_degree_latitude =
        meters_per_degree_latitude_base + latitude_fourth_harmonic;

    const double longitude_first_harmonic =
        111412.84 * std::cos(center_latitude_radians);
    const double longitude_third_harmonic =
        93.5 * std::cos(3.0 * center_latitude_radians);
    const double meters_per_degree_longitude =
        longitude_first_harmonic - longitude_third_harmonic;

    const double x_meters = (longitude - center_longitude) * meters_per_degree_longitude;
    const double z_meters = (latitude - center_latitude) * meters_per_degree_latitude;

    return LocalMeters{x_meters, z_meters};
}

}  // namespace runplay
