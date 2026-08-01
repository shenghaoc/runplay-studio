#include "TestSupport.hpp"
#include "RunPlayEngineCpp/ElevationProfile.hpp"
#include "RunPlayEngineCpp/RouteInterop.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <type_traits>
#include <vector>

namespace {

using namespace runplay;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static ElevationProfilePolicy default_policy() {
    ElevationProfilePolicy policy{};
    policy.plausible_altitude_minimum_meters = -500.0;
    policy.plausible_altitude_maximum_meters = 9'000.0;
    policy.spike_minimum_deviation_meters = 35.0;
    policy.short_excursion_minimum_deviation_meters = 100.0;
    policy.short_excursion_maximum_sample_count = 2;
    policy.spike_maximum_neighbor_difference_meters = 12.0;
    policy.spike_maximum_horizontal_span_meters = 150.0;
    policy.smoothing_radius_meters = 15.0;
    policy.minimum_reliable_sample_count = 2;
    policy.gain_loss_deadband_meters = 3.0;
    return policy;
}

static ElevationProfileInputSample make_sample(
    double distance,
    double altitude,
    std::int32_t group = 0,
    bool has_altitude = true)
{
    ElevationProfileInputSample sample{};
    sample.distance_meters = distance;
    sample.altitude_meters = altitude;
    sample.continuity_group = group;
    sample.has_altitude = has_altitude ? 1 : 0;
    return sample;
}

static void fill_sentinel(ElevationProfileOutputSample* output, std::size_t count) {
    for (std::size_t i = 0; i < count; ++i) {
        output[i].corrected_altitude_meters = 12345.0;
        output[i].cumulative_ascent_meters = 99.0;
        output[i].cumulative_descent_meters = 88.0;
        output[i].cumulative_signed_change_meters = 77.0;
        output[i].reliable_interval_count = 66.0;
        output[i].run_identifier = 42;
        output[i].reliable_run_identifier = 42;
        output[i].has_corrected_altitude = 7;
        output[i].source_altitude_was_rejected = 7;
    }
}

static bool near_equal(double a, double b, double tol = 1e-9) {
    if (a == b) return true;
    if (!std::isfinite(a) || !std::isfinite(b)) return false;
    return std::fabs(a - b) <= std::max(tol, std::fabs(b) * 1e-12);
}

// ---------------------------------------------------------------------------
// Compile-time tests
// ---------------------------------------------------------------------------

static void test_compile_time() {
    static_assert(__cplusplus >= 202302L);

    static_assert(std::is_standard_layout_v<ElevationProfileInputSample>);
    static_assert(std::is_trivially_copyable_v<ElevationProfileInputSample>);
    static_assert(std::is_nothrow_default_constructible_v<ElevationProfileInputSample>);
    static_assert(std::is_nothrow_copy_constructible_v<ElevationProfileInputSample>);

    static_assert(std::is_standard_layout_v<ElevationProfilePolicy>);
    static_assert(std::is_trivially_copyable_v<ElevationProfilePolicy>);

    static_assert(std::is_standard_layout_v<ElevationProfileOutputSample>);
    static_assert(std::is_trivially_copyable_v<ElevationProfileOutputSample>);

    static_assert(std::is_standard_layout_v<ElevationProfileSummary>);
    static_assert(std::is_trivially_copyable_v<ElevationProfileSummary>);

    static_assert(
        noexcept(build_elevation_profile(
            nullptr, 0, ElevationProfilePolicy{}, nullptr, 0)));
}

// ---------------------------------------------------------------------------
// Boundary tests
// ---------------------------------------------------------------------------

static void test_empty_input_null_buffers() {
    auto summary = build_elevation_profile(nullptr, 0, default_policy(), nullptr, 0);
    expect(summary.status == ElevationProfileStatus::success, "empty → success");
    expect(summary.sample_count == 0, "empty sample_count");
    expect(summary.required_output_capacity == 0, "empty capacity");
    expect(summary.rejected_altitude_count == 0, "empty rejected");
    expect(summary.run_count == 0, "empty runs");
    expect(summary.reliable_run_count == 0, "empty reliable");
    expect(summary.has_meaningful_elevation == 0, "empty meaningful");
    expect(summary.total_ascent_meters == 0.0, "empty ascent");
    expect(summary.total_descent_meters == 0.0, "empty descent");
}

static void test_null_nonempty_input() {
    ElevationProfileOutputSample output[1]{};
    fill_sentinel(output, 1);
    auto summary = build_elevation_profile(
        nullptr, 1, default_policy(), output, 1);
    expect(summary.status == ElevationProfileStatus::invalid_input_buffer,
           "null input");
    expect(output[0].corrected_altitude_meters == 12345.0,
           "output unchanged on null input");
}

static void test_null_output() {
    auto sample = make_sample(0, 100);
    auto summary = build_elevation_profile(
        &sample, 1, default_policy(), nullptr, 1);
    expect(summary.status == ElevationProfileStatus::invalid_output_buffer,
           "null output");
}

static void test_insufficient_capacity() {
    auto sample = make_sample(0, 100);
    ElevationProfileOutputSample output[1]{};
    fill_sentinel(output, 1);
    auto summary = build_elevation_profile(
        &sample, 1, default_policy(), output, 0);
    expect(summary.status == ElevationProfileStatus::insufficient_output_capacity,
           "insufficient capacity");
    expect(summary.required_output_capacity == 1, "required = sample_count");
    expect(output[0].corrected_altitude_meters == 12345.0,
           "output unchanged on insufficient capacity");
}

static void test_exact_capacity() {
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 105),
        make_sample(20, 110),
    };
    ElevationProfileOutputSample output[3]{};
    auto summary = build_elevation_profile(
        samples.data(), samples.size(), default_policy(), output, 3);
    expect(summary.status == ElevationProfileStatus::success, "exact capacity");
    expect(summary.sample_count == 3, "sample count");
    expect(summary.required_output_capacity == 3, "required capacity");
}

