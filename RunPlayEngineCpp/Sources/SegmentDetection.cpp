#include "RunPlayEngineCpp/SegmentDetection.hpp"
#include "RunPlayEngineCpp/RouteInterop.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <optional>

namespace runplay {
namespace {

// ---------------------------------------------------------------------------
// Internal distance-boundary location
// ---------------------------------------------------------------------------

struct DistanceLocation final {
    std::size_t before{0};
    std::size_t after{0};
    double fraction{0.0};  // 0 when exact point; >0 when interpolating
};

// Binary search for first index with distance >= target.
// Returns index into [0, count].
static std::size_t lower_bound_index(
    const SegmentDetectionSample* samples,
    std::size_t count,
    double target) noexcept
{
    std::size_t low = 0;
    std::size_t high = count;
    while (low < high) {
        const std::size_t middle = low + (high - low) / 2;
        if (samples[middle].distance_meters < target) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

// Binary search for first index with distance > target.
static std::size_t upper_bound_index(
    const SegmentDetectionSample* samples,
    std::size_t count,
    double target) noexcept
{
    std::size_t low = 0;
    std::size_t high = count;
    while (low < high) {
        const std::size_t middle = low + (high - low) / 2;
        if (samples[middle].distance_meters <= target) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

// Exact translation of WorkoutTimeline.distanceLocation semantics.
// Same-segment distance plateaus use first arrival for both roles, except a
// terminal range end includes the final sample. A plateau that crosses route
// segments assigns the start to the first point of the resumed segment and the
// end to the last point of the prior segment.
static std::optional<DistanceLocation> timeline_distance_location(
    const SegmentDetectionSample* samples,
    std::size_t count,
    double distance,
    bool is_range_start) noexcept
{
    if (count == 0) return std::nullopt;

    const double first_dist = samples[0].distance_meters;
    const double last_dist = samples[count - 1].distance_meters;
    const double target = std::max(first_dist, std::min(distance, last_dist));

    const std::size_t first_at_or_after = lower_bound_index(samples, count, target);

    if (first_at_or_after < count &&
        samples[first_at_or_after].distance_meters == target) {
        const std::size_t first = first_at_or_after;
        const std::size_t last = upper_bound_index(samples, count, target) - 1;
        std::size_t selected = first;

        if (samples[first].continuity_group == samples[last].continuity_group) {
            if (!is_range_start && last == count - 1) {
                selected = last;
            }
        } else if (is_range_start) {
            const std::int32_t resumed_group = samples[last].continuity_group;
            selected = last;
            while (selected > first &&
                   samples[selected - 1].continuity_group == resumed_group) {
                --selected;
            }
        } else {
            const std::int32_t prior_group = samples[first].continuity_group;
            selected = first;
            while (selected < last &&
                   samples[selected + 1].continuity_group == prior_group) {
                ++selected;
            }
        }
        return DistanceLocation{selected, selected, 0.0};
    }

    if (first_at_or_after == 0) {
        return DistanceLocation{0, 0, 0.0};
    }
    if (first_at_or_after >= count) {
        const std::size_t last = count - 1;
        return DistanceLocation{last, last, 0.0};
    }

    const std::size_t before = first_at_or_after - 1;
    const std::size_t after = first_at_or_after;

    if (samples[before].continuity_group != samples[after].continuity_group) {
        const std::size_t selected = is_range_start ? after : before;
        return DistanceLocation{selected, selected, 0.0};
    }

    const double span = samples[after].distance_meters -
                        samples[before].distance_meters;
    if (!(span > 0.0)) {
        const std::size_t selected = is_range_start ? after : before;
        return DistanceLocation{selected, selected, 0.0};
    }

    const double fraction = std::max(0.0, std::min(1.0,
        (target - samples[before].distance_meters) / span));
    return DistanceLocation{before, after, fraction};
}

// Exact translation of ElevationProfile.distanceLocation semantics.
// Clamp target to [samples[0].distance, samples[last].distance].
// Exact duplicate: range start → last duplicate; range end → first duplicate.
// Interpolation only inside one continuity_group.
// Cross-group target: start selects later group, end selects earlier group.
static std::optional<DistanceLocation> elevation_distance_location(
    const SegmentDetectionSample* samples,
    std::size_t count,
    double distance,
    bool is_range_start) noexcept
{
    if (count == 0) return std::nullopt;

    const double first_dist = samples[0].distance_meters;
    const double last_dist = samples[count - 1].distance_meters;
    const double target = std::max(first_dist, std::min(distance, last_dist));

    const std::size_t first_at_or_after = lower_bound_index(samples, count, target);

    if (first_at_or_after < count &&
        samples[first_at_or_after].distance_meters == target) {
        const std::size_t last = upper_bound_index(samples, count, target) - 1;
        const std::size_t selected = is_range_start ? last : first_at_or_after;
        return DistanceLocation{selected, selected, 0.0};
    }

    if (first_at_or_after == 0) {
        return DistanceLocation{0, 0, 0.0};
    }
    if (first_at_or_after >= count) {
        const std::size_t last = count - 1;
        return DistanceLocation{last, last, 0.0};
    }

    const std::size_t before = first_at_or_after - 1;
    const std::size_t after = first_at_or_after;

    if (samples[before].continuity_group != samples[after].continuity_group) {
        const std::size_t selected = is_range_start ? after : before;
        return DistanceLocation{selected, selected, 0.0};
    }

    const double span = samples[after].distance_meters -
                        samples[before].distance_meters;
    if (!(span > 0.0)) {
        const std::size_t selected = is_range_start ? after : before;
        return DistanceLocation{selected, selected, 0.0};
    }

    const double fraction = std::max(0.0, std::min(1.0,
        (target - samples[before].distance_meters) / span));
    return DistanceLocation{before, after, fraction};
}

/// Sample a value array at a distance using exact ElevationProfile semantics.
static std::optional<double> sampled_value_at(
    const SegmentDetectionSample* samples,
    std::size_t count,
    double (SegmentDetectionSample::*member),
    double distance,
    bool is_range_start) noexcept
{
    const auto loc = elevation_distance_location(
        samples, count, distance, is_range_start);
    if (!loc) return std::nullopt;

    if (loc->before == loc->after) {
        return samples[loc->before].*member;
    }

    if (samples[loc->before].continuity_group !=
        samples[loc->after].continuity_group) {
        return is_range_start
            ? samples[loc->after].*member
            : samples[loc->before].*member;
    }

    const double before_val = samples[loc->before].*member;
    const double after_val = samples[loc->after].*member;
    const double difference = after_val - before_val;
    const double scaled_difference = difference * loc->fraction;
    return before_val + scaled_difference;
}

/// Interpolate the two clocks at a distance — exact translation of
/// WorkoutTimeline.distanceSample interpolation.
static bool sample_clocks(
    const SegmentDetectionSample* samples,
    std::size_t count,
    double distance,
    bool is_range_start,
    double& out_elapsed,
    double& out_active) noexcept
{
    const auto location = timeline_distance_location(
        samples, count, distance, is_range_start);
    if (!location) return false;

    if (location->before == location->after) {
        out_elapsed = samples[location->before].elapsed_seconds;
        out_active = samples[location->before].active_seconds;
        return true;
    }

    const auto& before = samples[location->before];
    const auto& after = samples[location->after];
    const double elapsed_difference =
        after.elapsed_seconds - before.elapsed_seconds;
    const double scaled_elapsed_difference =
        elapsed_difference * location->fraction;
    out_elapsed = before.elapsed_seconds + scaled_elapsed_difference;
    const double active_difference =
        after.active_seconds - before.active_seconds;
    const double scaled_active_difference =
        active_difference * location->fraction;
    out_active = before.active_seconds + scaled_active_difference;
    return true;
}

// ---------------------------------------------------------------------------
// Range clock semantics
// ---------------------------------------------------------------------------

struct RangeClocks {
    double elapsed{0};
    double active{0};
};

static RangeClocks range_clocks(
    double start_elapsed,
    double end_elapsed,
    double start_active,
    double end_active) noexcept
{
    const double elapsed = std::max(0.0, end_elapsed - start_elapsed);
    const double active = std::min(
        std::max(0.0, end_active - start_active),
        elapsed);
    return {elapsed, active};
}

// ---------------------------------------------------------------------------
// Input validation
// ---------------------------------------------------------------------------

static SegmentDetectionStatus validate_input(
    const SegmentDetectionSample* samples,
    std::size_t sample_count) noexcept
{
    if (sample_count == 0) return SegmentDetectionStatus::success;

    if (samples == nullptr)
        return SegmentDetectionStatus::invalid_input_buffer;

    if (sample_count > max_route_input_samples)
        return SegmentDetectionStatus::resource_limit;

    // First sample invariants
    const auto& s0 = samples[0];
    if (!std::isfinite(s0.distance_meters)) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.distance_meters < 0.0) return SegmentDetectionStatus::invalid_input_contract;
    if (!std::isfinite(s0.elapsed_seconds)) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.elapsed_seconds < 0.0) return SegmentDetectionStatus::invalid_input_contract;
    if (!std::isfinite(s0.active_seconds)) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.active_seconds < 0.0) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.active_seconds - s0.elapsed_seconds > 1e-12)
        return SegmentDetectionStatus::invalid_input_contract;
    if (!std::isfinite(s0.cumulative_ascent_meters)) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.cumulative_ascent_meters < 0.0) return SegmentDetectionStatus::invalid_input_contract;
    if (!std::isfinite(s0.cumulative_descent_meters)) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.cumulative_descent_meters < 0.0) return SegmentDetectionStatus::invalid_input_contract;
    if (!std::isfinite(s0.reliable_interval_count)) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.reliable_interval_count < 0.0) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.continuity_group != 0) return SegmentDetectionStatus::invalid_input_contract;
    if (s0.reliable_elevation_run != -1 &&
        s0.reliable_elevation_run != 0)
        return SegmentDetectionStatus::invalid_input_contract;

    std::int32_t prev_group = 0;
    std::int32_t prev_reliable_run_seen = -1;
    std::int32_t prev_sample_reliable_run = s0.reliable_elevation_run;

    for (std::size_t i = 1; i < sample_count; ++i) {
        const auto& s = samples[i];
        const auto& prev = samples[i - 1];

        // Finiteness
        if (!std::isfinite(s.distance_meters)) return SegmentDetectionStatus::invalid_input_contract;
        if (!std::isfinite(s.elapsed_seconds)) return SegmentDetectionStatus::invalid_input_contract;
        if (!std::isfinite(s.active_seconds)) return SegmentDetectionStatus::invalid_input_contract;
        if (!std::isfinite(s.cumulative_ascent_meters)) return SegmentDetectionStatus::invalid_input_contract;
        if (!std::isfinite(s.cumulative_descent_meters)) return SegmentDetectionStatus::invalid_input_contract;
        if (!std::isfinite(s.reliable_interval_count)) return SegmentDetectionStatus::invalid_input_contract;

        // Nondecreasing distance
        if (s.distance_meters < prev.distance_meters)
            return SegmentDetectionStatus::invalid_input_contract;

        // Nondecreasing elapsed
        if (s.elapsed_seconds < prev.elapsed_seconds)
            return SegmentDetectionStatus::invalid_input_contract;

        // Nondecreasing active
        if (s.active_seconds < prev.active_seconds)
            return SegmentDetectionStatus::invalid_input_contract;

        // Active not beyond elapsed (narrow tolerance for numerical noise)
        const double active_excess = s.active_seconds - s.elapsed_seconds;
        if (active_excess > 1e-12)
            return SegmentDetectionStatus::invalid_input_contract;

        // Nondecreasing ascent/descent
        if (s.cumulative_ascent_meters < prev.cumulative_ascent_meters)
            return SegmentDetectionStatus::invalid_input_contract;
        if (s.cumulative_descent_meters < prev.cumulative_descent_meters)
            return SegmentDetectionStatus::invalid_input_contract;

        // Nondecreasing reliable interval count
        if (s.reliable_interval_count < prev.reliable_interval_count)
            return SegmentDetectionStatus::invalid_input_contract;

        // Continuity group: zero-based, nondecreasing, increments by ≤1
        if (s.continuity_group < 0) return SegmentDetectionStatus::invalid_input_contract;
        if (s.continuity_group < prev_group) return SegmentDetectionStatus::invalid_input_contract;
        const std::int32_t group_delta = s.continuity_group - prev.continuity_group;
        if (group_delta > 1) return SegmentDetectionStatus::invalid_input_contract;
        if (group_delta == 1 &&
            s.reliable_elevation_run >= 0 &&
            s.reliable_elevation_run == prev.reliable_elevation_run)
            return SegmentDetectionStatus::invalid_input_contract;
        prev_group = s.continuity_group;

        // Reliable elevation run validation
        if (s.reliable_elevation_run < -1) return SegmentDetectionStatus::invalid_input_contract;

        // Track compact runs: a nonnegative run ID must occupy one contiguous range
        if (s.reliable_elevation_run != prev_sample_reliable_run) {
            if (prev_sample_reliable_run >= 0) {
                // Just exited a reliable run. Verify this run ID was new.
                if (prev_sample_reliable_run <= prev_reliable_run_seen) {
                    return SegmentDetectionStatus::invalid_input_contract;
                }
                prev_reliable_run_seen = prev_sample_reliable_run;
            }
            // Entering a new run: must be compact (next expected ID)
            if (s.reliable_elevation_run >= 0) {
                if (s.reliable_elevation_run != prev_reliable_run_seen + 1) {
                    return SegmentDetectionStatus::invalid_input_contract;
                }
            }
        }
        prev_sample_reliable_run = s.reliable_elevation_run;
    }

    // Final exit check
    if (prev_sample_reliable_run >= 0) {
        if (prev_sample_reliable_run <= prev_reliable_run_seen) {
            return SegmentDetectionStatus::invalid_input_contract;
        }
    }

    return SegmentDetectionStatus::success;
}

