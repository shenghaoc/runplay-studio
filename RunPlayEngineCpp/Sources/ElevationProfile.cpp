#include "RunPlayEngineCpp/ElevationProfile.hpp"
#include "RunPlayEngineCpp/RouteInterop.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace runplay {
namespace {

// ---------------------------------------------------------------------------
// Working-altitude helpers (output buffer is the route-sized workspace)
// ---------------------------------------------------------------------------

[[nodiscard]]
static bool has_working_altitude(
    const ElevationProfileOutputSample& sample) noexcept
{
    return sample.has_corrected_altitude != 0;
}

[[nodiscard]]
static double working_altitude(
    const ElevationProfileOutputSample& sample) noexcept
{
    return sample.corrected_altitude_meters;
}

static void set_working_altitude(
    ElevationProfileOutputSample& sample,
    double altitude) noexcept
{
    sample.corrected_altitude_meters = altitude;
    sample.has_corrected_altitude = 1;
}

static void clear_working_altitude(
    ElevationProfileOutputSample& sample) noexcept
{
    sample.corrected_altitude_meters = 0.0;
    sample.has_corrected_altitude = 0;
}

static void mark_rejected(ElevationProfileOutputSample& sample) noexcept
{
    sample.source_altitude_was_rejected = 1;
}

// ---------------------------------------------------------------------------
// Validation (no output writes)
// ---------------------------------------------------------------------------

[[nodiscard]]
static ElevationProfileStatus validate_policy(
    const ElevationProfilePolicy& policy) noexcept
{
    if (!std::isfinite(policy.plausible_altitude_minimum_meters) ||
        !std::isfinite(policy.plausible_altitude_maximum_meters) ||
        !std::isfinite(policy.spike_minimum_deviation_meters) ||
        !std::isfinite(policy.short_excursion_minimum_deviation_meters) ||
        !std::isfinite(policy.spike_maximum_neighbor_difference_meters) ||
        !std::isfinite(policy.spike_maximum_horizontal_span_meters) ||
        !std::isfinite(policy.smoothing_radius_meters) ||
        !std::isfinite(policy.gain_loss_deadband_meters)) {
        return ElevationProfileStatus::invalid_policy;
    }

    if (policy.plausible_altitude_minimum_meters >
        policy.plausible_altitude_maximum_meters) {
        return ElevationProfileStatus::invalid_policy;
    }

    if (policy.spike_minimum_deviation_meters < 0.0) {
        return ElevationProfileStatus::invalid_policy;
    }
    if (policy.short_excursion_minimum_deviation_meters <
        policy.spike_minimum_deviation_meters) {
        return ElevationProfileStatus::invalid_policy;
    }
    if (policy.short_excursion_maximum_sample_count < 1) {
        return ElevationProfileStatus::invalid_policy;
    }
    if (policy.spike_maximum_neighbor_difference_meters < 0.0) {
        return ElevationProfileStatus::invalid_policy;
    }
    if (policy.spike_maximum_horizontal_span_meters < 0.0) {
        return ElevationProfileStatus::invalid_policy;
    }
    if (policy.smoothing_radius_meters < 0.0) {
        return ElevationProfileStatus::invalid_policy;
    }
    if (policy.minimum_reliable_sample_count < 2) {
        return ElevationProfileStatus::invalid_policy;
    }
    if (policy.gain_loss_deadband_meters < 0.0) {
        return ElevationProfileStatus::invalid_policy;
    }

    return ElevationProfileStatus::success;
}

[[nodiscard]]
static ElevationProfileStatus validate_input_contract(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count) noexcept
{
    if (sample_count == 0) {
        return ElevationProfileStatus::success;
    }

    if (samples[0].continuity_group != 0) {
        return ElevationProfileStatus::invalid_input_contract;
    }
    if (samples[0].has_altitude != 0 && samples[0].has_altitude != 1) {
        return ElevationProfileStatus::invalid_input_contract;
    }

    std::int32_t previous_group = 0;
    for (std::size_t index = 0; index < sample_count; ++index) {
        const auto& sample = samples[index];
        if (sample.has_altitude != 0 && sample.has_altitude != 1) {
            return ElevationProfileStatus::invalid_input_contract;
        }
        if (sample.continuity_group < 0) {
            return ElevationProfileStatus::invalid_input_contract;
        }
        if (sample.continuity_group < previous_group) {
            return ElevationProfileStatus::invalid_input_contract;
        }
        const std::int32_t group_delta =
            sample.continuity_group - previous_group;
        if (group_delta > 1) {
            return ElevationProfileStatus::invalid_input_contract;
        }
        previous_group = sample.continuity_group;
    }

    return ElevationProfileStatus::success;
}

[[nodiscard]]
static ElevationProfileSummary make_failure(
    ElevationProfileStatus status,
    std::size_t sample_count,
    std::size_t required_capacity) noexcept
{
    ElevationProfileSummary summary{};
    summary.status = status;
    summary.sample_count = 0;
    summary.rejected_altitude_count = 0;
    summary.run_count = 0;
    summary.reliable_run_count = 0;
    summary.required_output_capacity =
        static_cast<std::uint64_t>(required_capacity);
    summary.has_meaningful_elevation = 0;
    summary.total_ascent_meters = 0.0;
    summary.total_descent_meters = 0.0;
    // Silence unused when callers pass sample_count only for documentation.
    (void)sample_count;
    return summary;
}

// ---------------------------------------------------------------------------
// Stage helpers
// ---------------------------------------------------------------------------

[[nodiscard]]
static double interpolate(
    double first,
    double second,
    double fraction) noexcept
{
    // Literal Swift arithmetic order: first + ((second - first) * fraction)
    const double difference = second - first;
    const double scaled = difference * fraction;
    return first + scaled;
}

[[nodiscard]]
static double clamp_unit(double fraction) noexcept
{
    if (fraction < 0.0) {
        return 0.0;
    }
    if (fraction > 1.0) {
        return 1.0;
    }
    return fraction;
}

// ---------------------------------------------------------------------------
// Multi-pass pipeline (output is fully initialized on the success path)
// ---------------------------------------------------------------------------

static void stage_source_plausibility(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count,
    const ElevationProfilePolicy& policy,
    ElevationProfileOutputSample* output) noexcept
{
    for (std::size_t index = 0; index < sample_count; ++index) {
        auto& out = output[index];
        out.corrected_altitude_meters = 0.0;
        out.cumulative_ascent_meters = 0.0;
        out.cumulative_descent_meters = 0.0;
        out.cumulative_signed_change_meters = 0.0;
        out.reliable_interval_count = 0.0;
        out.run_identifier = -1;
        out.reliable_run_identifier = -1;
        out.has_corrected_altitude = 0;
        out.source_altitude_was_rejected = 0;

        const auto& sample = samples[index];
        if (sample.has_altitude == 0) {
            continue;
        }

        const double altitude = sample.altitude_meters;
        if (std::isfinite(altitude) &&
            altitude >= policy.plausible_altitude_minimum_meters &&
            altitude <= policy.plausible_altitude_maximum_meters) {
            set_working_altitude(out, altitude);
        } else {
            mark_rejected(out);
        }
    }
}

// Endpoint spikes: decisions read the post-plausibility snapshot (working
// altitudes). Both endpoints of a run are evaluated against that snapshot;
// mutations only apply after both decisions so neither endpoint influences the
// other (matching Swift's immutable sourceAltitudes copy).
static void stage_endpoint_spikes(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count,
    const ElevationProfilePolicy& policy,
    ElevationProfileOutputSample* output) noexcept
{
    if (sample_count < 3) {
        return;
    }

    std::size_t cursor = 0;
    while (cursor < sample_count) {
        if (!has_working_altitude(output[cursor])) {
            ++cursor;
            continue;
        }

        const std::int32_t run_group = samples[cursor].continuity_group;
        const std::size_t run_start = cursor;
        ++cursor;
        while (cursor < sample_count &&
               samples[cursor].continuity_group == run_group &&
               has_working_altitude(output[cursor])) {
            ++cursor;
        }
        const std::size_t run_end = cursor;
        if (run_end - run_start < 3) {
            continue;
        }

        // Evaluate both endpoints against the pre-mutation snapshot.
        const std::size_t endpoints[2] = {run_start, run_end - 1};
        bool reject_endpoint[2] = {false, false};

        for (int endpoint_slot = 0; endpoint_slot < 2; ++endpoint_slot) {
            const std::size_t endpoint_index = endpoints[endpoint_slot];
            const bool is_leading = endpoint_index == run_start;
            const std::size_t near_index =
                is_leading ? endpoint_index + 1 : endpoint_index - 1;
            const std::size_t far_index =
                is_leading ? endpoint_index + 2 : endpoint_index - 2;

            if (!has_working_altitude(output[endpoint_index]) ||
                !has_working_altitude(output[near_index]) ||
                !has_working_altitude(output[far_index])) {
                continue;
            }

            const double endpoint = working_altitude(output[endpoint_index]);
            const double near = working_altitude(output[near_index]);
            const double far = working_altitude(output[far_index]);
            if (std::fabs(near - far) >
                policy.spike_maximum_neighbor_difference_meters) {
                continue;
            }

            const double travelled_span = std::fabs(
                samples[far_index].distance_meters -
                samples[endpoint_index].distance_meters);
            const double neighbour_midpoint = (near + far) / 2.0;
            if (!std::isfinite(travelled_span) ||
                travelled_span > policy.spike_maximum_horizontal_span_meters ||
                std::fabs(endpoint - neighbour_midpoint) <
                    policy.spike_minimum_deviation_meters ||
                std::fabs(endpoint - near) <
                    policy.spike_minimum_deviation_meters ||
                std::fabs(endpoint - far) <
                    policy.spike_minimum_deviation_meters) {
                continue;
            }

            reject_endpoint[endpoint_slot] = true;
        }

        for (int endpoint_slot = 0; endpoint_slot < 2; ++endpoint_slot) {
            if (!reject_endpoint[endpoint_slot]) {
                continue;
            }
            clear_working_altitude(output[endpoints[endpoint_slot]]);
            mark_rejected(output[endpoints[endpoint_slot]]);
        }
    }
}

// Isolated interior spikes: left-to-right mutation on the working altitudes.
static void stage_isolated_interior_spikes(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count,
    const ElevationProfilePolicy& policy,
    ElevationProfileOutputSample* output) noexcept
{
    if (sample_count < 3) {
        return;
    }

    for (std::size_t index = 1; index + 1 < sample_count; ++index) {
        if (samples[index - 1].continuity_group !=
                samples[index].continuity_group ||
            samples[index].continuity_group !=
                samples[index + 1].continuity_group) {
            continue;
        }
        if (!has_working_altitude(output[index - 1]) ||
            !has_working_altitude(output[index]) ||
            !has_working_altitude(output[index + 1])) {
            continue;
        }

        const double previous = working_altitude(output[index - 1]);
        const double current = working_altitude(output[index]);
        const double next = working_altitude(output[index + 1]);
        if (std::fabs(previous - next) >
            policy.spike_maximum_neighbor_difference_meters) {
            continue;
        }

        const double horizontal_span =
            samples[index + 1].distance_meters -
            samples[index - 1].distance_meters;
        if (!std::isfinite(horizontal_span) ||
            horizontal_span > policy.spike_maximum_horizontal_span_meters) {
            continue;
        }

        const double neighbour_midpoint = (previous + next) / 2.0;
        if (std::fabs(current - neighbour_midpoint) <
                policy.spike_minimum_deviation_meters ||
            std::fabs(current - previous) <
                policy.spike_minimum_deviation_meters ||
            std::fabs(current - next) <
                policy.spike_minimum_deviation_meters) {
            continue;
        }

        clear_working_altitude(output[index]);
        mark_rejected(output[index]);
    }
}

// Short multi-sample excursions. Scan cursor advances past a rejected
// excursion (start = end), matching Swift.
static void stage_short_excursions(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count,
    const ElevationProfilePolicy& policy,
    ElevationProfileOutputSample* output) noexcept
{
    if (policy.short_excursion_maximum_sample_count < 2 ||
        sample_count < 4) {
        return;
    }

    const std::uint64_t max_excursion =
        policy.short_excursion_maximum_sample_count;
    std::size_t start = 1;
    while (start + 1 < sample_count) {
        if (!has_working_altitude(output[start])) {
            ++start;
            continue;
        }

        const double first_excursion = working_altitude(output[start]);
        std::size_t end = start + 1;
        while (end + 1 < sample_count &&
               static_cast<std::uint64_t>(end - start) < max_excursion &&
               samples[end].continuity_group ==
                   samples[start].continuity_group &&
               has_working_altitude(output[end]) &&
               std::fabs(working_altitude(output[end]) - first_excursion) <=
                   policy.spike_maximum_neighbor_difference_meters) {
            ++end;
        }

        const std::size_t excursion_count = end - start;
        if (excursion_count < 2 ||
            end >= sample_count ||
            samples[start - 1].continuity_group !=
                samples[start].continuity_group ||
            samples[end].continuity_group !=
                samples[start].continuity_group ||
            !has_working_altitude(output[start - 1]) ||
            !has_working_altitude(output[end])) {
            ++start;
            continue;
        }

        const double before = working_altitude(output[start - 1]);
        const double after = working_altitude(output[end]);
        if (std::fabs(before - after) >
            policy.spike_maximum_neighbor_difference_meters) {
            ++start;
            continue;
        }

        const double neighbour_midpoint = (before + after) / 2.0;
        bool excursion_is_extreme = true;
        for (std::size_t index = start; index < end; ++index) {
            if (!has_working_altitude(output[index]) ||
                std::fabs(working_altitude(output[index]) -
                          neighbour_midpoint) <
                    policy.short_excursion_minimum_deviation_meters) {
                excursion_is_extreme = false;
                break;
            }
        }

        const double horizontal_span =
            samples[end].distance_meters -
            samples[start - 1].distance_meters;
        if (!excursion_is_extreme ||
            !std::isfinite(horizontal_span) ||
            horizontal_span > policy.spike_maximum_horizontal_span_meters) {
            ++start;
            continue;
        }

        for (std::size_t index = start; index < end; ++index) {
            clear_working_altitude(output[index]);
            mark_rejected(output[index]);
        }
        start = end;
    }
}

// Supported interpolation of isolated rejected samples. Snapshot semantics:
// compute all eligible fills from the post-rejection working state, then apply
// so fills do not chain (matches Swift's rejectedAltitudes copy).
// Temporary fill values use cumulative_signed_change_meters + a presence bit
// in reliable_interval_count (0 empty / 1 pending fill) — both are reset in
// later stages.
static void stage_fill_rejected(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count,
    ElevationProfileOutputSample* output) noexcept
{
    if (sample_count < 3) {
        return;
    }

    for (std::size_t index = 0; index < sample_count; ++index) {
        output[index].cumulative_signed_change_meters = 0.0;
        output[index].reliable_interval_count = 0.0;
    }

    for (std::size_t index = 1; index + 1 < sample_count; ++index) {
        if (output[index].source_altitude_was_rejected == 0) {
            continue;
        }
        if (samples[index - 1].continuity_group !=
                samples[index].continuity_group ||
            samples[index].continuity_group !=
                samples[index + 1].continuity_group) {
            continue;
        }
        if (!has_working_altitude(output[index - 1]) ||
            !has_working_altitude(output[index + 1])) {
            continue;
        }

        const double previous = working_altitude(output[index - 1]);
        const double next = working_altitude(output[index + 1]);
        const double span =
            samples[index + 1].distance_meters -
            samples[index - 1].distance_meters;
        const double fraction = span > 0.0
            ? (samples[index].distance_meters -
               samples[index - 1].distance_meters) / span
            : 0.5;
        output[index].cumulative_signed_change_meters =
            interpolate(previous, next, clamp_unit(fraction));
        output[index].reliable_interval_count = 1.0;
    }

    for (std::size_t index = 1; index + 1 < sample_count; ++index) {
        if (output[index].reliable_interval_count == 0.0) {
            continue;
        }
        set_working_altitude(
            output[index],
            output[index].cumulative_signed_change_meters);
        // source_altitude_was_rejected remains true.
        output[index].cumulative_signed_change_meters = 0.0;
        output[index].reliable_interval_count = 0.0;
    }
}

// Run identification, reliable classification, and distance-domain smoothing.
// Working altitudes remain in corrected_* until overwritten by smoothing.
// For unreliable / zero-radius runs, corrected equals working (already set).
static void stage_runs_and_smoothing(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count,
    const ElevationProfilePolicy& policy,
    ElevationProfileOutputSample* output,
    std::uint64_t& run_count,
    std::uint64_t& reliable_run_count) noexcept
{
    run_count = 0;
    reliable_run_count = 0;

    std::size_t cursor = 0;
    std::int32_t next_run_id = 0;

    while (cursor < sample_count) {
        if (!has_working_altitude(output[cursor])) {
            output[cursor].run_identifier = -1;
            output[cursor].reliable_run_identifier = -1;
            // Corrected already absent.
            ++cursor;
            continue;
        }

        const std::int32_t segment = samples[cursor].continuity_group;
        const std::size_t start = cursor;
        ++cursor;
        while (cursor < sample_count &&
               samples[cursor].continuity_group == segment &&
               has_working_altitude(output[cursor])) {
            ++cursor;
        }
        const std::size_t end = cursor;
        const std::size_t run_sample_count = end - start;
        const std::int32_t run_id = next_run_id;
        ++next_run_id;
        ++run_count;

        const bool is_reliable =
            static_cast<std::uint64_t>(run_sample_count) >=
            policy.minimum_reliable_sample_count;
        if (is_reliable) {
            ++reliable_run_count;
        }

        for (std::size_t index = start; index < end; ++index) {
            output[index].run_identifier = run_id;
            output[index].reliable_run_identifier =
                is_reliable ? run_id : -1;
        }

        if (!is_reliable || policy.smoothing_radius_meters == 0.0) {
            // Working altitudes already stored as corrected values.
            continue;
        }

        // Stash unsmoothed working altitudes for the run into
        // cumulative_descent_meters so the sliding window always reads the
        // pre-smooth snapshot (Swift reads analysisAltitudes while writing
        // corrected). Cleared before the gain/loss stage reuses the field.
        for (std::size_t index = start; index < end; ++index) {
            output[index].cumulative_descent_meters =
                working_altitude(output[index]);
        }

        // Centered distance-domain moving average within the run only.
        // Literal Swift window inclusivity and summation order.
        std::size_t left = start;
        std::size_t right = start;
        double sum = 0.0;
        std::size_t window_count = 0;

        for (std::size_t index = start; index < end; ++index) {
            const double center_distance = samples[index].distance_meters;
            const double upper_distance =
                center_distance + policy.smoothing_radius_meters;

            while (right < end &&
                   samples[right].distance_meters <= upper_distance) {
                sum += output[right].cumulative_descent_meters;
                ++window_count;
                ++right;
            }

            const double lower_distance =
                center_distance - policy.smoothing_radius_meters;
            while (left < right &&
                   samples[left].distance_meters < lower_distance) {
                sum -= output[left].cumulative_descent_meters;
                --window_count;
                ++left;
            }

            if (window_count > 0) {
                set_working_altitude(
                    output[index],
                    sum / static_cast<double>(window_count));
            } else {
                set_working_altitude(
                    output[index],
                    output[index].cumulative_descent_meters);
            }
        }

        // Avoid moving the endpoints of a continuous recorded span.
        set_working_altitude(
            output[start],
            output[start].cumulative_descent_meters);
        set_working_altitude(
            output[end - 1],
            output[end - 1].cumulative_descent_meters);

        for (std::size_t index = start; index < end; ++index) {
            output[index].cumulative_descent_meters = 0.0;
        }
    }

    // Samples never entered as runs already have run_identifier = -1 from
    // stage_source_plausibility initialization.
}

// Cumulative signed change, reliable intervals, and deadband-confirmed
// gain/loss. Exact port of the Swift threshold-confirmed trend-reversal loop.
static void stage_cumulative_gain_loss(
    std::size_t sample_count,
    const ElevationProfilePolicy& policy,
    ElevationProfileOutputSample* output) noexcept
{
    double global_ascent = 0.0;
    double global_descent = 0.0;
    double global_signed = 0.0;
    double global_reliable_intervals = 0.0;

    std::size_t cursor = 0;
    while (cursor < sample_count) {
        if (output[cursor].run_identifier < 0) {
            output[cursor].cumulative_ascent_meters = global_ascent;
            output[cursor].cumulative_descent_meters = global_descent;
            output[cursor].cumulative_signed_change_meters = global_signed;
            output[cursor].reliable_interval_count = global_reliable_intervals;
            ++cursor;
            continue;
        }

        const std::int32_t run_id = output[cursor].run_identifier;
        const std::size_t start = cursor;
        ++cursor;
        while (cursor < sample_count &&
               output[cursor].run_identifier == run_id) {
            ++cursor;
        }
        const std::size_t end = cursor;
        const bool is_reliable =
            output[start].reliable_run_identifier >= 0;

        if (!is_reliable || !has_working_altitude(output[start])) {
            for (std::size_t index = start; index < end; ++index) {
                output[index].cumulative_ascent_meters = global_ascent;
                output[index].cumulative_descent_meters = global_descent;
                output[index].cumulative_signed_change_meters = global_signed;
                output[index].reliable_interval_count =
                    global_reliable_intervals;
            }
            continue;
        }

        const double first_altitude = working_altitude(output[start]);
        int trend = 0;  // 0 unknown, 1 rising, -1 falling
        double pivot = first_altitude;
        double extreme = first_altitude;
        double committed_ascent = global_ascent;
        double committed_descent = global_descent;
        double previous_altitude = first_altitude;

        for (std::size_t index = start; index < end; ++index) {
            if (!has_working_altitude(output[index])) {
                // Should not occur inside a continuous altitude run.
                continue;
            }
            const double altitude = working_altitude(output[index]);

            if (index > start) {
                global_signed += altitude - previous_altitude;
                global_reliable_intervals += 1.0;
            }
            previous_altitude = altitude;

            switch (trend) {
            case 0:
                if (altitude - pivot >= policy.gain_loss_deadband_meters) {
                    trend = 1;
                    extreme = altitude;
                } else if (pivot - altitude >=
                           policy.gain_loss_deadband_meters) {
                    trend = -1;
                    extreme = altitude;
                }
                break;
            case 1:
                if (altitude > extreme) {
                    extreme = altitude;
                } else if (extreme - altitude >=
                           policy.gain_loss_deadband_meters) {
                    committed_ascent += std::max(0.0, extreme - pivot);
                    pivot = extreme;
                    trend = -1;
                    extreme = altitude;
                }
                break;
            default:
                if (altitude < extreme) {
                    extreme = altitude;
                } else if (altitude - extreme >=
                           policy.gain_loss_deadband_meters) {
                    committed_descent += std::max(0.0, pivot - extreme);
                    pivot = extreme;
                    trend = 1;
                    extreme = altitude;
                }
                break;
            }

            const double provisional_ascent =
                trend == 1 ? std::max(0.0, extreme - pivot) : 0.0;
            const double provisional_descent =
                trend == -1 ? std::max(0.0, pivot - extreme) : 0.0;
            output[index].cumulative_ascent_meters =
                committed_ascent + provisional_ascent;
            output[index].cumulative_descent_meters =
                committed_descent + provisional_descent;
            output[index].cumulative_signed_change_meters = global_signed;
            output[index].reliable_interval_count = global_reliable_intervals;
        }

        global_ascent = output[end - 1].cumulative_ascent_meters;
        global_descent = output[end - 1].cumulative_descent_meters;
    }
}

}  // namespace

