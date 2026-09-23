#pragma once

// Internal DEM tile-grid geometry shared by tile planning and sampling.
// Not part of the public engine boundary and must not be installed under
// include/. Planning and sampling both call `dem_pixel_footprint`, so every
// tile a sample reads is, by construction, a tile the planner lists.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <numbers>

#include "RunPlayEngineCpp/DemElevationSampling.hpp"
#include "RunPlayEngineCpp/Geodesy.hpp"

namespace runplay::internal {

enum class DemCoordinateClass : std::uint8_t {
    projectable,
    invalid_coordinate,
    outside_projection,
};

/// The global pixels a bilinear sample of one coordinate reads.
///
/// Columns are wrapped into [0, world) so the antimeridian joins the last and
/// first columns; rows are clamped into [0, world) so a sample within half a
/// pixel of the Web Mercator limit extends the edge row instead of wrapping
/// across a pole. Only pixels with non-zero bilinear weight are listed: a
/// fraction of exactly zero lists one column (or row), and a clamped pair that
/// collapses onto one row lists one row.
struct DemPixelFootprint final {
    DemCoordinateClass classification{DemCoordinateClass::invalid_coordinate};

    std::array<std::int64_t, 2> columns{};
    std::array<std::int64_t, 2> rows{};
    std::uint32_t column_count{0};
    std::uint32_t row_count{0};

    /// Weight of `columns[1]` (and of `rows[1]`); meaningful only when the
    /// corresponding count is two.
    double column_fraction{0};
    double row_fraction{0};
};

[[nodiscard]]
inline std::int64_t dem_world_pixel_count(std::uint32_t zoom, std::uint32_t tile_size) noexcept {
    return (std::int64_t{1} << zoom) * static_cast<std::int64_t>(tile_size);
}

[[nodiscard]]
inline std::int64_t dem_wrap_column(std::int64_t column, std::int64_t world) noexcept {
    const std::int64_t remainder = column % world;
    return remainder < 0 ? remainder + world : remainder;
}

/// Classifies one coordinate and, when projectable, lists the pixels its
/// bilinear sample reads. Pixel (i, j) holds the height at its centre, so the
/// sample position is offset by half a pixel before flooring.
///
/// Statements are split so no single expression holds both a multiply and an
/// add: Clang's default `-ffp-contract=on` could otherwise fuse them into an
/// FMA on some targets and change a pixel boundary decision between platforms.
[[nodiscard]]
inline DemPixelFootprint dem_pixel_footprint(
    double latitude_degrees,
    double longitude_degrees,
    std::uint32_t zoom,
    std::uint32_t tile_size
) noexcept {
    DemPixelFootprint footprint{};
    if (!is_valid_coordinate(latitude_degrees, longitude_degrees)) {
        footprint.classification = DemCoordinateClass::invalid_coordinate;
        return footprint;
    }
    if (std::abs(latitude_degrees) > dem_web_mercator_max_latitude_degrees) {
        footprint.classification = DemCoordinateClass::outside_projection;
        return footprint;
    }
    footprint.classification = DemCoordinateClass::projectable;

    const std::int64_t world = dem_world_pixel_count(zoom, tile_size);
    const double world_pixels = static_cast<double>(world);

    // Longitude: x grows east from the antimeridian. ±180 give fractions 0 and
    // 1, which wrap to the same column pair below.
    const double shifted_longitude = longitude_degrees + 180.0;
    const double x_fraction = shifted_longitude / 360.0;
    const double global_x = x_fraction * world_pixels;
    const double column_position = global_x - 0.5;
    const double column_floor = std::floor(column_position);
    const double column_fraction = column_position - column_floor;
    const auto first_column = static_cast<std::int64_t>(column_floor);

    // Latitude: spherical Web Mercator, y grows south from the north edge.
    // Clamping absorbs the last ulp at the latitude limit.
    const double latitude_radians = latitude_degrees * std::numbers::pi_v<double> / 180.0;
    const double mercator = std::asinh(std::tan(latitude_radians));
    const double mercator_fraction = mercator / (2.0 * std::numbers::pi_v<double>);
    const double y_fraction = std::clamp(0.5 - mercator_fraction, 0.0, 1.0);
    const double global_y = y_fraction * world_pixels;
    const double row_position = global_y - 0.5;
    const double row_floor = std::floor(row_position);
    const double row_fraction = row_position - row_floor;
    const auto first_row = static_cast<std::int64_t>(row_floor);

    footprint.columns[0] = dem_wrap_column(first_column, world);
    footprint.column_count = 1;
    if (column_fraction > 0.0) {
        footprint.columns[1] = dem_wrap_column(first_column + 1, world);
        footprint.column_count = 2;
        footprint.column_fraction = column_fraction;
    }

    const std::int64_t last_row = world - 1;
    footprint.rows[0] = std::clamp(first_row, std::int64_t{0}, last_row);
    footprint.row_count = 1;
    const std::int64_t second_row = std::clamp(first_row + 1, std::int64_t{0}, last_row);
    if (row_fraction > 0.0 && second_row != footprint.rows[0]) {
        footprint.rows[1] = second_row;
        footprint.row_count = 2;
        footprint.row_fraction = row_fraction;
    }
    return footprint;
}

[[nodiscard]]
inline DemTileKey dem_tile_of_pixel(
    std::int64_t column,
    std::int64_t row,
    std::uint32_t tile_size
) noexcept {
    const auto size = static_cast<std::int64_t>(tile_size);
    return DemTileKey{
        static_cast<std::uint32_t>(column / size),
        static_cast<std::uint32_t>(row / size),
    };
}

[[nodiscard]]
inline bool dem_tile_key_less(const DemTileKey& lhs, const DemTileKey& rhs) noexcept {
    return lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x;
}

[[nodiscard]]
inline bool dem_tile_key_equal(const DemTileKey& lhs, const DemTileKey& rhs) noexcept {
    return lhs.x == rhs.x && lhs.y == rhs.y;
}

/// Distinct tiles holding the pixels of one footprint: at most four.
struct DemFootprintTiles final {
    std::array<DemTileKey, 4> keys{};
    std::size_t count{0};
};

[[nodiscard]]
inline DemFootprintTiles dem_footprint_tiles(
    const DemPixelFootprint& footprint,
    std::uint32_t tile_size
) noexcept {
    DemFootprintTiles tiles{};
    for (std::uint32_t row = 0; row < footprint.row_count; ++row) {
        for (std::uint32_t column = 0; column < footprint.column_count; ++column) {
            const DemTileKey key = dem_tile_of_pixel(
                footprint.columns[column],
                footprint.rows[row],
                tile_size);
            bool seen = false;
            for (std::size_t index = 0; index < tiles.count; ++index) {
                seen = seen || dem_tile_key_equal(tiles.keys[index], key);
            }
            if (!seen) {
                tiles.keys[tiles.count] = key;
                ++tiles.count;
            }
        }
    }
    return tiles;
}

}  // namespace runplay::internal
