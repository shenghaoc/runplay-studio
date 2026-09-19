#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace runplay {

/// The training-load boundary uses a fixed five-zone model: policy bounds and
/// summary buckets are five named members, not arrays, so the Swift surface
/// stays tuple-free.
inline constexpr std::size_t training_load_zone_count = 5;

/// One heart-rate time interval. Swift builds these from adjacent route
/// points inside one route segment: `weight_seconds` is the interval duration
/// and `heart_rate_bpm` is the interval's representative rate. Intervals that
/// span a recording gap or pause never become samples — their weight is zero
/// by construction in Swift, which owns active-time semantics.
struct TrainingLoadSample final {
    double heart_rate_bpm{0};
    double weight_seconds{0};
    std::uint8_t has_heart_rate{0};
};

static_assert(std::is_standard_layout_v<TrainingLoadSample>);
static_assert(std::is_trivially_copyable_v<TrainingLoadSample>);
static_assert(std::is_nothrow_default_constructible_v<TrainingLoadSample>);
static_assert(std::is_nothrow_copy_constructible_v<TrainingLoadSample>);
static_assert(std::is_nothrow_copy_assignable_v<TrainingLoadSample>);

/// Banister TRIMP parameters and the five-zone bucketing bounds. All values
/// are computed by Swift from the athlete profile; the engine never derives
/// them.
///
/// The interval load is the exponential Banister form
/// `(weight_seconds / 60) * hr_reserve * multiplier * exp(exponent * hr_reserve)`
/// where `hr_reserve = (heart_rate_bpm - resting) / (maximum - resting)`
/// clamped to `[0, 1]`. The published male-cohort coefficients are
/// `0.64 * exp(1.92 * x)` and the female-cohort coefficients are
/// `0.86 * exp(1.67 * x)`; Swift chooses the set, the engine only applies it.
struct TrainingLoadPolicy final {
    double resting_heart_rate_bpm{0};
    double maximum_heart_rate_bpm{0};
    double coefficient_multiplier{0};
    double coefficient_exponent{0};

    /// Ascending zone lower bounds in bpm. Zone 1 is `[zone1, zone2)`, ...,
    /// zone 5 is `[zone5, +inf)`. A rate below `zone1_lower_bound_bpm` still
    /// lands in zone 1 — zone 1 is the unbounded-low bucket. Swift's default
    /// profile passes `zone1_lower_bound_bpm = 0` so every finite rate counts.
    double zone1_lower_bound_bpm{0};
    double zone2_lower_bound_bpm{0};
    double zone3_lower_bound_bpm{0};
    double zone4_lower_bound_bpm{0};
    double zone5_lower_bound_bpm{0};
};

static_assert(std::is_standard_layout_v<TrainingLoadPolicy>);
static_assert(std::is_trivially_copyable_v<TrainingLoadPolicy>);
static_assert(std::is_nothrow_default_constructible_v<TrainingLoadPolicy>);
static_assert(std::is_nothrow_copy_constructible_v<TrainingLoadPolicy>);
static_assert(std::is_nothrow_copy_assignable_v<TrainingLoadPolicy>);

enum class TrainingLoadStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_policy,
    invalid_input_contract,
    internal_failure,
};

/// Aggregate training-load result. This boundary has no per-sample output
/// buffer: every product of the pass fits in fixed-size aggregates, so the
/// summary returns by value and an error summary carries no partial values —
/// every numeric field is zero and only `status` is set.
struct TrainingLoadSummary final {
    TrainingLoadStatus status{TrainingLoadStatus::success};
    /// Sum of Banister TRIMP over intervals that carry a heart rate.
    double total_trimp{0};
    /// Time-weighted mean rate over heart-rate intervals; zero (with
    /// `has_mean_heart_rate == 0`) when no interval carries one.
    double mean_heart_rate_bpm{0};
    double zone1_seconds{0};
    double zone2_seconds{0};
    double zone3_seconds{0};
    double zone4_seconds{0};
    double zone5_seconds{0};
    /// Total weight of intervals that carry a heart rate.
    double valid_heart_rate_seconds{0};
    /// Total weight of every interval, with or without a heart rate.
    double covered_seconds{0};
    std::uint64_t valid_interval_count{0};
    std::uint64_t total_interval_count{0};
    std::uint8_t has_mean_heart_rate{0};
};

static_assert(std::is_standard_layout_v<TrainingLoadSummary>);
static_assert(std::is_trivially_copyable_v<TrainingLoadSummary>);
static_assert(std::is_nothrow_default_constructible_v<TrainingLoadSummary>);
static_assert(std::is_nothrow_copy_constructible_v<TrainingLoadSummary>);
static_assert(std::is_nothrow_copy_assignable_v<TrainingLoadSummary>);

/// Accumulate Banister TRIMP and zone-time buckets over heart-rate intervals.
///
/// The samples buffer is Swift-owned and borrowed synchronously for this one
/// call; C++ retains no pointer, performs no callback, allocates nothing, and
/// writes nothing back. One call covers one whole workout — never one call
/// per interval. Cancellation is cooperative Swift work around the call.
[[nodiscard]]
TrainingLoadSummary compute_training_load(
    const TrainingLoadSample* samples,
    std::size_t sample_count,
    TrainingLoadPolicy policy
) noexcept;

}  // namespace runplay
