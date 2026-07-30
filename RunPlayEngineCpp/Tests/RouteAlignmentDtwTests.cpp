#include "RunPlayEngineCpp/RunPlayEngine.hpp"
#include "TestSupport.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <numbers>
#include <type_traits>
#include <vector>

// --- Compile-time contract ---------------------------------------------------

static_assert(__cplusplus >= 202302L, "RunPlayEngineCpp must compile as C++23");

static_assert(
    noexcept(runplay::compute_constrained_dtw_path(
        nullptr,
        0,
        nullptr,
        0,
        0.0,
        0.0,
        0.0,
        runplay::RouteAlignmentDtwPolicy{},
        nullptr,
        0)),
    "compute_constrained_dtw_path must remain noexcept");

static_assert(
    std::is_nothrow_invocable_v<
        decltype(&runplay::compute_constrained_dtw_path),
        const runplay::RouteAlignmentCostSample*,
        std::size_t,
        const runplay::RouteAlignmentCostSample*,
        std::size_t,
        double,
        double,
        double,
        runplay::RouteAlignmentDtwPolicy,
        runplay::RouteAlignmentDtwPathCell*,
        std::size_t>,
    "compute_constrained_dtw_path must be nothrow-invocable across the boundary");

static_assert(
    std::is_same_v<
        std::invoke_result_t<
            decltype(&runplay::compute_constrained_dtw_path),
            const runplay::RouteAlignmentCostSample*,
            std::size_t,
            const runplay::RouteAlignmentCostSample*,
            std::size_t,
            double,
            double,
            double,
            runplay::RouteAlignmentDtwPolicy,
            runplay::RouteAlignmentDtwPathCell*,
            std::size_t>,
        runplay::RouteAlignmentDtwSummary>,
    "compute_constrained_dtw_path must return RouteAlignmentDtwSummary by value");

static_assert(std::is_standard_layout_v<runplay::RouteAlignmentCostSample>);
static_assert(std::is_trivially_copyable_v<runplay::RouteAlignmentCostSample>);
static_assert(
    std::is_nothrow_default_constructible_v<runplay::RouteAlignmentCostSample>);
static_assert(
    std::is_nothrow_copy_constructible_v<runplay::RouteAlignmentCostSample>);

static_assert(std::is_standard_layout_v<runplay::RouteAlignmentDtwPolicy>);
static_assert(std::is_trivially_copyable_v<runplay::RouteAlignmentDtwPolicy>);
static_assert(
    std::is_nothrow_default_constructible_v<runplay::RouteAlignmentDtwPolicy>);
static_assert(
    std::is_nothrow_copy_constructible_v<runplay::RouteAlignmentDtwPolicy>);

static_assert(std::is_standard_layout_v<runplay::RouteAlignmentDtwPathCell>);
static_assert(std::is_trivially_copyable_v<runplay::RouteAlignmentDtwPathCell>);
static_assert(
    std::is_nothrow_default_constructible_v<runplay::RouteAlignmentDtwPathCell>);
static_assert(
    std::is_nothrow_copy_constructible_v<runplay::RouteAlignmentDtwPathCell>);

static_assert(std::is_standard_layout_v<runplay::RouteAlignmentDtwSummary>);
static_assert(std::is_trivially_copyable_v<runplay::RouteAlignmentDtwSummary>);
static_assert(
    std::is_nothrow_default_constructible_v<runplay::RouteAlignmentDtwSummary>);
static_assert(
    std::is_nothrow_copy_constructible_v<runplay::RouteAlignmentDtwSummary>);

static_assert(
    std::is_same_v<std::underlying_type_t<runplay::RouteAlignmentDtwStepKind>,
                   std::uint8_t>,
    "step kind must stay a byte so Swift can map it positionally");

