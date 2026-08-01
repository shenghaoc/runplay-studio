#include "TestSupport.hpp"
#include "RunPlayEngineCpp/SegmentDetection.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

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
    SegmentWindowCandidate output[5] = {};
    auto summary = detect_segment_windows(nullptr, 0, {}, output, 5);

    expect(summary.status == SegmentDetectionStatus::success,
            "empty input → success");
    expect(summary.candidate_count == 0,
            "empty input → zero candidates");
    expect(summary.sample_count == 0,
            "empty input → zero sample count");
}

static void test_one_sample() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(&sample, 1, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::success,
            "one sample → success");
    expect(summary.candidate_count == 0,
            "one sample → zero candidates");
}

static void test_null_nonempty_input() {
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(nullptr, 1, config, output, 5);
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
    expect(summary.required_output_capacity == 5, "required = 5");
}

static void test_output_unchanged_on_error() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 0, -1},
        {1, 10, 10, 0, 0, 0, 0, -1},
    };
    SegmentWindowCandidate output[5] = {};
    output[0].kind = SegmentWindowKind::fastest_1km;
    output[0].start_distance_meters = 99.9;

    // Trigger error: no max_evaluations
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 0;

    auto summary = detect_segment_windows(samples, 2, config, output, 5);
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
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;
    config.fastest_400m_distance_meters = std::numeric_limits<double>::quiet_NaN();

    auto summary = detect_segment_windows(&sample, 1, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_configuration,
            "NaN distance → invalid_config");
}

static void test_invalid_config_zero_distance() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;
    config.fastest_400m_distance_meters = 0;

    auto summary = detect_segment_windows(&sample, 1, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_configuration,
            "zero distance → invalid_config");
}

static void test_invalid_config_inverted_pace() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;
    config.minimum_valid_pace_seconds_per_kilometer = 500;
    config.maximum_valid_pace_seconds_per_kilometer = 200;

    auto summary = detect_segment_windows(&sample, 1, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_configuration,
            "inverted pace → invalid_config");
}

static void test_invalid_elevation_enabled_byte() {
    SegmentDetectionSample sample{0, 0, 0, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;
    config.elevation_enabled = 2;

    auto summary = detect_segment_windows(&sample, 1, config, output, 5);
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
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples, 2, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "NaN distance → invalid_input_contract");
}

static void test_decreasing_distance() {
    SegmentDetectionSample samples[2] = {
        {100, 0, 0, 0, 0, 0, 0, -1},
        {50, 10, 10, 0, 0, 0, 0, -1},
    };
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples, 2, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "decreasing distance → invalid_input_contract");
}

static void test_decreasing_elapsed() {
    SegmentDetectionSample samples[2] = {
        {0, 100, 50, 0, 0, 0, 0, -1},
        {100, 50, 50, 0, 0, 0, 0, -1},
    };
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples, 2, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "decreasing elapsed → invalid_input_contract");
}

static void test_continuity_group_not_zero() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 1, -1},  // starts at 1!
        {100, 10, 10, 0, 0, 0, 1, -1},
    };
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples, 2, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "first continuity != 0 → invalid_input_contract");
}

static void test_first_active_time_cannot_exceed_elapsed_time() {
    SegmentDetectionSample sample{0, 0, 1, 0, 0, 0, 0, -1};
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    const auto summary = detect_segment_windows(&sample, 1, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "first active > elapsed → invalid_input_contract");
}

static void test_first_reliable_run_must_be_zero_based() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 0, 1},
        {100, 30, 30, 1, 0, 1, 0, 1},
    };
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    const auto summary = detect_segment_windows(samples, 2, config, output, 5);
    expect(summary.status == SegmentDetectionStatus::invalid_input_contract,
            "first reliable run 1 → invalid_input_contract");
}

static void test_reliable_run_cannot_cross_continuity_group() {
    SegmentDetectionSample samples[2] = {
        {0, 0, 0, 0, 0, 0, 0, 0},
        {100, 30, 30, 1, 0, 1, 1, 0},
    };
    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.maximum_evaluations_per_search = 1000;

    const auto summary = detect_segment_windows(samples, 2, config, output, 5);
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

    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 50;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 100;

    auto summary = detect_segment_windows(samples.data(), samples.size(), config, output, 5);
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

    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 50;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples.data(), samples.size(), config, output, 5);
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

    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 50;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 100;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, 5);
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

    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 500;
    config.fastest_400m_step_meters = 500;
    config.one_kilometer_distance_meters = 1500;
    config.one_kilometer_step_meters = 50;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 10;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, 5);
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

    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.fastest_400m_distance_meters = 400;
    config.fastest_400m_step_meters = 100;
    config.one_kilometer_distance_meters = 1000;
    config.one_kilometer_step_meters = 100;
    config.minimum_valid_pace_seconds_per_kilometer = 120;
    config.maximum_valid_pace_seconds_per_kilometer = 1200;
    config.maximum_evaluations_per_search = 20;

    const auto summary = detect_segment_windows(
        samples.data(), samples.size(), config, output, 5);
    expect(summary.status == SegmentDetectionStatus::success,
            "individually bounded searches → success");
    expect(summary.pace_window_evaluation_count == 28,
            "pace summary counts 17 400m + 11 combined 1km evaluations");
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

    SegmentWindowCandidate output[5] = {};
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

    auto summary = detect_segment_windows(samples.data(), samples.size(), config, output, 5);
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

    SegmentWindowCandidate output[5] = {};
    SegmentDetectionConfiguration config{};
    config.elevation_enabled = 0; // explicitly disabled
    config.maximum_evaluations_per_search = 1000;

    auto summary = detect_segment_windows(samples.data(), samples.size(), config, output, 5);
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
    test_biggest_climb();
    test_flat_route_no_elevation();
}
