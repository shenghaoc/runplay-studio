#include "RunPlayEngineCpp/RunPlayEngine.hpp"
#include "TestSupport.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <type_traits>
#include <vector>

static_assert(
    noexcept(runplay::process_route_quality_geometry(
        nullptr,
        0,
        runplay::RouteQualityGeometryPolicy{},
        runplay::RouteQualityDistancePolicy::compute_from_coordinates,
        nullptr,
        0,
        nullptr,
        0)),
    "process_route_quality_geometry must remain noexcept");
static_assert(std::is_standard_layout_v<runplay::RouteQualityGeometryPolicy>);
static_assert(std::is_trivially_copyable_v<runplay::RouteQualityGeometryPolicy>);
static_assert(
    std::is_nothrow_copy_constructible_v<runplay::RouteQualityGeometryPolicy>);
static_assert(std::is_standard_layout_v<runplay::RouteQualityOutputSample>);
static_assert(std::is_trivially_copyable_v<runplay::RouteQualityOutputSample>);
static_assert(
    std::is_nothrow_default_constructible_v<runplay::RouteQualityOutputSample>);
static_assert(
    std::is_nothrow_copy_constructible_v<runplay::RouteQualityOutputSample>);
static_assert(std::is_standard_layout_v<runplay::RouteQualityPipelineSummary>);
static_assert(std::is_trivially_copyable_v<runplay::RouteQualityPipelineSummary>);
static_assert(
    std::is_nothrow_copy_constructible_v<runplay::RouteQualityPipelineSummary>);
static_assert(__cplusplus >= 202302L, "RunPlayEngineCpp must compile as C++23");