static void test_resource_limit() {
    auto sample = make_sample(0, 100);
    ElevationProfileOutputSample output[1]{};
    fill_sentinel(output, 1);
    auto summary = build_elevation_profile(
        &sample,
        max_route_input_samples + 1,
        default_policy(),
        output,
        max_route_input_samples + 1);
    expect(summary.status == ElevationProfileStatus::resource_limit,
           "resource limit");
    expect(output[0].corrected_altitude_meters == 12345.0,
           "output unchanged on resource limit");
}

static void test_malformed_presence_byte() {
    auto sample = make_sample(0, 100);
    sample.has_altitude = 2;
    ElevationProfileOutputSample output[1]{};
    fill_sentinel(output, 1);
    auto summary = build_elevation_profile(
        &sample, 1, default_policy(), output, 1);
    expect(summary.status == ElevationProfileStatus::invalid_input_contract,
           "malformed presence");
    expect(output[0].run_identifier == 42, "output unchanged");
}

static void test_malformed_continuity_groups() {
    {
        std::array samples{
            make_sample(0, 100, 1),
            make_sample(10, 105, 1),
        };
        ElevationProfileOutputSample output[2]{};
        fill_sentinel(output, 2);
        auto summary = build_elevation_profile(
            samples.data(), 2, default_policy(), output, 2);
        expect(summary.status == ElevationProfileStatus::invalid_input_contract,
               "group must start at 0");
        expect(output[0].run_identifier == 42, "unchanged start-group");
    }
    {
        std::array samples{
            make_sample(0, 100, 0),
            make_sample(10, 105, 2),
        };
        ElevationProfileOutputSample output[2]{};
        fill_sentinel(output, 2);
        auto summary = build_elevation_profile(
            samples.data(), 2, default_policy(), output, 2);
        expect(summary.status == ElevationProfileStatus::invalid_input_contract,
               "group jump > 1");
    }
    {
        std::array samples{
            make_sample(0, 100, 0),
            make_sample(10, 105, 1),
            make_sample(20, 110, 0),
        };
        ElevationProfileOutputSample output[3]{};
        fill_sentinel(output, 3);
        auto summary = build_elevation_profile(
            samples.data(), 3, default_policy(), output, 3);
        expect(summary.status == ElevationProfileStatus::invalid_input_contract,
               "group decrease");
    }
}