namespace {

using runplay::RouteAlignmentCostSample;
using runplay::RouteAlignmentDtwPathCell;
using runplay::RouteAlignmentDtwPolicy;
using runplay::RouteAlignmentDtwStatus;
using runplay::RouteAlignmentDtwStepKind;
using runplay::RouteAlignmentDtwSummary;
using runplay::compute_constrained_dtw_path;

constexpr double quiet_nan = std::numeric_limits<double>::quiet_NaN();
constexpr double infinity = std::numeric_limits<double>::infinity();

// --- Sample and policy construction -----------------------------------------

[[nodiscard]]
RouteAlignmentCostSample point(double x_meters) noexcept {
    return RouteAlignmentCostSample{x_meters, 0.0, 0.0, 0.0, 0};
}

[[nodiscard]]
RouteAlignmentCostSample point_at(
    double x_meters,
    double z_meters,
    double normalized_progress
) noexcept {
    return RouteAlignmentCostSample{
        x_meters, z_meters, normalized_progress, 0.0, 0};
}

[[nodiscard]]
RouteAlignmentCostSample point_with_heading(
    double x_meters,
    double z_meters,
    double normalized_progress,
    double heading_radians
) noexcept {
    return RouteAlignmentCostSample{
        x_meters, z_meters, normalized_progress, heading_radians, 1};
}

[[nodiscard]]
std::vector<RouteAlignmentCostSample> line(
    std::initializer_list<double> x_values
) {
    std::vector<RouteAlignmentCostSample> result;
    result.reserve(x_values.size());
    for (const double x_meters : x_values) {
        result.push_back(point(x_meters));
    }
    return result;
}

/// Small-fixture policy: the band covers the whole matrix, the open
/// prefix/suffix window collapses to its floor of one sample, the non-diagonal
/// penalty is zero, and point cost reduces to plain metre separation.
[[nodiscard]]
RouteAlignmentDtwPolicy tight_policy() noexcept {
    RouteAlignmentDtwPolicy policy{};
    policy.band_width_fraction = 1.0;
    policy.maximum_unmatched_prefix_suffix_meters = 0.0;
    policy.maximum_unmatched_prefix_suffix_fraction = 0.0;
    policy.non_diagonal_step_penalty = 0.0;
    policy.maximum_consecutive_warp_steps = 6;
    policy.spatial_distance_cost_scale_meters = 1.0;
    policy.maximum_spatial_cost = 1.0e9;
    policy.heading_penalty_weight = 0.0;
    policy.progress_penalty_weight = 0.0;
    policy.maximum_band_cells = 1'000'000;
    return policy;
}

/// The product defaults carried by `RouteAlignmentPolicy.default`.
[[nodiscard]]
RouteAlignmentDtwPolicy product_default_policy() noexcept {
    RouteAlignmentDtwPolicy policy{};
    policy.band_width_fraction = 0.15;
    policy.maximum_unmatched_prefix_suffix_meters = 500.0;
    policy.maximum_unmatched_prefix_suffix_fraction = 0.10;
    policy.non_diagonal_step_penalty = 0.35;
    policy.maximum_consecutive_warp_steps = 6;
    policy.spatial_distance_cost_scale_meters = 50.0;
    policy.maximum_spatial_cost = 8.0;
    policy.heading_penalty_weight = 0.45;
    policy.progress_penalty_weight = 1.5;
    policy.maximum_band_cells = 4'000'000;
    return policy;
}

// --- Output buffer helpers ---------------------------------------------------

constexpr std::uint64_t sentinel_primary = 0xFEEDFACE00000000ULL;
constexpr std::uint64_t sentinel_comparison = 0x0BADC0DE00000000ULL;

[[nodiscard]]
std::vector<RouteAlignmentDtwPathCell> make_output(
    std::size_t primary_count,
    std::size_t comparison_count
) {
    return std::vector<RouteAlignmentDtwPathCell>(
        primary_count + comparison_count + 1);
}

void fill_sentinel(std::vector<RouteAlignmentDtwPathCell>& buffer) noexcept {
    for (std::size_t i = 0; i < buffer.size(); ++i) {
        buffer[i].primary_index = sentinel_primary + static_cast<std::uint64_t>(i);
        buffer[i].comparison_index =
            sentinel_comparison + static_cast<std::uint64_t>(i);
        buffer[i].step = RouteAlignmentDtwStepKind::comparison_only;
    }
}

void expect_untouched(
    const std::vector<RouteAlignmentDtwPathCell>& buffer,
    const char* message
) {
    for (std::size_t i = 0; i < buffer.size(); ++i) {
        expect(
            buffer[i].primary_index
                == sentinel_primary + static_cast<std::uint64_t>(i),
            message);
        expect(
            buffer[i].comparison_index
                == sentinel_comparison + static_cast<std::uint64_t>(i),
            message);
        expect(
            buffer[i].step == RouteAlignmentDtwStepKind::comparison_only,
            message);
    }
}

[[nodiscard]]
RouteAlignmentDtwSummary solve(
    const std::vector<RouteAlignmentCostSample>& primary,
    const std::vector<RouteAlignmentCostSample>& comparison,
    double primary_route_distance_meters,
    double comparison_route_distance_meters,
    double effective_sample_interval_meters,
    const RouteAlignmentDtwPolicy& policy,
    std::vector<RouteAlignmentDtwPathCell>& output
) noexcept {
    return compute_constrained_dtw_path(
        primary.data(),
        primary.size(),
        comparison.data(),
        comparison.size(),
        primary_route_distance_meters,
        comparison_route_distance_meters,
        effective_sample_interval_meters,
        policy,
        output.data(),
        output.size());
}

// --- Path assertions ---------------------------------------------------------

struct ExpectedCell final {
    std::uint64_t primary_index{0};
    std::uint64_t comparison_index{0};
    RouteAlignmentDtwStepKind step{RouteAlignmentDtwStepKind::diagonal};
};

/// Structural invariants every successful solve must satisfy: reported counts
/// agree, indexes stay in range, the endpoint matches the final cell, and each
/// stored step exactly describes the index delta that reached its cell. Because
/// every step advances at least one index, this also rules out duplicates and
/// any backwards move.
void expect_valid_path(
    const RouteAlignmentDtwSummary& summary,
    const std::vector<RouteAlignmentDtwPathCell>& output,
    std::size_t primary_count,
    std::size_t comparison_count,
    const char* message
) {
    expect(summary.status == RouteAlignmentDtwStatus::success, message);
    expect(
        summary.primary_sample_count
            == static_cast<std::uint64_t>(primary_count),
        message);
    expect(
        summary.comparison_sample_count
            == static_cast<std::uint64_t>(comparison_count),
        message);
    expect(summary.written_path_count == summary.required_path_count, message);
    expect(summary.written_path_count > 0, message);
    expect(
        summary.written_path_count
            <= static_cast<std::uint64_t>(
                primary_count + comparison_count + 1),
        message);
    expect(
        summary.written_path_count <= static_cast<std::uint64_t>(output.size()),
        message);

    for (std::uint64_t k = 0; k < summary.written_path_count; ++k) {
        const RouteAlignmentDtwPathCell& cell =
            output[static_cast<std::size_t>(k)];
        expect(
            cell.primary_index < static_cast<std::uint64_t>(primary_count),
            message);
        expect(
            cell.comparison_index
                < static_cast<std::uint64_t>(comparison_count),
            message);

        if (k == 0) {
            continue;
        }

        const RouteAlignmentDtwPathCell& previous =
            output[static_cast<std::size_t>(k - 1)];
        switch (cell.step) {
            case RouteAlignmentDtwStepKind::diagonal:
                expect(
                    cell.primary_index == previous.primary_index + 1
                        && cell.comparison_index
                            == previous.comparison_index + 1,
                    message);
                break;
            case RouteAlignmentDtwStepKind::primary_only:
                expect(
                    cell.primary_index == previous.primary_index + 1
                        && cell.comparison_index == previous.comparison_index,
                    message);
                break;
            case RouteAlignmentDtwStepKind::comparison_only:
                expect(
                    cell.primary_index == previous.primary_index
                        && cell.comparison_index
                            == previous.comparison_index + 1,
                    message);
                break;
        }
    }

    const std::size_t last = static_cast<std::size_t>(
        summary.written_path_count - 1);
    expect(summary.best_end_primary_index == output[last].primary_index, message);
    expect(
        summary.best_end_comparison_index == output[last].comparison_index,
        message);
}

void expect_exact_path(
    const RouteAlignmentDtwSummary& summary,
    const std::vector<RouteAlignmentDtwPathCell>& output,
    const std::vector<ExpectedCell>& expected,
    const char* message
) {
    expect(
        summary.required_path_count
            == static_cast<std::uint64_t>(expected.size()),
        message);
    expect(
        summary.written_path_count
            == static_cast<std::uint64_t>(expected.size()),
        message);
    for (std::size_t k = 0; k < expected.size(); ++k) {
        expect(output[k].primary_index == expected[k].primary_index, message);
        expect(
            output[k].comparison_index == expected[k].comparison_index,
            message);
        expect(output[k].step == expected[k].step, message);
    }
}

[[nodiscard]]
bool nearly_equal(double lhs, double rhs, double tolerance) noexcept {
    return std::abs(lhs - rhs) <= tolerance;
}

// --- Independent band-geometry formula --------------------------------------

/// Recomputes the documented band geometry without consulting the kernel:
///   unmatched(d)  = min(policyMeters, max(0, d) * policyFraction)
///   open          = max(1, floor(max(unmatched(p), unmatched(c)) / max(step, 1)))
///   radius        = max(1, ceil(max(n, m) * bandWidthFraction), open)
///   center(i)     = trunc(i / max(n - 1, 1) * max(m - 1, 1))
///   start(i)      = min(i < open ? 0 : jStart, jStart)
///   end(i)        = max(i >= n - open ? m - 1 : jEnd, jEnd)
struct BandExpectation final {
    std::int64_t open_samples{0};
    std::int64_t band_radius{0};
    std::int64_t estimated_cells{0};
    std::int64_t band_cell_count{0};
    std::vector<std::int64_t> row_starts;
    std::vector<std::int64_t> row_ends;
};

[[nodiscard]]
double unmatched_meters(
    double route_distance_meters,
    const RouteAlignmentDtwPolicy& policy
) noexcept {
    const double finite = std::isfinite(route_distance_meters)
        ? std::max(0.0, route_distance_meters)
        : 0.0;
    return std::min(
        policy.maximum_unmatched_prefix_suffix_meters,
        finite * policy.maximum_unmatched_prefix_suffix_fraction);
}

[[nodiscard]]
BandExpectation expected_band(
    std::int64_t n,
    std::int64_t m,
    double primary_route_distance_meters,
    double comparison_route_distance_meters,
    double effective_sample_interval_meters,
    const RouteAlignmentDtwPolicy& policy
) {
    BandExpectation expectation;

    const double maximum = std::max(
        unmatched_meters(primary_route_distance_meters, policy),
        unmatched_meters(comparison_route_distance_meters, policy));
    const double step = std::max(effective_sample_interval_meters, 1.0);
    expectation.open_samples = std::max<std::int64_t>(
        1, static_cast<std::int64_t>(std::floor(maximum / step)));

    const double fractional = std::ceil(
        static_cast<double>(std::max(n, m)) * policy.band_width_fraction);
    expectation.band_radius = std::max<std::int64_t>(
        1, static_cast<std::int64_t>(fractional));
    expectation.band_radius =
        std::max(expectation.band_radius, expectation.open_samples);
    expectation.estimated_cells = n * (2 * expectation.band_radius + 1);

    expectation.row_starts.assign(static_cast<std::size_t>(n), 0);
    expectation.row_ends.assign(static_cast<std::size_t>(n), -1);

    const std::int64_t primary_span = std::max<std::int64_t>(n - 1, 1);
    const std::int64_t comparison_span = std::max<std::int64_t>(m - 1, 1);

    for (std::int64_t i = 0; i < n; ++i) {
        const double normalized =
            static_cast<double>(i) / static_cast<double>(primary_span);
        const std::int64_t center = static_cast<std::int64_t>(
            normalized * static_cast<double>(comparison_span));
        const std::int64_t j_start =
            std::max<std::int64_t>(0, center - expectation.band_radius);
        const std::int64_t j_end =
            std::min<std::int64_t>(m - 1, center + expectation.band_radius);
        const std::int64_t expanded_start =
            i < expectation.open_samples ? 0 : j_start;
        const std::int64_t expanded_end =
            i >= (n - expectation.open_samples) ? (m - 1) : j_end;
        const std::int64_t start = std::min(expanded_start, j_start);
        const std::int64_t end = std::max(expanded_end, j_end);

        expectation.row_starts[static_cast<std::size_t>(i)] = start;
        expectation.row_ends[static_cast<std::size_t>(i)] = end;
        expectation.band_cell_count += std::max<std::int64_t>(0, (end - start) + 1);
    }

    return expectation;
}

void expect_path_inside_band(
    const RouteAlignmentDtwSummary& summary,
    const std::vector<RouteAlignmentDtwPathCell>& output,
    const BandExpectation& band,
    const char* message
) {
    for (std::uint64_t k = 0; k < summary.written_path_count; ++k) {
        const RouteAlignmentDtwPathCell& cell =
            output[static_cast<std::size_t>(k)];
        const std::size_t row = static_cast<std::size_t>(cell.primary_index);
        const std::int64_t column = static_cast<std::int64_t>(cell.comparison_index);
        expect(row < band.row_starts.size(), message);
        expect(column >= band.row_starts[row], message);
        expect(column <= band.row_ends[row], message);
    }
}

// --- Shared fixtures ---------------------------------------------------------

/// Six co-located samples on each side. Under `tight_policy` the open window is
/// one sample, so the best endpoint is (4, 4) and the path is a pure diagonal.
[[nodiscard]]
std::vector<RouteAlignmentCostSample> identical_six() {
    return line({0.0, 10.0, 20.0, 30.0, 40.0, 50.0});
}

// --- Tests -------------------------------------------------------------------

void test_type_contract() {
    expect(
        static_cast<std::uint8_t>(RouteAlignmentDtwStepKind::diagonal) == 0,
        "diagonal step raw value must stay 0");
    expect(
        static_cast<std::uint8_t>(RouteAlignmentDtwStepKind::primary_only) == 1,
        "primary-only step raw value must stay 1");
    expect(
        static_cast<std::uint8_t>(RouteAlignmentDtwStepKind::comparison_only) == 2,
        "comparison-only step raw value must stay 2");

    const RouteAlignmentCostSample sample{};
    expect(sample.x_meters == 0.0, "default cost sample x is zero");
    expect(sample.z_meters == 0.0, "default cost sample z is zero");
    expect(sample.normalized_progress == 0.0, "default cost sample progress is zero");
    expect(sample.heading_radians == 0.0, "default cost sample heading is zero");
    expect(sample.has_heading == 0, "default cost sample has no heading");

    const RouteAlignmentDtwPolicy policy{};
    expect(policy.band_width_fraction == 0.0, "default policy band fraction is zero");
    expect(policy.maximum_consecutive_warp_steps == 0, "default policy warp cap is zero");
    expect(policy.maximum_band_cells == 0, "default policy band budget is zero");

    const RouteAlignmentDtwPathCell cell{};
    expect(cell.primary_index == 0, "default path cell primary index is zero");
    expect(cell.comparison_index == 0, "default path cell comparison index is zero");
    expect(
        cell.step == RouteAlignmentDtwStepKind::diagonal,
        "default path cell step is diagonal");

    const RouteAlignmentDtwSummary summary{};
    expect(
        summary.status == RouteAlignmentDtwStatus::success,
        "default summary status is success");
    expect(summary.required_path_count == 0, "default summary requires no cells");
    expect(summary.written_path_count == 0, "default summary writes no cells");
    expect(summary.best_end_cost == 0.0, "default summary end cost is zero");
}

void test_buffer_contracts() {
    const std::vector<RouteAlignmentCostSample> primary = identical_six();
    const std::vector<RouteAlignmentCostSample> comparison = identical_six();
    const RouteAlignmentDtwPolicy policy = tight_policy();
    std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 6);