namespace {

using runplay::RouteInputSample;
using runplay::RouteQualityDistancePolicy;
using runplay::RouteQualityDistanceSource;
using runplay::RouteQualityGeometryPolicy;
using runplay::RouteQualityOutputSample;
using runplay::RouteQualityPipelineStatus;
using runplay::RouteQualityPipelineSummary;
using runplay::RouteSegmentDistanceSource;
using runplay::max_route_input_samples;
using runplay::process_route_quality_geometry;

constexpr double quiet_nan = std::numeric_limits<double>::quiet_NaN();

[[nodiscard]]
RouteQualityGeometryPolicy default_policy() noexcept {
    return RouteQualityGeometryPolicy{
        /*.maximum_plausible_running_speed_meters_per_second=*/12.0,
        /*.maximum_useful_horizontal_accuracy_meters=*/100.0,
        /*.coordinate_spike_minimum_excess_distance_meters=*/200.0,
        /*.coordinate_spike_minimum_distortion_ratio=*/3.0,
        /*.poor_accuracy_evidence_multiplier=*/0.5,
        /*.implicit_gap_minimum_distance_meters=*/200.0,
        /*.implicit_gap_minimum_time_interval_seconds=*/120.0,
        /*.implicit_gap_minimum_time_discontinuity_ratio=*/3.0,
        /*.relocated_cluster_confirmation_point_count=*/3u,
        /*.relocated_cluster_maximum_step_meters=*/200.0,
    };
}

[[nodiscard]]
RouteInputSample make_sample(
    std::uint64_t source_index,
    double latitude,
    double longitude,
    double timestamp,
    double elapsed,
    double distance,
    std::int64_t segment,
    std::optional<double> accuracy = std::nullopt
) {
    return RouteInputSample{
        source_index,
        timestamp,
        latitude,
        longitude,
        std::nullopt,
        distance,
        elapsed,
        std::nullopt,
        std::nullopt,
        std::nullopt,
        std::nullopt,
        accuracy,
        segment,
    };
}

void expect_error_summary(
    const RouteQualityPipelineSummary& summary,
    RouteQualityPipelineStatus status,
    const char* message
) {
    expect(summary.status == status, message);
    expect(summary.input_sample_count == 0u, "error input_sample_count zero");
    expect(summary.retained_sample_count == 0u, "error retained zero");
    expect(
        summary.discarded_coordinate_point_count == 0u,
        "error discarded zero");
    expect(summary.inferred_route_gap_count == 0u, "error inferred zero");
    expect(summary.normalized_segment_count == 0u, "error segments zero");
    expect(
        summary.distance_source
            == RouteQualityDistanceSource::coordinate_derived,
        "error distance source coordinate");
    expect(
        summary.total_distance_meters == 0.0
            && !std::signbit(summary.total_distance_meters),
        "error total positive zero");
}

void fill_sentinel(std::vector<RouteQualityOutputSample>& buffer) {
    for (std::size_t index = 0u; index < buffer.size(); ++index) {
        buffer[index].source_index = 0xDEADBEEFu + index;
        buffer[index].normalized_segment_index = -99;
        buffer[index].normalized_distance_from_start_meters = -123.0;
        buffer[index].distance_source =
            RouteSegmentDistanceSource::device_supplied;
        buffer[index].retained = 7u;
        buffer[index].rejected_coordinate_outlier = 7u;
        buffer[index].inferred_boundary = 7u;
    }
}

void expect_unchanged(
    const std::vector<RouteQualityOutputSample>& buffer,
    const char* message
) {
    for (std::size_t index = 0u; index < buffer.size(); ++index) {
        expect(
            buffer[index].source_index == 0xDEADBEEFu + index,
            message);
        expect(buffer[index].normalized_segment_index == -99, message);
        expect(
            buffer[index].normalized_distance_from_start_meters == -123.0,
            message);
        expect(buffer[index].retained == 7u, message);
    }
}

[[nodiscard]]
bool close_to(double value, double expected, double tolerance) noexcept {
    return std::isfinite(value) && std::isfinite(expected)
        && std::abs(value - expected) <= tolerance;
}

// ~111 m per 0.001 deg latitude near the equator for simple fixtures.
constexpr double lat_step_for_metres(double metres) noexcept {
    return metres / 111'132.0;
}

void test_empty_and_boundary_errors() {
    {
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            nullptr,
            0u,
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            nullptr,
            0u);
        expect(
            summary.status == RouteQualityPipelineStatus::success,
            "empty succeeds");
        expect(summary.input_sample_count == 0u, "empty input count");
        expect(summary.total_distance_meters == 0.0, "empty total");
    }

    RouteInputSample sample = make_sample(0, 0.0, 0.0, 0.0, 0.0, 0.0, 0);
    std::vector<RouteQualityOutputSample> output(1);
    fill_sentinel(output);

    expect_error_summary(
        process_route_quality_geometry(
            nullptr,
            1u,
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            output.size()),
        RouteQualityPipelineStatus::invalid_input_buffer,
        "null input");
    expect_unchanged(output, "null input no write");

    expect_error_summary(
        process_route_quality_geometry(
            &sample,
            1u,
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            nullptr,
            1u),
        RouteQualityPipelineStatus::invalid_output_buffer,
        "null output");

    expect_error_summary(
        process_route_quality_geometry(
            &sample,
            1u,
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            0u),
        RouteQualityPipelineStatus::insufficient_output_capacity,
        "capacity");
    expect_unchanged(output, "capacity no write");

    expect_error_summary(
        process_route_quality_geometry(
            &sample,
            max_route_input_samples + 1u,
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            output.size()),
        RouteQualityPipelineStatus::resource_limit,
        "resource limit");
    expect_unchanged(output, "resource limit no write");

    RouteQualityGeometryPolicy bad = default_policy();
    bad.coordinate_spike_minimum_distortion_ratio = 0.5;
    expect_error_summary(
        process_route_quality_geometry(
            &sample,
            1u,
            bad,
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            output.size()),
        RouteQualityPipelineStatus::invalid_policy,
        "invalid policy");
    expect_unchanged(output, "invalid policy no write");