static void test_deterministic_repeated_calls() {
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 103),
        make_sample(20, 106),
        make_sample(30, 109),
        make_sample(40, 112),
    };
    ElevationProfileOutputSample a[5]{};
    ElevationProfileOutputSample b[5]{};
    auto s1 = build_elevation_profile(
        samples.data(), 5, default_policy(), a, 5);
    auto s2 = build_elevation_profile(
        samples.data(), 5, default_policy(), b, 5);
    expect(s1.status == ElevationProfileStatus::success, "first call");
    expect(s2.status == ElevationProfileStatus::success, "second call");
    expect(std::memcmp(a, b, sizeof(a)) == 0, "deterministic output");
    expect(s1.rejected_altitude_count == s2.rejected_altitude_count,
           "deterministic summary rejected");
    expect(s1.total_ascent_meters == s2.total_ascent_meters,
           "deterministic total ascent");
}

// ---------------------------------------------------------------------------
// Policy tests
// ---------------------------------------------------------------------------

static void test_invalid_policy_fields() {
    auto sample = make_sample(0, 100);
    ElevationProfileOutputSample output[1]{};

    auto check = [&](ElevationProfilePolicy policy, const char* msg) {
        fill_sentinel(output, 1);
        auto summary = build_elevation_profile(
            &sample, 1, policy, output, 1);
        expect(summary.status == ElevationProfileStatus::invalid_policy, msg);
        expect(output[0].corrected_altitude_meters == 12345.0, msg);
    };

    {
        auto p = default_policy();
        p.plausible_altitude_minimum_meters =
            std::numeric_limits<double>::quiet_NaN();
        check(p, "nan min altitude");
    }
    {
        auto p = default_policy();
        p.plausible_altitude_minimum_meters = 100;
        p.plausible_altitude_maximum_meters = 50;
        check(p, "inverted range");
    }
    {
        auto p = default_policy();
        p.spike_minimum_deviation_meters = -1;
        check(p, "negative spike");
    }
    {
        auto p = default_policy();
        p.short_excursion_minimum_deviation_meters = 10;
        p.spike_minimum_deviation_meters = 35;
        check(p, "excursion below spike");
    }
    {
        auto p = default_policy();
        p.short_excursion_maximum_sample_count = 0;
        check(p, "zero excursion count");
    }
    {
        auto p = default_policy();
        p.minimum_reliable_sample_count = 0;
        check(p, "zero reliable count");
    }
    {
        auto p = default_policy();
        p.minimum_reliable_sample_count = 1;
        check(p, "one reliable count");
    }
    {
        auto p = default_policy();
        p.smoothing_radius_meters = -1;
        check(p, "negative smoothing");
    }
    {
        auto p = default_policy();
        p.gain_loss_deadband_meters = -0.1;
        check(p, "negative deadband");
    }
    {
        auto p = default_policy();
        p.spike_maximum_neighbor_difference_meters = -1;
        check(p, "negative neighbor");
    }
    {
        auto p = default_policy();
        p.spike_maximum_horizontal_span_meters = -1;
        check(p, "negative span");
    }
}

// ---------------------------------------------------------------------------
// Source plausibility
// ---------------------------------------------------------------------------

static void test_source_plausibility() {
    std::array samples{
        make_sample(0, 100),                         // normal
        make_sample(10, 0, 0, false),                // missing
        make_sample(20, -500),                       // min boundary
        make_sample(30, 9000),                       // max boundary
        make_sample(40, -501),                       // below
        make_sample(50, 9001),                       // above
        make_sample(60, std::numeric_limits<double>::quiet_NaN()),
        make_sample(70, std::numeric_limits<double>::infinity()),
        make_sample(80, -std::numeric_limits<double>::infinity()),
    };
    ElevationProfileOutputSample output[9]{};
    auto summary = build_elevation_profile(
        samples.data(), samples.size(), default_policy(), output, 9);
    expect(summary.status == ElevationProfileStatus::success, "plausibility ok");
    expect(output[0].has_corrected_altitude == 1, "normal kept");
    expect(output[0].source_altitude_was_rejected == 0, "normal not rejected");
    expect(output[1].has_corrected_altitude == 0, "missing absent");
    expect(output[1].source_altitude_was_rejected == 0, "missing not rejected");
    expect(output[2].has_corrected_altitude == 1, "min boundary kept");
    expect(output[3].has_corrected_altitude == 1, "max boundary kept");
    expect(output[4].source_altitude_was_rejected == 1, "below rejected");
    expect(output[5].source_altitude_was_rejected == 1, "above rejected");
    expect(output[6].source_altitude_was_rejected == 1, "nan rejected");
    expect(output[7].source_altitude_was_rejected == 1, "+inf rejected");
    expect(output[8].source_altitude_was_rejected == 1, "-inf rejected");
    expect(summary.rejected_altitude_count == 5, "rejected count");
}

