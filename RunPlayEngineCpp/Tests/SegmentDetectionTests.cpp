#include "TestSupport.hpp"
#include "RunPlayEngineCpp/SegmentDetection.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <limits>
#include <vector>

namespace {

using namespace runplay;

// ---------------------------------------------------------------------------
// Compile-time tests
// ---------------------------------------------------------------------------

static void test_compile_time() {
    // C++23
    static_assert(__cplusplus >= 202302L);

    // Sample layout
    static_assert(std::is_standard_layout_v<SegmentDetectionSample>);
    static_assert(std::is_trivially_copyable_v<SegmentDetectionSample>);

    // Configuration layout
    static_assert(std::is_standard_layout_v<SegmentDetectionConfiguration>);
    static_assert(std::is_trivially_copyable_v<SegmentDetectionConfiguration>);

    // Candidate layout
    static_assert(std::is_standard_layout_v<SegmentWindowCandidate>);
    static_assert(std::is_trivially_copyable_v<SegmentWindowCandidate>);

    // Summary layout
    static_assert(std::is_standard_layout_v<SegmentDetectionSummary>);
    static_assert(std::is_trivially_copyable_v<SegmentDetectionSummary>);
}

// ---------------------------------------------------------------------------
// Boundary tests
// ---------------------------------------------------------------------------

static void test_empty_input() {
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    auto summary = detect_segment_windows(nullptr, 0, {}, output, std::size(output));

    expect(summary.status == SegmentDetectionStatus::success,
            "empty input → success");
    expect(summary.candidate_count == 0,
            "empty input → zero candidates");
    expect(summary.sample_count == 0,
            "empty input → zero sample count");
}

static void test_one_sample() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(&sample, 1, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "one sample → success");
    expect(summary.candidate_count == 0,
            "one sample → zero candidates");
}

static void test_null_nonempty_input() {
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(nullptr, 1, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_input_buffer,
            "null input → invalid_input_buffer");
    expect(summary.candidate_count == 0, "null input → zero candidates");
}

static void test_null_output() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(&sample, 1, config, nullptr, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_output_buffer,
            "null output → invalid_output_buffer");
}

static void test_insufficient_output_capacity() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[4] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(&sample, 1, config, output, 4);
    expect(summary.status == SegmentDetectionStatus::insufficient_output_capacity,
            "insufficient capacity");
    expect(summary.required_output_capacity == segment_detection_max_candidate_count,
            "required covers every candidate kind");
}

static void test_output_unchanged_on_error() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 0, -1},
        {1, 10, 10, 0, 0, 0, 0, -1},
    };
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    output[0].kind = SegmentWindowKind::fastest_1km;
    output[0].start_distance_meters = 99.9;

    // Trigger error: no max_evaluations
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 0;

    auto summary = detect_segment_windows(samples, 2, config, output, std::size(output));
    expect(summary.status != SegmentDetectionStatus::success, "error status");
    expect(output[0].kind == SegmentWindowKind::fastest_1km,
            "output unchanged on error");
    expect(output[0].start_distance_meters == 99.9,
            "output unchanged on error");
}

// ---------------------------------------------------------------------------
// Configuration tests
// ---------------------------------------------------------------------------

static void test_invalid_config_nan_distance() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;
    config.fastest_400m_distance_meters = std::numeric_limits<double>::quiet_NaN();

    auto summary = detect_segment_windows(&sample, 1, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_configuration,
            "NaN distance → invalid_config");
}

static void test_invalid_config_zero_distance() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;
    config.fastest_400m_distance_meters = 0;

    auto summary = detect_segment_windows(&sample, 1, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_configuration,
            "zero distance → invalid_config");
}

static void test_invalid_config_inverted_pace() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;
    config.minimum_valid_pace_seconds_per_kilometer = 500;
    config.maximum_valid_pace_seconds_per_kilometer = 200;

    auto summary = detect_segment_windows(&sample, 1, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_configuration,
            "inverted pace → invalid_config");
}

static void test_invalid_elevation_enabled_byte() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;
    config.elevation_enabled = 2;

    auto summary = detect_segment_windows(&sample, 1, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_configuration,
            "bad elevation byte → invalid_config");
}

// ---------------------------------------------------------------------------
// Input contract tests
// ---------------------------------------------------------------------------