// ---------------------------------------------------------------------------
// Configuration validation
// ---------------------------------------------------------------------------

static SegmentDetectionStatus validate_configuration(
    const SegmentDetectionConfiguration& config,
    std::size_t sample_count) noexcept
{
    // All doubles must be finite
    if (!std::isfinite(config.fastest_400m_distance_meters)) return SegmentDetectionStatus::invalid_configuration;
    if (!std::isfinite(config.fastest_400m_step_meters)) return SegmentDetectionStatus::invalid_configuration;
    if (!std::isfinite(config.one_kilometer_distance_meters)) return SegmentDetectionStatus::invalid_configuration;
    if (!std::isfinite(config.one_kilometer_step_meters)) return SegmentDetectionStatus::invalid_configuration;
    if (!std::isfinite(config.minimum_valid_pace_seconds_per_kilometer)) return SegmentDetectionStatus::invalid_configuration;
    if (!std::isfinite(config.maximum_valid_pace_seconds_per_kilometer)) return SegmentDetectionStatus::invalid_configuration;
    if (!std::isfinite(config.elevation_window_distance_meters)) return SegmentDetectionStatus::invalid_configuration;
    if (!std::isfinite(config.elevation_step_meters)) return SegmentDetectionStatus::invalid_configuration;

    // Pace distances positive
    if (!(config.fastest_400m_distance_meters > 0.0)) return SegmentDetectionStatus::invalid_configuration;
    if (!(config.fastest_400m_step_meters > 0.0)) return SegmentDetectionStatus::invalid_configuration;
    if (!(config.one_kilometer_distance_meters > 0.0)) return SegmentDetectionStatus::invalid_configuration;
    if (!(config.one_kilometer_step_meters > 0.0)) return SegmentDetectionStatus::invalid_configuration;

    // Pace range valid
    if (!(config.minimum_valid_pace_seconds_per_kilometer > 0.0)) return SegmentDetectionStatus::invalid_configuration;
    if (!(config.maximum_valid_pace_seconds_per_kilometer >= config.minimum_valid_pace_seconds_per_kilometer))
        return SegmentDetectionStatus::invalid_configuration;

    // elevation_enabled exactly 0 or 1
    if (config.elevation_enabled != 0 && config.elevation_enabled != 1)
        return SegmentDetectionStatus::invalid_configuration;

    if (config.elevation_enabled == 1) {
        if (!(config.elevation_window_distance_meters > 0.0)) return SegmentDetectionStatus::invalid_configuration;
        if (!(config.elevation_step_meters > 0.0)) return SegmentDetectionStatus::invalid_configuration;
    }

    // Maximum evaluations for nonempty route
    if (sample_count > 0) {
        if (config.maximum_evaluations_per_search < 1)
            return SegmentDetectionStatus::invalid_configuration;
    }

    return SegmentDetectionStatus::success;
}