    sample.latitude = 200.0;
    expect_error_summary(
        process_route_quality_geometry(
            &sample,
            1u,
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            output.size()),
        RouteQualityPipelineStatus::invalid_input_contract,
        "invalid coordinate");
    expect_unchanged(output, "invalid coordinate no write");
}

void test_ordinary_route_and_teleport() {
    // Straight ~100 m steps every second.
    std::vector<RouteInputSample> samples;
    for (std::uint64_t i = 0; i < 5; ++i) {
        samples.push_back(make_sample(
            100u + i,
            lat_step_for_metres(100.0 * static_cast<double>(i)),
            0.0,
            static_cast<double>(i),
            static_cast<double>(i),
            0.0,
            0));
    }
    std::vector<RouteQualityOutputSample> output(samples.size());
    const RouteQualityPipelineSummary summary = process_route_quality_geometry(
        samples.data(),
        samples.size(),
        default_policy(),
        RouteQualityDistancePolicy::compute_from_coordinates,
        nullptr,
        0u,
        output.data(),
        output.size());
    expect(summary.status == RouteQualityPipelineStatus::success, "straight ok");
    expect(summary.retained_sample_count == 5u, "straight retains all");
    expect(summary.discarded_coordinate_point_count == 0u, "no outliers");
    expect(summary.inferred_route_gap_count == 0u, "no gaps");
    expect(summary.normalized_segment_count == 1u, "one segment");
    expect(
        summary.distance_source == RouteQualityDistanceSource::coordinate_derived,
        "coordinate source");
    expect(output[0].normalized_distance_from_start_meters == 0.0, "starts zero");
    expect(
        close_to(output[4].normalized_distance_from_start_meters, 400.0, 5.0),
        "approx 400 m");
    for (std::size_t i = 0; i < samples.size(); ++i) {
        expect(output[i].source_index == samples[i].source_index, "source map");
        expect(output[i].retained == 1u, "retained");
        expect(output[i].rejected_coordinate_outlier == 0u, "not rejected");
    }

    // Isolated teleport: points 0,1,2,3,4 where index 2 is far away briefly.
    samples.clear();
    const double t0 = 0.0;
    samples.push_back(make_sample(0, 0.0, 0.0, t0, 0.0, 0.0, 0));
    samples.push_back(make_sample(
        1,
        lat_step_for_metres(10.0),
        0.0,
        t0 + 1.0,
        1.0,
        0.0,
        0));
    // Teleport ~5 km away for 1 second, then resume near the bridge path.
    samples.push_back(make_sample(
        2,
        lat_step_for_metres(5'000.0),
        0.0,
        t0 + 2.0,
        2.0,
        0.0,
        0));
    samples.push_back(make_sample(
        3,
        lat_step_for_metres(20.0),
        0.0,
        t0 + 3.0,
        3.0,
        0.0,
        0));
    samples.push_back(make_sample(
        4,
        lat_step_for_metres(30.0),
        0.0,
        t0 + 4.0,
        4.0,
        0.0,
        0));
    output.assign(samples.size(), {});
    const RouteQualityPipelineSummary teleport = process_route_quality_geometry(
        samples.data(),
        samples.size(),
        default_policy(),
        RouteQualityDistancePolicy::compute_from_coordinates,
        nullptr,
        0u,
        output.data(),
        output.size());
    expect(teleport.status == RouteQualityPipelineStatus::success, "teleport ok");
    expect(teleport.discarded_coordinate_point_count == 1u, "one outlier");
    expect(teleport.retained_sample_count == 4u, "four retained");
    expect(output[2].retained == 0u, "teleport rejected");
    expect(output[2].rejected_coordinate_outlier == 1u, "teleport flagged");
    expect(output[0].retained == 1u && output[1].retained == 1u, "ends kept");
    expect(output[3].retained == 1u && output[4].retained == 1u, "resume kept");
}

// Builds an oscillating track whose interior points alternate between the
// baseline and `spike_metres`. Every oscillating point is an outlier candidate
// because each neighbour pair straddles it while the bridge across it is short.
[[nodiscard]]
std::vector<RouteInputSample> make_oscillating_route(
    const std::vector<double>& metres
) {
    std::vector<RouteInputSample> samples;
    samples.reserve(metres.size());
    for (std::size_t index = 0u; index < metres.size(); ++index) {
        const double ordinal = static_cast<double>(index);
        samples.push_back(make_sample(
            index,
            lat_step_for_metres(metres[index]),
            0.0,
            ordinal,
            ordinal,
            0.0,
            0));
    }
    return samples;
}

void test_adjacent_candidates_and_endpoints() {
    // Exactly two adjacent candidates (indexes 2 and 3). Index 1 has a zero
    // inbound step and index 4 a zero outbound step, so neither qualifies.
    {
        const std::vector<RouteInputSample> samples =
            make_oscillating_route({0.0, 0.0, 5'000.0, 0.0, 5'000.0, 5'000.0});
        std::vector<RouteQualityOutputSample> output(samples.size());
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            output.size());
        expect(summary.status == RouteQualityPipelineStatus::success, "adjacent ok");
        // Adjacent candidate conservatism retains both ambiguous points.
        expect(output[2].retained == 1u, "adjacent candidate retained");
        expect(output[3].retained == 1u, "adjacent peer retained");
        expect(
            output[2].rejected_coordinate_outlier == 0u,
            "adjacent candidate not flagged");
        expect(
            output[3].rejected_coordinate_outlier == 0u,
            "adjacent peer not flagged");
        expect(summary.retained_sample_count == samples.size(), "all retained");
        expect(
            summary.discarded_coordinate_point_count == 0u,
            "no isolated discard");
    }

    // A run of three adjacent candidates (indexes 2, 3 and 4). The trailing
    // member of the run must not be rejected either.
    {
        const std::vector<RouteInputSample> samples = make_oscillating_route(
            {0.0, 0.0, 5'000.0, 0.0, 5'000.0, 0.0, 0.0});
        std::vector<RouteQualityOutputSample> output(samples.size());
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            output.size());
        expect(summary.status == RouteQualityPipelineStatus::success, "run ok");
        for (std::size_t index = 2u; index <= 4u; ++index) {
            expect(output[index].retained == 1u, "adjacent run retained");
            expect(
                output[index].rejected_coordinate_outlier == 0u,
                "adjacent run not flagged");
        }
        expect(summary.retained_sample_count == samples.size(), "run all retained");
        expect(
            summary.discarded_coordinate_point_count == 0u,
            "no discard in run");
    }

    // An isolated candidate is still rejected when its neighbours are clean.
    {
        const std::vector<RouteInputSample> samples = make_oscillating_route(
            {0.0, 0.0, 5'000.0, 0.0, 0.0, 0.0});
        std::vector<RouteQualityOutputSample> output(samples.size());
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            output.size());
        expect(summary.status == RouteQualityPipelineStatus::success, "isolated ok");
        expect(output[2].retained == 0u, "isolated candidate rejected");
        expect(
            output[2].rejected_coordinate_outlier == 1u,
            "isolated candidate flagged");
        expect(
            summary.discarded_coordinate_point_count == 1u,
            "one isolated discard");
    }
}

void test_gap_inference_and_segments() {
    // Coherent route, then a fast relocation of >200 m with confirmation cluster.
    std::vector<RouteInputSample> samples;
    for (std::uint64_t i = 0; i < 4; ++i) {
        samples.push_back(make_sample(
            i,
            lat_step_for_metres(10.0 * static_cast<double>(i)),
            0.0,
            static_cast<double>(i),
            static_cast<double>(i),
            0.0,
            0));
    }
    // Jump ~1 km in 1 second, then 3 coherent confirmation points.
    const double jump_lat = lat_step_for_metres(1'000.0);
    samples.push_back(make_sample(4, jump_lat, 0.0, 4.0, 4.0, 0.0, 0));
    samples.push_back(make_sample(
        5, jump_lat + lat_step_for_metres(10.0), 0.0, 5.0, 5.0, 0.0, 0));
    samples.push_back(make_sample(
        6, jump_lat + lat_step_for_metres(20.0), 0.0, 6.0, 6.0, 0.0, 0));
    samples.push_back(make_sample(
        7, jump_lat + lat_step_for_metres(30.0), 0.0, 7.0, 7.0, 0.0, 0));

    std::vector<RouteQualityOutputSample> output(samples.size());
    const RouteQualityPipelineSummary summary = process_route_quality_geometry(
        samples.data(),
        samples.size(),
        default_policy(),
        RouteQualityDistancePolicy::compute_from_coordinates,
        nullptr,
        0u,
        output.data(),
        output.size());
    expect(summary.status == RouteQualityPipelineStatus::success, "gap ok");
    expect(summary.inferred_route_gap_count == 1u, "one inferred gap");
    expect(output[4].inferred_boundary == 1u, "boundary at relocation");
    expect(summary.normalized_segment_count == 2u, "two final segments");
    expect(output[0].normalized_segment_index == 0, "first segment");
    expect(output[4].normalized_segment_index == 1, "second segment");
    // No distance across inferred boundary.
    expect(
        close_to(
            output[4].normalized_distance_from_start_meters,
            output[3].normalized_distance_from_start_meters,
            1e-9),
        "no jump distance across gap");
}

void test_supplied_distance_policies() {
    std::vector<RouteInputSample> samples;
    for (std::uint64_t i = 0; i < 4; ++i) {
        samples.push_back(make_sample(
            i,
            lat_step_for_metres(100.0 * static_cast<double>(i)),
            0.0,
            static_cast<double>(i),
            static_cast<double>(i),
            10.0 * static_cast<double>(i),
            0));
    }
    std::vector<RouteQualityOutputSample> output(samples.size());

    {
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::use_supplied_when_all_valid,
            nullptr,
            0u,
            output.data(),
            output.size());
        expect(summary.status == RouteQualityPipelineStatus::success, "supplied ok");
        expect(
            summary.distance_source
                == RouteQualityDistanceSource::device_supplied,
            "device supplied overall");
        expect(
            close_to(output[3].normalized_distance_from_start_meters, 30.0, 1e-9),
            "supplied total 30");
        expect(
            output[1].distance_source
                == RouteSegmentDistanceSource::device_supplied,
            "per-sample supplied");
    }

    samples[2] = make_sample(
        2,
        lat_step_for_metres(200.0),
        0.0,
        2.0,
        2.0,
        -5.0,
        0);
    output.assign(samples.size(), {});
    {
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::use_supplied_when_all_valid,
            nullptr,
            0u,
            output.data(),
            output.size());
        expect(
            summary.distance_source
                == RouteQualityDistanceSource::coordinate_derived,
            "invalid forces coordinate");
    }

    // Two source segments: first valid supplied, second invalid → mixed per-seg.
    samples.clear();
    for (std::uint64_t i = 0; i < 3; ++i) {
        samples.push_back(make_sample(
            i,
            lat_step_for_metres(50.0 * static_cast<double>(i)),
            0.0,
            static_cast<double>(i),
            static_cast<double>(i),
            5.0 * static_cast<double>(i),
            0));
    }
    for (std::uint64_t i = 0; i < 3; ++i) {
        samples.push_back(make_sample(
            10u + i,
            1.0 + lat_step_for_metres(50.0 * static_cast<double>(i)),
            0.0,
            10.0 + static_cast<double>(i),
            10.0 + static_cast<double>(i),
            (i == 1u) ? quiet_nan : 5.0 * static_cast<double>(i),
            1));
    }
    output.assign(samples.size(), {});
    {
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::use_supplied_per_segment,
            nullptr,
            0u,
            output.data(),
            output.size());
        expect(
            summary.distance_source == RouteQualityDistanceSource::mixed,
            "mixed per segment");
        expect(summary.normalized_segment_count == 2u, "two segments");
        expect(
            output[0].distance_source
                == RouteSegmentDistanceSource::device_supplied,
            "seg0 supplied");
        expect(
            output[3].distance_source
                == RouteSegmentDistanceSource::coordinate_derived,
            "seg1 coordinate");
    }

    // Selected-source policy with selection buffer.
    std::vector<std::uint8_t> selection(samples.size(), 0u);
    for (std::size_t i = 0; i < 3; ++i) {
        selection[i] = 1u;
    }
    output.assign(samples.size(), {});
    {
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::use_supplied_for_selected_source_segments,
            selection.data(),
            selection.size(),
            output.data(),
            output.size());
        expect(summary.status == RouteQualityPipelineStatus::success, "selected ok");
        expect(
            summary.distance_source == RouteQualityDistanceSource::mixed
                || summary.distance_source
                    == RouteQualityDistanceSource::device_supplied,
            "selected uses supplied for valid selected");
        expect(
            output[0].distance_source
                == RouteSegmentDistanceSource::device_supplied,
            "selected seg0 supplied");
        expect(
            output[3].distance_source
                == RouteSegmentDistanceSource::coordinate_derived,
            "unselected falls back");
    }

    // Invalid selection length
    fill_sentinel(output);
    expect_error_summary(
        process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::use_supplied_for_selected_source_segments,
            selection.data(),
            1u,
            output.data(),
            output.size()),
        RouteQualityPipelineStatus::invalid_selection_buffer,
        "bad selection length");
    expect_unchanged(output, "bad selection no write");
}