static void test_nonfinite_distance() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 0, -1},
        {std::numeric_limits<double>::quiet_NaN(), 10, 10, 0, 0, 0, 0, -1},
    };
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples, 2, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "NaN distance → invalid_input_contract");
}

static void test_decreasing_distance() {
    SegmentDetectionSample samples[2] = {
        {100, 0, 0, 0, 0, 0, 0, -1},
        {50, 10, 10, 0, 0, 0, 0, -1},
    };
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples, 2, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "decreasing distance → invalid_input_contract");
}

static void test_decreasing_elapsed() {
    SegmentDetectionSample samples[2] = {
        {0, 100, 50, 0, 0, 0, 0, -1},
        {100, 50, 50, 0, 0, 0, 0, -1},
    };
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples, 2, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "decreasing elapsed → invalid_input_contract");
}

static void test_continuity_group_not_zero() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 1, -1},  // starts at 1!
        {100, 10, 10, 0, 0, 0, 1, -1},
    };
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples, 2, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "first continuity != 0 → invalid_input_contract");
}

static void test_first_active_time_cannot_exceed_elapsed_time() {
    SegmentDetectionSample sample{0, 0, 1, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    const auto summary = detect_segment_windows(&sample, 1, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "first active > elapsed → invalid_input_contract");
}

static void test_first_reliable_run_must_be_zero_based() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 0, 1},
        {100, 30, 30, 1, 0, 1, 0, 1},
    };
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    const auto summary = detect_segment_windows(samples, 2, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "first reliable run 1 → invalid_input_contract");
}

static void test_reliable_run_cannot_cross_continuity_group() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 0, 0},
        {100, 30, 30, 1, 0, 1, 1, 0},
    };
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    const auto summary = detect_segment_windows(samples, 2, config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "reliable run crossing route gap → invalid_input_contract");
}

// ---------------------------------------------------------------------------
// Distance boundary tests
// ---------------------------------------------------------------------------

static void test_constant_pace_route() {
    // 4 points over 400m, constant 4:00/km pace (240s/km)
    // points at 0, 133.3, 266.7, 400m; each segment is 100m at elapsed 24s, active 24s
    std::array<SegmentDetectionSample, 4> samples = {{
        {0, 0, 0, 0, 0, 0, 0, -1},
        {133.333, 32, 32, 0, 0, 0, 0, -1},
        {266.667, 64, 64, 0, 0, 0, 0, -1},
        {400, 96, 96, 0, 0, 0, 0, -1},
    }};

    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 50;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 100;

    auto summary = detect_segment_windows(samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success, "success");

    // Fastest 400m should be found
    bool found_400 = false;
    for (uint64_t i = 0; i < summary.candidate_count; i++) {
        if (output[i].kind == SegmentWindowKind::fastest_400m) {
            found_400 = true;
            expect(output[i].start_distance_meters == 0, "400m starts at 0");
            expect(std::abs(output[i].end_distance_meters - 400) < 1e-3,
                    "400m ends near 400");
        }
    }
    expect(found_400, "found fastest 400m");
}

// ---------------------------------------------------------------------------
// Pause-spanning test (matches the failing Swift test)
// ---------------------------------------------------------------------------

static void test_pause_spanning_active_time() {
    // Replicates testPaceWindowSpansPauseUsingActiveTime:
    // 6 points, one pause (duplicate distance at 500m across segment boundary)
    std::array<SegmentDetectionSample, 6> samples = {{
        {0, 0, 0, 0, 0, 0, 0, -1},
        {500, 150, 150, 0, 0, 0, 0, -1},
        {500, 1150, 150, 0, 0, 0, 1, -1},
        {1000, 1300, 300, 0, 0, 0, 1, -1},
        {1500, 1600, 600, 0, 0, 0, 1, -1},
        {2000, 1900, 900, 0, 0, 0, 1, -1},
    }};

    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 50;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success, "pause test → success");

    bool found_1km = false;
    for (uint64_t i = 0; i < summary.candidate_count; i++) {
        if (output[i].kind == SegmentWindowKind::fastest_1km) {
            found_1km = true;
            expect(output[i].start_distance_meters == 0, "fastest 1km starts at 0");
            expect(output[i].end_distance_meters == 1000, "fastest 1km ends at 1000");
            // pace ≈ (300/1000)*1000 = 300 s/km
            expect(std::abs(output[i].selection_value - 300) < 1e-6,
                    "pace ≈ 300 s/km");
        }
    }
    expect(found_1km, "pause test → found fastest 1km");
}