// A distance-stepped loop evaluates floor(span / step) + 1 windows. Avoid
// converting an attacker-controlled quotient to an integer before proving it
// is within the caller-supplied bound.
static bool evaluation_count_is_within_limit(
    double window_distance,
    double step,
    double total_distance,
    std::uint64_t maximum_evaluations) noexcept
{
    if (!(total_distance >= window_distance)) return true;
    const double span = total_distance - window_distance;
    if (!(span >= 0.0)) return true;
    const double steps = span / step;
    if (!std::isfinite(steps)) return false;
    return steps < static_cast<double>(maximum_evaluations);
}

// ---------------------------------------------------------------------------
// Pace window search
// ---------------------------------------------------------------------------

struct PaceResult {
    double start_distance{0};
    double end_distance{0};
    double pace{0};
    bool found{false};
};

static PaceResult search_fastest_pace(
    const SegmentDetectionSample* samples,
    std::size_t sample_count,
    double window_distance,
    double step,
    double min_pace,
    double max_pace,
    double total_distance,
    std::uint64_t max_evaluations,
    std::uint64_t& out_eval_count) noexcept
{
    PaceResult best;
    best.found = false;
    out_eval_count = 0;

    if (!(total_distance >= window_distance)) return best;
    if (!(step > 0.0)) return best;
    if (sample_count < 2) return best;

    double best_pace = std::numeric_limits<double>::infinity();
    double window_start = samples[0].distance_meters;

    while (window_start + window_distance <= total_distance &&
           out_eval_count < max_evaluations) {
        ++out_eval_count;
        const double window_end = window_start + window_distance;

        double start_elapsed = 0, start_active = 0;
        double end_elapsed = 0, end_active = 0;

        if (!sample_clocks(samples, sample_count, window_start,
                          true, start_elapsed, start_active)) {
            break;
        }
        if (!sample_clocks(samples, sample_count, window_end,
                          false, end_elapsed, end_active)) {
            break;
        }

        const auto clocks = range_clocks(
            start_elapsed, end_elapsed, start_active, end_active);

        if (clocks.active > 0.0 && window_distance > 0.0) {
            const double pace = (clocks.active / window_distance) * 1000.0;
            if (std::isfinite(pace) &&
                pace >= min_pace && pace <= max_pace) {
                if (pace < best_pace) {
                    best_pace = pace;
                    best.start_distance = window_start;
                    best.end_distance = window_end;
                    best.pace = pace;
                    best.found = true;
                }
            }
        }

        window_start += step;
    }

    return best;
}

