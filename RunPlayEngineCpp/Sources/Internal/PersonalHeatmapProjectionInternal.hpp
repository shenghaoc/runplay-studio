#pragma once

#include <cmath>
#include <cstdint>
#include <numbers>
#include <optional>
#include "RunPlayEngineCpp/Geodesy.hpp"
#include "RunPlayEngineCpp/PersonalHeatmapCoverage.hpp"

namespace runplay::internal {

inline constexpr double personal_heatmap_half_world_meters =
    std::numbers::pi_v<double> * earth_radius_meters;

[[nodiscard]]
inline double personal_heatmap_clamp_latitude(double latitude) noexcept {
    return std::min(
        std::max(latitude, -personal_heatmap_max_latitude_degrees),
        personal_heatmap_max_latitude_degrees
    );
}

[[nodiscard]]
inline double personal_heatmap_normalize_longitude(double longitude) noexcept {
    if (!std::isfinite(longitude)) {
        return longitude;
    }
    double lon = std::fmod(longitude, 360.0);
    if (lon <= -180.0) {
        lon += 360.0;
    } else if (lon > 180.0) {
        lon -= 360.0;
    }
    return lon;
}

struct ProjectedPoint final {
    double x{0};
    double y{0};
};

[[nodiscard]]
inline std::optional<ProjectedPoint> personal_heatmap_project(
    double latitude,
    double longitude
) noexcept {
    if (!is_valid_coordinate(latitude, longitude)) {
        return std::nullopt;
    }

    const double lat = personal_heatmap_clamp_latitude(latitude);
    const double lon = personal_heatmap_normalize_longitude(longitude);

    const double lat_rad = lat * std::numbers::pi_v<double> / 180.0;
    const double lon_rad = lon * std::numbers::pi_v<double> / 180.0;
    const double r = earth_radius_meters;

    const double x = r * lon_rad;
    const double y = r * std::log(std::tan(std::numbers::pi_v<double> / 4.0 + lat_rad / 2.0));

    if (!std::isfinite(x) || !std::isfinite(y)) {
        return std::nullopt;
    }

    return ProjectedPoint{x, y};
}

[[nodiscard]]
inline std::optional<std::int64_t> personal_heatmap_cell_index(
    double projected,
    double cell_size_meters
) noexcept {
    if (!std::isfinite(projected) || !std::isfinite(cell_size_meters) || cell_size_meters <= 0.0) {
        return std::nullopt;
    }

    const double clamped = std::min(
        std::max(projected, -personal_heatmap_half_world_meters),
        personal_heatmap_half_world_meters
    );
    const double quotient = std::floor(clamped / cell_size_meters);

    if (!std::isfinite(quotient) ||
        quotient < static_cast<double>(INT64_MIN) ||
        quotient > static_cast<double>(INT64_MAX)) {
        return std::nullopt;
    }

    return static_cast<std::int64_t>(quotient);
}

}  // namespace runplay::internal
