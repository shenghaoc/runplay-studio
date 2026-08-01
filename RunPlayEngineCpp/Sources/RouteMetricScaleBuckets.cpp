#include "RunPlayEngineCpp/RouteMetricScaleBuckets.hpp"

#include "RunPlayEngineCpp/RouteInterop.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace runplay {
namespace {

RouteMetricScaleBucketSummary failure(
    RouteMetricScaleBucketStatus status,
    std::size_t sample_count
) noexcept {
    RouteMetricScaleBucketSummary summary{};
    summary.status = status;
    if (sample_count <= std::numeric_limits<std::uint64_t>::max()) {
        summary.required_output_capacity = static_cast<std::uint64_t>(sample_count);
    }
    return summary;
}

bool eligible(const RouteMetricScaleBucketOutputSample& sample) noexcept {
    // During the scale sort this otherwise-result field is a validated
    // workspace marker. Avoiding repeated isfinite calls in O(n log n)
    // comparisons materially reduces small-profile overhead.
    return sample.has_normalized_value == 1U;
}

bool scale_order(
    const RouteMetricScaleBucketOutputSample& lhs,
    const RouteMetricScaleBucketOutputSample& rhs
) noexcept {
    const bool lhs_eligible = eligible(lhs);
    const bool rhs_eligible = eligible(rhs);
    if (lhs_eligible != rhs_eligible) return lhs_eligible;
    if (!lhs_eligible) return lhs.source_index < rhs.source_index;
    if (lhs.metric_value != rhs.metric_value) return lhs.metric_value < rhs.metric_value;
    if (lhs.weight_meters != rhs.weight_meters) return lhs.weight_meters < rhs.weight_meters;
    return lhs.source_index < rhs.source_index;
}

double quantile(
    const RouteMetricScaleBucketOutputSample* samples,
    std::size_t eligible_count,
    double requested,
    double maximum_weight
) noexcept {
    const double q = std::min(1.0, std::max(0.0, requested));
    double total = 0.0;
    for (std::size_t index = 0; index < eligible_count; ++index) {
        total += samples[index].weight_meters / maximum_weight;
    }
    const double target = q * total;
    double cumulative = 0.0;
    for (std::size_t index = 0; index < eligible_count; ++index) {
        cumulative += samples[index].weight_meters / maximum_weight;
        if (cumulative + 1e-12 >= target) return samples[index].metric_value;
    }
    return samples[eligible_count - 1U].metric_value;
}

double normalized_value(double value, double lower, double upper) noexcept {
    if (!std::isfinite(value)) return 0.5;
    const double span = upper - lower;
    if (!std::isfinite(span) || std::abs(span) <= 1e-12) return 0.5;
    const double low = std::min(lower, upper);
    const double high = std::max(lower, upper);
    const double clamped_value = std::min(high, std::max(low, value));
    const double normalized = (clamped_value - lower) / span;
    return std::min(1.0, std::max(0.0, normalized));
}

std::int32_t bucket_index(double normalized, std::int32_t requested_count) noexcept {
    const std::int32_t count = std::max<std::int32_t>(2, requested_count);
    const double clamped = std::min(1.0, std::max(0.0, normalized));
    if (clamped >= 1.0) return count - 1;
    const double scaled = clamped * static_cast<double>(count);
    const auto truncated = static_cast<std::int32_t>(scaled);
    return std::min<std::int32_t>(count - 1, truncated);
}

}  // namespace