static void test_same_segment_distance_plateau_uses_first_arrival() {
    // Same-segment stationary time belongs to a window that starts at the
    // plateau. WorkoutTimeline selects the first arrival for that range start.
    std::array<SegmentDetectionSample, 4> samples = {{
        {0, 0, 0, 0, 0, 0, 0, -1},
        {400, 300, 300, 0, 0, 0, 0, -1},
        {400, 400, 400, 0, 0, 0, 0, -1},
        {800, 500, 500, 0, 0, 0, 0, -1},
    }};

    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 50;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 100;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "same-segment plateau → success");
    expect(summary.candidate_count == 1,
            "same-segment plateau → one pace candidate");
    expect(output[0].kind == SegmentWindowKind::fastest_400m,
            "same-segment plateau → fastest 400m");
    expect(output[0].start_distance_meters == 400,
            "same-segment plateau → winning window starts at plateau");
    expect(std::abs(output[0].selection_value - 500) < 1e-9,
            "same-segment plateau → stationary active time retained");
}

static void test_pause_plateau_uses_inner_segment_boundaries() {
    // Multiple samples can share the stop/resume distance on both sides of a
    // route gap. The end owns the last prior sample and the start owns the
    // first resumed sample, matching WorkoutTimeline exactly.
    std::array<SegmentDetectionSample, 6> samples = {{
        {0, 0, 0, 0, 0, 0, 0, -1},
        {500, 150, 150, 0, 0, 0, 0, -1},
        {500, 160, 160, 0, 0, 0, 0, -1},
        {500, 1160, 160, 0, 0, 0, 1, -1},
        {500, 1170, 170, 0, 0, 0, 1, -1},
        {1000, 1320, 320, 0, 0, 0, 1, -1},
    }};

    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 500;
    config.fastest_400m_step_meters = 500;
    config.one_kilometer_distance_meters = 1500;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 10;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "multi-sample pause plateau → success");
    expect(summary.candidate_count == 1,
            "multi-sample pause plateau → one candidate");
    expect(output[0].start_distance_meters == 0,
            "equal windows preserve first-winner tie");
    expect(std::abs(output[0].selection_value - 320) < 1e-9,
            "pause plateau uses last prior boundary sample");
}

static void test_each_search_has_its_own_evaluation_budget() {
    std::array<SegmentDetectionSample, 21> samples{};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const double distance = static_cast<double>(index) * 100.0;
        samples[index] = {
            distance,
            distance * 0.3,
            distance * 0.3,
            0,
            0,
            0,
            0,
            -1,
        };
    }

    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 100;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 100;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 20;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "individually bounded searches → success");
    expect(summary.pace_window_evaluation_count == 36,
            "pace summary counts 17 400m + 11 combined 1km + 8 one-mile evaluations");

    bool found_mile = false;
    for (std::uint64_t i = 0; i < summary.candidate_count; i++) {
        if (output[i].kind == SegmentWindowKind::fastest_one_mile) {
            found_mile = true;
        }
    }
    expect(found_mile, "2'000 m route attempts the one-mile record window");
}

static void test_finite_evaluation_quotient_beyond_uint64_is_resource_limited() {
    std::array<SegmentDetectionSample, 2> samples = {{
        {0, 0, 0, 0, 0, 0, 0, -1},
        {1.0e20, 1.0e12, 1.0e12, 0, 0, 0, 0, -1},
    }};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    output[0].start_distance_meters = 12345;

    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 1;
    config.one_kilometer_distance_meters = 1'000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1'200;
    config.maximum_evaluations_per_search = 1'000;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::resource_limit,
            "finite quotient beyond uint64 range is resource limited");
    expect(output[0].start_distance_meters == 12345,
            "resource-limit preflight leaves output unchanged");
}