    {
        fill_sentinel(output);
        const auto summary = compute_constrained_dtw_path(
            nullptr,
            primary.size(),
            comparison.data(),
            comparison.size(),
            1000.0,
            1000.0,
            20.0,
            policy,
            output.data(),
            output.size());
        expect(
            summary.status == RouteAlignmentDtwStatus::invalid_primary_buffer,
            "null primary with a non-zero count is an invalid primary buffer");
        expect(summary.primary_sample_count == 6, "primary count still reported");
        expect(summary.comparison_sample_count == 6, "comparison count still reported");
        expect(summary.written_path_count == 0, "null primary writes nothing");
        expect(summary.required_path_count == 0, "null primary requires nothing");
        expect_untouched(output, "null primary must not touch the output buffer");
    }

    {
        fill_sentinel(output);
        const auto summary = compute_constrained_dtw_path(
            primary.data(),
            primary.size(),
            nullptr,
            comparison.size(),
            1000.0,
            1000.0,
            20.0,
            policy,
            output.data(),
            output.size());
        expect(
            summary.status == RouteAlignmentDtwStatus::invalid_comparison_buffer,
            "null comparison with a non-zero count is an invalid comparison buffer");
        expect(summary.written_path_count == 0, "null comparison writes nothing");
        expect_untouched(output, "null comparison must not touch the output buffer");
    }

    {
        fill_sentinel(output);
        const auto summary = compute_constrained_dtw_path(
            primary.data(),
            0,
            comparison.data(),
            comparison.size(),
            1000.0,
            1000.0,
            20.0,
            policy,
            output.data(),
            output.size());
        expect(
            summary.status == RouteAlignmentDtwStatus::invalid_input_contract,
            "zero primary count violates the input contract");
        expect(summary.primary_sample_count == 0, "zero primary count reported");
        expect(summary.written_path_count == 0, "zero primary count writes nothing");
        expect_untouched(output, "zero primary count must not touch the output buffer");
    }

    {
        fill_sentinel(output);
        const auto summary = compute_constrained_dtw_path(
            primary.data(),
            primary.size(),
            comparison.data(),
            0,
            1000.0,
            1000.0,
            20.0,
            policy,
            output.data(),
            output.size());
        expect(
            summary.status == RouteAlignmentDtwStatus::invalid_input_contract,
            "zero comparison count violates the input contract");
        expect(summary.comparison_sample_count == 0, "zero comparison count reported");
        expect_untouched(output, "zero comparison count must not touch the output buffer");
    }

    {
        // Both counts zero is still an input-contract violation, not a success.
        fill_sentinel(output);
        const auto summary = compute_constrained_dtw_path(
            primary.data(),
            0,
            comparison.data(),
            0,
            1000.0,
            1000.0,
            20.0,
            policy,
            output.data(),
            output.size());
        expect(
            summary.status == RouteAlignmentDtwStatus::invalid_input_contract,
            "two empty routes violate the input contract");
        expect_untouched(output, "two empty routes must not touch the output buffer");
    }

    {
        const auto summary = compute_constrained_dtw_path(
            primary.data(),
            primary.size(),
            comparison.data(),
            comparison.size(),
            1000.0,
            1000.0,
            20.0,
            policy,
            nullptr,
            4);
        expect(
            summary.status == RouteAlignmentDtwStatus::invalid_output_buffer,
            "null output with a positive capacity is an invalid output buffer");
        expect(summary.written_path_count == 0, "null output writes nothing");
        expect(summary.required_path_count == 0, "null output reports no requirement");
    }

    {
        // The pure-diagonal solve needs five cells; four is one short.
        fill_sentinel(output);
        const auto summary = compute_constrained_dtw_path(
            primary.data(),
            primary.size(),
            comparison.data(),
            comparison.size(),
            1000.0,
            1000.0,
            20.0,
            policy,
            output.data(),
            4);
        expect(
            summary.status
                == RouteAlignmentDtwStatus::insufficient_output_capacity,
            "a short output buffer reports insufficient capacity");
        expect(summary.required_path_count == 5, "the exact requirement is reported");
        expect(summary.written_path_count == 0, "an insufficient buffer writes nothing");
        expect(summary.band_radius == 6, "band radius is reported before the copy");
        expect(summary.band_cell_count == 36, "band cell count is reported before the copy");
        expect_untouched(output, "insufficient capacity must not touch the output buffer");
    }

    {
        // Zero capacity with a null pointer clears the null-output check and
        // still reports the exact requirement.
        const auto summary = compute_constrained_dtw_path(
            primary.data(),
            primary.size(),
            comparison.data(),
            comparison.size(),
            1000.0,
            1000.0,
            20.0,
            policy,
            nullptr,
            0);
        expect(
            summary.status
                == RouteAlignmentDtwStatus::insufficient_output_capacity,
            "zero capacity reports insufficient capacity");
        expect(summary.required_path_count == 5, "zero capacity reports the requirement");
        expect(summary.written_path_count == 0, "zero capacity writes nothing");
    }

    {
        // Exactly the required capacity succeeds and writes every cell.
        std::vector<RouteAlignmentDtwPathCell> exact(5);
        const auto summary = compute_constrained_dtw_path(
            primary.data(),
            primary.size(),
            comparison.data(),
            comparison.size(),
            1000.0,
            1000.0,
            20.0,
            policy,
            exact.data(),
            exact.size());
        expect(
            summary.status == RouteAlignmentDtwStatus::success,
            "exact capacity succeeds");
        expect(summary.written_path_count == 5, "exact capacity writes every cell");
        expect_valid_path(summary, exact, 6, 6, "exact capacity path is well formed");
    }
}

void test_input_contracts() {
    const RouteAlignmentDtwPolicy policy = tight_policy();
    std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 6);

    const auto reject = [&](
        std::vector<RouteAlignmentCostSample> primary,
        std::vector<RouteAlignmentCostSample> comparison,
        double primary_distance,
        double comparison_distance,
        double interval,
        const char* message
    ) {
        fill_sentinel(output);
        const auto summary = solve(
            primary,
            comparison,
            primary_distance,
            comparison_distance,
            interval,
            policy,
            output);
        expect(
            summary.status == RouteAlignmentDtwStatus::invalid_input_contract,
            message);
        expect(summary.written_path_count == 0, message);
        expect(summary.required_path_count == 0, message);
        expect_untouched(output, message);
    };

    {
        auto primary = identical_six();
        primary[2].x_meters = quiet_nan;
        reject(primary, identical_six(), 1000.0, 1000.0, 20.0,
               "NaN x_meters violates the input contract");
    }
    {
        auto primary = identical_six();
        primary[5].x_meters = infinity;
        reject(primary, identical_six(), 1000.0, 1000.0, 20.0,
               "infinite x_meters violates the input contract");
    }
    {
        auto comparison = identical_six();
        comparison[1].z_meters = quiet_nan;
        reject(identical_six(), comparison, 1000.0, 1000.0, 20.0,
               "NaN z_meters violates the input contract");
    }
    {
        auto comparison = identical_six();
        comparison[0].z_meters = -infinity;
        reject(identical_six(), comparison, 1000.0, 1000.0, 20.0,
               "infinite z_meters violates the input contract");
    }
    {
        auto primary = identical_six();
        primary[3].normalized_progress = -0.25;
        reject(primary, identical_six(), 1000.0, 1000.0, 20.0,
               "negative normalized progress violates the input contract");
    }
    {
        auto comparison = identical_six();
        comparison[4].normalized_progress = 1.5;
        reject(identical_six(), comparison, 1000.0, 1000.0, 20.0,
               "normalized progress above one violates the input contract");
    }
    {
        auto primary = identical_six();
        primary[1].normalized_progress = quiet_nan;
        reject(primary, identical_six(), 1000.0, 1000.0, 20.0,
               "NaN normalized progress violates the input contract");
    }
    {
        auto primary = identical_six();
        primary[2].has_heading = 2;
        reject(primary, identical_six(), 1000.0, 1000.0, 20.0,
               "a has_heading byte of 2 violates the presence contract");
    }
    {
        auto comparison = identical_six();
        comparison[2].has_heading = 255;
        reject(identical_six(), comparison, 1000.0, 1000.0, 20.0,
               "a has_heading byte of 255 violates the presence contract");
    }
    {
        auto primary = identical_six();
        primary[2].has_heading = 1;
        primary[2].heading_radians = quiet_nan;
        reject(primary, identical_six(), 1000.0, 1000.0, 20.0,
               "a present but NaN heading violates the input contract");
    }
    {
        auto comparison = identical_six();
        comparison[3].has_heading = 1;
        comparison[3].heading_radians = infinity;
        reject(identical_six(), comparison, 1000.0, 1000.0, 20.0,
               "a present but infinite heading violates the input contract");
    }

    reject(identical_six(), identical_six(), quiet_nan, 1000.0, 20.0,
           "NaN primary route distance violates the input contract");
    reject(identical_six(), identical_six(), infinity, 1000.0, 20.0,
           "infinite primary route distance violates the input contract");
    reject(identical_six(), identical_six(), 0.0, 1000.0, 20.0,
           "zero primary route distance violates the input contract");
    reject(identical_six(), identical_six(), -5.0, 1000.0, 20.0,
           "negative primary route distance violates the input contract");
    reject(identical_six(), identical_six(), 1000.0, quiet_nan, 20.0,
           "NaN comparison route distance violates the input contract");
    reject(identical_six(), identical_six(), 1000.0, -infinity, 20.0,
           "infinite comparison route distance violates the input contract");
    reject(identical_six(), identical_six(), 1000.0, 0.0, 20.0,
           "zero comparison route distance violates the input contract");
    reject(identical_six(), identical_six(), 1000.0, -1.0, 20.0,
           "negative comparison route distance violates the input contract");
    reject(identical_six(), identical_six(), 1000.0, 1000.0, quiet_nan,
           "NaN sample interval violates the input contract");
    reject(identical_six(), identical_six(), 1000.0, 1000.0, infinity,
           "infinite sample interval violates the input contract");
    reject(identical_six(), identical_six(), 1000.0, 1000.0, 0.0,
           "zero sample interval violates the input contract");
    reject(identical_six(), identical_six(), 1000.0, 1000.0, -20.0,
           "negative sample interval violates the input contract");

    {
        // Positive control: the boundary values the contract does accept.
        auto primary = identical_six();
        primary[0].normalized_progress = 0.0;
        primary[5].normalized_progress = 1.0;
        primary[3].has_heading = 1;
        primary[3].heading_radians = -3.0;
        auto comparison = identical_six();
        comparison[3].has_heading = 1;
        comparison[3].heading_radians = 3.0;

        const auto summary = solve(
            primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect(
            summary.status == RouteAlignmentDtwStatus::success,
            "progress endpoints and present headings are accepted");
        expect_valid_path(summary, output, 6, 6, "accepted boundary input solves");
    }
}

