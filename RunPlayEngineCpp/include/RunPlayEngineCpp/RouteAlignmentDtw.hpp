#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace runplay {

/// One compact alignment sample as consumed by the constrained-DTW cost model.
///
/// Only the four quantities that affect DTW cost cross the boundary. Route
/// points, distances, segment indexes, elapsed time, pace, and identifiers stay
/// Swift-owned and are re-read later through the returned matched indexes.
///
/// `has_heading` is exactly 0 or 1. When it is 0, `heading_radians` is unused
/// and the heading term contributes nothing, matching Swift's optional heading.
struct RouteAlignmentCostSample final {
    double x_meters{0};
    double z_meters{0};
    double normalized_progress{0};
    double heading_radians{0};
    std::uint8_t has_heading{0};
};

static_assert(std::is_standard_layout_v<RouteAlignmentCostSample>);
static_assert(std::is_trivially_copyable_v<RouteAlignmentCostSample>);
static_assert(std::is_nothrow_default_constructible_v<RouteAlignmentCostSample>);
static_assert(std::is_nothrow_copy_constructible_v<RouteAlignmentCostSample>);

/// The subset of `RouteAlignmentPolicy` that the path solver actually reads.
///
/// Quality thresholds, chart policy, geographic extent, sample-building policy,
/// the algorithm version, and cancellation all remain Swift concerns and are
/// deliberately absent.
///
/// Swift maps a negative `maximumConsecutiveWarpSteps` or `maximumBandCells` to
/// zero before crossing; zero band cells therefore yields `resource_limit` and
/// zero warp steps forbids every non-diagonal transition, preserving the Swift
/// comparisons exactly.
struct RouteAlignmentDtwPolicy final {
    double band_width_fraction{0};

    double maximum_unmatched_prefix_suffix_meters{0};
    double maximum_unmatched_prefix_suffix_fraction{0};

    double non_diagonal_step_penalty{0};
    std::uint64_t maximum_consecutive_warp_steps{0};

    double spatial_distance_cost_scale_meters{0};
    double maximum_spatial_cost{0};
    double heading_penalty_weight{0};
    double progress_penalty_weight{0};

    std::uint64_t maximum_band_cells{0};
};

static_assert(std::is_standard_layout_v<RouteAlignmentDtwPolicy>);
static_assert(std::is_trivially_copyable_v<RouteAlignmentDtwPolicy>);
static_assert(std::is_nothrow_default_constructible_v<RouteAlignmentDtwPolicy>);
static_assert(std::is_nothrow_copy_constructible_v<RouteAlignmentDtwPolicy>);

/// Transition that produced a path cell. Raw values match the Swift step kind.
enum class RouteAlignmentDtwStepKind : std::uint8_t {
    diagonal = 0,
    primary_only = 1,
    comparison_only = 2,
};

/// One matched sample pair on the reconstructed path, in forward order.
struct RouteAlignmentDtwPathCell final {
    std::uint64_t primary_index{0};
    std::uint64_t comparison_index{0};
    RouteAlignmentDtwStepKind step{
        RouteAlignmentDtwStepKind::diagonal
    };
};

static_assert(std::is_standard_layout_v<RouteAlignmentDtwPathCell>);
static_assert(std::is_trivially_copyable_v<RouteAlignmentDtwPathCell>);
static_assert(std::is_nothrow_default_constructible_v<RouteAlignmentDtwPathCell>);
static_assert(std::is_nothrow_copy_constructible_v<RouteAlignmentDtwPathCell>);

enum class RouteAlignmentDtwStatus : std::uint8_t {
    success,
    invalid_primary_buffer,
    invalid_comparison_buffer,
    invalid_output_buffer,
    insufficient_output_capacity,
    invalid_policy,
    invalid_input_contract,
    resource_limit,
    no_path,
    allocation_failure,
    internal_failure,
};

/// Deterministic report for one constrained-DTW path solve.
///
/// Input counts are always populated. Band information is populated once the
/// band radius and packed layout are known. Endpoint fields and `best_end_cost`
/// are meaningful only when `status` is `success`.
struct RouteAlignmentDtwSummary final {
    RouteAlignmentDtwStatus status{
        RouteAlignmentDtwStatus::success
    };

    std::uint64_t primary_sample_count{0};
    std::uint64_t comparison_sample_count{0};

    std::uint64_t band_radius{0};
    std::uint64_t band_cell_count{0};

    std::uint64_t required_path_count{0};
    std::uint64_t written_path_count{0};

    std::uint64_t best_end_primary_index{0};
    std::uint64_t best_end_comparison_index{0};
    double best_end_cost{0};
};

static_assert(std::is_standard_layout_v<RouteAlignmentDtwSummary>);
static_assert(std::is_trivially_copyable_v<RouteAlignmentDtwSummary>);
static_assert(std::is_nothrow_default_constructible_v<RouteAlignmentDtwSummary>);
static_assert(std::is_nothrow_copy_constructible_v<RouteAlignmentDtwSummary>);

/// Solves one Sakoe-Chiba band-constrained DTW path over two compact routes.
///
/// Performs band-radius calculation, unmatched-prefix/suffix expansion,
/// band-packed row layout, resource-budget validation, point-cost calculation,
/// open-beginning seeding, constrained warp transitions with exact
/// diagonal-before-primary-before-comparison tie-breaking, maximum consecutive
/// warp enforcement, open-suffix endpoint selection, and deterministic path
/// reconstruction. It performs no per-element call back into Swift.
///
/// A valid path never exceeds `primary_sample_count + comparison_sample_count
/// + 1` cells, so a caller that allocates that upper bound never observes
/// `insufficient_output_capacity`.
///
/// Buffer ownership: `primary_samples`, `comparison_samples`, and `output_path`
/// are caller-owned and borrowed only for the duration of the call. The engine
/// retains no pointer and performs no callback. On every non-success status the
/// output buffer is left completely unchanged and `written_path_count` is zero.
[[nodiscard]]
RouteAlignmentDtwSummary compute_constrained_dtw_path(
    const RouteAlignmentCostSample* primary_samples,
    std::size_t primary_sample_count,

    const RouteAlignmentCostSample* comparison_samples,
    std::size_t comparison_sample_count,

    double primary_route_distance_meters,
    double comparison_route_distance_meters,
    double effective_sample_interval_meters,

    RouteAlignmentDtwPolicy policy,

    RouteAlignmentDtwPathCell* output_path,
    std::size_t output_capacity
) noexcept;

}  // namespace runplay