// Combined 1km loop: fastest and slowest in one pass.
struct CombinedPaceResults {
    PaceResult fastest;
    PaceResult slowest;
};

static CombinedPaceResults search_combined_one_km(
    const SegmentDetectionSample* samples,
    std::size_t sample_count,
    const SegmentDetectionConfiguration& config,
    double total_distance,
    std::uint64_t& out_eval_count) noexcept
{
    CombinedPaceResults results;
    out_eval_count = 0;

    const double window_distance = config.one_kilometer_distance_meters;
    const double step = config.one_kilometer_step_meters;
    const double min_pace = config.minimum_valid_pace_seconds_per_kilometer;
    const double max_pace = config.maximum_valid_pace_seconds_per_kilometer;

    if (!(total_distance >= window_distance)) return results;
    if (!(step > 0.0)) return results;
    if (sample_count < 2) return results;

    double fastest_pace = std::numeric_limits<double>::infinity();
    double slowest_pace = 0.0;
    double window_start = samples[0].distance_meters;

    while (window_start + window_distance <= total_distance &&
           out_eval_count < config.maximum_evaluations_per_search) {
        ++out_eval_count;
        const double window_end = window_start + window_distance;

        double start_elapsed = 0, start_active = 0;
        double end_elapsed = 0, end_active = 0;

        if (!sample_clocks(samples, sample_count, window_start,
                          true, start_elapsed, start_active)) {
            break;
        }
        if (!sample_clocks(samples, sample_count, window_end,
                          false, end_elapsed, end_active)) {
            break;
        }

        const auto clocks = range_clocks(
            start_elapsed, end_elapsed, start_active, end_active);

        if (clocks.active > 0.0 && window_distance > 0.0) {
            const double pace = (clocks.active / window_distance) * 1000.0;
            if (std::isfinite(pace) &&
                pace >= min_pace && pace <= max_pace) {
                if (pace < fastest_pace) {
                    fastest_pace = pace;
                    results.fastest.start_distance = window_start;
                    results.fastest.end_distance = window_end;
                    results.fastest.pace = pace;
                    results.fastest.found = true;
                }
                if (pace > slowest_pace) {
                    slowest_pace = pace;
                    results.slowest.start_distance = window_start;
                    results.slowest.end_distance = window_end;
                    results.slowest.pace = pace;
                    results.slowest.found = true;
                }
            }
        }

        window_start += step;
    }

    return results;
}

