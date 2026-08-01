#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace runplay {

// ---------------------------------------------------------------------------
// Input sample — one-to-one with route points (caller-owned)
// ---------------------------------------------------------------------------

/// Compact elevation-construction input for one route point.
///
/// Input order is source route-point order. Distance is the point's cumulative
/// normalized distance. Continuity group changes on every source route-segment
/// transition. `has_altitude == 0` means missing (`nil`); `has_altitude == 1`
/// means a present source value (including NaN/infinity, which are rejected as
/// data, not treated as missing).
struct ElevationProfileInputSample final {
    double distance_meters{0};
    double altitude_meters{0};

    std::int32_t continuity_group{0};
    std::uint8_t has_altitude{0};
};

static_assert(std::is_standard_layout_v<ElevationProfileInputSample>);
static_assert(std::is_trivially_copyable_v<ElevationProfileInputSample>);
static_assert(std::is_nothrow_default_constructible_v<ElevationProfileInputSample>);
static_assert(std::is_nothrow_copy_constructible_v<ElevationProfileInputSample>);
static_assert(std::is_nothrow_copy_assignable_v<ElevationProfileInputSample>);

// ---------------------------------------------------------------------------
// Policy — elevation construction only
// ---------------------------------------------------------------------------

struct ElevationProfilePolicy final {
    double plausible_altitude_minimum_meters{0};
    double plausible_altitude_maximum_meters{0};

    double spike_minimum_deviation_meters{0};
    double short_excursion_minimum_deviation_meters{0};
    std::uint64_t short_excursion_maximum_sample_count{0};

    double spike_maximum_neighbor_difference_meters{0};
    double spike_maximum_horizontal_span_meters{0};

    double smoothing_radius_meters{0};
    std::uint64_t minimum_reliable_sample_count{0};
    double gain_loss_deadband_meters{0};
};

static_assert(std::is_standard_layout_v<ElevationProfilePolicy>);
static_assert(std::is_trivially_copyable_v<ElevationProfilePolicy>);
static_assert(std::is_nothrow_default_constructible_v<ElevationProfilePolicy>);
static_assert(std::is_nothrow_copy_constructible_v<ElevationProfilePolicy>);
static_assert(std::is_nothrow_copy_assignable_v<ElevationProfilePolicy>);

// ---------------------------------------------------------------------------
// Output sample — one entry per input route point
// ---------------------------------------------------------------------------

/// Per-point elevation profile result.
///
/// `run_identifier == -1` when no corrected altitude exists.
/// `reliable_run_identifier == -1` for missing or unreliable samples.
/// Otherwise identifiers reproduce the live Swift run-numbering rules.
struct ElevationProfileOutputSample final {
    double corrected_altitude_meters{0};

    double cumulative_ascent_meters{0};
    double cumulative_descent_meters{0};
    double cumulative_signed_change_meters{0};
    double reliable_interval_count{0};

    std::int32_t run_identifier{-1};
    std::int32_t reliable_run_identifier{-1};

    std::uint8_t has_corrected_altitude{0};
    std::uint8_t source_altitude_was_rejected{0};
};

static_assert(std::is_standard_layout_v<ElevationProfileOutputSample>);
static_assert(std::is_trivially_copyable_v<ElevationProfileOutputSample>);
static_assert(std::is_nothrow_default_constructible_v<ElevationProfileOutputSample>);
static_assert(std::is_nothrow_copy_constructible_v<ElevationProfileOutputSample>);
static_assert(std::is_nothrow_copy_assignable_v<ElevationProfileOutputSample>);

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

enum class ElevationProfileStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_output_buffer,
    insufficient_output_capacity,
    invalid_policy,
    invalid_input_contract,
    resource_limit,
    internal_failure,
};

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

struct ElevationProfileSummary final {
    ElevationProfileStatus status{
        ElevationProfileStatus::success
    };

    std::uint64_t sample_count{0};
    std::uint64_t rejected_altitude_count{0};
    std::uint64_t run_count{0};
    std::uint64_t reliable_run_count{0};

    std::uint64_t required_output_capacity{0};

    std::uint8_t has_meaningful_elevation{0};
    double total_ascent_meters{0};
    double total_descent_meters{0};
};

static_assert(std::is_standard_layout_v<ElevationProfileSummary>);
static_assert(std::is_trivially_copyable_v<ElevationProfileSummary>);
static_assert(std::is_nothrow_default_constructible_v<ElevationProfileSummary>);
static_assert(std::is_nothrow_copy_constructible_v<ElevationProfileSummary>);
static_assert(std::is_nothrow_copy_assignable_v<ElevationProfileSummary>);

// ---------------------------------------------------------------------------
// Bulk function
// ---------------------------------------------------------------------------

/// Complete multi-pass elevation profile construction for one route.
///
/// samples          Swift-owned, immutable, borrowed synchronously
/// output_samples   Swift-owned, mutable, borrowed synchronously
///
/// C++ retains no pointer, performs no callback, and allocates no route-sized
/// storage. After validation succeeds the output buffer is the route-sized
/// workspace; every failure path returns before the first output write. On any
/// non-success status the output buffer is left completely unchanged.
///
/// Empty input allows null buffers and returns success with zero capacity.
[[nodiscard]]
ElevationProfileSummary build_elevation_profile(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count,
    ElevationProfilePolicy policy,
    ElevationProfileOutputSample* output_samples,
    std::size_t output_capacity
) noexcept;

}  // namespace runplay
