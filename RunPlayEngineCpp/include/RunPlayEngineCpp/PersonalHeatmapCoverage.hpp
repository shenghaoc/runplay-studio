#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace runplay {

inline constexpr double personal_heatmap_max_latitude_degrees =
    85.05112878;

inline constexpr std::size_t
personal_heatmap_default_maximum_cells_per_interval = 10000;

struct PersonalHeatmapRouteSample final {
    double latitude{0};
    double longitude{0};
    std::int64_t route_segment_index{0};
};

static_assert(std::is_standard_layout_v<PersonalHeatmapRouteSample>);
static_assert(std::is_trivially_copyable_v<PersonalHeatmapRouteSample>);
static_assert(std::is_nothrow_default_constructible_v<PersonalHeatmapRouteSample>);
static_assert(std::is_nothrow_copy_constructible_v<PersonalHeatmapRouteSample>);

struct PersonalHeatmapCellIndex final {
    std::int64_t x{0};
    std::int64_t y{0};
};

static_assert(std::is_standard_layout_v<PersonalHeatmapCellIndex>);
static_assert(std::is_trivially_copyable_v<PersonalHeatmapCellIndex>);
static_assert(std::is_nothrow_default_constructible_v<PersonalHeatmapCellIndex>);
static_assert(std::is_nothrow_copy_constructible_v<PersonalHeatmapCellIndex>);

enum class PersonalHeatmapCoverageStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_output_buffer,
    insufficient_output_capacity,
    invalid_configuration,
    invalid_input_contract,
    allocation_failure,
    internal_failure,
};

struct PersonalHeatmapCoverageSummary final {
    PersonalHeatmapCoverageStatus status{
        PersonalHeatmapCoverageStatus::success
    };

    std::uint64_t input_sample_count{0};
    std::uint64_t valid_projected_point_count{0};
    std::uint64_t effective_segment_count{0};
    std::uint64_t invalid_interval_count{0};

    std::uint64_t required_cell_count{0};
    std::uint64_t written_cell_count{0};
};

static_assert(std::is_standard_layout_v<PersonalHeatmapCoverageSummary>);
static_assert(std::is_trivially_copyable_v<PersonalHeatmapCoverageSummary>);
static_assert(std::is_nothrow_default_constructible_v<PersonalHeatmapCoverageSummary>);
static_assert(std::is_nothrow_copy_constructible_v<PersonalHeatmapCoverageSummary>);

[[nodiscard]]
PersonalHeatmapCoverageSummary
compute_personal_heatmap_workout_coverage(
    const PersonalHeatmapRouteSample* samples,
    std::size_t sample_count,
    double cell_size_meters,
    double maximum_interval_meters,
    std::size_t maximum_cells_per_interval,
    PersonalHeatmapCellIndex* output_cells,
    std::size_t output_capacity
) noexcept;

}  // namespace runplay
