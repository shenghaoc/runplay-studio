#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

#include "RunPlayEngineCpp/RouteInterop.hpp"

namespace runplay {

/// Geometry thresholds used by route-quality stages 2–4.
///
/// Contains only values consumed by outlier detection, gap inference, segment
/// compaction, and distance normalization. Altitude, source-speed validation,
/// elevation, and cancellation remain Swift-owned and are intentionally
/// absent.
struct RouteQualityGeometryPolicy final {
    double maximum_plausible_running_speed_meters_per_second;
    double maximum_useful_horizontal_accuracy_meters;

    double coordinate_spike_minimum_excess_distance_meters;
    double coordinate_spike_minimum_distortion_ratio;
    double poor_accuracy_evidence_multiplier;

    double implicit_gap_minimum_distance_meters;
    double implicit_gap_minimum_time_interval_seconds;
    double implicit_gap_minimum_time_discontinuity_ratio;

    std::uint64_t relocated_cluster_confirmation_point_count;
    double relocated_cluster_maximum_step_meters;
};

static_assert(std::is_standard_layout_v<RouteQualityGeometryPolicy>);
static_assert(std::is_trivially_copyable_v<RouteQualityGeometryPolicy>);
static_assert(std::is_nothrow_copy_constructible_v<RouteQualityGeometryPolicy>);

/// Distance-source selection strategy for final normalized segments.
enum class RouteQualityDistancePolicy : std::uint8_t {
    compute_from_coordinates,
    use_supplied_when_all_valid,
    use_supplied_per_segment,
    use_supplied_for_selected_source_segments,
};

/// Per-segment distance source reported on retained samples.
enum class RouteSegmentDistanceSource : std::uint8_t {
    coordinate_derived,
    device_supplied,
};

/// Overall route distance source after policy selection.
enum class RouteQualityDistanceSource : std::uint8_t {
    coordinate_derived,
    device_supplied,
    mixed,
};

/// Outcome of one combined route-quality geometry call.
enum class RouteQualityPipelineStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_output_buffer,
    insufficient_output_capacity,
    invalid_selection_buffer,
    invalid_policy,
    invalid_input_contract,
    resource_limit,
};

/// One output entry per input sample. Index `i` corresponds to input index `i`.
///
/// Normalized segment, distance, and distance-source fields are meaningful
/// only when `retained == 1`. Boolean-like fields use only `0` or `1`.
struct RouteQualityOutputSample final {
    std::uint64_t source_index{0};

    std::int64_t normalized_segment_index{0};
    double normalized_distance_from_start_meters{0};

    RouteSegmentDistanceSource distance_source{
        RouteSegmentDistanceSource::coordinate_derived
    };

    std::uint8_t retained{0};
    std::uint8_t rejected_coordinate_outlier{0};
    std::uint8_t inferred_boundary{0};
};

static_assert(std::is_standard_layout_v<RouteQualityOutputSample>);
static_assert(std::is_trivially_copyable_v<RouteQualityOutputSample>);
static_assert(std::is_nothrow_default_constructible_v<RouteQualityOutputSample>);
static_assert(std::is_nothrow_copy_constructible_v<RouteQualityOutputSample>);

/// Compact pure-value evidence returned after one complete geometry pipeline.
struct RouteQualityPipelineSummary final {
    RouteQualityPipelineStatus status{
        RouteQualityPipelineStatus::success
    };

    std::uint64_t input_sample_count{0};
    std::uint64_t retained_sample_count{0};
    std::uint64_t discarded_coordinate_point_count{0};
    std::uint64_t inferred_route_gap_count{0};
    std::uint64_t normalized_segment_count{0};

    RouteQualityDistanceSource distance_source{
        RouteQualityDistanceSource::coordinate_derived
    };

    double total_distance_meters{0};
};

static_assert(std::is_standard_layout_v<RouteQualityPipelineSummary>);
static_assert(std::is_trivially_copyable_v<RouteQualityPipelineSummary>);
static_assert(std::is_nothrow_copy_constructible_v<RouteQualityPipelineSummary>);

/// Processes stages 2–4 of route quality for one complete ordered route.
///
/// `samples` and `supplied_selection_by_sample` are borrowed only for this
/// call and are never stored. `output_samples` is caller-owned mutable
/// storage; C++ writes exactly `sample_count` entries on success and writes
/// nothing on error. A null input or output pointer is valid only when
/// `sample_count` is zero. Selection may be null with zero count for every
/// policy except `use_supplied_for_selected_source_segments`.
[[nodiscard]]
RouteQualityPipelineSummary process_route_quality_geometry(
    const RouteInputSample* samples,
    std::size_t sample_count,
    RouteQualityGeometryPolicy policy,
    RouteQualityDistancePolicy distance_policy,
    const std::uint8_t* supplied_selection_by_sample,
    std::size_t supplied_selection_count,
    RouteQualityOutputSample* output_samples,
    std::size_t output_capacity
) noexcept;

}  // namespace runplay
