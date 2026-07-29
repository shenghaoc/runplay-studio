#include "RunPlayEngineCpp/RunPlayEngine.hpp"
#include "TestSupport.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <type_traits>
#include <vector>

static_assert(
    noexcept(runplay::compute_route_step_distances(nullptr, 0, nullptr, 0)),
    "compute_route_step_distances must remain noexcept at the Swift boundary");
static_assert(std::is_standard_layout_v<runplay::RouteStepDistanceSummary>);
static_assert(std::is_trivially_copyable_v<runplay::RouteStepDistanceSummary>);
static_assert(
    std::is_nothrow_copy_constructible_v<runplay::RouteStepDistanceSummary>);

namespace {

using runplay::RouteInputSample;
using runplay::RouteStepDistanceStatus;
using runplay::RouteStepDistanceSummary;
using runplay::compute_route_step_distances;
using runplay::haversine_distance_meters;
using runplay::max_route_input_samples;

constexpr double quiet_nan = std::numeric_limits<double>::quiet_NaN();

[[nodiscard]]
RouteInputSample make_sample(
    std::uint64_t source_index,
    double latitude,
    double longitude,
    std::int64_t segment_index
) {
    return RouteInputSample{
        source_index,
        1'000.0 + static_cast<double>(source_index),
        latitude,
        longitude,
        std::nullopt,
        0.0,
        static_cast<double>(source_index),
        std::nullopt,
        std::nullopt,
        std::nullopt,
        std::nullopt,
        std::nullopt,
        segment_index,
    };
}

[[nodiscard]]
bool close_to(double value, double expected, double tolerance) noexcept {
    return std::isfinite(value) && std::isfinite(expected)
        && std::abs(value - expected) <= tolerance;
}

[[nodiscard]]
bool same_classification(double value, double expected) noexcept {
    if (std::isnan(expected)) {
        return std::isnan(value);
    }
    if (std::isinf(expected)) {
        return std::isinf(value) && (std::signbit(value) == std::signbit(expected));
    }
    const double tolerance = std::max(1e-9, std::abs(expected) * 1e-12);
    return close_to(value, expected, tolerance);
}

void expect_error_summary(
    const RouteStepDistanceSummary& summary,
    RouteStepDistanceStatus status,
    const char* message
) {
    expect(summary.status == status, message);
    expect(summary.sample_count == 0u, "error sample_count must be zero");
    expect(
        summary.segment_transition_count == 0u,
        "error segment_transition_count must be zero");
    expect(
        summary.invalid_coordinate_pair_count == 0u,
        "error invalid_coordinate_pair_count must be zero");
    expect(
        summary.total_distance_meters == 0.0
            && !std::signbit(summary.total_distance_meters),
        "error total must be positive zero");
}

void fill_sentinel(std::vector<double>& buffer, double value) {
    for (double& entry : buffer) {
        entry = value;
    }
}

void expect_unchanged(const std::vector<double>& buffer, double value) {
    for (double entry : buffer) {
        expect(entry == value, "error path must not write the output buffer");
    }
}

void test_empty_route_allows_null_pointers() {
    const RouteStepDistanceSummary summary =
        compute_route_step_distances(nullptr, 0u, nullptr, 0u);
    expect(summary.status == RouteStepDistanceStatus::success, "empty status");
    expect(summary.sample_count == 0u, "empty sample count");
    expect(summary.segment_transition_count == 0u, "empty transitions");
    expect(summary.invalid_coordinate_pair_count == 0u, "empty invalid pairs");
    expect(summary.total_distance_meters == 0.0, "empty total");
}

void test_boundary_errors_do_not_write() {
    const RouteInputSample sample = make_sample(0u, 1.0, 103.0, 0);
    std::vector<double> output(2u, 42.0);

    const RouteStepDistanceSummary null_input =
        compute_route_step_distances(nullptr, 1u, output.data(), output.size());
    expect_error_summary(
        null_input,
        RouteStepDistanceStatus::invalid_input_buffer,
        "null input with nonzero count");
    expect_unchanged(output, 42.0);

    const RouteStepDistanceSummary null_output =
        compute_route_step_distances(&sample, 1u, nullptr, 1u);
    expect_error_summary(
        null_output,
        RouteStepDistanceStatus::invalid_output_buffer,
        "null output with nonzero count");

    fill_sentinel(output, 7.0);
    const RouteStepDistanceSummary short_capacity =
        compute_route_step_distances(&sample, 1u, output.data(), 0u);
    expect_error_summary(
        short_capacity,
        RouteStepDistanceStatus::insufficient_output_capacity,
        "insufficient capacity");
    expect_unchanged(output, 7.0);

    fill_sentinel(output, 9.0);
    const RouteStepDistanceSummary resource =
        compute_route_step_distances(
            &sample,
            max_route_input_samples + 1u,
            output.data(),
            output.size());
    expect_error_summary(
        resource,
        RouteStepDistanceStatus::resource_limit,
        "resource limit");
    expect_unchanged(output, 9.0);
}

void test_capacity_larger_than_sample_count() {
    const RouteInputSample sample = make_sample(0u, 1.0, 103.0, 0);
    std::array<double, 4> output{1.0, 2.0, 3.0, 4.0};

    const RouteStepDistanceSummary summary = compute_route_step_distances(
        &sample,
        1u,
        output.data(),
        output.size());
    expect(summary.status == RouteStepDistanceStatus::success, "extra capacity");
    expect(summary.sample_count == 1u, "extra capacity sample count");
    expect(output[0] == 0.0, "first step is zero");
    expect(output[1] == 2.0, "unused capacity remains unchanged");
    expect(output[2] == 3.0, "unused capacity remains unchanged");
    expect(output[3] == 4.0, "unused capacity remains unchanged");
}

void test_single_and_repeated_points() {
    const RouteInputSample single = make_sample(0u, 37.7749, -122.4194, 0);
    double single_out = 99.0;
    const RouteStepDistanceSummary single_summary =
        compute_route_step_distances(&single, 1u, &single_out, 1u);
    expect(single_summary.status == RouteStepDistanceStatus::success, "single");
    expect(single_out == 0.0, "single first step");
    expect(single_summary.total_distance_meters == 0.0, "single total");

    const std::array<RouteInputSample, 2> repeated{
        make_sample(0u, 1.352083, 103.819836, 0),
        make_sample(1u, 1.352083, 103.819836, 0),
    };
    std::array<double, 2> repeated_out{};
    const RouteStepDistanceSummary repeated_summary = compute_route_step_distances(
        repeated.data(),
        repeated.size(),
        repeated_out.data(),
        repeated_out.size());
    expect(
        repeated_summary.status == RouteStepDistanceStatus::success,
        "repeated status");
    expect(repeated_out[0] == 0.0, "repeated first step");
    expect(repeated_out[1] == 0.0, "repeated second step");
    expect(repeated_summary.total_distance_meters == 0.0, "repeated total");
}

void test_two_and_three_valid_points() {
    // Hard-coded independently derived Haversine fixture: equator 1° longitude.
    constexpr double expected_one_degree =
        111'194.92664455873;  // earth_radius * 2 * atan2(sqrt(a), sqrt(1-a))
    const std::array<RouteInputSample, 2> two{
        make_sample(0u, 0.0, 0.0, 0),
        make_sample(1u, 0.0, 1.0, 0),
    };
    std::array<double, 2> two_out{};
    const RouteStepDistanceSummary two_summary = compute_route_step_distances(
        two.data(),
        two.size(),
        two_out.data(),
        two_out.size());
    expect(two_summary.status == RouteStepDistanceStatus::success, "two status");
    expect(two_out[0] == 0.0, "two first step");
    expect(
        close_to(two_out[1], expected_one_degree, 1e-6),
        "two-point equator fixture");
    expect(
        close_to(two_summary.total_distance_meters, expected_one_degree, 1e-6),
        "two-point total");
    expect(
        two_out[1] == haversine_distance_meters(0.0, 0.0, 0.0, 1.0),
        "two-point must reuse haversine_distance_meters");

    // North-south 1° latitude on the meridian: second independent fixture.
    constexpr double expected_one_degree_lat =
        111'194.92664455873;
    const std::array<RouteInputSample, 3> three{
        make_sample(0u, 0.0, 0.0, 0),
        make_sample(1u, 1.0, 0.0, 0),
        make_sample(2u, 1.0, 1.0, 0),
    };
    std::array<double, 3> three_out{};
    const RouteStepDistanceSummary three_summary = compute_route_step_distances(
        three.data(),
        three.size(),
        three_out.data(),
        three_out.size());
    expect(three_summary.status == RouteStepDistanceStatus::success, "three");
    expect(three_out[0] == 0.0, "three first");
    expect(
        close_to(three_out[1], expected_one_degree_lat, 1e-6),
        "three second step");
    const double third = haversine_distance_meters(1.0, 0.0, 1.0, 1.0);
    expect(three_out[2] == third, "three third step matches haversine");
    expect(
        close_to(
            three_summary.total_distance_meters,
            three_out[1] + three_out[2],
            1e-9),
        "three total is left-to-right sum");
}

void test_segment_boundaries() {
    const std::array<RouteInputSample, 4> samples{
        make_sample(0u, 0.0, 0.0, 0),
        make_sample(1u, 0.0, 1.0, 0),
        make_sample(2u, 0.0, 1.0, 1),  // same coordinates, new segment
        make_sample(3u, 0.0, 2.0, 1),
    };
    std::array<double, 4> out{};
    const RouteStepDistanceSummary summary = compute_route_step_distances(
        samples.data(),
        samples.size(),
        out.data(),
        out.size());
    expect(summary.status == RouteStepDistanceStatus::success, "segments");
    expect(summary.segment_transition_count == 1u, "one transition");
    expect(out[0] == 0.0, "seg first");
    expect(out[1] > 0.0, "seg second positive");
    expect(out[2] == 0.0, "segment boundary step is zero");
    expect(out[3] > 0.0, "after boundary positive");
    expect(
        close_to(summary.total_distance_meters, out[1] + out[3], 1e-9),
        "segment total ignores boundary zero");

    const std::array<RouteInputSample, 5> multi{
        make_sample(0u, 0.0, 0.0, 0),
        make_sample(1u, 0.0, 0.5, 0),
        make_sample(2u, 0.1, 0.5, 1),
        make_sample(3u, 0.2, 0.5, 1),
        make_sample(4u, 0.3, 0.5, 2),
    };
    std::array<double, 5> multi_out{};
    const RouteStepDistanceSummary multi_summary = compute_route_step_distances(
        multi.data(),
        multi.size(),
        multi_out.data(),
        multi_out.size());
    expect(multi_summary.segment_transition_count == 2u, "two transitions");
    expect(multi_out[2] == 0.0, "transition at index 2");
    expect(multi_out[4] == 0.0, "transition at index 4");
}

void test_invalid_coordinates() {
    const std::array<RouteInputSample, 4> samples{
        make_sample(0u, 0.0, 0.0, 0),
        make_sample(1u, quiet_nan, 1.0, 0),
        make_sample(2u, 0.0, 2.0, 0),
        make_sample(3u, 0.0, 3.0, 0),
    };
    std::array<double, 4> out{};
    const RouteStepDistanceSummary summary = compute_route_step_distances(
        samples.data(),
        samples.size(),
        out.data(),
        out.size());
    expect(summary.status == RouteStepDistanceStatus::success, "invalid pairs");
    expect(summary.invalid_coordinate_pair_count == 2u, "two invalid pairs");
    expect(out[0] == 0.0, "invalid first");
    expect(out[1] == 0.0, "invalid previous yields zero");
    expect(out[2] == 0.0, "invalid current yields zero");
    expect(out[3] > 0.0, "valid pair after invalid pair");
}

void test_antimeridian_near_pole_signed_zero_and_nan() {
    const std::array<RouteInputSample, 2> antimeridian{
        make_sample(0u, 0.0, 179.5, 0),
        make_sample(1u, 0.0, -179.5, 0),
    };
    std::array<double, 2> anti_out{};
    const RouteStepDistanceSummary anti = compute_route_step_distances(
        antimeridian.data(),
        antimeridian.size(),
        anti_out.data(),
        anti_out.size());
    expect(
        anti_out[1]
            == haversine_distance_meters(0.0, 179.5, 0.0, -179.5),
        "antimeridian matches haversine");

    const std::array<RouteInputSample, 2> near_pole{
        make_sample(0u, 89.9, 10.0, 0),
        make_sample(1u, 89.9, 20.0, 0),
    };
    std::array<double, 2> pole_out{};
    const RouteStepDistanceSummary pole = compute_route_step_distances(
        near_pole.data(),
        near_pole.size(),
        pole_out.data(),
        pole_out.size());
    expect(
        pole_out[1] == haversine_distance_meters(89.9, 10.0, 89.9, 20.0),
        "near-pole matches haversine");
    expect(pole.status == RouteStepDistanceStatus::success, "near-pole status");
    expect(anti.status == RouteStepDistanceStatus::success, "anti status");

    const std::array<RouteInputSample, 2> signed_zero{
        make_sample(0u, -0.0, -0.0, 0),
        make_sample(1u, 0.0, 0.0, 0),
    };
    std::array<double, 2> zero_out{};
    const RouteStepDistanceSummary zeros = compute_route_step_distances(
        signed_zero.data(),
        signed_zero.size(),
        zero_out.data(),
        zero_out.size());
    expect(zeros.status == RouteStepDistanceStatus::success, "signed zero");
    expect(zero_out[1] == 0.0, "signed zero distance");

    // Ordinary NaN input is invalid → zero step, not NaN propagation.
    const std::array<RouteInputSample, 2> ordinary_nan{
        make_sample(0u, quiet_nan, 0.0, 0),
        make_sample(1u, 0.0, 0.0, 0),
    };
    std::array<double, 2> nan_out{};
    const RouteStepDistanceSummary ordinary = compute_route_step_distances(
        ordinary_nan.data(),
        ordinary_nan.size(),
        nan_out.data(),
        nan_out.size());
    expect(nan_out[1] == 0.0, "ordinary NaN pair is zero");
    expect(ordinary.invalid_coordinate_pair_count == 1u, "ordinary NaN count");

    // Exactly antipodal valid coordinates may produce NaN via sqrt(1-a).
    const std::array<RouteInputSample, 2> antipodal{
        make_sample(0u, 0.0, 0.0, 0),
        make_sample(1u, 0.0, 180.0, 0),
    };
    std::array<double, 2> antipodal_out{};
    const RouteStepDistanceSummary antipodal_summary =
        compute_route_step_distances(
            antipodal.data(),
            antipodal.size(),
            antipodal_out.data(),
            antipodal_out.size());
    const double reference = haversine_distance_meters(0.0, 0.0, 0.0, 180.0);
    expect(
        same_classification(antipodal_out[1], reference),
        "exactly-antipodal NaN behavior is preserved");
    expect(
        same_classification(antipodal_summary.total_distance_meters, reference),
        "antipodal total classification matches");
}

void test_noncontiguous_source_indexes_use_array_order() {
    // source_index values deliberately skip and reverse relative to array order.
    const std::array<RouteInputSample, 3> samples{
        make_sample(100u, 0.0, 0.0, 0),
        make_sample(10u, 0.0, 1.0, 0),
        make_sample(50u, 1.0, 1.0, 0),
    };
    std::array<double, 3> out{};
    const RouteStepDistanceSummary summary = compute_route_step_distances(
        samples.data(),
        samples.size(),
        out.data(),
        out.size());
    expect(summary.status == RouteStepDistanceStatus::success, "noncontig");
    expect(out[0] == 0.0, "array order first");
    expect(
        out[1] == haversine_distance_meters(0.0, 0.0, 0.0, 1.0),
        "array order second");
    expect(
        out[2] == haversine_distance_meters(0.0, 1.0, 1.0, 1.0),
        "array order third");
}

void test_deterministic_repeated_calls() {
    const std::array<RouteInputSample, 4> samples{
        make_sample(0u, 1.0, 103.0, 0),
        make_sample(1u, 1.001, 103.001, 0),
        make_sample(2u, 1.002, 103.002, 1),
        make_sample(3u, 1.003, 103.003, 1),
    };
    std::array<double, 4> first{};
    std::array<double, 4> second{};
    const RouteStepDistanceSummary a = compute_route_step_distances(
        samples.data(),
        samples.size(),
        first.data(),
        first.size());
    const RouteStepDistanceSummary b = compute_route_step_distances(
        samples.data(),
        samples.size(),
        second.data(),
        second.size());
    expect(a.status == b.status, "deterministic status");
    expect(a.sample_count == b.sample_count, "deterministic count");
    expect(
        a.segment_transition_count == b.segment_transition_count,
        "deterministic transitions");
    expect(
        a.invalid_coordinate_pair_count == b.invalid_coordinate_pair_count,
        "deterministic invalid");
    expect(
        a.total_distance_meters == b.total_distance_meters
            || (std::isnan(a.total_distance_meters)
                && std::isnan(b.total_distance_meters)),
        "deterministic total");
    for (std::size_t index = 0u; index < first.size(); ++index) {
        expect(
            first[index] == second[index]
                || (std::isnan(first[index]) && std::isnan(second[index])),
            "deterministic steps");
    }
}

void test_large_route() {
    constexpr std::size_t sample_count = 100'000u;
    std::vector<RouteInputSample> samples;
    samples.reserve(sample_count);
    for (std::size_t index = 0u; index < sample_count; ++index) {
        const double meters = static_cast<double>(index) * 10.0;
        const double latitude = 1.0 + meters / 111'132.0;
        samples.push_back(make_sample(
            static_cast<std::uint64_t>(index),
            latitude,
            103.0,
            static_cast<std::int64_t>(index / 25'000u)));
    }

    std::vector<double> steps(sample_count, -1.0);
    const RouteStepDistanceSummary summary = compute_route_step_distances(
        samples.data(),
        samples.size(),
        steps.data(),
        steps.size());
    expect(summary.status == RouteStepDistanceStatus::success, "large status");
    expect(summary.sample_count == sample_count, "large sample count");
    expect(summary.segment_transition_count == 3u, "large transitions");
    expect(steps[0] == 0.0, "large first step");
    expect(steps[25'000] == 0.0, "large boundary step");
    expect(steps[50'000] == 0.0, "large boundary step 2");
    expect(steps[75'000] == 0.0, "large boundary step 3");
    expect(std::isfinite(summary.total_distance_meters), "large total finite");
    expect(summary.total_distance_meters > 0.0, "large total positive");

    double recomputed = 0.0;
    for (double step : steps) {
        recomputed += step;
    }
    expect(
        close_to(summary.total_distance_meters, recomputed, 1e-6)
            || summary.total_distance_meters == recomputed,
        "large total matches left-to-right sum");
}

}  // namespace

void run_route_geometry_tests() {
    test_empty_route_allows_null_pointers();
    test_boundary_errors_do_not_write();
    test_capacity_larger_than_sample_count();
    test_single_and_repeated_points();
    test_two_and_three_valid_points();
    test_segment_boundaries();
    test_invalid_coordinates();
    test_antimeridian_near_pole_signed_zero_and_nan();
    test_noncontiguous_source_indexes_use_array_order();
    test_deterministic_repeated_calls();
    test_large_route();
}