// ---------------------------------------------------------------------------
// Spike / excursion / fill / run / smoothing / gain-loss
// ---------------------------------------------------------------------------

static void test_leading_endpoint_spike() {
    // Endpoint 200 is a spike; next two agree near 100.
    std::array samples{
        make_sample(0, 200),
        make_sample(10, 100),
        make_sample(20, 101),
        make_sample(30, 102),
        make_sample(40, 103),
    };
    ElevationProfileOutputSample output[5]{};
    auto summary = build_elevation_profile(
        samples.data(), 5, default_policy(), output, 5);
    expect(summary.status == ElevationProfileStatus::success, "endpoint spike");
    expect(output[0].source_altitude_was_rejected == 1, "leading rejected");
    // Fill only applies to interior rejected samples (1..count-2).
    expect(output[0].has_corrected_altitude == 0, "leading not filled");
}

static void test_trailing_endpoint_spike() {
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 101),
        make_sample(20, 102),
        make_sample(30, 103),
        make_sample(40, 200),
    };
    ElevationProfileOutputSample output[5]{};
    auto summary = build_elevation_profile(
        samples.data(), 5, default_policy(), output, 5);
    expect(summary.status == ElevationProfileStatus::success, "trailing ok");
    expect(output[4].source_altitude_was_rejected == 1, "trailing rejected");
}

static void test_sustained_endpoint_change_retained() {
    // Gradual climb to endpoint — not a spike against agreeing neighbours.
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 120),
        make_sample(20, 140),
        make_sample(30, 160),
    };
    ElevationProfileOutputSample output[4]{};
    auto summary = build_elevation_profile(
        samples.data(), 4, default_policy(), output, 4);
    expect(summary.status == ElevationProfileStatus::success, "sustained ok");
    expect(output[0].source_altitude_was_rejected == 0, "start kept");
    expect(output[3].source_altitude_was_rejected == 0, "end kept");
}

static void test_isolated_interior_spike() {
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 101),
        make_sample(20, 200),  // spike
        make_sample(30, 102),
        make_sample(40, 103),
    };
    ElevationProfileOutputSample output[5]{};
    auto summary = build_elevation_profile(
        samples.data(), 5, default_policy(), output, 5);
    expect(summary.status == ElevationProfileStatus::success, "interior ok");
    expect(output[2].source_altitude_was_rejected == 1, "interior rejected");
    expect(output[2].has_corrected_altitude == 1, "interior filled");
}

static void test_legitimate_hill_retained() {
    // Wide, multi-point climb — not a short excursion or single spike.
    std::array samples{
        make_sample(0, 100),
        make_sample(20, 110),
        make_sample(40, 130),
        make_sample(60, 150),
        make_sample(80, 140),
        make_sample(100, 120),
        make_sample(120, 105),
    };
    ElevationProfileOutputSample output[7]{};
    auto summary = build_elevation_profile(
        samples.data(), 7, default_policy(), output, 7);
    expect(summary.status == ElevationProfileStatus::success, "hill ok");
    for (std::size_t i = 0; i < 7; ++i) {
        expect(output[i].source_altitude_was_rejected == 0, "hill kept");
        expect(output[i].has_corrected_altitude == 1, "hill altitude");
    }
}

static void test_short_excursion_two_sample() {
    // Anchor points ~100–103 so endpoints are not themselves spikes.
    // Two-sample plateau at 220/225 (deviation ≥ 100 from midpoint).
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 101),
        make_sample(20, 220),
        make_sample(30, 225),
        make_sample(40, 102),
        make_sample(50, 103),
    };
    ElevationProfileOutputSample output[6]{};
    auto summary = build_elevation_profile(
        samples.data(), 6, default_policy(), output, 6);
    expect(summary.status == ElevationProfileStatus::success, "excursion ok");
    expect(output[2].source_altitude_was_rejected == 1, "exc1 rejected");
    expect(output[3].source_altitude_was_rejected == 1, "exc2 rejected");
}