RouteMetricScaleBucketSummary assign_route_metric_scale_buckets(
    const RouteMetricScaleBucketInputSample* samples,
    std::size_t sample_count,
    RouteMetricScaleBucketPolicy policy,
    RouteMetricScaleBucketOutputSample* output_samples,
    std::size_t output_capacity
) noexcept {
    if (sample_count == 0U) return RouteMetricScaleBucketSummary{};
    if (sample_count > std::numeric_limits<std::uint64_t>::max()) {
        return failure(RouteMetricScaleBucketStatus::resource_limit, 0U);
    }
    if (samples == nullptr) {
        return failure(RouteMetricScaleBucketStatus::invalid_input_buffer, sample_count);
    }
    if (output_samples == nullptr) {
        return failure(RouteMetricScaleBucketStatus::invalid_output_buffer, sample_count);
    }
    if (output_capacity < sample_count) {
        return failure(RouteMetricScaleBucketStatus::insufficient_output_capacity, sample_count);
    }
    if (sample_count > max_route_input_samples) {
        return failure(RouteMetricScaleBucketStatus::resource_limit, sample_count);
    }

    std::uint64_t valid_count = 0;
    double valid_coverage = 0.0;
    for (std::size_t index = 0; index < sample_count; ++index) {
        const auto& sample = samples[index];
        if (sample.has_metric_value > 1U
            || !std::isfinite(sample.weight_meters)
            || sample.weight_meters < 0.0) {
            return failure(RouteMetricScaleBucketStatus::invalid_input_contract, sample_count);
        }
        if (sample.has_metric_value == 1U
            && std::isfinite(sample.metric_value)
            && sample.weight_meters > 0.0) {
            ++valid_count;
            valid_coverage += sample.weight_meters;
        }
    }

    // No failure is possible below this point. The caller-owned result buffer
    // is now also the native route-sized sorting workspace.
    for (std::size_t index = 0; index < sample_count; ++index) {
        output_samples[index].source_index = static_cast<std::uint64_t>(index);
        output_samples[index].metric_value = samples[index].metric_value;
        output_samples[index].weight_meters = samples[index].weight_meters;
        output_samples[index].normalized_value = 0.0;
        output_samples[index].bucket_index = -1;
        output_samples[index].has_metric_value = samples[index].has_metric_value;
        output_samples[index].has_normalized_value =
            samples[index].has_metric_value == 1U
                && std::isfinite(samples[index].metric_value)
                && samples[index].weight_meters > 0.0
            ? 1U
            : 0U;
    }

    std::sort(output_samples, output_samples + sample_count, scale_order);

    const std::size_t eligible_count = static_cast<std::size_t>(valid_count);
    bool has_scale = false;
    double lower = 0.0;
    double median = 0.0;
    double upper = 0.0;
    if (valid_count >= policy.minimum_valid_interval_count
        && eligible_count > 0U
        && std::isfinite(policy.lower_quantile)
        && std::isfinite(policy.upper_quantile)) {
        double maximum_weight = 0.0;
        for (std::size_t index = 0; index < eligible_count; ++index) {
            maximum_weight = std::max(maximum_weight, output_samples[index].weight_meters);
        }
        lower = quantile(output_samples, eligible_count, policy.lower_quantile, maximum_weight);
        median = quantile(output_samples, eligible_count, 0.5, maximum_weight);
        upper = quantile(output_samples, eligible_count, policy.upper_quantile, maximum_weight);
        has_scale = std::abs(upper - lower) + 1e-12
            >= std::max(0.0, policy.minimum_scale_span);
    }

    std::sort(
        output_samples,
        output_samples + sample_count,
        [](const auto& lhs, const auto& rhs) noexcept {
            return lhs.source_index < rhs.source_index;
        }
    );

    std::uint64_t no_data_count = 0;
    if (has_scale) {
        for (std::size_t index = 0; index < sample_count; ++index) {
            auto& output = output_samples[index];
            if (output.has_metric_value == 0U) {
                output.has_normalized_value = 0U;
                ++no_data_count;
                continue;
            }
            const double normalized = normalized_value(output.metric_value, lower, upper);
            output.normalized_value = normalized;
            output.bucket_index = bucket_index(normalized, policy.bucket_count);
            output.has_normalized_value = 1U;
        }
    } else {
        no_data_count = static_cast<std::uint64_t>(sample_count);
        for (std::size_t index = 0; index < sample_count; ++index) {
            output_samples[index].has_normalized_value = 0U;
        }
    }

    RouteMetricScaleBucketSummary summary{};
    summary.sample_count = static_cast<std::uint64_t>(sample_count);
    summary.valid_interval_count = valid_count;
    summary.no_data_interval_count = no_data_count;
    summary.required_output_capacity = static_cast<std::uint64_t>(sample_count);
    summary.valid_coverage_distance_meters = valid_coverage;
    summary.lower_bound = has_scale ? lower : 0.0;
    summary.median = has_scale ? median : 0.0;
    summary.upper_bound = has_scale ? upper : 0.0;
    summary.has_scale = has_scale ? 1U : 0U;
    return summary;
}

}  // namespace runplay
