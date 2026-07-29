#include "RunPlayEngineCpp/RunPlayEngine.hpp"
#include "TestSupport.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>
#include <vector>

static_assert(
    noexcept(runplay::compute_personal_heatmap_workout_coverage(
        nullptr, 0, 10.0, 500.0, 10'000, nullptr, 0)),
    "compute_personal_heatmap_workout_coverage must be noexcept");

static_assert(std::is_standard_layout_v<runplay::PersonalHeatmapRouteSample>);
static_assert(std::is_trivially_copyable_v<runplay::PersonalHeatmapRouteSample>);
static_assert(std::is_nothrow_default_constructible_v<runplay::PersonalHeatmapRouteSample>);
static_assert(std::is_nothrow_copy_constructible_v<runplay::PersonalHeatmapRouteSample>);

static_assert(std::is_standard_layout_v<runplay::PersonalHeatmapCellIndex>);
static_assert(std::is_trivially_copyable_v<runplay::PersonalHeatmapCellIndex>);
static_assert(std::is_nothrow_default_constructible_v<runplay::PersonalHeatmapCellIndex>);
static_assert(std::is_nothrow_copy_constructible_v<runplay::PersonalHeatmapCellIndex>);

static_assert(std::is_standard_layout_v<runplay::PersonalHeatmapCoverageSummary>);
static_assert(std::is_trivially_copyable_v<runplay::PersonalHeatmapCoverageSummary>);
static_assert(std::is_nothrow_default_constructible_v<runplay::PersonalHeatmapCoverageSummary>);
static_assert(std::is_nothrow_copy_constructible_v<runplay::PersonalHeatmapCoverageSummary>);

static_assert(__cplusplus >= 202302L, "RunPlayEngineCpp must compile as C++23");

namespace {

using runplay::PersonalHeatmapCellIndex;
using runplay::PersonalHeatmapCoverageStatus;
using runplay::PersonalHeatmapCoverageSummary;
using runplay::PersonalHeatmapRouteSample;
using runplay::compute_personal_heatmap_workout_coverage;

constexpr double quiet_nan = std::numeric_limits<double>::quiet_NaN();
constexpr double infinity = std::numeric_limits<double>::infinity();

void fill_sentinel(std::vector<PersonalHeatmapCellIndex>& buffer) {
    for (std::size_t i = 0; i < buffer.size(); ++i) {
        buffer[i].x = static_cast<std::int64_t>(0xDEADBEEF00000000ULL + i);
        buffer[i].y = static_cast<std::int64_t>(0xCAFEBABE00000000ULL + i);
    }
}

void expect_unchanged(
    const std::vector<PersonalHeatmapCellIndex>& buffer,
    const char* message
) {
    for (std::size_t i = 0; i < buffer.size(); ++i) {
        expect(
            buffer[i].x == static_cast<std::int64_t>(0xDEADBEEF00000000ULL + i),
            message);
        expect(
            buffer[i].y == static_cast<std::int64_t>(0xCAFEBABE00000000ULL + i),
            message);
    }
}

void test_empty_and_boundary_errors() {
    {
        const auto summary = compute_personal_heatmap_workout_coverage(
            nullptr, 0, 10.0, 500.0, 10'000, nullptr, 0);
        expect(summary.status == PersonalHeatmapCoverageStatus::success, "empty route succeeds");
        expect(summary.input_sample_count == 0, "empty input count");
        expect(summary.valid_projected_point_count == 0, "empty valid count");
        expect(summary.effective_segment_count == 0, "empty segment count");
        expect(summary.invalid_interval_count == 0, "empty invalid intervals");
        expect(summary.required_cell_count == 0, "empty required count");
        expect(summary.written_cell_count == 0, "empty written count");
    }

    PersonalHeatmapRouteSample sample{37.7749, -122.4194, 0};
    std::vector<PersonalHeatmapCellIndex> output(10);
    fill_sentinel(output);

    {
        const auto summary = compute_personal_heatmap_workout_coverage(
            nullptr, 1, 10.0, 500.0, 10'000, output.data(), output.size());
        expect(summary.status == PersonalHeatmapCoverageStatus::invalid_input_buffer, "null input buffer");
        expect_unchanged(output, "null input no write");
    }

    {
        const auto summary = compute_personal_heatmap_workout_coverage(
            &sample, 1, 10.0, 500.0, 10'000, nullptr, 5);
        expect(summary.status == PersonalHeatmapCoverageStatus::invalid_output_buffer, "null output buffer");
    }

    {
        const auto summary = compute_personal_heatmap_workout_coverage(
            &sample, 1, 0.0, 500.0, 10'000, output.data(), output.size());
        expect(summary.status == PersonalHeatmapCoverageStatus::invalid_configuration, "zero cell size");
        expect_unchanged(output, "zero cell size no write");
    }

    {
        const auto summary = compute_personal_heatmap_workout_coverage(
            &sample, 1, -10.0, 500.0, 10'000, output.data(), output.size());
        expect(summary.status == PersonalHeatmapCoverageStatus::invalid_configuration, "negative cell size");
        expect_unchanged(output, "negative cell size no write");
    }

    {
        const auto summary = compute_personal_heatmap_workout_coverage(
            &sample, 1, 10.0, 0.0, 10'000, output.data(), output.size());
        expect(summary.status == PersonalHeatmapCoverageStatus::invalid_configuration, "zero max interval");
        expect_unchanged(output, "zero max interval no write");
    }

    {
        const auto summary = compute_personal_heatmap_workout_coverage(
            &sample, 1, 10.0, 500.0, 0, output.data(), output.size());
        expect(summary.status == PersonalHeatmapCoverageStatus::invalid_configuration, "zero max cells per interval");
        expect_unchanged(output, "zero max cells no write");
    }

    {
        fill_sentinel(output);
        const auto summary = compute_personal_heatmap_workout_coverage(
            &sample, 1, 10.0, 500.0, 10'000, output.data(), 0);
        expect(summary.status == PersonalHeatmapCoverageStatus::insufficient_output_capacity, "zero capacity");
        expect(summary.required_cell_count == 1, "required cell count is 1");
        expect(summary.written_cell_count == 0, "written cell count is 0");
        expect_unchanged(output, "zero capacity no write");
    }
}

void test_projection_and_cell_indexing() {
    std::vector<PersonalHeatmapRouteSample> samples = {
        {0.0, 0.0, 0},               // equator & prime meridian
        {85.05112878, 180.0, 0},      // top right valid boundary
        {-85.05112878, -180.0, 0},    // bottom left valid boundary (-180 normalizes to 180)
        {89.0, 45.0, 0},              // lat > 85.05112878 clamped
        {-89.0, -45.0, 0},            // lat < -85.05112878 clamped
        {100.0, 0.0, 0},              // invalid lat (> 90) -> skipped
        {0.0, 200.0, 0},              // invalid lon (> 180) -> skipped
        {quiet_nan, 0.0, 0},          // NaN lat -> skipped
        {0.0, infinity, 0},           // Inf lon -> skipped
    };

    std::vector<PersonalHeatmapCellIndex> output(20);
    const auto summary = compute_personal_heatmap_workout_coverage(
        samples.data(), samples.size(), 10.0, 50000.0, 10'000, output.data(), output.size());

    expect(summary.status == PersonalHeatmapCoverageStatus::success, "projection test success");
    expect(summary.input_sample_count == samples.size(), "input count matches");
    expect(summary.valid_projected_point_count == 5, "5 valid projected points");
}

void test_segments_and_invalid_gaps() {
    std::vector<PersonalHeatmapRouteSample> samples = {
        {0.0, 0.0, 0},
        {0.001, 0.001, 0},
        {100.0, 100.0, 0}, // invalid coordinate -> gap
        {0.002, 0.002, 0},
        {0.003, 0.003, 1}, // segment change from 0 to 1
        {0.004, 0.004, -5}, // segment change from 1 to -5
    };

    std::vector<PersonalHeatmapCellIndex> output(50);
    const auto summary = compute_personal_heatmap_workout_coverage(
        samples.data(), samples.size(), 10.0, 500.0, 10'000, output.data(), output.size());

    expect(summary.status == PersonalHeatmapCoverageStatus::success, "segments test success");
    expect(summary.valid_projected_point_count == 5, "5 valid points");
    expect(summary.effective_segment_count == 4, "4 effective segments");
}

void test_coverage_traversal_and_sorting() {
    std::vector<PersonalHeatmapRouteSample> samples = {
        {0.0, 0.0, 0},
        {0.0, 0.001, 0},
        {0.001, 0.001, 0},
        {0.0, 0.0, 0}, // loop back to start
    };

    std::vector<PersonalHeatmapCellIndex> output(100);
    const auto summary = compute_personal_heatmap_workout_coverage(
        samples.data(), samples.size(), 10.0, 500.0, 10'000, output.data(), output.size());

    expect(summary.status == PersonalHeatmapCoverageStatus::success, "traversal success");
    expect(summary.written_cell_count == summary.required_cell_count, "written == required");

    for (std::size_t i = 1; i < summary.written_cell_count; ++i) {
        const auto& prev = output[i - 1];
        const auto& curr = output[i];
        bool sorted = (prev.y < curr.y) || (prev.y == curr.y && prev.x < curr.x);
        expect(sorted, "output cells sorted by y then x");
        bool unique = !(prev.x == curr.x && prev.y == curr.y);
        expect(unique, "output cells are unique");
    }
}

void test_oversized_intervals() {
    std::vector<PersonalHeatmapRouteSample> samples = {
        {0.0, 0.0, 0},
        {1.0, 1.0, 0}, // ~150 km jump > 500 m max interval
    };

    std::vector<PersonalHeatmapCellIndex> output(100);
    const auto summary = compute_personal_heatmap_workout_coverage(
        samples.data(), samples.size(), 10.0, 500.0, 10'000, output.data(), output.size());

    expect(summary.status == PersonalHeatmapCoverageStatus::success, "oversized interval success");
    expect(summary.invalid_interval_count == 1, "1 invalid interval count");
    expect(summary.required_cell_count == 2, "2 point cells retained");
}

void test_large_route() {
    constexpr std::size_t sample_count = 100'000;
    std::vector<PersonalHeatmapRouteSample> samples;
    samples.reserve(sample_count);

    for (std::size_t i = 0; i < sample_count; ++i) {
        double offset = static_cast<double>(i) * 0.00001;
        samples.push_back(PersonalHeatmapRouteSample{
            37.7749 + offset,
            -122.4194 + offset,
            static_cast<std::int64_t>(i / 10'000)
        });
    }

    std::vector<PersonalHeatmapCellIndex> output(200'000);
    const auto summary = compute_personal_heatmap_workout_coverage(
        samples.data(), samples.size(), 10.0, 500.0, 10'000, output.data(), output.size());

    expect(summary.status == PersonalHeatmapCoverageStatus::success, "large route success");
    expect(summary.input_sample_count == sample_count, "large route input count");
    expect(summary.valid_projected_point_count == sample_count, "large route valid count");
    expect(summary.effective_segment_count == 10, "10 effective segments");
    expect(summary.written_cell_count > 0, "written cells > 0");
}

}  // namespace

void run_personal_heatmap_coverage_tests() {
    test_empty_and_boundary_errors();
    test_projection_and_cell_indexing();
    test_segments_and_invalid_gaps();
    test_coverage_traversal_and_sorting();
    test_oversized_intervals();
    test_large_route();
}
