#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace runplay {

struct RouteMetricScaleBucketInputSample final {
    double metric_value{0};
    double weight_meters{0};
    std::uint8_t has_metric_value{0};
};

static_assert(std::is_standard_layout_v<RouteMetricScaleBucketInputSample>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketInputSample>);
static_assert(std::is_nothrow_default_constructible_v<RouteMetricScaleBucketInputSample>);
static_assert(std::is_nothrow_copy_constructible_v<RouteMetricScaleBucketInputSample>);
static_assert(std::is_nothrow_copy_assignable_v<RouteMetricScaleBucketInputSample>);

/// Caller-owned dense workspace for quantile-eligible (metric, weight) pairs.
///
/// Swift allocates and owns this buffer. C++ may compact eligible samples into
/// the leading prefix and sort that prefix. Guaranteed no-scale paths need not
/// touch the workspace. Capacity must be at least `sample_count`.
struct RouteMetricScaleBucketWorkspaceSample final {
    double metric_value{0};
    double weight_meters{0};
};

static_assert(sizeof(RouteMetricScaleBucketWorkspaceSample) == 16);
static_assert(std::is_standard_layout_v<RouteMetricScaleBucketWorkspaceSample>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketWorkspaceSample>);
static_assert(std::is_nothrow_default_constructible_v<RouteMetricScaleBucketWorkspaceSample>);
static_assert(std::is_nothrow_copy_constructible_v<RouteMetricScaleBucketWorkspaceSample>);
static_assert(std::is_nothrow_copy_assignable_v<RouteMetricScaleBucketWorkspaceSample>);

struct RouteMetricScaleBucketPolicy final {
    double lower_quantile{0};
    double upper_quantile{0};
    double minimum_scale_span{0};
    std::uint64_t minimum_valid_interval_count{0};
    /// Supported Swift `Int` domain on all targets (full 64-bit signed range).
    std::int64_t bucket_count{0};
};

static_assert(std::is_standard_layout_v<RouteMetricScaleBucketPolicy>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketPolicy>);
static_assert(std::is_nothrow_default_constructible_v<RouteMetricScaleBucketPolicy>);
static_assert(std::is_nothrow_copy_constructible_v<RouteMetricScaleBucketPolicy>);
static_assert(std::is_nothrow_copy_assignable_v<RouteMetricScaleBucketPolicy>);

struct RouteMetricScaleBucketOutputSample final {
    std::uint64_t source_index{0};
    double metric_value{0};
    double weight_meters{0};
    double normalized_value{0};
    /// `-1` = no data; otherwise `0...(bucket_count - 1)`.
    std::int64_t bucket_index{-1};
    std::uint8_t has_metric_value{0};
    std::uint8_t has_normalized_value{0};
};

static_assert(std::is_standard_layout_v<RouteMetricScaleBucketOutputSample>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketOutputSample>);
static_assert(std::is_nothrow_default_constructible_v<RouteMetricScaleBucketOutputSample>);
static_assert(std::is_nothrow_copy_constructible_v<RouteMetricScaleBucketOutputSample>);
static_assert(std::is_nothrow_copy_assignable_v<RouteMetricScaleBucketOutputSample>);

enum class RouteMetricScaleBucketStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_output_buffer,
    invalid_workspace_buffer,
    insufficient_output_capacity,
    insufficient_workspace_capacity,
    invalid_policy,
    invalid_input_contract,
    resource_limit,
    internal_failure,
};

struct RouteMetricScaleBucketSummary final {
    RouteMetricScaleBucketStatus status{RouteMetricScaleBucketStatus::success};
    std::uint64_t sample_count{0};
    std::uint64_t valid_interval_count{0};
    std::uint64_t no_data_interval_count{0};
    std::uint64_t required_output_capacity{0};
    double valid_coverage_distance_meters{0};
    double lower_bound{0};
    double median{0};
    double upper_bound{0};
    std::uint8_t has_scale{0};
};

static_assert(std::is_standard_layout_v<RouteMetricScaleBucketSummary>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketSummary>);
static_assert(std::is_nothrow_default_constructible_v<RouteMetricScaleBucketSummary>);
static_assert(std::is_nothrow_copy_constructible_v<RouteMetricScaleBucketSummary>);
static_assert(std::is_nothrow_copy_assignable_v<RouteMetricScaleBucketSummary>);

/// Assign a deterministic numeric scale and bucket to one metric profile.
///
/// All buffers are Swift-owned and borrowed synchronously. C++ retains no
/// pointer and performs no callback. The workspace is a typed eligible-only
/// sort buffer — never an alias over the output buffer. Every error leaves
/// the output buffer byte-for-byte unchanged. No route-sized native heap
/// allocation occurs.
///
/// When a scale is known to be impossible after the read-only validation pass,
/// the kernel initializes the output in source order, leaves the workspace
/// untouched, and performs no sort. Otherwise it compacts quantile-eligible
/// records into the workspace prefix, sorts that prefix only, then writes
/// results into the output buffer in source order.
[[nodiscard]]
RouteMetricScaleBucketSummary assign_route_metric_scale_buckets(
    const RouteMetricScaleBucketInputSample* samples,
    std::size_t sample_count,
    RouteMetricScaleBucketPolicy policy,
    RouteMetricScaleBucketWorkspaceSample* workspace_samples,
    std::size_t workspace_capacity,
    RouteMetricScaleBucketOutputSample* output_samples,
    std::size_t output_capacity
) noexcept;

}  // namespace runplay
