#include "RunPlayEngineCpp/DemElevationSampling.hpp"
#include "RunPlayEngineCpp/RouteInterop.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <new>
#include <vector>

#include "Internal/DemTileGridInternal.hpp"

namespace runplay {
namespace {

// ---- Validation (no output writes) -----------------------------------------

[[nodiscard]]
bool is_valid_policy(const DemSamplingPolicy& policy) noexcept {
    return policy.zoom <= dem_maximum_zoom
        && policy.tile_size >= dem_minimum_tile_size
        && policy.tile_size <= dem_maximum_tile_size
        && policy.maximum_tile_count >= 1u
        && policy.maximum_tile_count <= dem_maximum_tile_count
        && std::isfinite(policy.minimum_plausible_elevation_meters)
        && std::isfinite(policy.maximum_plausible_elevation_meters)
        && policy.minimum_plausible_elevation_meters
            < policy.maximum_plausible_elevation_meters;
}

[[nodiscard]]
DemTilePlanSummary plan_failure(DemSamplingStatus status) noexcept {
    DemTilePlanSummary summary{};
    summary.status = status;
    return summary;
}

[[nodiscard]]
DemSamplingSummary sampling_failure(
    DemSamplingStatus status,
    std::size_t sample_count
) noexcept {
    DemSamplingSummary summary{};
    summary.status = status;
    summary.required_output_capacity = static_cast<std::uint64_t>(sample_count);
    return summary;
}

/// Directory contract: at most `maximum_tile_count` keys, strictly ascending by
/// (y, x), every key inside the zoom's grid, and exactly `tile_size^2` heights
/// per key. Checked in full before sampling writes anything.
[[nodiscard]]
bool is_valid_tile_directory(
    const DemSamplingPolicy& policy,
    const DemTileKey* tiles,
    std::size_t tile_count,
    std::size_t tile_height_count
) noexcept {
    if (static_cast<std::uint64_t>(tile_count) > policy.maximum_tile_count) {
        return false;
    }
    // tile_count <= 65,536 and tile_size^2 <= 2^24, so the product fits.
    const std::uint64_t heights_per_tile =
        static_cast<std::uint64_t>(policy.tile_size) * policy.tile_size;
    if (static_cast<std::uint64_t>(tile_height_count)
        != static_cast<std::uint64_t>(tile_count) * heights_per_tile) {
        return false;
    }
    const std::uint64_t tiles_per_axis = std::uint64_t{1} << policy.zoom;
    for (std::size_t index = 0u; index < tile_count; ++index) {
        if (tiles[index].x >= tiles_per_axis || tiles[index].y >= tiles_per_axis) {
            return false;
        }
        if (index > 0u && !internal::dem_tile_key_less(tiles[index - 1u], tiles[index])) {
            return false;
        }
    }
    return true;
}

/// Directory position of `key`, remembering the previous hit because
/// consecutive corners and consecutive points usually share a tile.
class TileDirectory final {
public:
    TileDirectory(const DemTileKey* tiles, std::size_t tile_count) noexcept
        : tiles_(tiles), tile_count_(tile_count) {}

