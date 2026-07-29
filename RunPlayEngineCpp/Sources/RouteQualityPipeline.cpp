#include "RunPlayEngineCpp/RouteQualityPipeline.hpp"

#include "Internal/RouteGeometryInternal.hpp"
#include "RunPlayEngineCpp/Geodesy.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>

namespace runplay {
namespace {

[[nodiscard]]
RouteQualityPipelineSummary empty_summary(
    RouteQualityPipelineStatus status
) noexcept {
    return RouteQualityPipelineSummary{
        /*.status=*/status,
        /*.input_sample_count=*/0u,
        /*.retained_sample_count=*/0u,
        /*.discarded_coordinate_point_count=*/0u,
        /*.inferred_route_gap_count=*/0u,
        /*.normalized_segment_count=*/0u,
        /*.distance_source=*/RouteQualityDistanceSource::coordinate_derived,
        /*.total_distance_meters=*/0.0,
    };
}

[[nodiscard]]
bool policy_is_valid(const RouteQualityGeometryPolicy& policy) noexcept {
    const double doubles[] = {
        policy.maximum_plausible_running_speed_meters_per_second,
        policy.maximum_useful_horizontal_accuracy_meters,
        policy.coordinate_spike_minimum_excess_distance_meters,
        policy.coordinate_spike_minimum_distortion_ratio,
        policy.poor_accuracy_evidence_multiplier,
        policy.implicit_gap_minimum_distance_meters,
        policy.implicit_gap_minimum_time_interval_seconds,
        policy.implicit_gap_minimum_time_discontinuity_ratio,
        policy.relocated_cluster_maximum_step_meters,
    };
    for (double value : doubles) {
        if (!std::isfinite(value)) {
            return false;
        }
    }
    if (policy.maximum_plausible_running_speed_meters_per_second < 0.0
        || policy.maximum_useful_horizontal_accuracy_meters < 0.0
        || policy.coordinate_spike_minimum_excess_distance_meters < 0.0
        || policy.implicit_gap_minimum_distance_meters < 0.0
        || policy.implicit_gap_minimum_time_interval_seconds < 0.0
        || policy.relocated_cluster_maximum_step_meters < 0.0) {
        return false;
    }
    if (policy.coordinate_spike_minimum_distortion_ratio < 1.0
        || policy.implicit_gap_minimum_time_discontinuity_ratio < 1.0) {
        return false;
    }
    if (policy.poor_accuracy_evidence_multiplier < 0.0
        || policy.poor_accuracy_evidence_multiplier > 1.0) {
        return false;
    }
    if (policy.relocated_cluster_confirmation_point_count < 2u) {
        return false;
    }
    // Confirmation window is scanned with size_t indexes; reject values that
    // cannot convert safely into a local size for bounds arithmetic.
    if (policy.relocated_cluster_confirmation_point_count
        > static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max())) {
        return false;
    }
    return true;
}

[[nodiscard]]
bool distance_policy_is_known(RouteQualityDistancePolicy policy) noexcept {
    switch (policy) {
        case RouteQualityDistancePolicy::compute_from_coordinates:
        case RouteQualityDistancePolicy::use_supplied_when_all_valid:
        case RouteQualityDistancePolicy::use_supplied_per_segment:
        case RouteQualityDistancePolicy::use_supplied_for_selected_source_segments:
            return true;
    }
    return false;
}

[[nodiscard]]
bool selection_requires_buffer(RouteQualityDistancePolicy policy) noexcept {
    return policy
        == RouteQualityDistancePolicy::use_supplied_for_selected_source_segments;
}

[[nodiscard]]
bool optional_accuracy_ok(const RouteOptionalDouble& accuracy) noexcept {
    if (!accuracy.has_value()) {
        return true;
    }
    const double value = *accuracy;
    return std::isfinite(value) && value >= 0.0;
}

[[nodiscard]]
bool validate_input_contract(
    std::span<const RouteInputSample> samples
) noexcept {
    if (samples.empty()) {
        return true;
    }

    std::int64_t expected_segment = 0;
    double previous_elapsed = -std::numeric_limits<double>::infinity();
    std::int64_t previous_segment = -1;

    for (std::size_t index = 0u; index < samples.size(); ++index) {
        const RouteInputSample& sample = samples[index];
        if (!is_valid_coordinate(sample.latitude, sample.longitude)) {
            return false;
        }
        if (!std::isfinite(sample.timestamp_seconds_since_reference_date)) {
            return false;
        }
        if (!std::isfinite(sample.elapsed_seconds)
            || sample.elapsed_seconds < 0.0
            || sample.elapsed_seconds < previous_elapsed) {
            return false;
        }
        previous_elapsed = sample.elapsed_seconds;

        if (sample.route_segment_index < 0) {
            return false;
        }
        if (index == 0u) {
            if (sample.route_segment_index != 0) {
                return false;
            }
            previous_segment = 0;
            expected_segment = 0;
            continue;
        }
        if (sample.route_segment_index < previous_segment) {
            return false;
        }
        if (sample.route_segment_index > previous_segment) {
            if (sample.route_segment_index != previous_segment + 1) {
                return false;
            }
            expected_segment = sample.route_segment_index;
        } else if (sample.route_segment_index != expected_segment) {
            return false;
        }
        previous_segment = sample.route_segment_index;

        if (!optional_accuracy_ok(sample.horizontal_accuracy)) {
            return false;
        }
    }
    return true;
}

[[nodiscard]]
bool validate_selection_buffer(
    std::span<const RouteInputSample> samples,
    const std::uint8_t* selection,
    std::size_t selection_count,
    RouteQualityDistancePolicy distance_policy
) noexcept {
    if (!selection_requires_buffer(distance_policy)) {
        return selection == nullptr && selection_count == 0u;
    }
    if (samples.empty()) {
        return selection == nullptr && selection_count == 0u;
    }
    if (selection == nullptr || selection_count != samples.size()) {
        return false;
    }

    std::int64_t current_segment = samples[0].route_segment_index;
    std::uint8_t current_value = selection[0];
    if (current_value != 0u && current_value != 1u) {
        return false;
    }

    for (std::size_t index = 0u; index < samples.size(); ++index) {
        const std::uint8_t value = selection[index];
        if (value != 0u && value != 1u) {
            return false;
        }
        if (samples[index].route_segment_index != current_segment) {
            current_segment = samples[index].route_segment_index;
            current_value = value;
            continue;
        }
        if (value != current_value) {
            return false;
        }
    }
    return true;
}

[[nodiscard]]
double timestamp_interval_seconds(
    const RouteInputSample& first,
    const RouteInputSample& second
) noexcept {
    return second.timestamp_seconds_since_reference_date
        - first.timestamp_seconds_since_reference_date;
}

[[nodiscard]]
bool implied_speed(
    const RouteInputSample& first,
    const RouteInputSample& second,
    double& speed_out
) noexcept {
    const double interval = timestamp_interval_seconds(first, second);
    if (!std::isfinite(interval) || interval <= 0.0) {
        return false;
    }
    const double metres = internal::pairwise_haversine_meters(first, second);
    if (!std::isfinite(metres) || metres < 0.0) {
        return false;
    }
    speed_out = metres / interval;
    return true;
}

[[nodiscard]]
bool poor_accuracy_supports_rejection(
    const RouteInputSample& previous,
    const RouteInputSample& candidate,
    const RouteInputSample& next,
    const RouteQualityGeometryPolicy& policy
) noexcept {
    if (!candidate.horizontal_accuracy.has_value()) {
        return false;
    }
    const double candidate_accuracy = *candidate.horizontal_accuracy;
    if (!(candidate_accuracy > policy.maximum_useful_horizontal_accuracy_meters)) {
        return false;
    }

    bool any_neighbour = false;
    if (previous.horizontal_accuracy.has_value()) {
        any_neighbour = true;
        const double accuracy = *previous.horizontal_accuracy;
        if (!(accuracy <= policy.maximum_useful_horizontal_accuracy_meters)
            || !(accuracy < candidate_accuracy)) {
            return false;
        }
    }
    if (next.horizontal_accuracy.has_value()) {
        any_neighbour = true;
        const double accuracy = *next.horizontal_accuracy;
        if (!(accuracy <= policy.maximum_useful_horizontal_accuracy_meters)
            || !(accuracy < candidate_accuracy)) {
            return false;
        }
    }
    return any_neighbour;
}

void mark_outlier_candidates(
    std::span<const RouteInputSample> samples,
    std::span<RouteQualityOutputSample> output,
    const RouteQualityGeometryPolicy& policy
) noexcept {
    if (samples.size() < 3u) {
        return;
    }

    for (std::size_t index = 1u; index + 1u < samples.size(); ++index) {
        const RouteInputSample& previous = samples[index - 1u];
        const RouteInputSample& candidate = samples[index];
        const RouteInputSample& next = samples[index + 1u];

        if (previous.route_segment_index != candidate.route_segment_index
            || candidate.route_segment_index != next.route_segment_index) {
            continue;
        }

        double inbound_speed = 0.0;
        double outbound_speed = 0.0;
        double bridge_speed = 0.0;
        if (!implied_speed(previous, candidate, inbound_speed)
            || !implied_speed(candidate, next, outbound_speed)
            || !implied_speed(previous, next, bridge_speed)) {
            continue;
        }
        if (!(inbound_speed > policy.maximum_plausible_running_speed_meters_per_second)
            || !(outbound_speed
                > policy.maximum_plausible_running_speed_meters_per_second)
            || !(bridge_speed
                <= policy.maximum_plausible_running_speed_meters_per_second)) {
            continue;
        }

        const double inbound_distance =
            internal::pairwise_haversine_meters(previous, candidate);
        const double outbound_distance =
            internal::pairwise_haversine_meters(candidate, next);
        const double bridge_distance =
            internal::pairwise_haversine_meters(previous, next);
        const double path_distance = inbound_distance + outbound_distance;
        const double distortion_ratio = path_distance / std::max(1.0, bridge_distance);
        const bool accuracy_supports = poor_accuracy_supports_rejection(
            previous,
            candidate,
            next,
            policy);
        const double required_excess =
            policy.coordinate_spike_minimum_excess_distance_meters
            * (accuracy_supports ? policy.poor_accuracy_evidence_multiplier : 1.0);

        if ((path_distance - bridge_distance) >= required_excess
            && distortion_ratio >= policy.coordinate_spike_minimum_distortion_ratio) {
            // Temporarily mark candidates; adjacent conservatism finalizes
            // retained / rejected flags next.
            output[index].rejected_coordinate_outlier = 1u;
        }
    }

    for (std::size_t index = 1u; index + 1u < samples.size(); ++index) {
        if (output[index].rejected_coordinate_outlier == 0u) {
            continue;
        }
        const bool adjacent_candidate =
            output[index - 1u].rejected_coordinate_outlier != 0u
            || output[index + 1u].rejected_coordinate_outlier != 0u;
        if (adjacent_candidate) {
            // Ambiguous adjacent run: keep the point.
            output[index].rejected_coordinate_outlier = 0u;
            continue;
        }
        output[index].retained = 0u;
    }
}

[[nodiscard]]
std::size_t confirmation_window_end(
    std::span<const RouteQualityOutputSample> output,
    std::size_t start_retained_index,
    std::uint64_t confirmation_count
) noexcept {
    std::size_t seen = 0u;
    for (std::size_t index = start_retained_index; index < output.size(); ++index) {
        if (output[index].retained == 0u) {
            continue;
        }
        ++seen;
        if (seen == confirmation_count) {
            return index + 1u;
        }
    }
    return output.size() + 1u;  // sentinel: insufficient retained points
}

[[nodiscard]]
bool confirms_time_discontinuity(
    double interval,
    std::span<const RouteInputSample> samples,
    std::span<const RouteQualityOutputSample> output,
    std::size_t start_retained_index,
    const RouteQualityGeometryPolicy& policy
) noexcept {
    if (!std::isfinite(interval) || interval <= 0.0) {
        return false;
    }
    const std::size_t end = confirmation_window_end(
        output,
        start_retained_index,
        policy.relocated_cluster_confirmation_point_count);
    if (end > output.size()) {
        return false;
    }

    double longest_confirmation_interval = 0.0;
    std::size_t previous_retained = start_retained_index;
    for (std::size_t index = start_retained_index + 1u; index < end; ++index) {
        if (output[index].retained == 0u) {
            continue;
        }
        const double candidate = timestamp_interval_seconds(
            samples[previous_retained],
            samples[index]);
        if (!std::isfinite(candidate) || candidate <= 0.0) {
            return false;
        }
        longest_confirmation_interval =
            std::max(longest_confirmation_interval, candidate);
        previous_retained = index;
    }
    if (!(longest_confirmation_interval > 0.0)) {
        return false;
    }
    return (interval / longest_confirmation_interval)
        >= policy.implicit_gap_minimum_time_discontinuity_ratio;
}

[[nodiscard]]
bool confirms_relocated_cluster(
    std::span<const RouteInputSample> samples,
    std::span<const RouteQualityOutputSample> output,
    std::size_t start_retained_index,
    const RouteQualityGeometryPolicy& policy
) noexcept {
    const std::size_t end = confirmation_window_end(
        output,
        start_retained_index,
        policy.relocated_cluster_confirmation_point_count);
    if (end > output.size()) {
        return false;
    }

    const std::int64_t segment = samples[start_retained_index].route_segment_index;
    std::size_t retained_in_window = 0u;
    for (std::size_t index = start_retained_index; index < end; ++index) {
        if (output[index].retained == 0u) {
            continue;
        }
        ++retained_in_window;
        if (samples[index].route_segment_index != segment) {
            return false;
        }
    }
    if (retained_in_window < 2u) {
        return false;
    }

    std::size_t previous_retained = start_retained_index;
    for (std::size_t index = start_retained_index + 1u; index < end; ++index) {
        if (output[index].retained == 0u) {
            continue;
        }
        const RouteInputSample& previous = samples[previous_retained];
        const RouteInputSample& current = samples[index];
        const double step = internal::pairwise_haversine_meters(previous, current);
        const double interval = timestamp_interval_seconds(previous, current);
        if (std::isfinite(interval) && interval > 0.0) {
            if (!(step / interval
                    <= policy.maximum_plausible_running_speed_meters_per_second)) {
                return false;
            }
        } else if (step > policy.relocated_cluster_maximum_step_meters) {
            return false;
        }
        previous_retained = index;
    }
    return true;
}

void infer_gap_boundaries(
    std::span<const RouteInputSample> samples,
    std::span<RouteQualityOutputSample> output,
    const RouteQualityGeometryPolicy& policy,
    std::uint64_t& inferred_gap_count
) noexcept {
    inferred_gap_count = 0u;
    std::size_t retained_count = 0u;
    for (const RouteQualityOutputSample& sample : output) {
        if (sample.retained != 0u) {
            ++retained_count;
        }
    }
    if (retained_count
        < policy.relocated_cluster_confirmation_point_count + 1u) {
        return;
    }

    std::size_t previous_retained = samples.size();
    for (std::size_t index = 0u; index < samples.size(); ++index) {
        if (output[index].retained == 0u) {
            continue;
        }
        if (previous_retained >= samples.size()) {
            previous_retained = index;
            continue;
        }

        const RouteInputSample& previous = samples[previous_retained];
        const RouteInputSample& current = samples[index];
        if (previous.route_segment_index != current.route_segment_index) {
            previous_retained = index;
            continue;
        }

        const double jump =
            internal::pairwise_haversine_meters(previous, current);
        if (!(jump >= policy.implicit_gap_minimum_distance_meters)) {
            previous_retained = index;
            continue;
        }

        const double interval = timestamp_interval_seconds(previous, current);
        const bool is_implausibly_fast = std::isfinite(interval) && interval > 0.0
            && (jump / interval)
                > policy.maximum_plausible_running_speed_meters_per_second;
        const bool has_long_discontinuity = std::isfinite(interval)
            && interval >= policy.implicit_gap_minimum_time_interval_seconds
            && confirms_time_discontinuity(
                interval,
                samples,
                output,
                index,
                policy);
        if ((is_implausibly_fast || has_long_discontinuity)
            && confirms_relocated_cluster(samples, output, index, policy)) {
            output[index].inferred_boundary = 1u;
            ++inferred_gap_count;
        }
        previous_retained = index;
    }
}

void compact_segments(
    std::span<const RouteInputSample> samples,
    std::span<RouteQualityOutputSample> output,
    std::uint64_t& normalized_segment_count
) noexcept {
    normalized_segment_count = 0u;
    std::int64_t output_segment = -1;
    std::int64_t source_segment = std::numeric_limits<std::int64_t>::min();

    for (std::size_t index = 0u; index < samples.size(); ++index) {
        if (output[index].retained == 0u) {
            output[index].normalized_segment_index = 0;
            continue;
        }
        const bool new_segment =
            samples[index].route_segment_index != source_segment
            || output[index].inferred_boundary != 0u;
        if (new_segment) {
            ++output_segment;
            source_segment = samples[index].route_segment_index;
        }
        output[index].normalized_segment_index = output_segment;
    }
    if (output_segment >= 0) {
        normalized_segment_count = static_cast<std::uint64_t>(output_segment + 1);
    }
}

[[nodiscard]]
bool supplied_distance_series_is_valid(
    std::span<const RouteInputSample> samples,
    std::span<const RouteQualityOutputSample> output,
    std::int64_t segment_index
) noexcept {
    double previous = -std::numeric_limits<double>::infinity();
    bool any = false;
    for (std::size_t index = 0u; index < samples.size(); ++index) {
        if (output[index].retained == 0u) {
            continue;
        }
        if (output[index].normalized_segment_index != segment_index) {
            continue;
        }
        any = true;
        const double distance = samples[index].distance_from_start_meters;
        if (!std::isfinite(distance) || distance < 0.0 || distance < previous) {
            return false;
        }
        previous = distance;
    }
    return any;
}

[[nodiscard]]
bool segment_uses_supplied(
    RouteQualityDistancePolicy distance_policy,
    bool segment_valid,
    bool all_segments_valid,
    bool source_selected
) noexcept {
    switch (distance_policy) {
        case RouteQualityDistancePolicy::compute_from_coordinates:
            return false;
        case RouteQualityDistancePolicy::use_supplied_when_all_valid:
            return all_segments_valid;
        case RouteQualityDistancePolicy::use_supplied_per_segment:
            return segment_valid;
        case RouteQualityDistancePolicy::use_supplied_for_selected_source_segments:
            return source_selected && segment_valid;
    }
    return false;
}

void normalize_distances(
    std::span<const RouteInputSample> samples,
    std::span<RouteQualityOutputSample> output,
    RouteQualityDistancePolicy distance_policy,
    const std::uint8_t* selection,
    std::uint64_t normalized_segment_count,
    RouteQualityDistanceSource& overall_source,
    double& total_distance_meters
) noexcept {
    total_distance_meters = 0.0;
    overall_source = RouteQualityDistanceSource::coordinate_derived;
    if (normalized_segment_count == 0u) {
        return;
    }

    // Per-segment validity and selection are evaluated by scanning retained
    // points; no route-length heap storage is allocated.
    std::uint64_t supplied_segment_count = 0u;
    double cumulative_distance = 0.0;

    bool all_segments_valid = true;
    for (std::uint64_t segment = 0u; segment < normalized_segment_count; ++segment) {
        if (!supplied_distance_series_is_valid(
                samples,
                output,
                static_cast<std::int64_t>(segment))) {
            all_segments_valid = false;
            break;
        }
    }

    for (std::uint64_t segment = 0u; segment < normalized_segment_count; ++segment) {
        const std::int64_t segment_index = static_cast<std::int64_t>(segment);
        const bool valid = supplied_distance_series_is_valid(
            samples,
            output,
            segment_index);

        bool source_selected = false;
        std::size_t first_retained = samples.size();
        std::size_t previous_retained = samples.size();
        for (std::size_t index = 0u; index < samples.size(); ++index) {
            if (output[index].retained == 0u) {
                continue;
            }
            if (output[index].normalized_segment_index != segment_index) {
                continue;
            }
            if (first_retained >= samples.size()) {
                first_retained = index;
                if (selection != nullptr) {
                    source_selected = selection[index] != 0u;
                }
            }
        }
        if (first_retained >= samples.size()) {
            continue;
        }

        const bool use_supplied = segment_uses_supplied(
            distance_policy,
            valid,
            all_segments_valid,
            source_selected);
        if (use_supplied) {
            ++supplied_segment_count;
        }

        const RouteSegmentDistanceSource segment_source = use_supplied
            ? RouteSegmentDistanceSource::device_supplied
            : RouteSegmentDistanceSource::coordinate_derived;
        const double supplied_base =
            samples[first_retained].distance_from_start_meters;

        previous_retained = samples.size();
        for (std::size_t index = 0u; index < samples.size(); ++index) {
            if (output[index].retained == 0u) {
                continue;
            }
            if (output[index].normalized_segment_index != segment_index) {
                continue;
            }

            output[index].distance_source = segment_source;
            if (previous_retained >= samples.size()) {
                output[index].normalized_distance_from_start_meters =
                    cumulative_distance;
                previous_retained = index;
                continue;
            }

            if (use_supplied) {
                const double relative = std::max(
                    0.0,
                    samples[index].distance_from_start_meters - supplied_base);
                const double candidate = cumulative_distance + relative;
                const double previous_distance =
                    output[previous_retained].normalized_distance_from_start_meters;
                output[index].normalized_distance_from_start_meters =
                    std::max(previous_distance, candidate);
            } else {
                const double step = internal::pairwise_coordinate_step_meters(
                    samples[previous_retained],
                    samples[index]);
                const double previous_distance =
                    output[previous_retained].normalized_distance_from_start_meters;
                const double addition =
                    std::isfinite(step) ? std::max(0.0, step) : 0.0;
                output[index].normalized_distance_from_start_meters =
                    previous_distance + addition;
            }
            previous_retained = index;
        }

        if (previous_retained < samples.size()) {
            cumulative_distance =
                output[previous_retained].normalized_distance_from_start_meters;
        }
    }

    total_distance_meters = cumulative_distance;
    if (supplied_segment_count == 0u) {
        overall_source = RouteQualityDistanceSource::coordinate_derived;
    } else if (supplied_segment_count == normalized_segment_count) {
        overall_source = RouteQualityDistanceSource::device_supplied;
    } else {
        overall_source = RouteQualityDistanceSource::mixed;
    }
}

}  // namespace

