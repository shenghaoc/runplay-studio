#include "TestSupport.hpp"

#include "RunPlayEngineCpp/TrainingLoad.hpp"

#include <cmath>
#include <limits>

namespace {

using runplay::TrainingLoadPolicy;
using runplay::TrainingLoadSample;
using runplay::TrainingLoadStatus;
using runplay::TrainingLoadSummary;
using runplay::compute_training_load;
using runplay::training_load_zone_count;

static_assert(training_load_zone_count == 5);

/// Reference policy: resting 50, maximum 150 (span 100), male-cohort Banister
/// coefficients, zones 0/100/120/140/160 bpm.
TrainingLoadPolicy reference_policy() {
    TrainingLoadPolicy policy;
    policy.resting_heart_rate_bpm = 50.0;
    policy.maximum_heart_rate_bpm = 150.0;
    policy.coefficient_multiplier = 0.64;
    policy.coefficient_exponent = 1.92;
    policy.zone1_lower_bound_bpm = 0.0;
    policy.zone2_lower_bound_bpm = 100.0;
    policy.zone3_lower_bound_bpm = 120.0;
    policy.zone4_lower_bound_bpm = 140.0;
    policy.zone5_lower_bound_bpm = 160.0;
    return policy;
}

TrainingLoadSample sample(double rate, double seconds) {
    TrainingLoadSample value;
    value.heart_rate_bpm = rate;
    value.weight_seconds = seconds;
    value.has_heart_rate = 1;
    return value;
}

TrainingLoadSample sample_without_rate(double seconds) {
    TrainingLoadSample value;
    value.heart_rate_bpm = 0.0;
    value.weight_seconds = seconds;
    value.has_heart_rate = 0;
    return value;
}

void expect_success(const TrainingLoadSummary& summary) {
    expect(summary.status == TrainingLoadStatus::success, "expected success");
}

void expect_error_clean(const TrainingLoadSummary& summary, TrainingLoadStatus status) {
    expect(summary.status == status, "expected error status");
    expect(summary.total_trimp == 0.0, "error summary must not carry TRIMP");
    expect(summary.mean_heart_rate_bpm == 0.0, "error summary must not carry mean rate");
    expect(summary.zone1_seconds == 0.0, "error summary must not carry zone seconds");
    expect(summary.valid_heart_rate_seconds == 0.0, "error summary must not carry valid time");
    expect(summary.covered_seconds == 0.0, "error summary must not carry covered time");
    expect(summary.valid_interval_count == 0, "error summary must not carry counts");
    expect(summary.total_interval_count == 0, "error summary must not carry total counts");
    expect(summary.has_mean_heart_rate == 0, "error summary must not carry mean flag");
}

/// Relative tolerance for hand-mirrored double arithmetic.
void expect_near(double actual, double expected, double tolerance, const char* message) {
    const double scale = expected > 0.0 ? expected : 1.0;
    expect(std::abs(actual - expected) <= tolerance * scale, message);
}

/// One 60-second interval at heart rate 100: reserve is exactly 0.5, so
/// TRIMP = 1 min * 0.5 * 0.64 * exp(0.96) = 0.32 * exp(0.96).
void test_single_interval_hand_computed() {
    const TrainingLoadSample samples[] = {sample(100.0, 60.0)};
    const TrainingLoadSummary summary =
        compute_training_load(samples, 1, reference_policy());
    expect_success(summary);

    const double exponential = std::exp(1.92 * 0.5);
    const double expected = 0.32 * exponential;
    expect_near(summary.total_trimp, expected, 1e-12, "single-interval TRIMP");
    // exp(0.96) = 2.6116964734... so 0.32 * exp(0.96) = 0.8357428715...
    expect_near(summary.total_trimp, 0.8357428714969990, 1e-9, "hand literal TRIMP");

    expect(summary.mean_heart_rate_bpm == 100.0, "mean rate");
    expect(summary.has_mean_heart_rate == 1, "mean flag");
    expect(summary.valid_heart_rate_seconds == 60.0, "valid seconds");
    expect(summary.covered_seconds == 60.0, "covered seconds");
    expect(summary.valid_interval_count == 1, "valid count");
    expect(summary.total_interval_count == 1, "total count");
    expect(summary.zone2_seconds == 60.0, "zone 2 seconds for rate 100");
}

/// A 60-minute steady run at reserve 0.5: 60 min * 0.32 * exp(0.96).
void test_steady_hour_scales_linearly() {
    const TrainingLoadSample samples[] = {sample(100.0, 3600.0)};
    const TrainingLoadSummary summary =
        compute_training_load(samples, 1, reference_policy());
    expect_success(summary);
    expect_near(summary.total_trimp, 19.2 * std::exp(0.96), 1e-12, "hour TRIMP");
}

/// Mixed intensities sum interval by interval.
void test_mixed_intervals_sum() {
    const TrainingLoadSample samples[] = {
        sample(100.0, 600.0),
        sample(130.0, 600.0),
    };
    const TrainingLoadSummary summary =
        compute_training_load(samples, 2, reference_policy());
    expect_success(summary);

    const double easy = 10.0 * 0.5 * 0.64 * std::exp(1.92 * 0.5);
    const double hard = 10.0 * 0.8 * 0.64 * std::exp(1.92 * 0.8);
    expect_near(summary.total_trimp, easy + hard, 1e-12, "mixed TRIMP sum");
    // Time-weighted mean: (100*600 + 130*600) / 1200 = 115.
    expect_near(summary.mean_heart_rate_bpm, 115.0, 1e-12, "weighted mean rate");
    expect(summary.zone2_seconds == 600.0, "easy interval in zone 2");
    expect(summary.zone3_seconds == 600.0, "hard interval in zone 3");
}

/// Zone boundaries are inclusive on the lower bound; zone 5 is unbounded
/// above; zone 1 also absorbs rates below its own lower bound.
void test_zone_boundaries() {
    const TrainingLoadSample samples[] = {
        sample(95.0, 100.0),    // zone 1
        sample(100.0, 10.0),    // zone 2 (bound inclusive)
        sample(119.0, 20.0),    // zone 2
        sample(120.0, 30.0),    // zone 3 (bound inclusive)
        sample(139.0, 40.0),    // zone 3
        sample(140.0, 50.0),    // zone 4 (bound inclusive)
        sample(159.0, 60.0),    // zone 4
        sample(160.0, 70.0),    // zone 5 (bound inclusive)
        sample(200.0, 80.0),    // zone 5 (unbounded above)
        sample(30.0, 90.0),     // zone 1 (floor at zero bound)
    };
    const TrainingLoadSummary summary =
        compute_training_load(samples, 10, reference_policy());
    expect_success(summary);
    expect(summary.zone1_seconds == 190.0, "zone 1 seconds");
    expect(summary.zone2_seconds == 30.0, "zone 2 seconds");
    expect(summary.zone3_seconds == 70.0, "zone 3 seconds");
    expect(summary.zone4_seconds == 110.0, "zone 4 seconds");
    expect(summary.zone5_seconds == 150.0, "zone 5 seconds");
    const double zone_sum = summary.zone1_seconds + summary.zone2_seconds
        + summary.zone3_seconds + summary.zone4_seconds + summary.zone5_seconds;
    expect(zone_sum == summary.valid_heart_rate_seconds, "zone sum equals valid time");
}

/// A non-zero zone-1 floor still routes below-floor rates into zone 1.
void test_nonzero_zone1_floor() {
    TrainingLoadPolicy policy = reference_policy();
    policy.zone1_lower_bound_bpm = 100.0;
    policy.zone2_lower_bound_bpm = 110.0;
    policy.zone3_lower_bound_bpm = 120.0;
    policy.zone4_lower_bound_bpm = 130.0;
    policy.zone5_lower_bound_bpm = 140.0;
    const TrainingLoadSample samples[] = {sample(50.0, 30.0), sample(145.0, 30.0)};
    const TrainingLoadSummary summary = compute_training_load(samples, 2, policy);
    expect_success(summary);
    expect(summary.zone1_seconds == 30.0, "below-floor rate lands in zone 1");
    expect(summary.zone5_seconds == 30.0, "above-ceiling rate lands in zone 5");
}

/// Intervals without a heart rate (an HR gap mid-run) count toward covered
/// time only — never TRIMP, zone time, or the mean.
void test_hr_gap_intervals() {
    const TrainingLoadSample samples[] = {
        sample(100.0, 300.0),
        sample_without_rate(120.0),
        sample(140.0, 300.0),
    };
    const TrainingLoadSummary summary =
        compute_training_load(samples, 3, reference_policy());
    expect_success(summary);
    expect(summary.covered_seconds == 720.0, "gap counts as covered time");
    expect(summary.valid_heart_rate_seconds == 600.0, "gap excluded from valid time");
    expect(summary.valid_interval_count == 2, "gap excluded from valid count");
    expect(summary.total_interval_count == 3, "gap counted as an interval");
    expect_near(summary.mean_heart_rate_bpm, 120.0, 1e-12, "mean skips gap");
    const double easy = 5.0 * 0.5 * 0.64 * std::exp(0.96);
    const double threshold = 5.0 * 0.9 * 0.64 * std::exp(1.92 * 0.9);
    expect_near(summary.total_trimp, easy + threshold, 1e-12, "gap adds no TRIMP");
}

/// Zero-weight intervals (pauses collapsed by Swift) are counted but add
/// nothing anywhere.
void test_zero_weight_intervals() {
    const TrainingLoadSample samples[] = {
        sample(100.0, 0.0),
        sample_without_rate(0.0),
    };
    const TrainingLoadSummary summary =
        compute_training_load(samples, 2, reference_policy());
    expect_success(summary);
    expect(summary.total_interval_count == 2, "zero-weight intervals counted");
    expect(summary.valid_interval_count == 1, "zero-weight HR interval is valid");
    expect(summary.covered_seconds == 0.0, "zero weight adds no covered time");
    expect(summary.total_trimp == 0.0, "zero weight adds no TRIMP");
    expect(summary.has_mean_heart_rate == 0, "no weighted time means no mean");
}

/// Reserve is clamped: below resting contributes zero TRIMP (but zone time
/// and valid time still count); above maximum saturates at reserve 1.
void test_reserve_clamping() {
    const TrainingLoadSample below[] = {sample(40.0, 600.0)};
    const TrainingLoadSummary below_summary =
        compute_training_load(below, 1, reference_policy());
    expect_success(below_summary);
    expect(below_summary.total_trimp == 0.0, "below-resting reserve clamps to zero");
    expect(below_summary.valid_heart_rate_seconds == 600.0, "below-resting still valid time");
    expect(below_summary.zone1_seconds == 600.0, "below-resting still zone time");

    const TrainingLoadSample above[] = {sample(200.0, 600.0)};
    const TrainingLoadSummary above_summary =
        compute_training_load(above, 1, reference_policy());
    expect_success(above_summary);
    const double saturated = 10.0 * 1.0 * 0.64 * std::exp(1.92);
    expect_near(above_summary.total_trimp, saturated, 1e-12, "above-max saturates");
}

/// An empty pass succeeds with zeroes and no mean.
void test_empty_input() {
    const TrainingLoadSummary summary =
        compute_training_load(nullptr, 0, reference_policy());
    expect_success(summary);
    expect(summary.total_trimp == 0.0, "empty TRIMP");
    expect(summary.has_mean_heart_rate == 0, "empty mean flag");
    expect(summary.total_interval_count == 0, "empty interval count");
}

/// The female-cohort coefficient set flows through the same formula.
void test_female_coefficients() {
    TrainingLoadPolicy policy = reference_policy();
    policy.coefficient_multiplier = 0.86;
    policy.coefficient_exponent = 1.67;
    const TrainingLoadSample samples[] = {sample(100.0, 60.0)};
    const TrainingLoadSummary summary = compute_training_load(samples, 1, policy);
    expect_success(summary);
    const double expected = 0.5 * 0.86 * std::exp(1.67 * 0.5);
    expect_near(summary.total_trimp, expected, 1e-12, "female coefficient TRIMP");
}

void test_invalid_input_buffer() {
    const TrainingLoadSummary summary =
        compute_training_load(nullptr, 2, reference_policy());
    expect_error_clean(summary, TrainingLoadStatus::invalid_input_buffer);
}

void test_invalid_policies() {
    const TrainingLoadSample samples[] = {sample(100.0, 60.0)};

    TrainingLoadPolicy resting_above_max = reference_policy();
    resting_above_max.resting_heart_rate_bpm = 160.0;
    expect_error_clean(
        compute_training_load(samples, 1, resting_above_max),
        TrainingLoadStatus::invalid_policy);

    TrainingLoadPolicy resting_zero = reference_policy();
    resting_zero.resting_heart_rate_bpm = 0.0;
    expect_error_clean(
        compute_training_load(samples, 1, resting_zero),
        TrainingLoadStatus::invalid_policy);

    TrainingLoadPolicy max_nan = reference_policy();
    max_nan.maximum_heart_rate_bpm = std::nan("");
    expect_error_clean(
        compute_training_load(samples, 1, max_nan),
        TrainingLoadStatus::invalid_policy);

    TrainingLoadPolicy multiplier_zero = reference_policy();
    multiplier_zero.coefficient_multiplier = 0.0;
    expect_error_clean(
        compute_training_load(samples, 1, multiplier_zero),
        TrainingLoadStatus::invalid_policy);

    TrainingLoadPolicy multiplier_negative = reference_policy();
    multiplier_negative.coefficient_multiplier = -0.64;
    expect_error_clean(
        compute_training_load(samples, 1, multiplier_negative),
        TrainingLoadStatus::invalid_policy);

    TrainingLoadPolicy exponent_zero = reference_policy();
    exponent_zero.coefficient_exponent = 0.0;
    expect_error_clean(
        compute_training_load(samples, 1, exponent_zero),
        TrainingLoadStatus::invalid_policy);

    TrainingLoadPolicy bound_nan = reference_policy();
    bound_nan.zone3_lower_bound_bpm = std::nan("");
    expect_error_clean(
        compute_training_load(samples, 1, bound_nan),
        TrainingLoadStatus::invalid_policy);

    TrainingLoadPolicy bounds_equal = reference_policy();
    bounds_equal.zone2_lower_bound_bpm = 100.0;
    bounds_equal.zone1_lower_bound_bpm = 100.0;
    expect_error_clean(
        compute_training_load(samples, 1, bounds_equal),
        TrainingLoadStatus::invalid_policy);

    TrainingLoadPolicy bounds_descending = reference_policy();
    bounds_descending.zone4_lower_bound_bpm = 130.0;
    bounds_descending.zone3_lower_bound_bpm = 135.0;
    expect_error_clean(
        compute_training_load(samples, 1, bounds_descending),
        TrainingLoadStatus::invalid_policy);
}

void test_invalid_input_contracts() {
    TrainingLoadSample negative_weight = sample(100.0, -1.0);
    expect_error_clean(
        compute_training_load(&negative_weight, 1, reference_policy()),
        TrainingLoadStatus::invalid_input_contract);

    TrainingLoadSample nan_weight = sample(100.0, std::nan(""));
    expect_error_clean(
        compute_training_load(&nan_weight, 1, reference_policy()),
        TrainingLoadStatus::invalid_input_contract);

    TrainingLoadSample infinite_weight = sample(100.0, std::numeric_limits<double>::infinity());
    expect_error_clean(
        compute_training_load(&infinite_weight, 1, reference_policy()),
        TrainingLoadStatus::invalid_input_contract);

    TrainingLoadSample bad_flag = sample(100.0, 60.0);
    bad_flag.has_heart_rate = 2;
    expect_error_clean(
        compute_training_load(&bad_flag, 1, reference_policy()),
        TrainingLoadStatus::invalid_input_contract);

    TrainingLoadSample nan_rate = sample(std::nan(""), 60.0);
    expect_error_clean(
        compute_training_load(&nan_rate, 1, reference_policy()),
        TrainingLoadStatus::invalid_input_contract);

    TrainingLoadSample zero_rate = sample(0.0, 60.0);
    expect_error_clean(
        compute_training_load(&zero_rate, 1, reference_policy()),
        TrainingLoadStatus::invalid_input_contract);

    TrainingLoadSample negative_rate = sample(-5.0, 60.0);
    expect_error_clean(
        compute_training_load(&negative_rate, 1, reference_policy()),
        TrainingLoadStatus::invalid_input_contract);
}

/// A contract violation after valid intervals must discard all partial work.
void test_error_after_partial_pass() {
    const TrainingLoadSample samples[] = {
        sample(100.0, 600.0),
        sample_without_rate(60.0),
        sample(std::nan(""), 60.0),
    };
    expect_error_clean(
        compute_training_load(samples, 3, reference_policy()),
        TrainingLoadStatus::invalid_input_contract);
}

/// Weights below one second still resolve fractional minutes.
void test_fractional_weights() {
    const TrainingLoadSample samples[] = {sample(100.0, 0.5)};
    const TrainingLoadSummary summary =
        compute_training_load(samples, 1, reference_policy());
    expect_success(summary);
    const double expected = (0.5 / 60.0) * 0.5 * 0.64 * std::exp(0.96);
    expect_near(summary.total_trimp, expected, 1e-12, "fractional TRIMP");
}

}  // namespace

void run_training_load_tests() {
    test_single_interval_hand_computed();
    test_steady_hour_scales_linearly();
    test_mixed_intervals_sum();
    test_zone_boundaries();
    test_nonzero_zone1_floor();
    test_hr_gap_intervals();
    test_zero_weight_intervals();
    test_reserve_clamping();
    test_empty_input();
    test_female_coefficients();
    test_invalid_input_buffer();
    test_invalid_policies();
    test_invalid_input_contracts();
    test_error_after_partial_pass();
    test_fractional_weights();
    std::cout << "training load tests passed\n";
}