void test_policy_contracts() {
    const std::vector<RouteAlignmentCostSample> primary = identical_six();
    const std::vector<RouteAlignmentCostSample> comparison = identical_six();
    std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 6);

    const auto reject = [&](
        const RouteAlignmentDtwPolicy& policy,
        const char* message
    ) {
        fill_sentinel(output);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect(summary.status == RouteAlignmentDtwStatus::invalid_policy, message);
        expect(summary.written_path_count == 0, message);
        expect(summary.required_path_count == 0, message);
        expect_untouched(output, message);
    };

    {
        auto policy = tight_policy();
        policy.band_width_fraction = quiet_nan;
        reject(policy, "NaN band width fraction is an invalid policy");
    }
    {
        auto policy = tight_policy();
        policy.band_width_fraction = infinity;
        reject(policy, "infinite band width fraction is an invalid policy");
    }
    {
        auto policy = tight_policy();
        policy.maximum_unmatched_prefix_suffix_meters = infinity;
        reject(policy, "infinite unmatched prefix/suffix metres is an invalid policy");
    }
    {
        auto policy = tight_policy();
        policy.maximum_unmatched_prefix_suffix_fraction = quiet_nan;
        reject(policy, "NaN unmatched prefix/suffix fraction is an invalid policy");
    }
    {
        auto policy = tight_policy();
        policy.non_diagonal_step_penalty = quiet_nan;
        reject(policy, "NaN non-diagonal step penalty is an invalid policy");
    }
    {
        auto policy = tight_policy();
        policy.spatial_distance_cost_scale_meters = -infinity;
        reject(policy, "infinite spatial cost scale is an invalid policy");
    }
    {
        auto policy = tight_policy();
        policy.maximum_spatial_cost = quiet_nan;
        reject(policy, "NaN maximum spatial cost is an invalid policy");
    }
    {
        auto policy = tight_policy();
        policy.heading_penalty_weight = quiet_nan;
        reject(policy, "NaN heading penalty weight is an invalid policy");
    }
    {
        auto policy = tight_policy();
        policy.progress_penalty_weight = infinity;
        reject(policy, "infinite progress penalty weight is an invalid policy");
    }
}

void test_resource_limits() {
    const std::vector<RouteAlignmentCostSample> five =
        line({0.0, 10.0, 20.0, 30.0, 40.0});
    std::vector<RouteAlignmentDtwPathCell> output = make_output(5, 5);

    // n * (2 * radius + 1) = 5 * 11 = 55 estimated cells, 25 packed cells.
    {
        auto policy = tight_policy();
        policy.maximum_band_cells = 54;
        fill_sentinel(output);
        const auto summary =
            solve(five, five, 1000.0, 1000.0, 20.0, policy, output);
        expect(
            summary.status == RouteAlignmentDtwStatus::resource_limit,
            "an estimated budget below n * (2r + 1) is a resource limit");
        expect(summary.band_radius == 5, "band radius is reported on the early rejection");
        expect(
            summary.band_cell_count == 0,
            "the early rejection happens before the packed layout is built");
        expect(summary.written_path_count == 0, "a resource limit writes nothing");
        expect_untouched(output, "a resource limit must not touch the output buffer");
    }

    {
        auto policy = tight_policy();
        policy.maximum_band_cells = 55;
        const auto summary =
            solve(five, five, 1000.0, 1000.0, 20.0, policy, output);
        expect(
            summary.status == RouteAlignmentDtwStatus::success,
            "an estimated budget exactly at n * (2r + 1) is accepted");
        expect(summary.band_radius == 5, "accepted boundary reports the radius");
        expect(summary.band_cell_count == 25, "accepted boundary reports packed cells");
        expect_valid_path(summary, output, 5, 5, "accepted boundary path is well formed");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {2, 2, RouteAlignmentDtwStepKind::diagonal},
                {3, 3, RouteAlignmentDtwStepKind::diagonal},
            },
            "accepted boundary yields the pure diagonal path");
    }

    {
        auto policy = tight_policy();
        policy.maximum_band_cells = 0;
        fill_sentinel(output);
        const auto summary =
            solve(five, five, 1000.0, 1000.0, 20.0, policy, output);
        expect(
            summary.status == RouteAlignmentDtwStatus::resource_limit,
            "a zero band budget is always a resource limit");
        expect(summary.band_cell_count == 0, "a zero budget never packs a layout");
        expect_untouched(output, "a zero budget must not touch the output buffer");
    }

    // A 20 x 100 shape whose open-window expansion makes the packed layout
    // larger than the pre-check estimate: 180 estimated cells, 211 packed.
    std::vector<RouteAlignmentCostSample> primary;
    primary.reserve(20);
    for (std::int64_t i = 0; i < 20; ++i) {
        primary.push_back(point_at(
            static_cast<double>(i) * 5.0, 0.0, static_cast<double>(i) / 19.0));
    }
    std::vector<RouteAlignmentCostSample> comparison;
    comparison.reserve(100);
    for (std::int64_t j = 0; j < 100; ++j) {
        comparison.push_back(point_at(
            static_cast<double>(j), 0.0, static_cast<double>(j) / 99.0));
    }

    auto packed_policy = tight_policy();
    packed_policy.band_width_fraction = 0.01;
    packed_policy.maximum_unmatched_prefix_suffix_meters = 400.0;
    packed_policy.maximum_unmatched_prefix_suffix_fraction = 1.0;

    const BandExpectation band =
        expected_band(20, 100, 400.0, 400.0, 100.0, packed_policy);
    expect(band.open_samples == 4, "the 20 x 100 fixture opens four samples");
    expect(band.band_radius == 4, "the 20 x 100 fixture uses a radius of four");
    expect(band.estimated_cells == 180, "the 20 x 100 estimate is 180 cells");
    expect(
        band.band_cell_count == 211,
        "the 20 x 100 packed layout is larger than the estimate");

    std::vector<RouteAlignmentDtwPathCell> wide_output = make_output(20, 100);

    {
        auto policy = packed_policy;
        policy.maximum_band_cells = 210;
        fill_sentinel(wide_output);
        const auto summary =
            solve(primary, comparison, 400.0, 400.0, 100.0, policy, wide_output);
        expect(
            summary.status == RouteAlignmentDtwStatus::resource_limit,
            "a budget below the packed layout is a resource limit");
        expect(
            summary.band_cell_count == 211,
            "the packed rejection reports the exact packed cell count");
        expect(summary.band_radius == 4, "the packed rejection reports the radius");
        expect(summary.written_path_count == 0, "the packed rejection writes nothing");
        expect_untouched(
            wide_output, "the packed rejection must not touch the output buffer");
    }

    {
        auto policy = packed_policy;
        policy.maximum_band_cells = 211;
        const auto summary =
            solve(primary, comparison, 400.0, 400.0, 100.0, policy, wide_output);
        expect(
            summary.status == RouteAlignmentDtwStatus::success,
            "a budget exactly at the packed layout is accepted");
        expect(summary.band_cell_count == 211, "the accepted packed count is reported");
        expect(summary.required_path_count == 96, "the packed solve needs 96 cells");
        expect(summary.best_end_primary_index == 19, "the packed solve ends at primary 19");
        expect(summary.best_end_comparison_index == 95, "the packed solve ends at comparison 95");
        expect_valid_path(
            summary, wide_output, 20, 100, "the packed solve path is well formed");
        expect_path_inside_band(
            summary, wide_output, band, "the packed solve path stays inside the band");
    }
}