static void test_pace_uses_rounded_window_boundary_distance() {
    constexpr double start_distance = 8'388'475.4963460555;
    const double end_distance = start_distance + 1'000.0;
    std::array<SegmentDetectionSample, 2> samples = {{
        {start_distance, 0, 0, 0, 0, 0, 0, -1},
        {end_distance, 300, 300, 0, 0, 0, 0, -1},
    }};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};

    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 2'000;
    config.fastest_400m_step_meters = 50;
    config.one_kilometer_distance_meters = 1'000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1'200;
    config.maximum_evaluations_per_search = 10;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "large-distance rounded window → success");
    expect(summary.candidate_count == 2,
            "large-distance rounded window → fastest and slowest 1km");

    const double evaluated_distance = end_distance - start_distance;
    const double expected_pace = (300.0 / evaluated_distance) * 1'000.0;
    expect(output[0].selection_value == expected_pace,
            "fastest pace uses rounded boundary subtraction");
    expect(output[1].selection_value == expected_pace,
            "slowest pace uses rounded boundary subtraction");
}

// ---------------------------------------------------------------------------
// Personal-record window tests
// ---------------------------------------------------------------------------

// Constant 300 s/km route helper: samples every `interval` metres with clocks
// scaled at 0.3 seconds per metre.
static std::vector<SegmentDetectionSample> make_constant_pace_samples(
    double total_distance,
    double interval) {
    std::vector<SegmentDetectionSample> samples;
    const std::size_t count = static_cast<std::size_t>(total_distance / interval) + 1;
    samples.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        const double distance = static_cast<double>(index) * interval;
        samples.push_back({
            distance,
            distance * 0.3,
            distance * 0.3,
            0,
            0,
            0,
            0,
            -1,
        });
    }
    return samples;
}

static bool has_candidate(
    const SegmentWindowCandidate* output,
    std::uint64_t candidate_count,
    SegmentWindowKind kind) {
    for (std::uint64_t i = 0; i < candidate_count; i++) {
        if (output[i].kind == kind) return true;
    }
    return false;
}