RouteQualityPipelineSummary process_route_quality_geometry(
    const RouteInputSample* samples,
    std::size_t sample_count,
    RouteQualityGeometryPolicy policy,
    RouteQualityDistancePolicy distance_policy,
    const std::uint8_t* supplied_selection_by_sample,
    std::size_t supplied_selection_count,
    RouteQualityOutputSample* output_samples,
    std::size_t output_capacity
) noexcept {
    if (sample_count > max_route_input_samples) {
        return empty_summary(RouteQualityPipelineStatus::resource_limit);
    }
    if (sample_count == 0u) {
        return empty_summary(RouteQualityPipelineStatus::success);
    }
    if (samples == nullptr) {
        return empty_summary(RouteQualityPipelineStatus::invalid_input_buffer);
    }
    if (output_samples == nullptr) {
        return empty_summary(RouteQualityPipelineStatus::invalid_output_buffer);
    }
    if (output_capacity < sample_count) {
        return empty_summary(
            RouteQualityPipelineStatus::insufficient_output_capacity);
    }
    if (!distance_policy_is_known(distance_policy) || !policy_is_valid(policy)) {
        return empty_summary(RouteQualityPipelineStatus::invalid_policy);
    }

    const std::span<const RouteInputSample> input(samples, sample_count);
    if (!validate_input_contract(input)) {
        return empty_summary(RouteQualityPipelineStatus::invalid_input_contract);
    }
    if (!validate_selection_buffer(
            input,
            supplied_selection_by_sample,
            supplied_selection_count,
            distance_policy)) {
        return empty_summary(RouteQualityPipelineStatus::invalid_selection_buffer);
    }

    // All expected failures have been checked. Writing may begin.
    const std::span<RouteQualityOutputSample> output(output_samples, sample_count);
    for (std::size_t index = 0u; index < sample_count; ++index) {
        RouteQualityOutputSample& entry = output[index];
        entry.source_index = input[index].source_index;
        entry.normalized_segment_index = 0;
        entry.normalized_distance_from_start_meters = 0.0;
        entry.distance_source = RouteSegmentDistanceSource::coordinate_derived;
        entry.retained = 1u;
        entry.rejected_coordinate_outlier = 0u;
        entry.inferred_boundary = 0u;
    }

    mark_outlier_candidates(input, output, policy);

    std::uint64_t discarded = 0u;
    std::uint64_t retained = 0u;
    for (const RouteQualityOutputSample& entry : output) {
        if (entry.retained != 0u) {
            ++retained;
        }
        if (entry.rejected_coordinate_outlier != 0u) {
            ++discarded;
        }
    }

    std::uint64_t inferred_gaps = 0u;
    infer_gap_boundaries(input, output, policy, inferred_gaps);

    std::uint64_t normalized_segments = 0u;
    compact_segments(input, output, normalized_segments);

    RouteQualityDistanceSource distance_source =
        RouteQualityDistanceSource::coordinate_derived;
    double total_distance = 0.0;
    normalize_distances(
        input,
        output,
        distance_policy,
        supplied_selection_by_sample,
        normalized_segments,
        distance_source,
        total_distance);

    RouteQualityPipelineSummary summary =
        empty_summary(RouteQualityPipelineStatus::success);
    summary.input_sample_count = static_cast<std::uint64_t>(sample_count);
    summary.retained_sample_count = retained;
    summary.discarded_coordinate_point_count = discarded;
    summary.inferred_route_gap_count = inferred_gaps;
    summary.normalized_segment_count = normalized_segments;
    summary.distance_source = distance_source;
    summary.total_distance_meters = total_distance;
    return summary;
}

}  // namespace runplay