// ---------------------------------------------------------------------------
// Elevation window search
// ---------------------------------------------------------------------------

struct ElevationResult {
    double start_distance{0};
    double end_distance{0};
    double selection_value{0};  // signed delta
    bool found{false};
};

static bool is_same_reliable_run(
    const SegmentDetectionSample* samples,
    std::size_t count,
    double start_distance,
    double end_distance) noexcept
{
    const auto start_loc = elevation_distance_location(
        samples, count, start_distance, true);
    const auto end_loc = elevation_distance_location(
        samples, count, end_distance, false);
    if (!start_loc || !end_loc) return false;

    // For range_start (is_range_start=true):
    //   Exact: before==after → the last duplicate (resumed side). Valid.
    //   Interpolated: before/after are both in the same continuity_group.
    // For range_end (is_range_start=false):
    //   Exact: before==after → the first duplicate (held side). Valid.
    //   Interpolated: before/after are both in the same continuity_group.

    // For the start boundary: check that all involved points share the same
    // nonnegative reliable run.
    const std::int32_t start_run_a = samples[start_loc->before].reliable_elevation_run;
    const std::int32_t start_run_b = samples[start_loc->after].reliable_elevation_run;
    if (start_run_a < 0 || start_run_b < 0) return false;
    if (start_run_a != start_run_b) return false;

    const std::int32_t end_run_a = samples[end_loc->before].reliable_elevation_run;
    const std::int32_t end_run_b = samples[end_loc->after].reliable_elevation_run;
    if (end_run_a < 0 || end_run_b < 0) return false;
    if (end_run_a != end_run_b) return false;

    return start_run_a == end_run_a;
}