    [[nodiscard]]
    bool find(const DemTileKey& key, std::size_t& position) noexcept {
        if (has_cached_ && internal::dem_tile_key_equal(tiles_[cached_], key)) {
            position = cached_;
            return true;
        }
        const DemTileKey* end = tiles_ + tile_count_;
        const DemTileKey* found = std::lower_bound(tiles_, end, key, internal::dem_tile_key_less);
        if (found == end || !internal::dem_tile_key_equal(*found, key)) {
            return false;
        }
        cached_ = static_cast<std::size_t>(found - tiles_);
        has_cached_ = true;
        position = cached_;
        return true;
    }

private:
    const DemTileKey* tiles_;
    std::size_t tile_count_;
    std::size_t cached_{0};
    bool has_cached_{false};
};

/// `first + (second - first) * fraction`, split so no statement holds both a
/// multiply and an add (see the footprint note on -ffp-contract).
[[nodiscard]]
double interpolate(double first, double second, double fraction) noexcept {
    const double difference = second - first;
    const double scaled = difference * fraction;
    return first + scaled;
}

}  // namespace

// ---------------------------------------------------------------------------
// Tile planning
// ---------------------------------------------------------------------------

DemTilePlanSummary plan_dem_tiles(
    const DemRouteSample* samples,
    std::size_t sample_count,
    DemSamplingPolicy policy,
    DemTileKey* output_tiles,
    std::size_t output_capacity
) noexcept {
    if (sample_count == 0u) {
        return is_valid_policy(policy)
            ? DemTilePlanSummary{}
            : plan_failure(DemSamplingStatus::invalid_policy);
    }
    if (samples == nullptr) {
        return plan_failure(DemSamplingStatus::invalid_input_buffer);
    }
    if (output_tiles == nullptr && output_capacity > 0u) {
        return plan_failure(DemSamplingStatus::invalid_output_buffer);
    }
    if (sample_count > max_route_input_samples) {
        return plan_failure(DemSamplingStatus::resource_limit);
    }
    if (!is_valid_policy(policy)) {
        return plan_failure(DemSamplingStatus::invalid_policy);
    }

    try {
        // Strictly ascending (y, x) set, bounded by the tile budget rather than
        // by route length. Consecutive points usually share their tiles, so
        // the previous footprint is checked before the binary search.
        std::vector<DemTileKey> tiles;
        tiles.reserve(static_cast<std::size_t>(
            std::min<std::uint64_t>(policy.maximum_tile_count, 256u)));
        internal::DemFootprintTiles previous{};

        DemTilePlanSummary summary{};
        summary.sample_count = static_cast<std::uint64_t>(sample_count);

        for (std::size_t index = 0u; index < sample_count; ++index) {
            const DemRouteSample& sample = samples[index];
            const internal::DemPixelFootprint footprint = internal::dem_pixel_footprint(
                sample.latitude_degrees,
                sample.longitude_degrees,
                policy.zoom,
                policy.tile_size);
            if (footprint.classification == internal::DemCoordinateClass::invalid_coordinate) {
                ++summary.invalid_coordinate_count;
                continue;
            }
            if (footprint.classification == internal::DemCoordinateClass::outside_projection) {
                ++summary.outside_projection_count;
                continue;
            }
            ++summary.projectable_sample_count;

            const internal::DemFootprintTiles current =
                internal::dem_footprint_tiles(footprint, policy.tile_size);
            for (std::size_t key_index = 0u; key_index < current.count; ++key_index) {
                const DemTileKey key = current.keys[key_index];
                bool recent = false;
                for (std::size_t seen = 0u; seen < previous.count; ++seen) {
                    recent = recent || internal::dem_tile_key_equal(previous.keys[seen], key);
                }
                if (recent) {
                    continue;
                }
                const auto position = std::lower_bound(
                    tiles.begin(), tiles.end(), key, internal::dem_tile_key_less);
                if (position != tiles.end() && internal::dem_tile_key_equal(*position, key)) {
                    continue;
                }
                if (static_cast<std::uint64_t>(tiles.size()) >= policy.maximum_tile_count) {
                    DemTilePlanSummary exceeded{};
                    exceeded.status = DemSamplingStatus::tile_budget_exceeded;
                    exceeded.sample_count = static_cast<std::uint64_t>(sample_count);
                    exceeded.required_tile_count = policy.maximum_tile_count + 1u;
                    return exceeded;
                }
                tiles.insert(position, key);
            }
            previous = current;
        }

        summary.required_tile_count = static_cast<std::uint64_t>(tiles.size());
        if (tiles.size() > output_capacity) {
            summary.status = DemSamplingStatus::insufficient_output_capacity;
            return summary;
        }
        std::copy(tiles.begin(), tiles.end(), output_tiles);
        summary.written_tile_count = summary.required_tile_count;
        return summary;
    } catch (const std::bad_alloc&) {
        return plan_failure(DemSamplingStatus::allocation_failure);
    } catch (...) {
        return plan_failure(DemSamplingStatus::internal_failure);
    }
}

// ---------------------------------------------------------------------------
// Bilinear sampling
// ---------------------------------------------------------------------------

DemSamplingSummary sample_dem_elevations(
    const DemRouteSample* samples,
    std::size_t sample_count,
    DemSamplingPolicy policy,
    const DemTileKey* tiles,
    std::size_t tile_count,
    const DemTileHeightSample* tile_heights,
    std::size_t tile_height_count,
    DemElevationOutputSample* output_samples,
    std::size_t output_capacity
) noexcept {
    // ---- Validation (no output writes) ----
    if (samples == nullptr && sample_count > 0u) {
        return sampling_failure(DemSamplingStatus::invalid_input_buffer, sample_count);
    }
    if ((tiles == nullptr && tile_count > 0u)
        || (tile_heights == nullptr && tile_height_count > 0u)) {
        return sampling_failure(DemSamplingStatus::invalid_input_buffer, sample_count);
    }
    if (output_samples == nullptr && output_capacity > 0u) {
        return sampling_failure(DemSamplingStatus::invalid_output_buffer, sample_count);
    }
    if (output_capacity < sample_count) {
        return sampling_failure(DemSamplingStatus::insufficient_output_capacity, sample_count);
    }
    if (sample_count > max_route_input_samples) {
        return sampling_failure(DemSamplingStatus::resource_limit, sample_count);
    }
    if (!is_valid_policy(policy)) {
        return sampling_failure(DemSamplingStatus::invalid_policy, sample_count);
    }
    if (!is_valid_tile_directory(policy, tiles, tile_count, tile_height_count)) {
        return sampling_failure(DemSamplingStatus::invalid_tile_directory, sample_count);
    }

    // ---- Validation complete. Every output entry is written below. ----
    DemSamplingSummary summary{};
    summary.sample_count = static_cast<std::uint64_t>(sample_count);
    summary.required_output_capacity = summary.sample_count;

    const std::size_t tile_size = policy.tile_size;
    const std::size_t heights_per_tile = tile_size * tile_size;
    TileDirectory directory(tiles, tile_count);

    for (std::size_t index = 0u; index < sample_count; ++index) {
        DemElevationOutputSample result{};
        const internal::DemPixelFootprint footprint = internal::dem_pixel_footprint(
            samples[index].latitude_degrees,
            samples[index].longitude_degrees,
            policy.zoom,
            policy.tile_size);

        if (footprint.classification == internal::DemCoordinateClass::invalid_coordinate) {
            result.status = DemSampleStatus::invalid_coordinate;
        } else if (footprint.classification == internal::DemCoordinateClass::outside_projection) {
            result.status = DemSampleStatus::outside_projection;
        } else {
            // corner[row][column]; only non-zero-weight corners are resolved.
            std::array<std::array<double, 2>, 2> corner{};
            bool missing = false;
            bool implausible = false;
            for (std::uint32_t row = 0u; row < footprint.row_count; ++row) {
                for (std::uint32_t column = 0u; column < footprint.column_count; ++column) {
                    const std::int64_t global_column = footprint.columns[column];
                    const std::int64_t global_row = footprint.rows[row];
                    const DemTileKey key =
                        internal::dem_tile_of_pixel(global_column, global_row, policy.tile_size);
                    std::size_t position = 0u;
                    if (!directory.find(key, position)) {
                        missing = true;
                        continue;
                    }
                    const auto local_column = static_cast<std::size_t>(
                        global_column % static_cast<std::int64_t>(tile_size));
                    const auto local_row = static_cast<std::size_t>(
                        global_row % static_cast<std::int64_t>(tile_size));
                    const std::size_t offset =
                        position * heights_per_tile + local_row * tile_size + local_column;
                    const double height = static_cast<double>(tile_heights[offset].height_meters);
                    if (!std::isfinite(height)
                        || height < policy.minimum_plausible_elevation_meters
                        || height > policy.maximum_plausible_elevation_meters) {
                        implausible = true;
                    }
                    corner[row][column] = height;
                }
            }

            if (missing) {
                result.status = DemSampleStatus::missing_tile;
            } else if (implausible) {
                result.status = DemSampleStatus::implausible_height;
            } else {
                const double top = footprint.column_count == 2u
                    ? interpolate(corner[0][0], corner[0][1], footprint.column_fraction)
                    : corner[0][0];
                double elevation = top;
                if (footprint.row_count == 2u) {
                    const double bottom = footprint.column_count == 2u
                        ? interpolate(corner[1][0], corner[1][1], footprint.column_fraction)
                        : corner[1][0];
                    elevation = interpolate(top, bottom, footprint.row_fraction);
                }
                result.status = DemSampleStatus::sampled;
                result.elevation_meters = elevation;
                result.has_elevation = 1u;
            }
        }

        switch (result.status) {
        case DemSampleStatus::sampled:
            ++summary.sampled_count;
            break;
        case DemSampleStatus::invalid_coordinate:
            ++summary.invalid_coordinate_count;
            break;
        case DemSampleStatus::outside_projection:
            ++summary.outside_projection_count;
            break;
        case DemSampleStatus::missing_tile:
            ++summary.missing_tile_count;
            break;
        case DemSampleStatus::implausible_height:
            ++summary.implausible_height_count;
            break;
        }
        output_samples[index] = result;
    }
    return summary;
}

}  // namespace runplay