void test_warp_limits() {
    // A zero warp cap forbids every non-diagonal transition. Identical routes
    // need none, so the path stays a pure diagonal.
    {
        auto policy = tight_policy();
        policy.maximum_consecutive_warp_steps = 0;
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 6);
        const auto summary = solve(
            identical_six(), identical_six(), 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 6, 6, "zero warp cap still solves identical routes");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {2, 2, RouteAlignmentDtwStepKind::diagonal},
                {3, 3, RouteAlignmentDtwStepKind::diagonal},
                {4, 4, RouteAlignmentDtwStepKind::diagonal},
            },
            "a zero warp cap yields a pure diagonal path");
    }

    // A shape that would prefer a warp: every transition cell must still be
    // diagonal. The only non-diagonal cell is the open-prefix seed on column 0,
    // which is a seeding assignment rather than a warp transition.
    {
        auto policy = tight_policy();
        policy.maximum_consecutive_warp_steps = 0;
        const auto primary = line({0.0, 10.0, 10.0, 20.0, 30.0, 40.0});
        const auto comparison = line({0.0, 10.0, 20.0, 30.0, 40.0, 50.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 6);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 6, 6, "zero warp cap solves the stretched shape");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 0, RouteAlignmentDtwStepKind::primary_only},
                {2, 1, RouteAlignmentDtwStepKind::diagonal},
                {3, 2, RouteAlignmentDtwStepKind::diagonal},
                {4, 3, RouteAlignmentDtwStepKind::diagonal},
                {5, 4, RouteAlignmentDtwStepKind::diagonal},
            },
            "a zero warp cap leaves only the open-prefix seed non-diagonal");
        expect(
            nearly_equal(summary.best_end_cost, 10.0, 1e-12),
            "the zero-warp-cap solve pays the seeded prefix once");

        for (std::uint64_t k = 0; k < summary.written_path_count; ++k) {
            const RouteAlignmentDtwPathCell& cell =
                output[static_cast<std::size_t>(k)];
            if (cell.primary_index == 0 || cell.comparison_index == 0) {
                continue;
            }
            expect(
                cell.step == RouteAlignmentDtwStepKind::diagonal,
                "a zero warp cap forbids every non-diagonal transition");
        }
    }

    // A cap of two: the optimum wants six consecutive primary-only steps but
    // must break them into runs of at most two.
    {
        auto policy = tight_policy();
        policy.maximum_consecutive_warp_steps = 2;
        const auto primary =
            line({0.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 60.0});
        const auto comparison = line({0.0, 5.0, 60.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(8, 3);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 8, 3, "the warp-capped solve is well formed");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {2, 1, RouteAlignmentDtwStepKind::primary_only},
                {3, 1, RouteAlignmentDtwStepKind::primary_only},
                {4, 2, RouteAlignmentDtwStepKind::diagonal},
                {5, 2, RouteAlignmentDtwStepKind::primary_only},
                {6, 2, RouteAlignmentDtwStepKind::primary_only},
            },
            "a warp cap of two breaks the run with diagonals");

        std::uint64_t longest_run = 0;
        std::uint64_t current_run = 0;
        for (std::uint64_t k = 0; k < summary.written_path_count; ++k) {
            const RouteAlignmentDtwPathCell& cell =
                output[static_cast<std::size_t>(k)];
            if (cell.step == RouteAlignmentDtwStepKind::diagonal) {
                current_run = 0;
                continue;
            }
            current_run += 1;
            longest_run = std::max(longest_run, current_run);
        }
        expect(longest_run == 2, "no warp run exceeds the configured cap");
    }

    // Warp runs saturate at 255 instead of wrapping. A 2 x 400 shape needs a
    // run of 396 consecutive comparison-only steps. With a cap of exactly 255
    // the saturated counter blocks the 256th step and no path exists; a wrapping
    // counter would restart at zero and find one.
    const auto make_wide_comparison = []() {
        std::vector<RouteAlignmentCostSample> comparison;
        comparison.reserve(400);
        for (std::int64_t j = 0; j < 400; ++j) {
            comparison.push_back(point(static_cast<double>(j)));
        }
        return comparison;
    };
    const std::vector<RouteAlignmentCostSample> narrow_primary =
        line({0.0, 0.0});
    const std::vector<RouteAlignmentCostSample> wide_comparison =
        make_wide_comparison();

    {
        auto policy = tight_policy();
        policy.maximum_consecutive_warp_steps = 255;
        std::vector<RouteAlignmentDtwPathCell> output = make_output(2, 400);
        fill_sentinel(output);
        const auto summary = solve(
            narrow_primary, wide_comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect(
            summary.status == RouteAlignmentDtwStatus::no_path,
            "a saturated warp counter blocks the 256th consecutive warp");
        expect(summary.band_radius == 400, "the no-path solve still reports the radius");
        expect(summary.band_cell_count == 800, "the no-path solve still reports packed cells");
        expect(summary.written_path_count == 0, "a no-path result writes nothing");
        expect(summary.required_path_count == 0, "a no-path result requires nothing");
        expect_untouched(output, "a no-path result must not touch the output buffer");
    }

    std::vector<RouteAlignmentDtwPathCell> saturated_output = make_output(2, 400);
    std::vector<RouteAlignmentDtwPathCell> huge_output = make_output(2, 400);

    {
        auto policy = tight_policy();
        policy.maximum_consecutive_warp_steps = 256;
        const auto summary = solve(
            narrow_primary,
            wide_comparison,
            1000.0,
            1000.0,
            20.0,
            policy,
            saturated_output);
        expect_valid_path(
            summary, saturated_output, 2, 400, "the long warp run solves");
        expect(summary.required_path_count == 399, "the long warp run needs 399 cells");
        expect(summary.best_end_primary_index == 1, "the long warp run ends at primary 1");
        expect(
            summary.best_end_comparison_index == 398,
            "the long warp run ends at comparison 398");
        expect(
            nearly_equal(summary.best_end_cost, 79401.0, 1e-9),
            "the long warp run accumulates the expected cost");

        std::uint64_t longest_run = 0;
        std::uint64_t current_run = 0;
        for (std::uint64_t k = 0; k < summary.written_path_count; ++k) {
            const RouteAlignmentDtwPathCell& cell =
                saturated_output[static_cast<std::size_t>(k)];
            if (cell.step == RouteAlignmentDtwStepKind::comparison_only) {
                current_run += 1;
                longest_run = std::max(longest_run, current_run);
            } else {
                current_run = 0;
            }
        }
        expect(
            longest_run == 396,
            "the long warp run exceeds 255 without wrapping the byte counter");
    }

    {
        // Once the counter saturates, every cap of 256 or more behaves the same.
        auto policy = tight_policy();
        policy.maximum_consecutive_warp_steps = 1'000'000'000;
        const auto summary = solve(
            narrow_primary,
            wide_comparison,
            1000.0,
            1000.0,
            20.0,
            policy,
            huge_output);
        expect_valid_path(summary, huge_output, 2, 400, "a huge warp cap solves");
        expect(summary.required_path_count == 399, "a huge warp cap needs 399 cells");
        expect(
            std::memcmp(
                saturated_output.data(),
                huge_output.data(),
                static_cast<std::size_t>(summary.written_path_count)
                    * sizeof(RouteAlignmentDtwPathCell)) == 0,
            "a saturated counter makes caps of 256 and 1e9 byte-identical");
    }
}

