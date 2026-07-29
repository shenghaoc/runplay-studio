#include "RunPlayEngineCpp/RouteAlignmentDtw.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <exception>
#include <limits>
#include <new>
#include <numbers>
#include <vector>

namespace runplay {
namespace {

constexpr std::int64_t int64_max = std::numeric_limits<std::int64_t>::max();
constexpr std::int64_t int64_min = std::numeric_limits<std::int64_t>::min();

/// Unreachable-cost sentinel. Matches Swift's `Double.greatestFiniteMagnitude / 4`.
const double unreachable_cost = std::numeric_limits<double>::max() / 4;

[[nodiscard]]
constexpr std::int64_t saturating_add(std::int64_t lhs, std::int64_t rhs) noexcept {
    if (rhs > 0 && lhs > int64_max - rhs) {
        return int64_max;
    }
    if (rhs < 0 && lhs < int64_min - rhs) {
        return int64_min;
    }
    return lhs + rhs;
}

[[nodiscard]]
constexpr std::int64_t saturating_sub(std::int64_t lhs, std::int64_t rhs) noexcept {
    if (rhs < 0 && lhs > int64_max + rhs) {
        return int64_max;
    }
    if (rhs > 0 && lhs < int64_min + rhs) {
        return int64_min;
    }
    return lhs - rhs;
}

/// Checked multiplication for non-negative operands.
[[nodiscard]]
constexpr bool checked_multiply(
    std::int64_t lhs,
    std::int64_t rhs,
    std::int64_t& out
) noexcept {
    if (lhs == 0 || rhs == 0) {
        out = 0;
        return true;
    }
    if (lhs > int64_max / rhs) {
        return false;
    }
    out = lhs * rhs;
    return true;
}

/// Checked addition for non-negative operands.
[[nodiscard]]
constexpr bool checked_add(
    std::int64_t lhs,
    std::int64_t rhs,
    std::int64_t& out
) noexcept {
    if (lhs > int64_max - rhs) {
        return false;
    }
    out = lhs + rhs;
    return true;
}

/// Truncates toward zero like Swift's `Int(_: Double)` but saturates instead of
/// trapping. Swift would trap on an out-of-range conversion, so no fixture that
/// the Swift oracle can evaluate ever reaches saturation; saturation exists only
/// so the C++ boundary stays free of undefined behaviour on hostile input.
[[nodiscard]]
std::int64_t saturating_int64_from_double(double value) noexcept {
    if (std::isnan(value)) {
        return 0;
    }
    // 2^63 as a double is exactly one past int64_max.
    constexpr double upper_bound = 9223372036854775808.0;
    constexpr double lower_bound = -9223372036854775808.0;
    if (value >= upper_bound) {
        return int64_max;
    }
    if (value <= lower_bound) {
        return int64_min;
    }
    return static_cast<std::int64_t>(value);
}

[[nodiscard]]
std::size_t to_size(std::int64_t value) noexcept {
    return static_cast<std::size_t>(value);
}

/// Literal port of `RouteAlignmentPolicy.maximumUnmatchedDistance(forRouteDistance:)`.
[[nodiscard]]
double maximum_unmatched_distance(
    double route_distance_meters,
    const RouteAlignmentDtwPolicy& policy
) noexcept {
    const double finite = std::isfinite(route_distance_meters)
        ? std::max(0.0, route_distance_meters)
        : 0.0;
    const double fractional =
        finite * policy.maximum_unmatched_prefix_suffix_fraction;
    return std::min(policy.maximum_unmatched_prefix_suffix_meters, fractional);
}

/// Literal port of the aligner's `maxPrefixSuffixSamples`.
///
/// Floors so the sample window cannot exceed the metre-based policy once
/// multiplied back by the effective interval.
[[nodiscard]]
std::int64_t max_prefix_suffix_samples(
    double primary_route_distance_meters,
    double comparison_route_distance_meters,
    double effective_sample_interval_meters,
    const RouteAlignmentDtwPolicy& policy
) noexcept {
    const double primary_maximum =
        maximum_unmatched_distance(primary_route_distance_meters, policy);
    const double comparison_maximum =
        maximum_unmatched_distance(comparison_route_distance_meters, policy);
    const double maximum_meters = std::max(primary_maximum, comparison_maximum);
    const double step = std::max(effective_sample_interval_meters, 1.0);
    const double quotient = maximum_meters / step;
    const double floored = std::floor(quotient);
    return std::max<std::int64_t>(1, saturating_int64_from_double(floored));
}

/// Literal port of `ConstrainedDynamicTimeWarpingAligner.pointCost`.
///
/// Statements are split so `-ffp-contract` cannot fuse a multiply-add that
/// Swift performs as two separately rounded operations.
[[nodiscard]]
double point_cost(
    const RouteAlignmentCostSample& primary,
    const RouteAlignmentCostSample& comparison,
    const RouteAlignmentDtwPolicy& policy
) noexcept {
    const double dx = primary.x_meters - comparison.x_meters;
    const double dz = primary.z_meters - comparison.z_meters;
    const double dx_squared = dx * dx;
    const double dz_squared = dz * dz;
    const double sum_of_squares = dx_squared + dz_squared;
    const double separation = std::sqrt(sum_of_squares);

    const double scale = std::max(policy.spatial_distance_cost_scale_meters, 1.0);
    const double scaled_separation = separation / scale;
    const double spatial = std::min(policy.maximum_spatial_cost, scaled_separation);

    double heading_term = 0.0;
    if (primary.has_heading != 0 && comparison.has_heading != 0) {
        const double heading_difference =
            primary.heading_radians - comparison.heading_radians;
        double delta = std::abs(heading_difference);
        if (delta > std::numbers::pi_v<double>) {
            const double full_turn = 2 * std::numbers::pi_v<double>;
            delta = full_turn - delta;
        }
        // 0...pi maps to 0...1 before weighting.
        const double normalized_delta = delta / std::numbers::pi_v<double>;
        heading_term = normalized_delta * policy.heading_penalty_weight;
    }

    const double progress_difference =
        primary.normalized_progress - comparison.normalized_progress;
    const double progress_delta = std::abs(progress_difference);
    const double progress_term = progress_delta * policy.progress_penalty_weight;

    const double spatial_and_heading = spatial + heading_term;
    const double total = spatial_and_heading + progress_term;
    if (std::isfinite(total)) {
        return total;
    }
    return policy.maximum_spatial_cost;
}

[[nodiscard]]
bool policy_is_finite(const RouteAlignmentDtwPolicy& policy) noexcept {
    return std::isfinite(policy.band_width_fraction)
        && std::isfinite(policy.maximum_unmatched_prefix_suffix_meters)
        && std::isfinite(policy.maximum_unmatched_prefix_suffix_fraction)
        && std::isfinite(policy.non_diagonal_step_penalty)
        && std::isfinite(policy.spatial_distance_cost_scale_meters)
        && std::isfinite(policy.maximum_spatial_cost)
        && std::isfinite(policy.heading_penalty_weight)
        && std::isfinite(policy.progress_penalty_weight);
}

[[nodiscard]]
bool samples_satisfy_contract(
    const RouteAlignmentCostSample* samples,
    std::int64_t count
) noexcept {
    for (std::int64_t i = 0; i < count; ++i) {
        const RouteAlignmentCostSample& sample = samples[to_size(i)];
        if (!std::isfinite(sample.x_meters) || !std::isfinite(sample.z_meters)) {
            return false;
        }
        if (!std::isfinite(sample.normalized_progress)) {
            return false;
        }
        if (sample.normalized_progress < 0.0 || sample.normalized_progress > 1.0) {
            return false;
        }
        if (sample.has_heading > 1) {
            return false;
        }
        if (sample.has_heading == 1 && !std::isfinite(sample.heading_radians)) {
            return false;
        }
    }
    return true;
}

/// Band-packed dynamic-programming state for one solve.
struct BandLayout final {
    std::vector<std::int64_t> row_starts;
    std::vector<std::int64_t> row_ends;
    std::vector<std::int64_t> offsets;
    std::int64_t total_cells{0};
};

constexpr std::uint8_t step_diagonal = 0;
constexpr std::uint8_t step_primary_only = 1;
constexpr std::uint8_t step_comparison_only = 2;
constexpr std::uint8_t step_unset = 255;

[[nodiscard]]
RouteAlignmentDtwSummary failure(
    RouteAlignmentDtwSummary summary,
    RouteAlignmentDtwStatus status
) noexcept {
    summary.status = status;
    summary.written_path_count = 0;
    return summary;
}

}  // namespace

RouteAlignmentDtwSummary compute_constrained_dtw_path(
    const RouteAlignmentCostSample* primary_samples,
    std::size_t primary_sample_count,

    const RouteAlignmentCostSample* comparison_samples,
    std::size_t comparison_sample_count,

    double primary_route_distance_meters,
    double comparison_route_distance_meters,
    double effective_sample_interval_meters,

    RouteAlignmentDtwPolicy policy,

    RouteAlignmentDtwPathCell* output_path,
    std::size_t output_capacity
) noexcept {
    RouteAlignmentDtwSummary summary{};
    summary.primary_sample_count =
        static_cast<std::uint64_t>(primary_sample_count);
    summary.comparison_sample_count =
        static_cast<std::uint64_t>(comparison_sample_count);

    // --- Buffer contracts ----------------------------------------------------

    if (primary_sample_count > 0 && primary_samples == nullptr) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_primary_buffer);
    }
    if (comparison_sample_count > 0 && comparison_samples == nullptr) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_comparison_buffer);
    }
    if (output_capacity > 0 && output_path == nullptr) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_output_buffer);
    }

    // The production aligner only calls after both routes satisfy the Swift
    // minimum-sample policy; an empty route is a boundary contract violation.
    if (primary_sample_count == 0 || comparison_sample_count == 0) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_input_contract);
    }

    // --- Policy contract -----------------------------------------------------

    if (!policy_is_finite(policy)) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_policy);
    }

    // --- Input contract ------------------------------------------------------

    constexpr std::size_t signed_limit = static_cast<std::size_t>(int64_max);
    if (primary_sample_count > signed_limit
        || comparison_sample_count > signed_limit) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_input_contract);
    }

    const std::int64_t n = static_cast<std::int64_t>(primary_sample_count);
    const std::int64_t m = static_cast<std::int64_t>(comparison_sample_count);

    // A valid path never exceeds n + m + 1 cells; the caller allocates that
    // bound, so it must be representable.
    std::int64_t path_upper_bound = 0;
    if (!checked_add(n, m, path_upper_bound)
        || !checked_add(path_upper_bound, 1, path_upper_bound)) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_input_contract);
    }

    if (!std::isfinite(primary_route_distance_meters)
        || primary_route_distance_meters <= 0.0
        || !std::isfinite(comparison_route_distance_meters)
        || comparison_route_distance_meters <= 0.0
        || !std::isfinite(effective_sample_interval_meters)
        || effective_sample_interval_meters <= 0.0) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_input_contract);
    }

    if (!samples_satisfy_contract(primary_samples, n)
        || !samples_satisfy_contract(comparison_samples, m)) {
        return failure(summary, RouteAlignmentDtwStatus::invalid_input_contract);
    }

    // --- Band radius ---------------------------------------------------------

    const std::int64_t open_samples = max_prefix_suffix_samples(
        primary_route_distance_meters,
        comparison_route_distance_meters,
        effective_sample_interval_meters,
        policy
    );

    const double longer_count = static_cast<double>(std::max(n, m));
    const double fractional_radius_raw = longer_count * policy.band_width_fraction;
    const double fractional_radius = std::ceil(fractional_radius_raw);
    const std::int64_t fractional_radius_samples =
        saturating_int64_from_double(fractional_radius);

    std::int64_t band_radius = std::max<std::int64_t>(1, fractional_radius_samples);
    band_radius = std::max(band_radius, open_samples);
    summary.band_radius = static_cast<std::uint64_t>(band_radius);

    // --- Estimated band budget ----------------------------------------------

    std::int64_t doubled_radius = 0;
    std::int64_t band_width = 0;
    std::int64_t estimated_cells = 0;
    if (!checked_multiply(2, band_radius, doubled_radius)
        || !checked_add(doubled_radius, 1, band_width)
        || !checked_multiply(n, band_width, estimated_cells)) {
        return failure(summary, RouteAlignmentDtwStatus::resource_limit);
    }
    if (static_cast<std::uint64_t>(estimated_cells) > policy.maximum_band_cells) {
        return failure(summary, RouteAlignmentDtwStatus::resource_limit);
    }

    try {
        // --- Band-packed row layout -----------------------------------------

        BandLayout layout;
        layout.row_starts.assign(to_size(n), 0);
        layout.row_ends.assign(to_size(n), -1);
        layout.offsets.assign(to_size(n), 0);

        const std::int64_t primary_span = std::max<std::int64_t>(n - 1, 1);
        const std::int64_t comparison_span = std::max<std::int64_t>(m - 1, 1);
        const std::int64_t suffix_threshold = saturating_sub(n, open_samples);

        for (std::int64_t i = 0; i < n; ++i) {
            const double row_position = static_cast<double>(i);
            const double normalized_row =
                row_position / static_cast<double>(primary_span);
            const double projected_column =
                normalized_row * static_cast<double>(comparison_span);
            const std::int64_t center =
                saturating_int64_from_double(projected_column);

            const std::int64_t j_start =
                std::max<std::int64_t>(0, saturating_sub(center, band_radius));
            const std::int64_t j_end =
                std::min<std::int64_t>(m - 1, saturating_add(center, band_radius));

            // Expand near both ends so an open beginning and open suffix stay
            // reachable inside the packed band.
            const std::int64_t expanded_start = i < open_samples ? 0 : j_start;
            const std::int64_t expanded_end =
                i >= suffix_threshold ? (m - 1) : j_end;

            const std::int64_t start = std::min(expanded_start, j_start);
            const std::int64_t end = std::max(expanded_end, j_end);

            layout.row_starts[to_size(i)] = start;
            layout.row_ends[to_size(i)] = end;
            layout.offsets[to_size(i)] = layout.total_cells;

            const std::int64_t row_cells =
                std::max<std::int64_t>(0, (end - start) + 1);
            if (!checked_add(layout.total_cells, row_cells, layout.total_cells)) {
                return failure(summary, RouteAlignmentDtwStatus::resource_limit);
            }
        }

        summary.band_cell_count = static_cast<std::uint64_t>(layout.total_cells);
        if (static_cast<std::uint64_t>(layout.total_cells)
            > policy.maximum_band_cells) {
            return failure(summary, RouteAlignmentDtwStatus::resource_limit);
        }

        // --- Band-packed dynamic-programming state ---------------------------

        std::vector<double> costs(to_size(layout.total_cells), unreachable_cost);
        std::vector<std::uint8_t> steps(to_size(layout.total_cells), step_unset);
        std::vector<std::uint8_t> warp_runs(to_size(layout.total_cells), 0);

        const auto packed_index = [&layout, n](
            std::int64_t i,
            std::int64_t j
        ) noexcept -> std::int64_t {
            if (i < 0 || i >= n) {
                return -1;
            }
            const std::size_t row = to_size(i);
            if (j < layout.row_starts[row] || j > layout.row_ends[row]) {
                return -1;
            }
            return layout.offsets[row] + (j - layout.row_starts[row]);
        };

        const auto cost_at = [&](std::int64_t i, std::int64_t j) noexcept -> double {
            return point_cost(
                primary_samples[to_size(i)],
                comparison_samples[to_size(j)],
                policy
            );
        };

        const double quarter_penalty = policy.non_diagonal_step_penalty * 0.25;

        // --- Open beginning: comparison prefix along row 0 -------------------

        for (std::int64_t j = layout.row_starts[0]; j <= layout.row_ends[0]; ++j) {
            const std::int64_t index = packed_index(0, j);
            if (index < 0) {
                continue;
            }
            const std::size_t cell = to_size(index);
            if (j == 0) {
                costs[cell] = cost_at(0, 0);
                steps[cell] = step_diagonal;
                warp_runs[cell] = 0;
            } else if (j <= open_samples) {
                const std::int64_t previous = packed_index(0, j - 1);
                const double previous_cost =
                    previous >= 0 ? costs[to_size(previous)] : unreachable_cost;
                const double partial = previous_cost + cost_at(0, j);
                costs[cell] = partial + quarter_penalty;
                steps[cell] = step_comparison_only;
                const std::size_t warp_source =
                    previous >= 0 ? to_size(previous) : cell;
                const std::int64_t run =
                    static_cast<std::int64_t>(warp_runs[warp_source]) + 1;
                warp_runs[cell] =
                    static_cast<std::uint8_t>(std::min<std::int64_t>(255, run));
            }
        }

        // --- Open beginning: primary prefix down column 0 --------------------

        for (std::int64_t i = 1; i < n; ++i) {
            if (layout.row_starts[to_size(i)] != 0) {
                continue;
            }
            const std::int64_t index = packed_index(i, 0);
            const std::int64_t previous = packed_index(i - 1, 0);
            if (index < 0 || previous < 0) {
                continue;
            }
            if (i <= open_samples) {
                const std::size_t cell = to_size(index);
                const std::size_t previous_cell = to_size(previous);
                const double partial = costs[previous_cell] + cost_at(i, 0);
                costs[cell] = partial + quarter_penalty;
                steps[cell] = step_primary_only;
                const std::int64_t run =
                    static_cast<std::int64_t>(warp_runs[previous_cell]) + 1;
                warp_runs[cell] =
                    static_cast<std::uint8_t>(std::min<std::int64_t>(255, run));
            }
        }

        // --- Constrained transitions -----------------------------------------

        for (std::int64_t i = 1; i < n; ++i) {
            const std::int64_t j_low = layout.row_starts[to_size(i)];
            const std::int64_t j_high = layout.row_ends[to_size(i)];
            if (j_low > j_high) {
                continue;
            }
            for (std::int64_t j = j_low; j <= j_high; ++j) {
                if (j == 0) {
                    continue;
                }
                const std::int64_t index = packed_index(i, j);
                if (index < 0) {
                    continue;
                }
                const std::size_t cell = to_size(index);
                const double step_cost = cost_at(i, j);

                double best = unreachable_cost;
                std::uint8_t best_step = step_diagonal;
                std::uint8_t best_warp = 0;

                // Evaluated diagonal, then primary-only, then comparison-only,
                // replacing only on a strictly lower candidate. That ordering is
                // the tie priority: diagonal wins, then primary-only.
                const std::int64_t diagonal = packed_index(i - 1, j - 1);
                if (diagonal >= 0 && costs[to_size(diagonal)] < unreachable_cost) {
                    const double candidate = costs[to_size(diagonal)] + step_cost;
                    if (candidate < best) {
                        best = candidate;
                        best_step = step_diagonal;
                        best_warp = 0;
                    }
                }

                const std::int64_t vertical = packed_index(i - 1, j);
                if (vertical >= 0 && costs[to_size(vertical)] < unreachable_cost) {
                    const std::int64_t run =
                        static_cast<std::int64_t>(warp_runs[to_size(vertical)]) + 1;
                    if (static_cast<std::uint64_t>(run)
                        <= policy.maximum_consecutive_warp_steps) {
                        const double partial = costs[to_size(vertical)] + step_cost;
                        const double candidate =
                            partial + policy.non_diagonal_step_penalty;
                        if (candidate < best) {
                            best = candidate;
                            best_step = step_primary_only;
                            best_warp = static_cast<std::uint8_t>(
                                std::min<std::int64_t>(255, run)
                            );
                        }
                    }
                }

                const std::int64_t horizontal = packed_index(i, j - 1);
                if (horizontal >= 0
                    && costs[to_size(horizontal)] < unreachable_cost) {
                    const std::int64_t run =
                        static_cast<std::int64_t>(warp_runs[to_size(horizontal)]) + 1;
                    if (static_cast<std::uint64_t>(run)
                        <= policy.maximum_consecutive_warp_steps) {
                        const double partial =
                            costs[to_size(horizontal)] + step_cost;
                        const double candidate =
                            partial + policy.non_diagonal_step_penalty;
                        if (candidate < best) {
                            best = candidate;
                            best_step = step_comparison_only;
                            best_warp = static_cast<std::uint8_t>(
                                std::min<std::int64_t>(255, run)
                            );
                        }
                    }
                }

                costs[cell] = best;
                steps[cell] = best_step;
                warp_runs[cell] = best_warp;
            }
        }

        // --- Open-suffix endpoint selection ----------------------------------

        std::int64_t best_end_primary = n - 1;
        std::int64_t best_end_comparison = m - 1;
        double best_end_cost = unreachable_cost;

        const std::int64_t primary_from =
            std::max<std::int64_t>(0, saturating_sub(n - 1, open_samples));
        const std::int64_t comparison_from =
            std::max<std::int64_t>(0, saturating_sub(m - 1, open_samples));

        for (std::int64_t i = primary_from; i < n; ++i) {
            for (std::int64_t j = comparison_from; j < m; ++j) {
                const std::int64_t index = packed_index(i, j);
                if (index < 0) {
                    continue;
                }
                if (!(costs[to_size(index)] < best_end_cost)) {
                    continue;
                }
                best_end_cost = costs[to_size(index)];
                best_end_primary = i;
                best_end_comparison = j;
            }
        }

        if (!(best_end_cost < unreachable_cost)
            || packed_index(best_end_primary, best_end_comparison) < 0) {
            return failure(summary, RouteAlignmentDtwStatus::no_path);
        }

        // --- Path reconstruction ---------------------------------------------

        std::vector<RouteAlignmentDtwPathCell> path;
        path.reserve(to_size(std::min<std::int64_t>(path_upper_bound, 4096)));

        std::int64_t current_primary = best_end_primary;
        std::int64_t current_comparison = best_end_comparison;
        std::int64_t guard_counter = 0;
        const std::int64_t guard_limit = saturating_add(path_upper_bound, 7);

        while (true) {
            guard_counter += 1;
            if (guard_counter > guard_limit) {
                break;
            }
            const std::int64_t index =
                packed_index(current_primary, current_comparison);
            if (index < 0 || steps[to_size(index)] == step_unset) {
                break;
            }

            const std::uint8_t raw_step = steps[to_size(index)];
            RouteAlignmentDtwStepKind step = RouteAlignmentDtwStepKind::diagonal;
            switch (raw_step) {
                case step_diagonal:
                    step = RouteAlignmentDtwStepKind::diagonal;
                    break;
                case step_primary_only:
                    step = RouteAlignmentDtwStepKind::primary_only;
                    break;
                case step_comparison_only:
                    step = RouteAlignmentDtwStepKind::comparison_only;
                    break;
                default:
                    // Unreachable: only 0, 1, 2, and the unset sentinel are ever
                    // stored. Refuse to emit a path from corrupted state.
                    return failure(
                        summary,
                        RouteAlignmentDtwStatus::internal_failure
                    );
            }

            path.push_back(RouteAlignmentDtwPathCell{
                static_cast<std::uint64_t>(current_primary),
                static_cast<std::uint64_t>(current_comparison),
                step
            });

            if (current_primary == 0 && current_comparison == 0) {
                break;
            }

            const std::int64_t previous_primary = current_primary;
            const std::int64_t previous_comparison = current_comparison;

            switch (step) {
                case RouteAlignmentDtwStepKind::diagonal:
                    current_primary = std::max<std::int64_t>(0, current_primary - 1);
                    current_comparison =
                        std::max<std::int64_t>(0, current_comparison - 1);
                    break;
                case RouteAlignmentDtwStepKind::primary_only:
                    if (current_primary != 0) {
                        current_primary -= 1;
                    }
                    break;
                case RouteAlignmentDtwStepKind::comparison_only:
                    if (current_comparison != 0) {
                        current_comparison -= 1;
                    }
                    break;
            }

            if (current_primary == previous_primary
                && current_comparison == previous_comparison) {
                // A primary-only step at row 0 or a comparison-only step at
                // column 0 cannot occur: row 0 stores only diagonal and
                // comparison-only, column 0 only diagonal and primary-only.
                // Treat it as corrupted state rather than emitting duplicates.
                return failure(summary, RouteAlignmentDtwStatus::internal_failure);
            }

            if (current_primary == 0 && current_comparison == 0) {
                path.push_back(RouteAlignmentDtwPathCell{
                    0,
                    0,
                    RouteAlignmentDtwStepKind::diagonal
                });
                break;
            }
        }

        std::reverse(path.begin(), path.end());

        if (path.empty()) {
            return failure(summary, RouteAlignmentDtwStatus::no_path);
        }

        summary.required_path_count = static_cast<std::uint64_t>(path.size());
        summary.best_end_primary_index =
            static_cast<std::uint64_t>(best_end_primary);
        summary.best_end_comparison_index =
            static_cast<std::uint64_t>(best_end_comparison);
        summary.best_end_cost = best_end_cost;

        if (output_capacity < path.size()) {
            return failure(
                summary,
                RouteAlignmentDtwStatus::insufficient_output_capacity
            );
        }

        for (std::size_t i = 0; i < path.size(); ++i) {
            output_path[i] = path[i];
        }

        summary.written_path_count = static_cast<std::uint64_t>(path.size());
        summary.status = RouteAlignmentDtwStatus::success;
        return summary;
    } catch (const std::bad_alloc&) {
        return failure(summary, RouteAlignmentDtwStatus::allocation_failure);
    } catch (...) {
        return failure(summary, RouteAlignmentDtwStatus::internal_failure);
    }
}

}  // namespace runplay