ElevationProfileSummary build_elevation_profile(
    const ElevationProfileInputSample* samples,
    std::size_t sample_count,
    ElevationProfilePolicy policy,
    ElevationProfileOutputSample* output_samples,
    std::size_t output_capacity
) noexcept
{
    // Empty input: null buffers allowed.
    if (sample_count == 0) {
        ElevationProfileSummary summary{};
        summary.status = ElevationProfileStatus::success;
        summary.sample_count = 0;
        summary.rejected_altitude_count = 0;
        summary.run_count = 0;
        summary.reliable_run_count = 0;
        summary.required_output_capacity = 0;
        summary.has_meaningful_elevation = 0;
        summary.total_ascent_meters = 0.0;
        summary.total_descent_meters = 0.0;
        return summary;
    }

    if (samples == nullptr) {
        return make_failure(
            ElevationProfileStatus::invalid_input_buffer,
            sample_count,
            sample_count);
    }
    if (output_samples == nullptr) {
        return make_failure(
            ElevationProfileStatus::invalid_output_buffer,
            sample_count,
            sample_count);
    }
    if (output_capacity < sample_count) {
        return make_failure(
            ElevationProfileStatus::insufficient_output_capacity,
            sample_count,
            sample_count);
    }
    if (sample_count > max_route_input_samples) {
        return make_failure(
            ElevationProfileStatus::resource_limit,
            sample_count,
            sample_count);
    }

    const ElevationProfileStatus policy_status = validate_policy(policy);
    if (policy_status != ElevationProfileStatus::success) {
        return make_failure(policy_status, sample_count, sample_count);
    }

    const ElevationProfileStatus contract_status =
        validate_input_contract(samples, sample_count);
    if (contract_status != ElevationProfileStatus::success) {
        return make_failure(contract_status, sample_count, sample_count);
    }

    // ---- Validation complete. Output is now the route-sized workspace. ----

    stage_source_plausibility(samples, sample_count, policy, output_samples);
    stage_endpoint_spikes(samples, sample_count, policy, output_samples);
    stage_isolated_interior_spikes(
        samples, sample_count, policy, output_samples);
    stage_short_excursions(samples, sample_count, policy, output_samples);
    stage_fill_rejected(samples, sample_count, output_samples);

    std::uint64_t run_count = 0;
    std::uint64_t reliable_run_count = 0;
    stage_runs_and_smoothing(
        samples,
        sample_count,
        policy,
        output_samples,
        run_count,
        reliable_run_count);
    stage_cumulative_gain_loss(sample_count, policy, output_samples);

    std::uint64_t rejected_count = 0;
    for (std::size_t index = 0; index < sample_count; ++index) {
        if (output_samples[index].source_altitude_was_rejected != 0) {
            ++rejected_count;
        }
    }

    const double final_reliable =
        output_samples[sample_count - 1].reliable_interval_count;
    const bool meaningful = final_reliable > 0.0;

    ElevationProfileSummary summary{};
    summary.status = ElevationProfileStatus::success;
    summary.sample_count = static_cast<std::uint64_t>(sample_count);
    summary.rejected_altitude_count = rejected_count;
    summary.run_count = run_count;
    summary.reliable_run_count = reliable_run_count;
    summary.required_output_capacity =
        static_cast<std::uint64_t>(sample_count);
    summary.has_meaningful_elevation = meaningful ? 1 : 0;
    summary.total_ascent_meters =
        meaningful ? output_samples[sample_count - 1].cumulative_ascent_meters
                   : 0.0;
    summary.total_descent_meters =
        meaningful ? output_samples[sample_count - 1].cumulative_descent_meters
                   : 0.0;
    return summary;
}

}  // namespace runplay