void test_point_cost() {
    // A one-by-one solve reports the single point cost as best_end_cost.
    const auto probe = [](
        const RouteAlignmentCostSample& primary_sample,
        const RouteAlignmentCostSample& comparison_sample,
        const RouteAlignmentDtwPolicy& policy
    ) {
        const std::vector<RouteAlignmentCostSample> primary{primary_sample};
        const std::vector<RouteAlignmentCostSample> comparison{comparison_sample};
        std::vector<RouteAlignmentDtwPathCell> output = make_output(1, 1);
        return solve(
            primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
    };

    {
        const auto summary =
            probe(point_at(12.5, -7.5, 0.5), point_at(12.5, -7.5, 0.5), tight_policy());
        expect(
            summary.status == RouteAlignmentDtwStatus::success,
            "the one-by-one probe solves");
        expect(summary.required_path_count == 1, "the one-by-one probe needs one cell");
        expect(summary.band_cell_count == 1, "the one-by-one probe packs one cell");
        expect(
            nearly_equal(summary.best_end_cost, 0.0, 0.0),
            "identical samples cost exactly zero");
    }

    {
        auto policy = tight_policy();
        policy.spatial_distance_cost_scale_meters = 2.0;
        policy.maximum_spatial_cost = 1000.0;
        const auto summary =
            probe(point_at(0.0, 0.0, 0.0), point_at(3.0, 4.0, 0.0), policy);
        expect(
            nearly_equal(summary.best_end_cost, 2.5, 1e-12),
            "spatial cost is the separation divided by the scale");
    }

    {
        // A sub-metre scale is clamped up to one metre.
        auto policy = tight_policy();
        policy.spatial_distance_cost_scale_meters = 0.25;
        policy.maximum_spatial_cost = 1000.0;
        const auto summary =
            probe(point_at(0.0, 0.0, 0.0), point_at(3.0, 4.0, 0.0), policy);
        expect(
            nearly_equal(summary.best_end_cost, 5.0, 1e-12),
            "a spatial scale below one metre is clamped to one");
    }

    {
        auto policy = tight_policy();
        policy.maximum_spatial_cost = 8.0;
        const auto summary =
            probe(point_at(0.0, 0.0, 0.0), point_at(3000.0, 4000.0, 0.0), policy);
        expect(
            nearly_equal(summary.best_end_cost, 8.0, 0.0),
            "spatial cost is bounded by the maximum spatial cost");
    }

    {
        auto policy = tight_policy();
        policy.heading_penalty_weight = 0.45;
        const auto summary = probe(
            point_with_heading(0.0, 0.0, 0.0, 0.0),
            point_at(0.0, 0.0, 0.0),
            policy);
        expect(
            nearly_equal(summary.best_end_cost, 0.0, 0.0),
            "an absent comparison heading contributes nothing");
    }

    {
        auto policy = tight_policy();
        policy.heading_penalty_weight = 0.45;
        const auto summary = probe(
            point_at(0.0, 0.0, 0.0),
            point_with_heading(0.0, 0.0, 0.0, std::numbers::pi_v<double>),
            policy);
        expect(
            nearly_equal(summary.best_end_cost, 0.0, 0.0),
            "an absent primary heading contributes nothing");
    }

    {
        auto policy = tight_policy();
        policy.heading_penalty_weight = 0.45;
        const auto summary = probe(
            point_with_heading(0.0, 0.0, 0.0, 1.25),
            point_with_heading(0.0, 0.0, 0.0, 1.25),
            policy);
        expect(
            nearly_equal(summary.best_end_cost, 0.0, 0.0),
            "equal headings contribute nothing");
    }

    {
        auto policy = tight_policy();
        policy.heading_penalty_weight = 0.45;
        const auto summary = probe(
            point_with_heading(0.0, 0.0, 0.0, 0.0),
            point_with_heading(0.0, 0.0, 0.0, std::numbers::pi_v<double>),
            policy);
        expect(
            nearly_equal(summary.best_end_cost, 0.45, 1e-12),
            "a heading difference of pi costs the full heading weight");
    }

    {
        // 3.0 and -3.0 differ by 6.0 radians, which wraps to 2*pi - 6.0.
        auto policy = tight_policy();
        policy.heading_penalty_weight = 0.45;
        const auto summary = probe(
            point_with_heading(0.0, 0.0, 0.0, 3.0),
            point_with_heading(0.0, 0.0, 0.0, -3.0),
            policy);
        expect(
            nearly_equal(summary.best_end_cost, 0.04056330730376515, 1e-15),
            "a heading difference above pi wraps around the full turn");
    }

    {
        auto policy = tight_policy();
        policy.progress_penalty_weight = 1.5;
        const auto summary =
            probe(point_at(0.0, 0.0, 0.25), point_at(0.0, 0.0, 0.75), policy);
        expect(
            nearly_equal(summary.best_end_cost, 0.75, 1e-12),
            "progress difference is weighted linearly");
    }

    {
        // Unusual but finite weights are accepted verbatim; a negative weight
        // produces a negative cost rather than a rejection.
        auto policy = tight_policy();
        policy.heading_penalty_weight = -2.0;
        const auto summary = probe(
            point_with_heading(0.0, 0.0, 0.0, 0.0),
            point_with_heading(0.0, 0.0, 0.0, std::numbers::pi_v<double>),
            policy);
        expect(
            summary.status == RouteAlignmentDtwStatus::success,
            "a negative heading weight is a finite policy");
        expect(
            nearly_equal(summary.best_end_cost, -2.0, 1e-12),
            "a negative heading weight produces a negative cost");
    }

    {
        // Finite weights whose sum overflows fall back to the maximum spatial
        // cost instead of returning a non-finite cost.
        auto policy = tight_policy();
        policy.maximum_spatial_cost = 1.0e300;
        policy.heading_penalty_weight = 1.0e308;
        policy.progress_penalty_weight = 1.0e308;
        const auto summary = probe(
            point_with_heading(0.0, 0.0, 0.0, 0.0),
            point_with_heading(0.0, 0.0, 1.0, std::numbers::pi_v<double>),
            policy);
        expect(
            summary.status == RouteAlignmentDtwStatus::success,
            "an overflowing point cost still solves");
        expect(
            nearly_equal(summary.best_end_cost, 1.0e300, 0.0),
            "an overflowing point cost falls back to the maximum spatial cost");
    }

    {
        // A finite cost at or above the unreachable sentinel leaves every cell
        // unreachable, which the endpoint scan reports as no path.
        auto policy = tight_policy();
        policy.maximum_spatial_cost = 1.0e308;
        const auto summary =
            probe(point_at(0.0, 0.0, 0.0), point_at(1.0e308, 0.0, 0.0), policy);
        expect(
            summary.status == RouteAlignmentDtwStatus::no_path,
            "a point cost at the unreachable sentinel yields no path");
        expect(summary.written_path_count == 0, "a no-path probe writes nothing");
    }
}

void test_paths() {
    const RouteAlignmentDtwPolicy policy = tight_policy();

    {
        // Identical sequences: a pure diagonal ending one sample short of the
        // final pair because the open suffix window is one sample wide.
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 6);
        const auto summary = solve(
            identical_six(), identical_six(), 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 6, 6, "identical routes solve");
        expect(summary.band_radius == 6, "identical routes report a radius of six");
        expect(summary.band_cell_count == 36, "identical routes pack 36 cells");
        expect(
            nearly_equal(summary.best_end_cost, 0.0, 0.0),
            "identical routes align at zero cost");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {2, 2, RouteAlignmentDtwStepKind::diagonal},
                {3, 3, RouteAlignmentDtwStepKind::diagonal},
                {4, 4, RouteAlignmentDtwStepKind::diagonal},
            },
            "identical routes produce a pure diagonal path");
    }

    {
        // Every candidate ties at zero. Diagonal is evaluated first and is
        // replaced only by a strictly lower candidate, so it wins every tie.
        const auto flat = line({0.0, 0.0, 0.0, 0.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(4, 4);
        const auto summary =
            solve(flat, flat, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 4, 4, "the all-ties fixture solves");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {2, 2, RouteAlignmentDtwStepKind::diagonal},
            },
            "diagonal beats primary-only and comparison-only on a tie");
    }

    {
        // At (2, 2) the diagonal predecessor costs 20 while the vertical and
        // horizontal predecessors both cost 11: primary-only is evaluated
        // before comparison-only, so it wins the tie.
        const auto primary = line({0.0, 10.0, -9.0, 1000.0});
        const auto comparison = line({0.0, -10.0, 11.0, -1000.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(4, 4);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 4, 4, "the primary-only tie fixture solves");
        expect(
            nearly_equal(summary.best_end_cost, 31.0, 1e-12),
            "the primary-only tie fixture costs 31");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {0, 1, RouteAlignmentDtwStepKind::comparison_only},
                {1, 2, RouteAlignmentDtwStepKind::diagonal},
                {2, 2, RouteAlignmentDtwStepKind::primary_only},
            },
            "primary-only beats comparison-only on a tie");
    }

    {
        // The primary route repeats a sample, so one primary-only warp absorbs it.
        const auto primary = line({0.0, 10.0, 10.0, 20.0, 30.0, 40.0});
        const auto comparison = line({0.0, 10.0, 20.0, 30.0, 40.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 5);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 6, 5, "the longer-primary fixture solves");
        expect(summary.band_cell_count == 30, "the longer-primary fixture packs 30 cells");
        expect(
            nearly_equal(summary.best_end_cost, 0.0, 0.0),
            "the longer-primary fixture aligns at zero cost");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {2, 1, RouteAlignmentDtwStepKind::primary_only},
                {3, 2, RouteAlignmentDtwStepKind::diagonal},
                {4, 3, RouteAlignmentDtwStepKind::diagonal},
            },
            "a longer primary route warps with a primary-only step");
    }

    {
        // The mirror image: the comparison route repeats a sample.
        const auto primary = line({0.0, 10.0, 20.0, 30.0, 40.0});
        const auto comparison = line({0.0, 10.0, 10.0, 20.0, 30.0, 40.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(5, 6);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 5, 6, "the longer-comparison fixture solves");
        expect(summary.band_cell_count == 30, "the longer-comparison fixture packs 30 cells");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {1, 2, RouteAlignmentDtwStepKind::comparison_only},
                {2, 3, RouteAlignmentDtwStepKind::diagonal},
                {3, 4, RouteAlignmentDtwStepKind::diagonal},
            },
            "a longer comparison route warps with a comparison-only step");
    }

    // A four-sample open window: 400 unmatched metres over a 100 metre interval.
    auto open_policy = tight_policy();
    open_policy.maximum_unmatched_prefix_suffix_meters = 100.0;
    open_policy.maximum_unmatched_prefix_suffix_fraction = 1.0;

    {
        // The comparison route starts with two samples the primary never visits;
        // the open prefix absorbs them with comparison-only seeds along row 0.
        const auto primary = line({0.0, 25.0, 50.0, 75.0, 100.0, 125.0});
        const auto comparison =
            line({-1000.0, -1001.0, 0.0, 25.0, 50.0, 75.0, 100.0, 125.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 8);
        const auto summary =
            solve(primary, comparison, 100.0, 100.0, 25.0, open_policy, output);
        expect_valid_path(summary, output, 6, 8, "the prefix-offset fixture solves");
        expect(summary.band_radius == 8, "the prefix-offset fixture uses a radius of eight");
        expect(
            nearly_equal(summary.best_end_cost, 2001.0, 1e-12),
            "the prefix-offset fixture pays for the unmatched prefix once");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {0, 1, RouteAlignmentDtwStepKind::comparison_only},
                {0, 2, RouteAlignmentDtwStepKind::comparison_only},
                {1, 3, RouteAlignmentDtwStepKind::diagonal},
            },
            "an unmatched prefix is consumed by the open beginning");
    }

    {
        // The comparison route ends with two samples the primary never visits;
        // the open suffix simply stops the path before them.
        const auto primary = line({0.0, 25.0, 50.0, 75.0, 100.0, 125.0});
        const auto comparison =
            line({0.0, 25.0, 50.0, 75.0, 100.0, 125.0, 5000.0, 5001.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 8);
        const auto summary =
            solve(primary, comparison, 100.0, 100.0, 25.0, open_policy, output);
        expect_valid_path(summary, output, 6, 8, "the suffix-offset fixture solves");
        expect(
            nearly_equal(summary.best_end_cost, 0.0, 0.0),
            "the suffix-offset fixture aligns the shared prefix at zero cost");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {2, 2, RouteAlignmentDtwStepKind::diagonal},
                {3, 3, RouteAlignmentDtwStepKind::diagonal},
            },
            "an unmatched suffix is left outside the path");
    }

    {
        // Determinism: two identical calls must produce byte-identical output.
        std::vector<RouteAlignmentCostSample> primary;
        primary.reserve(64);
        std::vector<RouteAlignmentCostSample> comparison;
        comparison.reserve(70);
        for (std::int64_t i = 0; i < 64; ++i) {
            const double t = static_cast<double>(i);
            primary.push_back(point_with_heading(
                t * 9.0, std::sin(t * 0.25) * 30.0, t / 63.0, std::cos(t * 0.1)));
        }
        for (std::int64_t j = 0; j < 70; ++j) {
            const double t = static_cast<double>(j);
            comparison.push_back(point_with_heading(
                t * 8.0 + 4.0,
                std::sin(t * 0.23) * 28.0,
                t / 69.0,
                std::cos(t * 0.11)));
        }

        auto mixed_policy = product_default_policy();
        mixed_policy.band_width_fraction = 0.5;

        std::vector<RouteAlignmentDtwPathCell> first = make_output(64, 70);
        std::vector<RouteAlignmentDtwPathCell> second = make_output(64, 70);
        std::memset(
            first.data(), 0, first.size() * sizeof(RouteAlignmentDtwPathCell));
        std::memset(
            second.data(), 0, second.size() * sizeof(RouteAlignmentDtwPathCell));

        const auto first_summary = solve(
            primary, comparison, 1200.0, 1300.0, 20.0, mixed_policy, first);
        const auto second_summary = solve(
            primary, comparison, 1200.0, 1300.0, 20.0, mixed_policy, second);

        expect_valid_path(first_summary, first, 64, 70, "the determinism fixture solves");
        expect_valid_path(
            second_summary, second, 64, 70, "the repeated determinism fixture solves");
        expect(
            first_summary.required_path_count == second_summary.required_path_count,
            "repeated calls require the same path length");
        expect(
            first_summary.band_cell_count == second_summary.band_cell_count,
            "repeated calls pack the same band");
        expect(
            first_summary.best_end_cost == second_summary.best_end_cost,
            "repeated calls report the same end cost");
        expect(
            std::memcmp(
                first.data(),
                second.data(),
                first.size() * sizeof(RouteAlignmentDtwPathCell)) == 0,
            "repeated calls produce byte-identical output");
    }
}

