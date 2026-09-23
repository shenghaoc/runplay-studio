#include "RunPlayEngineCpp/DemElevationSampling.hpp"
#include "RunPlayEngineCpp/RouteInterop.hpp"

#include <algorithm>
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

}  // namespace runplay
