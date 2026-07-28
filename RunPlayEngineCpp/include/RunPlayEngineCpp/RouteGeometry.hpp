#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

#include "RunPlayEngineCpp/RouteInterop.hpp"

namespace runplay {

/// Outcome of one bulk route step-distance calculation.
enum class RouteStepDistanceStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_output_buffer,
    insufficient_output_capacity,
    resource_limit,
};

/// Compact pure-value evidence returned after computing one complete step
/// series.
///
/// Allocation-free aggregate so the Swift adapter can copy named fields
/// without ownership transfer or dynamic storage.
struct RouteStepDistanceSummary final {
    RouteStepDistanceStatus status;
    std::uint64_t sample_count;
    std::uint64_t segment_transition_count;
    std::uint64_t invalid_coordinate_pair_count;
    double total_distance_meters;
};

static_assert(std::is_standard_layout_v<RouteStepDistanceSummary>);
static_assert(std::is_trivially_copyable_v<RouteStepDistanceSummary>);
static_assert(std::is_nothrow_copy_constructible_v<RouteStepDistanceSummary>);

/// Computes per-sample step distances for one complete route.
///
/// `samples` is borrowed only for this call and is never stored.
/// `step_distances_meters` is caller-owned mutable storage; C++ writes
/// exactly `sample_count` entries on success and writes nothing on error.
/// A null input or output pointer is valid only when `sample_count` is zero.
/// Output index `i` corresponds to input index `i`.
[[nodiscard]]
RouteStepDistanceSummary compute_route_step_distances(
    const RouteInputSample* samples,
    std::size_t sample_count,
    double* step_distances_meters,
    std::size_t step_distance_capacity
) noexcept;

}  // namespace runplay