struct CombinedElevationResults {
    ElevationResult climb;
    ElevationResult descent;
};

static CombinedElevationResults search_combined_elevation(
    const SegmentDetectionSample* samples,
    std::size_t sample_count,
    const SegmentDetectionConfiguration& config,
    double total_distance,
    std::uint64_t& out_eval_count) noexcept
{
    CombinedElevationResults results;
    out_eval_count = 0;

    const double window_distance = config.elevation_window_distance_meters;
    const double step = config.elevation_step_meters;

    if (!(total_distance >= window_distance)) return results;
    if (!(step > 0.0)) return results;
    if (sample_count < 2) return results;

    double best_climb = 0.0;
    double best_descent = -0.0;  // saved as negative

    double window_start = samples[0].distance_meters;

    while (window_start + window_distance <= total_distance &&
           out_eval_count < config.maximum_evaluations_per_search) {
        ++out_eval_count;
        const double window_end = window_start + window_distance;

        if (!is_same_reliable_run(samples, sample_count,
                                  window_start, window_end)) {
            window_start += step;
            continue;
        }

        // Sample cumulative values at boundaries
        const auto start_ascent = sampled_value_at(samples, sample_count,
            &SegmentDetectionSample::cumulative_ascent_meters, window_start, true);
        const auto end_ascent = sampled_value_at(samples, sample_count,
            &SegmentDetectionSample::cumulative_ascent_meters, window_end, false);
        const auto start_descent = sampled_value_at(samples, sample_count,
            &SegmentDetectionSample::cumulative_descent_meters, window_start, true);
        const auto end_descent = sampled_value_at(samples, sample_count,
            &SegmentDetectionSample::cumulative_descent_meters, window_end, false);
        const auto start_reliable = sampled_value_at(samples, sample_count,
            &SegmentDetectionSample::reliable_interval_count, window_start, true);
        const auto end_reliable = sampled_value_at(samples, sample_count,
            &SegmentDetectionSample::reliable_interval_count, window_end, false);

        if (!start_ascent || !end_ascent || !start_descent || !end_descent ||
            !start_reliable || !end_reliable) {
            window_start += step;
            continue;
        }

        // Must have reliable interval increase
        if (!(*end_reliable > *start_reliable)) {
            window_start += step;
            continue;
        }

        const double ascent = std::max(0.0, *end_ascent - *start_ascent);
        const double descent = std::max(0.0, *end_descent - *start_descent);

        // Climb: replace when delta > best
        if (ascent > best_climb) {
            best_climb = ascent;
            results.climb.start_distance = window_start;
            results.climb.end_distance = window_end;
            results.climb.selection_value = ascent;
            results.climb.found = true;
        }

        // Descent: saved as negative; replace when delta < best (more negative = bigger)
        const double negative_descent = -descent;
        if (negative_descent < best_descent) {
            best_descent = negative_descent;
            results.descent.start_distance = window_start;
            results.descent.end_distance = window_end;
            results.descent.selection_value = negative_descent;
            results.descent.found = true;
        }

        window_start += step;
    }

    return results;
}

}  // namespace

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