static void test_personal_record_window_lengths() {
    // 12 km constant-pace route: mile, 5 km, and 10 km fit; half and full do not.
    const auto samples = make_constant_pace_samples(12'000.0, 100.0);
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 100'000;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "12 km route → success");

    expect(has_candidate(output, summary.candidate_count,
                          SegmentWindowKind::fastest_one_mile),
            "12 km route → one-mile record attempted");
    expect(has_candidate(output, summary.candidate_count,
                          SegmentWindowKind::fastest_5km),
            "12 km route → 5 km record attempted");
    expect(has_candidate(output, summary.candidate_count,
                          SegmentWindowKind::fastest_10km),
            "12 km route → 10 km record attempted");
    expect(!has_candidate(output, summary.candidate_count,
                           SegmentWindowKind::fastest_half_marathon),
            "12 km route → half marathon not attempted");
    expect(!has_candidate(output, summary.candidate_count,
                           SegmentWindowKind::fastest_marathon),
            "12 km route → marathon not attempted");

    for (std::uint64_t i = 0; i < summary.candidate_count; i++) {
        const double length = output[i].end_distance_meters -
                              output[i].start_distance_meters;
        bool sample_aligned_window = true;
        switch (output[i].kind) {
        case SegmentWindowKind::fastest_one_mile:
            sample_aligned_window = false;
            expect(length == personal_record_one_mile_meters,
                    "one-mile window covers exactly 1'609.344 m");
            break;
        case SegmentWindowKind::fastest_5km:
            expect(length == personal_record_five_km_meters,
                    "5 km window covers exactly 5'000 m");
            break;
        case SegmentWindowKind::fastest_10km:
            expect(length == personal_record_ten_km_meters,
                    "10 km window covers exactly 10'000 m");
            break;
        default:
            break;
        }
        // Windows whose boundaries land exactly on samples have exactly
        // constant pace, so the first window at the route start wins ties.
        // Interpolated boundaries (the mile here) can differ by ULP noise.
        if (sample_aligned_window) {
            expect(output[i].start_distance_meters == samples.front().distance_meters,
                    "sample-aligned window preserves first-winner tie at start");
        }
        expect(std::abs(output[i].selection_value - 300.0) < 1e-9,
                "constant-pace record value is 300 s/km");
    }

    // Canonical order: raw kind values strictly ascend in emission order.
    for (std::uint64_t i = 1; i < summary.candidate_count; i++) {
        expect(static_cast<std::uint8_t>(output[i].kind) >
                   static_cast<std::uint8_t>(output[i - 1].kind),
                "candidates emit in canonical kind order");
    }
}

static void test_window_longer_than_route_is_not_attempted() {
    // 4 km route: the mile fits, everything longer is not attempted. An
    // unattempted record must be absent, never a zero-valued placeholder.
    const auto samples = make_constant_pace_samples(4'000.0, 100.0);
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 100'000;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "4 km route → success");
    expect(has_candidate(output, summary.candidate_count,
                          SegmentWindowKind::fastest_one_mile),
            "4 km route → one-mile record attempted");
    expect(!has_candidate(output, summary.candidate_count,
                           SegmentWindowKind::fastest_5km),
            "4 km route → 5 km record not attempted");
    expect(!has_candidate(output, summary.candidate_count,
                           SegmentWindowKind::fastest_10km),
            "4 km route → 10 km record not attempted");
    expect(!has_candidate(output, summary.candidate_count,
                           SegmentWindowKind::fastest_half_marathon),
            "4 km route → half marathon not attempted");
    expect(!has_candidate(output, summary.candidate_count,
                           SegmentWindowKind::fastest_marathon),
            "4 km route → marathon not attempted");

    for (std::uint64_t i = 0; i < summary.candidate_count; i++) {
        expect(output[i].selection_value > 0.0,
                "no zero-valued placeholder candidates");
    }
}

static void test_exact_length_route_yields_whole_run_window() {
    // A route of exactly marathon length has zero spare distance, so the
    // marathon search evaluates exactly one window: the whole run.
    const auto samples = make_constant_pace_samples(personal_record_marathon_meters,
                                                     personal_record_marathon_meters / 2);
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 100'000;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "exact marathon route → success");

    bool found_marathon = false;
    for (std::uint64_t i = 0; i < summary.candidate_count; i++) {
        if (output[i].kind == SegmentWindowKind::fastest_marathon) {
            found_marathon = true;
            expect(output[i].start_distance_meters == 0.0,
                    "exact-length marathon window starts at the route start");
            expect(output[i].end_distance_meters == personal_record_marathon_meters,
                    "exact-length marathon window ends at the route end");
            expect(std::abs(output[i].selection_value - 300.0) < 1e-9,
                    "exact-length marathon pace is 300 s/km");
        }
    }
    expect(found_marathon, "exact marathon route → marathon record attempted");
}

static void test_marathon_window_spanning_pause_uses_active_time() {
    // Marathon-length route with a 500 s pause at the halfway plateau. The
    // marathon window spans the pause in cumulative distance; its pace must
    // use the active clock, which holds during the pause.
    std::array<SegmentDetectionSample, 4> samples = {{
        {0, 0, 0, 0, 0, 0, 0, -1},
        {21'097.5, 5'274.375, 5'274.375, 0, 0, 0, 0, -1},
        {21'097.5, 5'774.375, 5'274.375, 0, 0, 0, 1, -1},
        {42'195.0, 11'023.125, 10'548.75, 0, 0, 0, 1, -1},
    }};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 100'000;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success,
            "paused marathon route → success");

    bool found_marathon = false;
    for (std::uint64_t i = 0; i < summary.candidate_count; i++) {
        if (output[i].kind == SegmentWindowKind::fastest_marathon) {
            found_marathon = true;
            expect(output[i].start_distance_meters == 0.0,
                    "marathon window spans from the route start");
            expect(output[i].end_distance_meters == personal_record_marathon_meters,
                    "marathon window ends at the route end");
            expect(std::abs(output[i].selection_value - 250.0) < 1e-6,
                    "marathon pace excludes the 500 s pause (250 s/km)");
        }
    }
    expect(found_marathon, "paused marathon route → marathon record attempted");
}

static void test_invalid_config_personal_record_windows() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};

    {
        SegmentDetectionConfiguration config{};
        config.maximum_evaluations_per_search = 1000;
        config.one_mile_distance_meters =
            std::numeric_limits<double>::quiet_NaN();
        const auto summary = detect_segment_windows(
            &sample, 1, config, output, std::size(output));
        expect(summary.status == SegmentDetectionStatus::invalid_configuration,
                "NaN one-mile distance → invalid_config");
    }
    {
        SegmentDetectionConfiguration config{};
        config.maximum_evaluations_per_search = 1000;
        config.five_kilometer_step_meters = 0;
        const auto summary = detect_segment_windows(
            &sample, 1, config, output, std::size(output));
        expect(summary.status == SegmentDetectionStatus::invalid_configuration,
                "zero 5 km step → invalid_config");
    }
    {
        SegmentDetectionConfiguration config{};
        config.maximum_evaluations_per_search = 1000;
        config.marathon_distance_meters = -42'195;
        const auto summary = detect_segment_windows(
            &sample, 1, config, output, std::size(output));
        expect(summary.status == SegmentDetectionStatus::invalid_configuration,
                "negative marathon distance → invalid_config");
    }
}

// ---------------------------------------------------------------------------
// Elevation tests
// ---------------------------------------------------------------------------

static void test_biggest_climb() {
    // Route with increasing cumulative ascent
    std::array<SegmentDetectionSample, 5> samples = {{
        {0, 0, 0, 0, 0, 0, 0, 0},
        {250, 60, 60, 10, 0, 1, 0, 0},
        {500, 120, 120, 20, 0, 2, 0, 0},
        {750, 180, 180, 30, 0, 3, 0, 0},
        {1000, 240, 240, 50, 0, 4, 0, 0},
    }};

    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 50;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.elevation_window_distance_meters = 500;
    config.elevation_step_meters = 250;
    config.elevation_enabled = 1;
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success, "climb → success");

    bool found_climb = false;
    for (uint64_t i = 0; i < summary.candidate_count; i++) {
        if (output[i].kind == SegmentWindowKind::biggest_climb) {
            found_climb = true;
            expect(output[i].selection_value > 0, "climb value positive");
        }
    }
    expect(found_climb, "found biggest climb");
}

static void test_flat_route_no_elevation() {
    // Flat route - no meaningful elevation, disabled
    std::array<SegmentDetectionSample, 5> samples = {{
        {0, 0, 0, 0, 0, 0, 0, -1},
        {250, 60, 60, 0, 0, 0, 0, -1},
        {500, 120, 120, 0, 0, 0, 0, -1},
        {750, 180, 180, 0, 0, 0, 0, -1},
        {1000, 240, 240, 0, 0, 0, 0, -1},
    }};

    SegmentWindowCandidate output[segment_detection_max_candidate_count] = {};
    SegmentDetectionConfiguration config{};
    config.elevation_enabled = 0; // explicitly disabled
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples.data(), samples.size(), config, output, std::size(output));
    expect(summary.status == SegmentDetectionStatus::success, "flat → success");
    expect(summary.elevation_window_evaluation_count == 0, "flat → zero elevation evals");
}