void test_segment_contract_and_identity() {
    std::vector<RouteInputSample> samples = {
        make_sample(42, 0.0, 0.0, 0.0, 0.0, 0.0, 0),
        make_sample(7, lat_step_for_metres(50.0), 0.0, 1.0, 1.0, 0.0, 0),
        make_sample(99, 1.0, 0.0, 2.0, 2.0, 0.0, 1),
        make_sample(3, 1.0 + lat_step_for_metres(50.0), 0.0, 3.0, 3.0, 0.0, 1),
    };
    std::vector<RouteQualityOutputSample> output(samples.size());
    const RouteQualityPipelineSummary summary = process_route_quality_geometry(
        samples.data(),
        samples.size(),
        default_policy(),
        RouteQualityDistancePolicy::compute_from_coordinates,
        nullptr,
        0u,
        output.data(),
        output.size());
    expect(summary.status == RouteQualityPipelineStatus::success, "identity ok");
    expect(summary.normalized_segment_count == 2u, "two source segments");
    expect(output[0].source_index == 42u, "noncontiguous source 0");
    expect(output[1].source_index == 7u, "noncontiguous source 1");
    expect(output[2].source_index == 99u, "noncontiguous source 2");
    expect(output[3].source_index == 3u, "noncontiguous source 3");
    expect(
        close_to(
            output[2].normalized_distance_from_start_meters,
            output[1].normalized_distance_from_start_meters,
            1e-9),
        "no distance across explicit boundary");

    // Malformed segment jump by two.
    samples[2] = make_sample(99, 1.0, 0.0, 2.0, 2.0, 0.0, 2);
    fill_sentinel(output);
    expect_error_summary(
        process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            RouteQualityDistancePolicy::compute_from_coordinates,
            nullptr,
            0u,
            output.data(),
            output.size()),
        RouteQualityPipelineStatus::invalid_input_contract,
        "segment jump");
    expect_unchanged(output, "segment jump no write");
}

