#include "RunPlayEngineCpp/PersonalHeatmapCoverage.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <exception>
#include <limits>
#include <new>
#include <unordered_set>
#include <vector>

#include "Internal/PersonalHeatmapProjectionInternal.hpp"

namespace runplay {
namespace {

struct InternalProjectedSample final {
    double x{0};
    double y{0};
    std::uint64_t effective_segment{0};
};

struct CellIndexHash final {
    [[nodiscard]]
    std::size_t operator()(const PersonalHeatmapCellIndex& cell) const noexcept {
        const std::uint64_t ux = static_cast<std::uint64_t>(cell.x);
        const std::uint64_t uy = static_cast<std::uint64_t>(cell.y);
        // Standard 64-bit split mix hash combination
        std::uint64_t h = ux ^ (uy + 0x9e3779b97f4a7c15ULL + (ux << 6) + (ux >> 2));
        return static_cast<std::size_t>(h);
    }
};

struct CellIndexEqual final {
    [[nodiscard]]
    bool operator()(const PersonalHeatmapCellIndex& lhs, const PersonalHeatmapCellIndex& rhs) const noexcept {
        return lhs.x == rhs.x && lhs.y == rhs.y;
    }
};

void supercover_grid_traversal(
    InternalProjectedSample start,
    InternalProjectedSample end,
    double cell_size_meters,
    std::size_t maximum_cells,
    std::unordered_set<PersonalHeatmapCellIndex, CellIndexHash, CellIndexEqual>& visited_cells
) {
    if (maximum_cells < 1) {
        return;
    }

    const auto start_x_opt = internal::personal_heatmap_cell_index(start.x, cell_size_meters);
    const auto start_y_opt = internal::personal_heatmap_cell_index(start.y, cell_size_meters);
    if (!start_x_opt.has_value() || !start_y_opt.has_value()) {
        return;
    }

    const std::int64_t start_x = *start_x_opt;
    const std::int64_t start_y = *start_y_opt;

    if (start.x == end.x && start.y == end.y) {
        visited_cells.insert(PersonalHeatmapCellIndex{start_x, start_y});
        return;
    }

    const auto end_x_opt = internal::personal_heatmap_cell_index(end.x, cell_size_meters);
    const auto end_y_opt = internal::personal_heatmap_cell_index(end.y, cell_size_meters);
    if (!end_x_opt.has_value() || !end_y_opt.has_value()) {
        return;
    }

    const std::int64_t end_x = *end_x_opt;
    const std::int64_t end_y = *end_y_opt;

    if (start_x == end_x && start_y == end_y) {
        visited_cells.insert(PersonalHeatmapCellIndex{start_x, start_y});
        return;
    }

    std::int64_t x = start_x;
    std::int64_t y = start_y;

    const double dx = end.x - start.x;
    const double dy = end.y - start.y;

    const std::int64_t step_x = dx > 0 ? 1 : (dx < 0 ? -1 : 0);
    const std::int64_t step_y = dy > 0 ? 1 : (dy < 0 ? -1 : 0);

    const double t_delta_x = step_x == 0 ? std::numeric_limits<double>::infinity() : std::abs(cell_size_meters / dx);
    const double t_delta_y = step_y == 0 ? std::numeric_limits<double>::infinity() : std::abs(cell_size_meters / dy);

    auto next_boundary = [](std::int64_t index, std::int64_t step, double cell_size) noexcept -> double {
        if (step > 0) {
            return static_cast<double>(index + 1) * cell_size;
        } else if (step < 0) {
            return static_cast<double>(index) * cell_size;
        }
        return 0.0;
    };

    double t_max_x = 0.0;
    if (step_x == 0) {
        t_max_x = std::numeric_limits<double>::infinity();
    } else {
        const double boundary = next_boundary(x, step_x, cell_size_meters);
        t_max_x = (boundary - start.x) / dx;
        if (t_max_x < 0.0) { t_max_x = 0.0; }
    }

    double t_max_y = 0.0;
    if (step_y == 0) {
        t_max_y = std::numeric_limits<double>::infinity();
    } else {
        const double boundary = next_boundary(y, step_y, cell_size_meters);
        t_max_y = (boundary - start.y) / dy;
        if (t_max_y < 0.0) { t_max_y = 0.0; }
    }

    std::vector<PersonalHeatmapCellIndex> interval_cells;
    interval_cells.reserve(std::min(maximum_cells, static_cast<std::size_t>(64)));
    interval_cells.push_back(PersonalHeatmapCellIndex{x, y});

    std::size_t iterations = 0;
    while ((x != end_x || y != end_y) && iterations < maximum_cells) {
        iterations++;

        if (t_max_x == t_max_y) {
            t_max_x += t_delta_x;
            t_max_y += t_delta_y;
            if (step_x != 0) { x += step_x; }
            if (step_y != 0) { y += step_y; }
        } else if (t_max_x < t_max_y) {
            t_max_x += t_delta_x;
            if (step_x != 0) { x += step_x; }
        } else {
            t_max_y += t_delta_y;
            if (step_y != 0) { y += step_y; }
        }

        const double next_t = std::min(t_max_x, t_max_y);
        if (!std::isfinite(next_t) && (x != end_x || y != end_y)) {
            x = end_x;
            y = end_y;
        }

        const PersonalHeatmapCellIndex cell{x, y};
        if (interval_cells.back().x != cell.x || interval_cells.back().y != cell.y) {
            interval_cells.push_back(cell);
        }

        if (t_max_x > 1.0000001 && t_max_y > 1.0000001) {
            if (interval_cells.back().x != end_x || interval_cells.back().y != end_y) {
                interval_cells.push_back(PersonalHeatmapCellIndex{end_x, end_y});
            }
            break;
        }
    }

    const PersonalHeatmapCellIndex end_cell{end_x, end_y};
    if ((interval_cells.back().x != end_cell.x || interval_cells.back().y != end_cell.y) &&
        interval_cells.size() < maximum_cells) {
        interval_cells.push_back(end_cell);
    }

    for (const auto& cell : interval_cells) {
        visited_cells.insert(cell);
    }
}

}  // namespace

PersonalHeatmapCoverageSummary
compute_personal_heatmap_workout_coverage(
    const PersonalHeatmapRouteSample* samples,
    std::size_t sample_count,
    double cell_size_meters,
    double maximum_interval_meters,
    std::size_t maximum_cells_per_interval,
    PersonalHeatmapCellIndex* output_cells,
    std::size_t output_capacity
) noexcept {
    PersonalHeatmapCoverageSummary summary{};
    summary.input_sample_count = static_cast<std::uint64_t>(sample_count);

    if (sample_count == 0) {
        if (!std::isfinite(cell_size_meters) || cell_size_meters <= 0.0 ||
            !std::isfinite(maximum_interval_meters) || maximum_interval_meters <= 0.0 ||
            maximum_cells_per_interval < 1) {
            summary.status = PersonalHeatmapCoverageStatus::invalid_configuration;
            return summary;
        }
        summary.status = PersonalHeatmapCoverageStatus::success;
        summary.required_cell_count = 0;
        summary.written_cell_count = 0;
        return summary;
    }

    if (samples == nullptr) {
        summary.status = PersonalHeatmapCoverageStatus::invalid_input_buffer;
        return summary;
    }

    if (output_cells == nullptr && output_capacity > 0) {
        summary.status = PersonalHeatmapCoverageStatus::invalid_output_buffer;
        return summary;
    }

    if (!std::isfinite(cell_size_meters) || cell_size_meters <= 0.0 ||
        !std::isfinite(maximum_interval_meters) || maximum_interval_meters <= 0.0 ||
        maximum_cells_per_interval < 1) {
        summary.status = PersonalHeatmapCoverageStatus::invalid_configuration;
        return summary;
    }

    try {
        std::vector<InternalProjectedSample> projected;
        projected.reserve(sample_count);

        std::uint64_t effective_segment = 0;
        std::int64_t previous_source_segment = 0;
        bool requires_new_segment = true;

        for (std::size_t i = 0; i < sample_count; ++i) {
            const auto& sample = samples[i];
            const auto proj_opt = internal::personal_heatmap_project(sample.latitude, sample.longitude);
            if (!proj_opt.has_value()) {
                requires_new_segment = true;
                continue;
            }

            if (requires_new_segment || previous_source_segment != sample.route_segment_index) {
                effective_segment++;
            }

            projected.push_back(InternalProjectedSample{
                proj_opt->x,
                proj_opt->y,
                effective_segment
            });

            previous_source_segment = sample.route_segment_index;
            requires_new_segment = false;
        }

        summary.valid_projected_point_count = static_cast<std::uint64_t>(projected.size());
        summary.effective_segment_count = effective_segment;

        std::unordered_set<PersonalHeatmapCellIndex, CellIndexHash, CellIndexEqual> visited_cells;
        visited_cells.reserve(std::min(projected.size() * 2, static_cast<std::size_t>(4096)));

        for (const auto& point : projected) {
            const auto x_opt = internal::personal_heatmap_cell_index(point.x, cell_size_meters);
            const auto y_opt = internal::personal_heatmap_cell_index(point.y, cell_size_meters);
            if (x_opt.has_value() && y_opt.has_value()) {
                visited_cells.insert(PersonalHeatmapCellIndex{*x_opt, *y_opt});
            }
        }

        if (projected.size() > 1) {
            for (std::size_t i = 0; i < projected.size() - 1; ++i) {
                const auto& a = projected[i];
                const auto& b = projected[i + 1];

                if (a.effective_segment != b.effective_segment) {
                    continue;
                }

                const double dx = b.x - a.x;
                const double dy = b.y - a.y;
                const double length = std::sqrt(dx * dx + dy * dy);

                if (length == 0.0) {
                    const auto x_opt = internal::personal_heatmap_cell_index(a.x, cell_size_meters);
                    const auto y_opt = internal::personal_heatmap_cell_index(a.y, cell_size_meters);
                    if (x_opt.has_value() && y_opt.has_value()) {
                        visited_cells.insert(PersonalHeatmapCellIndex{*x_opt, *y_opt});
                    }
                    continue;
                }

                if (length > maximum_interval_meters) {
                    summary.invalid_interval_count++;
                    continue;
                }

                supercover_grid_traversal(
                    a,
                    b,
                    cell_size_meters,
                    maximum_cells_per_interval,
                    visited_cells
                );
            }
        }

        summary.required_cell_count = static_cast<std::uint64_t>(visited_cells.size());

        if (output_capacity < summary.required_cell_count) {
            summary.status = PersonalHeatmapCoverageStatus::insufficient_output_capacity;
            summary.written_cell_count = 0;
            return summary;
        }

        std::vector<PersonalHeatmapCellIndex> sorted_cells(visited_cells.begin(), visited_cells.end());
        std::sort(sorted_cells.begin(), sorted_cells.end(), [](const PersonalHeatmapCellIndex& lhs, const PersonalHeatmapCellIndex& rhs) noexcept {
            if (lhs.y != rhs.y) {
                return lhs.y < rhs.y;
            }
            return lhs.x < rhs.x;
        });

        for (std::size_t i = 0; i < sorted_cells.size(); ++i) {
            output_cells[i] = sorted_cells[i];
        }

        summary.written_cell_count = static_cast<std::uint64_t>(sorted_cells.size());
        summary.status = PersonalHeatmapCoverageStatus::success;
        return summary;
    } catch (const std::bad_alloc&) {
        summary.status = PersonalHeatmapCoverageStatus::allocation_failure;
        summary.written_cell_count = 0;
        return summary;
    } catch (...) {
        summary.status = PersonalHeatmapCoverageStatus::internal_failure;
        summary.written_cell_count = 0;
        return summary;
    }
}

}  // namespace runplay