void test_step_penalty() {
    // A non-diagonal transition pays the full penalty exactly once.
    {
        auto policy = tight_policy();
        policy.non_diagonal_step_penalty = 0.4;
        const auto primary = line({0.0, 10.0, 10.0, 20.0, 30.0, 40.0});
        const auto comparison = line({0.0, 10.0, 20.0, 30.0, 40.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 5);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 6, 5, "the penalised warp fixture solves");
        expect_exact_path(
            summary,
            output,
            {
                {0, 0, RouteAlignmentDtwStepKind::diagonal},
                {1, 1, RouteAlignmentDtwStepKind::diagonal},
                {2, 1, RouteAlignmentDtwStepKind::primary_only},
                {3, 2, RouteAlignmentDtwStepKind::diagonal},
                {4, 3, RouteAlignmentDtwStepKind::diagonal},
            },
            "a penalised warp keeps the same path");
        expect(
            nearly_equal(summary.best_end_cost, 0.4, 1e-12),
            "one warp transition pays the full non-diagonal penalty once");
    }

    // Open-beginning seeds along row 0 pay a quarter of the penalty each.
    {
        auto policy = tight_policy();
        policy.maximum_unmatched_prefix_suffix_meters = 100.0;
        policy.maximum_unmatched_prefix_suffix_fraction = 1.0;
        policy.non_diagonal_step_penalty = 0.4;
        const auto primary = line({0.0, 25.0, 50.0, 75.0, 100.0, 125.0});
        const auto comparison =
            line({-1000.0, -1001.0, 0.0, 25.0, 50.0, 75.0, 100.0, 125.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 8);
        const auto summary =
            solve(primary, comparison, 100.0, 100.0, 25.0, policy, output);
        expect_valid_path(summary, output, 6, 8, "the penalised prefix fixture solves");
        expect(summary.required_path_count == 4, "the penalised prefix keeps four cells");
        // 1000 + 1001 metres of separation plus two quarter penalties of 0.4.
        expect(
            nearly_equal(summary.best_end_cost, 2001.2, 1e-9),
            "each comparison-prefix seed pays a quarter of the penalty");
    }

    // The open-beginning seed down column 0 pays the same quarter penalty.
    {
        auto policy = tight_policy();
        policy.non_diagonal_step_penalty = 0.4;
        policy.maximum_consecutive_warp_steps = 0;
        const auto primary = line({0.0, 10.0, 10.0, 20.0, 30.0, 40.0});
        const auto comparison = line({0.0, 10.0, 20.0, 30.0, 40.0, 50.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(6, 6);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 6, 6, "the penalised column seed fixture solves");
        expect(summary.required_path_count == 6, "the penalised column seed keeps six cells");
        // 10 metres of separation plus one quarter penalty of 0.4.
        expect(
            nearly_equal(summary.best_end_cost, 10.1, 1e-9),
            "the primary-prefix seed pays a quarter of the penalty");
    }
}

void test_band_geometry() {
    // Narrow band: 100 x 100 at a 0.02 fraction is a radius of two.
    {
        auto policy = tight_policy();
        policy.band_width_fraction = 0.02;

        const BandExpectation band =
            expected_band(100, 100, 1000.0, 1000.0, 20.0, policy);
        expect(band.open_samples == 1, "a zero unmatched allowance opens one sample");
        expect(band.band_radius == 2, "ceil(100 * 0.02) is a radius of two");
        expect(band.band_cell_count == 494, "the narrow band packs 494 cells");

        // The comparison route covers half the ground per sample, so the
        // unconstrained optimum leaves the band and the solver must ride its edge.
        std::vector<RouteAlignmentCostSample> primary;
        std::vector<RouteAlignmentCostSample> comparison;
        primary.reserve(100);
        comparison.reserve(100);
        for (std::int64_t i = 0; i < 100; ++i) {
            const double t = static_cast<double>(i);
            primary.push_back(point_at(t * 10.0, 0.0, t / 99.0));
            comparison.push_back(point_at(t * 5.0, 0.0, t / 99.0));
        }

        std::vector<RouteAlignmentDtwPathCell> output = make_output(100, 100);
        const auto summary =
            solve(primary, comparison, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 100, 100, "the narrow-band fixture solves");
        expect(
            summary.band_radius == static_cast<std::uint64_t>(band.band_radius),
            "the reported radius matches the documented formula");
        expect(
            summary.band_cell_count
                == static_cast<std::uint64_t>(band.band_cell_count),
            "the reported packed cell count matches the documented formula");
        expect_path_inside_band(
            summary, output, band, "the narrow-band path never leaves the band");

        bool touches_row_end = false;
        for (std::uint64_t k = 0; k < summary.written_path_count; ++k) {
            const RouteAlignmentDtwPathCell& cell =
                output[static_cast<std::size_t>(k)];
            const std::size_t row = static_cast<std::size_t>(cell.primary_index);
            if (static_cast<std::int64_t>(cell.comparison_index)
                == band.row_ends[row]) {
                touches_row_end = true;
                break;
            }
        }
        expect(
            touches_row_end,
            "the narrow-band path rides the last column of a packed row");
    }

    // Fractional band width: ceil(7 * 0.15) rounds 1.05 up to two.
    {
        auto policy = tight_policy();
        policy.band_width_fraction = 0.15;

        const BandExpectation band =
            expected_band(7, 7, 1000.0, 1000.0, 20.0, policy);
        expect(band.band_radius == 2, "a fractional band width rounds up");
        expect(band.band_cell_count == 29, "the fractional band packs 29 cells");

        const auto route =
            line({0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0});
        std::vector<RouteAlignmentDtwPathCell> output = make_output(7, 7);
        const auto summary =
            solve(route, route, 1000.0, 1000.0, 20.0, policy, output);
        expect_valid_path(summary, output, 7, 7, "the fractional-band fixture solves");
        expect(summary.band_radius == 2, "the fractional band radius is reported");
        expect(summary.band_cell_count == 29, "the fractional band cell count is reported");
        expect_path_inside_band(
            summary, output, band, "the fractional-band path stays inside the band");
    }

    // Open-prefix and open-suffix expansion widen rows beyond the raw radius.
    {
        auto policy = tight_policy();
        policy.band_width_fraction = 0.01;
        policy.maximum_unmatched_prefix_suffix_meters = 400.0;
        policy.maximum_unmatched_prefix_suffix_fraction = 1.0;

        const BandExpectation band =
            expected_band(20, 100, 400.0, 400.0, 100.0, policy);
        expect(band.open_samples == 4, "400 metres over a 100 metre interval opens four");
        expect(band.band_radius == 4, "the radius is lifted to the open window");

        // Row 1 centres on column 5, so its raw start would be 1. The open
        // prefix pulls it back to 0.
        expect(band.row_starts[1] == 0, "the open prefix expands row 1 back to column 0");
        expect(band.row_ends[1] == 9, "row 1 keeps its raw band end");
        // Row 16 centres on column 83, so its raw end would be 87. The open
        // suffix pushes it out to the final column.
        expect(band.row_ends[16] == 99, "the open suffix expands row 16 to the last column");
        expect(band.row_starts[16] == 79, "row 16 keeps its raw band start");
        // Interior rows are untouched by either expansion.
        expect(band.row_starts[10] == 48, "an interior row keeps its raw band start");
        expect(band.row_ends[10] == 56, "an interior row keeps its raw band end");
        expect(
            band.band_cell_count > band.estimated_cells,
            "expansion can make the packed layout exceed the pre-check estimate");

        std::vector<RouteAlignmentCostSample> primary;
        std::vector<RouteAlignmentCostSample> comparison;
        primary.reserve(20);
        comparison.reserve(100);
        for (std::int64_t i = 0; i < 20; ++i) {
            primary.push_back(point_at(
                static_cast<double>(i) * 5.0, 0.0, static_cast<double>(i) / 19.0));
        }
        for (std::int64_t j = 0; j < 100; ++j) {
            comparison.push_back(point_at(
                static_cast<double>(j), 0.0, static_cast<double>(j) / 99.0));
        }

        std::vector<RouteAlignmentDtwPathCell> output = make_output(20, 100);
        const auto summary =
            solve(primary, comparison, 400.0, 400.0, 100.0, policy, output);
        expect_valid_path(summary, output, 20, 100, "the expanded-band fixture solves");
        expect(
            summary.band_radius == static_cast<std::uint64_t>(band.band_radius),
            "the expanded band reports the documented radius");
        expect(
            summary.band_cell_count
                == static_cast<std::uint64_t>(band.band_cell_count),
            "the expanded band reports the documented cell count");
        expect_path_inside_band(
            summary, output, band, "the expanded-band path stays inside the band");
    }

    // Unequal route counts pack asymmetrically: the row count follows the
    // primary route while the column clamp follows the comparison route.
    {
        auto policy = tight_policy();
        policy.band_width_fraction = 0.1;

        std::vector<RouteAlignmentCostSample> shorter;
        std::vector<RouteAlignmentCostSample> longer;
        shorter.reserve(30);
        longer.reserve(45);
        for (std::int64_t i = 0; i < 30; ++i) {
            shorter.push_back(point_at(
                static_cast<double>(i) * 15.0, 0.0, static_cast<double>(i) / 29.0));
        }
        for (std::int64_t j = 0; j < 45; ++j) {
            longer.push_back(point_at(
                static_cast<double>(j) * 10.0, 0.0, static_cast<double>(j) / 44.0));
        }

        const BandExpectation wide =
            expected_band(30, 45, 1000.0, 1000.0, 20.0, policy);
        expect(wide.band_radius == 5, "ceil(45 * 0.1) is a radius of five");
        expect(wide.band_cell_count == 309, "the 30 x 45 layout packs 309 cells");

        std::vector<RouteAlignmentDtwPathCell> wide_output = make_output(30, 45);
        const auto wide_summary =
            solve(shorter, longer, 1000.0, 1000.0, 20.0, policy, wide_output);
        expect_valid_path(
            wide_summary, wide_output, 30, 45, "the 30 x 45 fixture solves");
        expect(wide_summary.band_radius == 5, "the 30 x 45 radius is reported");
        expect(wide_summary.band_cell_count == 309, "the 30 x 45 cell count is reported");
        expect_path_inside_band(
            wide_summary, wide_output, wide, "the 30 x 45 path stays inside the band");

        const BandExpectation tall =
            expected_band(45, 30, 1000.0, 1000.0, 20.0, policy);
        expect(tall.band_radius == 5, "the transposed shape keeps a radius of five");
        expect(tall.band_cell_count == 450, "the 45 x 30 layout packs 450 cells");

        std::vector<RouteAlignmentDtwPathCell> tall_output = make_output(45, 30);
        const auto tall_summary =
            solve(longer, shorter, 1000.0, 1000.0, 20.0, policy, tall_output);
        expect_valid_path(
            tall_summary, tall_output, 45, 30, "the 45 x 30 fixture solves");
        expect(tall_summary.band_radius == 5, "the 45 x 30 radius is reported");
        expect(tall_summary.band_cell_count == 450, "the 45 x 30 cell count is reported");
        expect_path_inside_band(
            tall_summary, tall_output, tall, "the 45 x 30 path stays inside the band");
    }
}

void test_large_shapes() {
    constexpr std::int64_t sample_count = 2000;

    std::vector<RouteAlignmentCostSample> primary;
    std::vector<RouteAlignmentCostSample> comparison;
    primary.reserve(static_cast<std::size_t>(sample_count));
    comparison.reserve(static_cast<std::size_t>(sample_count));
    for (std::int64_t i = 0; i < sample_count; ++i) {
        const double t = static_cast<double>(i);
        const double progress = t / static_cast<double>(sample_count - 1);
        primary.push_back(point_at(t * 20.0, 0.0, progress));
        comparison.push_back(point_at(t * 20.0, 0.0, progress));
    }

    std::vector<RouteAlignmentDtwPathCell> output =
        make_output(static_cast<std::size_t>(sample_count),
                    static_cast<std::size_t>(sample_count));

    {
        // The product default shape: a 0.15 band fraction over 2000 samples.
        const RouteAlignmentDtwPolicy policy = product_default_policy();
        const BandExpectation band = expected_band(
            sample_count, sample_count, 40000.0, 40000.0, 20.0, policy);
        expect(band.open_samples == 25, "the default policy opens 25 samples");
        expect(band.band_radius == 300, "the default policy uses a radius of 300");
        expect(band.band_cell_count == 1'111'690, "the default 2000 x 2000 band packs 1111690 cells");

        const auto summary =
            solve(primary, comparison, 40000.0, 40000.0, 20.0, policy, output);
        expect_valid_path(
            summary,
            output,
            static_cast<std::size_t>(sample_count),
            static_cast<std::size_t>(sample_count),
            "the default 2000 x 2000 shape solves");
        expect(summary.band_radius == 300, "the large default radius is reported");
        expect(
            summary.band_cell_count == 1'111'690,
            "the large default packed cell count is reported");
        expect(
            summary.required_path_count == 1975,
            "the large default solve stops one open window short");
        expect(
            nearly_equal(summary.best_end_cost, 0.0, 0.0),
            "identical large routes align at zero cost");

        for (std::uint64_t k = 0; k < summary.written_path_count; ++k) {
            const RouteAlignmentDtwPathCell& cell =
                output[static_cast<std::size_t>(k)];
            expect(
                cell.step == RouteAlignmentDtwStepKind::diagonal,
                "identical large routes need no warp");
            expect(
                cell.primary_index == cell.comparison_index,
                "identical large routes stay on the matrix diagonal");
        }
    }

    {
        // A shape whose packed layout lands exactly on four million cells.
        auto policy = tight_policy();
        policy.band_width_fraction = 1.0;
        policy.spatial_distance_cost_scale_meters = 50.0;
        policy.maximum_spatial_cost = 8.0;
        policy.maximum_band_cells = 8'002'000;

        const BandExpectation band = expected_band(
            sample_count, sample_count, 40000.0, 40000.0, 20.0, policy);
        expect(band.band_radius == 2000, "the full band uses a radius of 2000");
        expect(band.estimated_cells == 8'002'000, "the full band estimate is 8002000 cells");
        expect(band.band_cell_count == 4'000'000, "the full band packs exactly 4000000 cells");

        const auto summary =
            solve(primary, comparison, 40000.0, 40000.0, 20.0, policy, output);
        expect_valid_path(
            summary,
            output,
            static_cast<std::size_t>(sample_count),
            static_cast<std::size_t>(sample_count),
            "the four-million-cell shape solves");
        expect(
            summary.band_cell_count == 4'000'000,
            "the four-million-cell packed count is reported");
        expect(
            summary.required_path_count == 1999,
            "the four-million-cell solve produces a full-length path");
        expect(
            summary.best_end_primary_index == 1998,
            "the four-million-cell solve ends one open window short");
    }
}

}  // namespace

void run_route_alignment_dtw_tests() {
    test_type_contract();
    test_buffer_contracts();
    test_input_contracts();
    test_policy_contracts();
    test_resource_limits();
    test_warp_limits();
    test_point_cost();
    test_paths();
    test_step_penalty();
    test_band_geometry();
    test_large_shapes();
}