void test_large_route() {
    constexpr std::size_t count = 100'000;
    std::vector<RouteInputSample> samples;
    samples.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        // One-metre steps along a gentle diagonal keep speeds realistic and
        // avoid wrap-around teleports that would exercise outlier rejection.
        const double metres = static_cast<double>(i);
        samples.push_back(make_sample(
            static_cast<std::uint64_t>(i),
            lat_step_for_metres(metres),
            lat_step_for_metres(metres) * 0.01,
            static_cast<double>(i),
            static_cast<double>(i),
            0.0,
            static_cast<std::int64_t>(i / 25'000)));
    }
    std::vector<RouteQualityOutputSample> output(count);
    const RouteQualityPipelineSummary summary = process_route_quality_geometry(
        samples.data(),
        samples.size(),
        default_policy(),
        RouteQualityDistancePolicy::compute_from_coordinates,
        nullptr,
        0u,
        output.data(),
        output.size());
    expect(summary.status == RouteQualityPipelineStatus::success, "large ok");
    expect(summary.input_sample_count == count, "large count");
    expect(summary.retained_sample_count == count, "large retained");
    expect(summary.normalized_segment_count == 4u, "four segments");
    expect(output[0].normalized_distance_from_start_meters == 0.0, "large zero");
    expect(
        output[count - 1].normalized_distance_from_start_meters >= 0.0,
        "large total nonneg");
}

// Many short segments. Distance normalization must stay linear in the sample
// count: scanning the whole route once per segment would make this quadratic,
// so a regression here shows up as a large slowdown as well as by assertion.
void test_many_segments() {
    constexpr std::size_t count = 100'000;
    constexpr std::size_t segment_length = 100;
    constexpr std::size_t segment_count = count / segment_length;

    std::vector<RouteInputSample> samples;
    samples.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        const double metres = static_cast<double>(i);
        samples.push_back(make_sample(
            static_cast<std::uint64_t>(i),
            lat_step_for_metres(metres),
            0.0,
            static_cast<double>(i),
            static_cast<double>(i),
            // Supplied distances restart at zero on every source segment.
            static_cast<double>(i % segment_length),
            static_cast<std::int64_t>(i / segment_length)));
    }

    for (const RouteQualityDistancePolicy policy : {
             RouteQualityDistancePolicy::compute_from_coordinates,
             RouteQualityDistancePolicy::use_supplied_per_segment,
             RouteQualityDistancePolicy::use_supplied_when_all_valid,
         }) {
        std::vector<RouteQualityOutputSample> output(count);
        const RouteQualityPipelineSummary summary = process_route_quality_geometry(
            samples.data(),
            samples.size(),
            default_policy(),
            policy,
            nullptr,
            0u,
            output.data(),
            output.size());
        expect(summary.status == RouteQualityPipelineStatus::success, "many ok");
        expect(summary.retained_sample_count == count, "many retained");
        expect(
            summary.normalized_segment_count == segment_count,
            "many segment count");
        expect(
            output[count - 1].normalized_segment_index
                == static_cast<std::int64_t>(segment_count) - 1,
            "many last segment");

        // Cumulative distance never decreases and never jumps across a
        // segment boundary.
        double previous = -1.0;
        for (std::size_t i = 0; i < count; ++i) {
            const double value =
                output[i].normalized_distance_from_start_meters;
            expect(value >= previous, "many monotonic");
            previous = value;
        }
        expect(
            output[0].normalized_distance_from_start_meters == 0.0,
            "many starts at zero");

        const bool supplied =
            policy != RouteQualityDistancePolicy::compute_from_coordinates;
        expect(
            summary.distance_source
                == (supplied
                        ? RouteQualityDistanceSource::device_supplied
                        : RouteQualityDistanceSource::coordinate_derived),
            "many distance source");
    }
}

}  // namespace

void run_route_quality_pipeline_tests() {
    test_empty_and_boundary_errors();
    test_ordinary_route_and_teleport();
    test_adjacent_candidates_and_endpoints();
    test_gap_inference_and_segments();
    test_supplied_distance_policies();
    test_segment_contract_and_identity();
    test_large_route();
    test_many_segments();
}