[[nodiscard]]
SegmentDetectionSummary detect_segment_windows(
    const SegmentDetectionSample* samples,
    std::size_t sample_count,
    SegmentDetectionConfiguration configuration,
    SegmentWindowCandidate* output_candidates,
    std::size_t output_capacity
) noexcept
{
    SegmentDetectionSummary summary{};

    // Empty route
    if (sample_count == 0) {
        summary.status = SegmentDetectionStatus::success;
        summary.sample_count = 0;
        summary.candidate_count = 0;
        summary.pace_window_evaluation_count = 0;
        summary.elevation_window_evaluation_count = 0;
        summary.required_output_capacity = 0;
        return summary;
    }

    // Validate capacity first (no-input path)
    if (output_candidates == nullptr) {
        summary.status = SegmentDetectionStatus::invalid_output_buffer;
        summary.sample_count = sample_count;
        summary.required_output_capacity = segment_detection_max_candidate_count;
        return summary;
    }
    if (output_capacity < segment_detection_max_candidate_count) {
        summary.status = SegmentDetectionStatus::insufficient_output_capacity;
        summary.sample_count = sample_count;
        summary.required_output_capacity = segment_detection_max_candidate_count;
        return summary;
    }

    // Validate configuration
    const auto config_status = validate_configuration(configuration, sample_count);
    if (config_status != SegmentDetectionStatus::success) {
        summary.status = config_status;
        summary.sample_count = sample_count;
        return summary;
    }

    // Validate input
    const auto input_status = validate_input(samples, sample_count);
    if (input_status != SegmentDetectionStatus::success) {
        summary.status = input_status;
        summary.sample_count = sample_count;
        return summary;
    }

    const double total_distance = samples[sample_count - 1].distance_meters;
    const double start_distance = samples[0].distance_meters;
    const double span = total_distance - start_distance;

    // Estimate evaluation counts and check resource limits
    // Fastest 400m
    if (span >= configuration.fastest_400m_distance_meters) {
        const bool is_within_limit = evaluation_count_is_within_limit(
            configuration.fastest_400m_distance_meters,
            configuration.fastest_400m_step_meters,
            span,
            configuration.maximum_evaluations_per_search);
        if (!is_within_limit) {
            summary.status = SegmentDetectionStatus::resource_limit;
            summary.sample_count = sample_count;
            return summary;
        }
    }

    // 1km windows (fastest + slowest combined)
    if (span >= configuration.one_kilometer_distance_meters) {
        const bool is_within_limit = evaluation_count_is_within_limit(
            configuration.one_kilometer_distance_meters,
            configuration.one_kilometer_step_meters,
            span,
            configuration.maximum_evaluations_per_search);
        if (!is_within_limit) {
            summary.status = SegmentDetectionStatus::resource_limit;
            summary.sample_count = sample_count;
            return summary;
        }
    }

    // Elevation windows
    if (configuration.elevation_enabled == 1 &&
        span >= configuration.elevation_window_distance_meters) {
        const bool is_within_limit = evaluation_count_is_within_limit(
            configuration.elevation_window_distance_meters,
            configuration.elevation_step_meters,
            span,
            configuration.maximum_evaluations_per_search);
        if (!is_within_limit) {
            summary.status = SegmentDetectionStatus::resource_limit;
            summary.sample_count = sample_count;
            return summary;
        }
    }

    // All validation done; perform searches into local storage
    // then copy to output only on success.

    std::array<SegmentWindowCandidate, segment_detection_max_candidate_count> candidates{};
    std::uint64_t candidate_count = 0;
    std::uint64_t pace_evals = 0;
    std::uint64_t elev_evals = 0;

    // 1. Fastest 400m
    {
        std::uint64_t evals = 0;
        auto result = search_fastest_pace(
            samples, sample_count,
            configuration.fastest_400m_distance_meters,
            configuration.fastest_400m_step_meters,
            configuration.minimum_valid_pace_seconds_per_kilometer,
            configuration.maximum_valid_pace_seconds_per_kilometer,
            total_distance,
            configuration.maximum_evaluations_per_search,
            evals);
        pace_evals += evals;

        if (result.found && candidate_count < segment_detection_max_candidate_count) {
            candidates[candidate_count].kind = SegmentWindowKind::fastest_400m;
            candidates[candidate_count].start_distance_meters = result.start_distance;
            candidates[candidate_count].end_distance_meters = result.end_distance;
            candidates[candidate_count].selection_value = result.pace;
            ++candidate_count;
        }
    }

    // 2 & 3. Combined 1km loop
    {
        std::uint64_t evals = 0;
        auto combined = search_combined_one_km(
            samples, sample_count, configuration, total_distance, evals);
        pace_evals += evals;

        if (combined.fastest.found && candidate_count < segment_detection_max_candidate_count) {
            candidates[candidate_count].kind = SegmentWindowKind::fastest_1km;
            candidates[candidate_count].start_distance_meters = combined.fastest.start_distance;
            candidates[candidate_count].end_distance_meters = combined.fastest.end_distance;
            candidates[candidate_count].selection_value = combined.fastest.pace;
            ++candidate_count;
        }

        if (combined.slowest.found && candidate_count < segment_detection_max_candidate_count) {
            candidates[candidate_count].kind = SegmentWindowKind::slowest_1km;
            candidates[candidate_count].start_distance_meters = combined.slowest.start_distance;
            candidates[candidate_count].end_distance_meters = combined.slowest.end_distance;
            candidates[candidate_count].selection_value = combined.slowest.pace;
            ++candidate_count;
        }
    }

    // 4 & 5. Combined elevation loop (only when enabled)
    if (configuration.elevation_enabled == 1) {
        std::uint64_t evals = 0;
        auto elev = search_combined_elevation(
            samples, sample_count, configuration, total_distance, evals);
        elev_evals = evals;

        if (elev.climb.found && candidate_count < segment_detection_max_candidate_count) {
            candidates[candidate_count].kind = SegmentWindowKind::biggest_climb;
            candidates[candidate_count].start_distance_meters = elev.climb.start_distance;
            candidates[candidate_count].end_distance_meters = elev.climb.end_distance;
            candidates[candidate_count].selection_value = elev.climb.selection_value;
            ++candidate_count;
        }

        if (elev.descent.found && candidate_count < segment_detection_max_candidate_count) {
            candidates[candidate_count].kind = SegmentWindowKind::biggest_descent;
            candidates[candidate_count].start_distance_meters = elev.descent.start_distance;
            candidates[candidate_count].end_distance_meters = elev.descent.end_distance;
            candidates[candidate_count].selection_value = elev.descent.selection_value;
            ++candidate_count;
        }
    }

    // Copy to output
    for (std::size_t i = 0; i < candidate_count; ++i) {
        output_candidates[i] = candidates[i];
    }

    summary.status = SegmentDetectionStatus::success;
    summary.sample_count = static_cast<std::uint64_t>(sample_count);
    summary.candidate_count = candidate_count;
    summary.pace_window_evaluation_count = pace_evals;
    summary.elevation_window_evaluation_count = elev_evals;
    summary.required_output_capacity = segment_detection_max_candidate_count;

    return summary;
}

}  // namespace runplay
