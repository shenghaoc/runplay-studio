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

/// Dense eligible workspace packed into the caller-owned output buffer.
/// Smaller records keep the single sort cheaper than reordering full
/// `RouteMetricScaleBucketOutputSample` values.
struct EligibleRecord final {
    double metric_value{0};
    double weight_meters{0};
    std::uint64_t source_index{0};
};

static_assert(sizeof(EligibleRecord) <= sizeof(RouteMetricScaleBucketOutputSample));
static_assert(alignof(EligibleRecord) <= alignof(RouteMetricScaleBucketOutputSample));

bool eligible_scale_order(
    const EligibleRecord& lhs,
    const EligibleRecord& rhs
) noexcept {
    if (lhs.metric_value != rhs.metric_value) return lhs.metric_value < rhs.metric_value;
    if (lhs.weight_meters != rhs.weight_meters) return lhs.weight_meters < rhs.weight_meters;
    return lhs.source_index < rhs.source_index;
}

double quantile(
    const EligibleRecord* samples,
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

/// Preserve Swift `bucketIndex` semantics across the full `Int64` domain.
///
/// Avoid undefined floating-to-integer conversion near `Int64::max` by
/// clamping the scaled value before the cast when it meets or exceeds
/// `count - 1` as a double.
std::int64_t bucket_index(double normalized, std::int64_t requested_count) noexcept {
    const std::int64_t count = std::max<std::int64_t>(2, requested_count);
    const double clamped = std::min(1.0, std::max(0.0, normalized));

    if (clamped >= 1.0) {
        return count - 1;
    }

    const double scaled = clamped * static_cast<double>(count);

    if (!(scaled > 0.0)) {
        return 0;
    }

    const double final_bucket_as_double = static_cast<double>(count - 1);

    if (!std::isfinite(scaled) || scaled >= final_bucket_as_double) {
        return count - 1;
    }

    return std::min<std::int64_t>(
        count - 1,
        static_cast<std::int64_t>(scaled)
    );
}

bool is_quantile_eligible(
    std::uint8_t has_metric_value,
    double metric_value,
    double weight_meters
) noexcept {
    return has_metric_value == 1U
        && std::isfinite(metric_value)
        && std::isfinite(weight_meters)
        && weight_meters > 0.0;
}

bool is_valid_interval(
    std::uint8_t has_metric_value,
    double metric_value,
    double weight_meters
) noexcept {
    // Valid intervals may carry a positive-infinite weight; those still count
    // toward valid coverage and the minimum-valid-interval gate, but not
    // toward weighted quantiles.
    return has_metric_value == 1U
        && std::isfinite(metric_value)
        && weight_meters > 0.0;
}

void write_no_scale_output(
    const RouteMetricScaleBucketInputSample* samples,
    std::size_t sample_count,
    RouteMetricScaleBucketOutputSample* output_samples
) noexcept {
    for (std::size_t index = 0; index < sample_count; ++index) {
        output_samples[index].source_index = static_cast<std::uint64_t>(index);
        output_samples[index].metric_value = samples[index].metric_value;
        output_samples[index].weight_meters = samples[index].weight_meters;
        output_samples[index].normalized_value = 0.0;
        output_samples[index].bucket_index = -1;
        output_samples[index].has_metric_value = samples[index].has_metric_value;
        output_samples[index].has_normalized_value = 0U;
    }
}

RouteMetricScaleBucketSummary success_summary(
    std::size_t sample_count,
    std::uint64_t valid_count,
    std::uint64_t no_data_count,
    double valid_coverage,
    bool has_scale,
    double lower,
    double median,
    double upper
) noexcept {
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

    // Read-only validation pass. Also accumulates the counts that decide
    // whether a scale can possibly exist, so guaranteed no-scale inputs skip
    // both subsequent sorts.
    std::uint64_t valid_count = 0;
    std::size_t eligible_count = 0;
    double valid_coverage = 0.0;
    for (std::size_t index = 0; index < sample_count; ++index) {
        const auto& sample = samples[index];
        // Accept finite nonnegative weights, positive infinity, and negative
        // zero. Reject NaN and any negative weight (including -infinity).
        if (sample.has_metric_value > 1U
            || std::isnan(sample.weight_meters)
            || sample.weight_meters < 0.0) {
            return failure(RouteMetricScaleBucketStatus::invalid_input_contract, sample_count);
        }
        if (is_valid_interval(
                sample.has_metric_value,
                sample.metric_value,
                sample.weight_meters
            )) {
            ++valid_count;
            valid_coverage += sample.weight_meters;
            if (std::isfinite(sample.weight_meters)) {
                ++eligible_count;
            }
        }
    }

    // A scale is known to be impossible before any sorting when any of these
    // holds. NaN / negative-infinite minimum_scale_span must continue through
    // the general path so they follow Swift `max(0, minimumScaleSpan)`.
    const bool scale_known_impossible =
        valid_count < policy.minimum_valid_interval_count
        || eligible_count == 0U
        || !std::isfinite(policy.lower_quantile)
        || !std::isfinite(policy.upper_quantile)
        || policy.minimum_scale_span == std::numeric_limits<double>::infinity();

    // No failure is possible below this point. Only now may the caller-owned
    // result buffer become a native workspace.
    if (scale_known_impossible) {
        write_no_scale_output(samples, sample_count, output_samples);
        return success_summary(
            sample_count,
            valid_count,
            static_cast<std::uint64_t>(sample_count),
            valid_coverage,
            false,
            0.0,
            0.0,
            0.0
        );
    }

    // Compact quantile-eligible samples into a dense EligibleRecord prefix
    // overlaid on the output buffer, sort that prefix only, then rewrite the
    // full output in source order from input (no second full-buffer sort).
    auto* eligible_records = reinterpret_cast<EligibleRecord*>(
        static_cast<void*>(output_samples)
    );
    std::size_t write = 0;
    for (std::size_t index = 0; index < sample_count; ++index) {
        if (!is_quantile_eligible(
                samples[index].has_metric_value,
                samples[index].metric_value,
                samples[index].weight_meters
            )) {
            continue;
        }
        eligible_records[write].metric_value = samples[index].metric_value;
        eligible_records[write].weight_meters = samples[index].weight_meters;
        eligible_records[write].source_index = static_cast<std::uint64_t>(index);
        ++write;
    }
    std::sort(
        eligible_records,
        eligible_records + write,
        eligible_scale_order
    );
    eligible_count = write;

    double maximum_weight = 0.0;
    for (std::size_t index = 0; index < eligible_count; ++index) {
        maximum_weight = std::max(maximum_weight, eligible_records[index].weight_meters);
    }
    const double lower =
        quantile(eligible_records, eligible_count, policy.lower_quantile, maximum_weight);
    const double median =
        quantile(eligible_records, eligible_count, 0.5, maximum_weight);
    const double upper =
        quantile(eligible_records, eligible_count, policy.upper_quantile, maximum_weight);
    // Match Swift `max(0, minimumScaleSpan)` including NaN → 0 via the false
    // comparison against the left operand.
    const bool has_scale = std::abs(upper - lower) + 1e-12
        >= std::max(0.0, policy.minimum_scale_span);

    // Rewrite the full output buffer in original source order from input.
    std::uint64_t no_data_count = 0;
    if (has_scale) {
        for (std::size_t index = 0; index < sample_count; ++index) {
            auto& output = output_samples[index];
            output.source_index = static_cast<std::uint64_t>(index);
            output.metric_value = samples[index].metric_value;
            output.weight_meters = samples[index].weight_meters;
            output.has_metric_value = samples[index].has_metric_value;
            if (samples[index].has_metric_value == 0U) {
                output.normalized_value = 0.0;
                output.bucket_index = -1;
                output.has_normalized_value = 0U;
                ++no_data_count;
                continue;
            }
            const double normalized =
                normalized_value(samples[index].metric_value, lower, upper);
            output.normalized_value = normalized;
            output.bucket_index = bucket_index(normalized, policy.bucket_count);
            output.has_normalized_value = 1U;
        }
    } else {
        write_no_scale_output(samples, sample_count, output_samples);
        no_data_count = static_cast<std::uint64_t>(sample_count);
    }

    return success_summary(
        sample_count,
        valid_count,
        no_data_count,
        valid_coverage,
        has_scale,
        lower,
        median,
        upper
    );
}

}  // namespace runplay