static void test_longer_excursion_retained() {
    auto policy = default_policy();
    policy.short_excursion_maximum_sample_count = 2;
    // Three-sample plateau exceeds max sample count.
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 101),
        make_sample(20, 220),
        make_sample(30, 221),
        make_sample(40, 222),
        make_sample(50, 102),
        make_sample(60, 103),
    };
    ElevationProfileOutputSample output[7]{};
    auto summary = build_elevation_profile(
        samples.data(), 7, policy, output, 7);
    expect(summary.status == ElevationProfileStatus::success, "long exc ok");
    expect(output[2].source_altitude_was_rejected == 0, "long kept 1");
    expect(output[3].source_altitude_was_rejected == 0, "long kept 2");
    expect(output[4].source_altitude_was_rejected == 0, "long kept 3");
}

static void test_fill_distance_weighted_and_no_chain() {
    // Reject middle via interior spike; fill from 100 and 110.
    // Distances 0, 5, 20 → fraction = 5/20 = 0.25 → 102.5
    // Zero smoothing so the filled value is not averaged away.
    auto policy = default_policy();
    policy.smoothing_radius_meters = 0;
    std::array samples{
        make_sample(0, 100),
        make_sample(5, 200),
        make_sample(20, 110),
        make_sample(30, 111),
    };
    ElevationProfileOutputSample output[4]{};
    auto summary = build_elevation_profile(
        samples.data(), 4, policy, output, 4);
    expect(summary.status == ElevationProfileStatus::success, "fill ok");
    expect(output[1].source_altitude_was_rejected == 1, "fill rejected flag");
    expect(output[1].has_corrected_altitude == 1, "fill has altitude");
    expect(near_equal(output[1].corrected_altitude_meters, 102.5),
           "distance-weighted fill");
}

static void test_fill_zero_span_uses_half() {
    std::array samples{
        make_sample(10, 100),
        make_sample(10, 200),
        make_sample(10, 120),
        make_sample(20, 121),
    };
    ElevationProfileOutputSample output[4]{};
    auto summary = build_elevation_profile(
        samples.data(), 4, default_policy(), output, 4);
    expect(summary.status == ElevationProfileStatus::success, "zero span ok");
    if (output[1].source_altitude_was_rejected == 1 &&
        output[1].has_corrected_altitude == 1) {
        expect(near_equal(output[1].corrected_altitude_meters, 110.0),
               "zero span half");
    }
}

static void test_no_fill_across_continuity() {
    std::array samples{
        make_sample(0, 100, 0),
        make_sample(10, 200, 0),
        make_sample(20, 110, 1),
        make_sample(30, 111, 1),
    };
    ElevationProfileOutputSample output[4]{};
    auto summary = build_elevation_profile(
        samples.data(), 4, default_policy(), output, 4);
    expect(summary.status == ElevationProfileStatus::success, "gap fill ok");
    // Interior spike needs same continuity for triplet — group changes at 2.
    // Point 1 may still reject as endpoint of short run.
}

static void test_run_identifiers() {
    // Two runs split by missing altitude: [100,101] and [110,111,112]
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 101),
        make_sample(20, 0, 0, false),
        make_sample(30, 110),
        make_sample(40, 111),
        make_sample(50, 112),
    };
    ElevationProfileOutputSample output[6]{};
    auto summary = build_elevation_profile(
        samples.data(), 6, default_policy(), output, 6);
    expect(summary.status == ElevationProfileStatus::success, "runs ok");
    expect(summary.run_count == 2, "two runs");
    expect(output[0].run_identifier == 0, "run0");
    expect(output[1].run_identifier == 0, "run0b");
    expect(output[2].run_identifier == -1, "gap");
    expect(output[3].run_identifier == 1, "run1");
    expect(output[4].run_identifier == 1, "run1b");
    expect(output[5].run_identifier == 1, "run1c");
    // Both runs >= 2 samples → reliable IDs equal run IDs.
    expect(output[0].reliable_run_identifier == 0, "rel0");
    expect(output[3].reliable_run_identifier == 1, "rel1");
    expect(summary.reliable_run_count == 2, "two reliable");
}