// ---------------------------------------------------------------------------
// Run all
// ---------------------------------------------------------------------------

}  // namespace

void run_segment_detection_tests() {
    test_compile_time();
    test_empty_input();
    test_one_sample();
    test_null_nonempty_input();
    test_null_output();
    test_insufficient_output_capacity();
    test_output_unchanged_on_error();
    test_invalid_config_nan_distance();
    test_invalid_config_zero_distance();
    test_invalid_config_inverted_pace();
    test_invalid_elevation_enabled_byte();
    test_nonfinite_distance();
    test_decreasing_distance();
    test_decreasing_elapsed();
    test_continuity_group_not_zero();
    test_first_active_time_cannot_exceed_elapsed_time();
    test_first_reliable_run_must_be_zero_based();
    test_reliable_run_cannot_cross_continuity_group();
    test_constant_pace_route();
    test_pause_spanning_active_time();
    test_same_segment_distance_plateau_uses_first_arrival();
    test_pause_plateau_uses_inner_segment_boundaries();
    test_each_search_has_its_own_evaluation_budget();
    test_finite_evaluation_quotient_beyond_uint64_is_resource_limited();
    test_pace_uses_rounded_window_boundary_distance();
    test_personal_record_window_lengths();
    test_window_longer_than_route_is_not_attempted();
    test_exact_length_route_yields_whole_run_window();
    test_marathon_window_spanning_pause_uses_active_time();
    test_invalid_config_personal_record_windows();
    test_biggest_climb();
    test_flat_route_no_elevation();
}