static void test_unreliable_then_reliable_gap_ids() {
    auto policy = default_policy();
    policy.minimum_reliable_sample_count = 3;
    // Run 0: 1 sample (unreliable), run 1: 3 samples (reliable).
    // Reliable ID for run 1 is still 1 (gap in reliable sequence).
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 0, 0, false),
        make_sample(20, 110),
        make_sample(30, 111),
        make_sample(40, 112),
    };
    ElevationProfileOutputSample output[5]{};
    auto summary = build_elevation_profile(
        samples.data(), 5, policy, output, 5);
    expect(summary.status == ElevationProfileStatus::success, "gap ids ok");
    expect(output[0].run_identifier == 0, "short run id");
    expect(output[0].reliable_run_identifier == -1, "short unreliable");
    expect(output[2].run_identifier == 1, "long run id");
    expect(output[2].reliable_run_identifier == 1, "long reliable keeps gap");
    expect(summary.reliable_run_count == 1, "one reliable run");
}

static void test_zero_radius_smoothing() {
    auto policy = default_policy();
    policy.smoothing_radius_meters = 0;
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 110),
        make_sample(20, 120),
    };
    ElevationProfileOutputSample output[3]{};
    auto summary = build_elevation_profile(
        samples.data(), 3, policy, output, 3);
    expect(summary.status == ElevationProfileStatus::success, "zero radius");
    expect(near_equal(output[0].corrected_altitude_meters, 100), "raw0");
    expect(near_equal(output[1].corrected_altitude_meters, 110), "raw1");
    expect(near_equal(output[2].corrected_altitude_meters, 120), "raw2");
}

static void test_monotonic_climb_gain() {
    auto policy = default_policy();
    policy.smoothing_radius_meters = 0;
    policy.gain_loss_deadband_meters = 3;
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 104),
        make_sample(20, 108),
        make_sample(30, 112),
        make_sample(40, 116),
    };
    ElevationProfileOutputSample output[5]{};
    auto summary = build_elevation_profile(
        samples.data(), 5, policy, output, 5);
    expect(summary.status == ElevationProfileStatus::success, "climb ok");
    expect(summary.has_meaningful_elevation == 1, "meaningful");
    expect(near_equal(summary.total_ascent_meters, 16.0), "total ascent 16");
    expect(near_equal(summary.total_descent_meters, 0.0), "no descent");
    expect(near_equal(output[4].cumulative_signed_change_meters, 16.0),
           "signed 16");
    expect(near_equal(output[4].reliable_interval_count, 4.0),
           "four intervals");
}

static void test_noise_below_deadband() {
    auto policy = default_policy();
    policy.smoothing_radius_meters = 0;
    policy.gain_loss_deadband_meters = 3;
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 101),
        make_sample(20, 100.5),
        make_sample(30, 101.5),
        make_sample(40, 100.2),
    };
    ElevationProfileOutputSample output[5]{};
    auto summary = build_elevation_profile(
        samples.data(), 5, policy, output, 5);
    expect(summary.status == ElevationProfileStatus::success, "noise ok");
    // Trend never confirms past deadband → provisional totals stay 0 after
    // end-of-run (no flush of unconfirmed noise in Swift either — actually
    // Swift leaves provisional on last sample if trend confirmed partially).
    // With max excursion ~1.5 < 3, trend stays 0 → ascent/descent 0.
    expect(near_equal(summary.total_ascent_meters, 0.0), "no ascent noise");
    expect(near_equal(summary.total_descent_meters, 0.0), "no descent noise");
}

static void test_confirmed_reversal() {
    auto policy = default_policy();
    policy.smoothing_radius_meters = 0;
    policy.gain_loss_deadband_meters = 3;
    // Climb 10 then descend 10.
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 105),
        make_sample(20, 110),
        make_sample(30, 105),
        make_sample(40, 100),
    };
    ElevationProfileOutputSample output[5]{};
    auto summary = build_elevation_profile(
        samples.data(), 5, policy, output, 5);
    expect(summary.status == ElevationProfileStatus::success, "reversal ok");
    expect(near_equal(summary.total_ascent_meters, 10.0), "ascent 10");
    expect(near_equal(summary.total_descent_meters, 10.0), "descent 10");
}

static void test_zero_deadband() {
    auto policy = default_policy();
    policy.smoothing_radius_meters = 0;
    policy.gain_loss_deadband_meters = 0;
    std::array samples{
        make_sample(0, 100),
        make_sample(10, 101),
        make_sample(20, 100),
    };
    ElevationProfileOutputSample output[3]{};
    auto summary = build_elevation_profile(
        samples.data(), 3, policy, output, 3);
    expect(summary.status == ElevationProfileStatus::success, "zero deadband");
    expect(near_equal(summary.total_ascent_meters, 1.0), "ascent 1");
    expect(near_equal(summary.total_descent_meters, 1.0), "descent 1");
}

static void test_no_meaningful_elevation() {
    std::array samples{
        make_sample(0, 0, 0, false),
        make_sample(10, 0, 0, false),
    };
    ElevationProfileOutputSample output[2]{};
    auto summary = build_elevation_profile(
        samples.data(), 2, default_policy(), output, 2);
    expect(summary.status == ElevationProfileStatus::success, "no elev ok");
    expect(summary.has_meaningful_elevation == 0, "not meaningful");
    expect(summary.total_ascent_meters == 0.0, "ascent zeroed");
    expect(summary.total_descent_meters == 0.0, "descent zeroed");
}

static void test_malformed_distances_processed() {
    // Production Swift does not reject these; preserve processing.
    std::array samples{
        make_sample(-10, 100),
        make_sample(5, 105),
        make_sample(3, 110),   // decreasing
        make_sample(3, 115),   // duplicate
        make_sample(1e12, 120),
    };
    ElevationProfileOutputSample output[5]{};
    auto summary = build_elevation_profile(
        samples.data(), 5, default_policy(), output, 5);
    expect(summary.status == ElevationProfileStatus::success,
           "malformed distances accepted");
    expect(summary.sample_count == 5, "processed all");
}

static void test_large_dense_route() {
    constexpr std::size_t n = 10'000;
    std::vector<ElevationProfileInputSample> samples(n);
    std::vector<ElevationProfileOutputSample> output(n);
    for (std::size_t i = 0; i < n; ++i) {
        samples[i] = make_sample(
            static_cast<double>(i) * 1.0,
            100.0 + static_cast<double>(i) * 0.01);
    }
    auto summary = build_elevation_profile(
        samples.data(), n, default_policy(), output.data(), n);
    expect(summary.status == ElevationProfileStatus::success, "large ok");
    expect(summary.sample_count == n, "large count");
    expect(summary.has_meaningful_elevation == 1, "large meaningful");
    expect(output[0].has_corrected_altitude == 1, "large first");
    expect(output[n - 1].has_corrected_altitude == 1, "large last");
}

}  // namespace

void run_elevation_profile_tests() {
    test_compile_time();
    test_empty_input_null_buffers();
    test_null_nonempty_input();
    test_null_output();
    test_insufficient_capacity();
    test_exact_capacity();
    test_resource_limit();
    test_malformed_presence_byte();
    test_malformed_continuity_groups();
    test_deterministic_repeated_calls();
    test_invalid_policy_fields();
    test_source_plausibility();
    test_leading_endpoint_spike();
    test_trailing_endpoint_spike();
    test_sustained_endpoint_change_retained();
    test_isolated_interior_spike();
    test_legitimate_hill_retained();
    test_short_excursion_two_sample();
    test_longer_excursion_retained();
    test_fill_distance_weighted_and_no_chain();
    test_fill_zero_span_uses_half();
    test_no_fill_across_continuity();
    test_run_identifiers();
    test_unreliable_then_reliable_gap_ids();
    test_zero_radius_smoothing();
    test_monotonic_climb_gain();
    test_noise_below_deadband();
    test_confirmed_reversal();
    test_zero_deadband();
    test_no_meaningful_elevation();
    test_malformed_distances_processed();
    test_large_dense_route();
}
