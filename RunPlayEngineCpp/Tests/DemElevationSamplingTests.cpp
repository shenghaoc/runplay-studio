#include "RunPlayEngineCpp/RunPlayEngine.hpp"
#include "TestSupport.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <limits>
#include <numbers>
#include <vector>

static_assert(
    noexcept(runplay::plan_dem_tiles(
        nullptr, 0u, runplay::DemSamplingPolicy{}, nullptr, 0u)),
    "plan_dem_tiles must remain noexcept at the Swift boundary");

namespace {

using runplay::DemRouteSample;
using runplay::DemSamplingPolicy;
using runplay::DemSamplingStatus;
using runplay::DemTileKey;
using runplay::DemTilePlanSummary;
using runplay::plan_dem_tiles;

constexpr double quiet_nan = std::numeric_limits<double>::quiet_NaN();
constexpr double infinity = std::numeric_limits<double>::infinity();

// The default test grid: zoom 2 with 4-pixel tiles, so the world is 16 pixels
// (4 x 4 tiles) and one pixel spans 22.5 degrees of longitude. Tiles are tiny
// so every tile edge is a few pixels away.
constexpr std::uint32_t grid_zoom = 2u;
constexpr std::uint32_t grid_tile_size = 4u;
constexpr double grid_world_pixels = 16.0;

[[nodiscard]]
DemSamplingPolicy make_policy(
    std::uint32_t zoom = grid_zoom,
    std::uint32_t tile_size = grid_tile_size,
    std::uint64_t maximum_tile_count = 64u
) noexcept {
    DemSamplingPolicy policy{};
    policy.zoom = zoom;
    policy.tile_size = tile_size;
    policy.maximum_tile_count = maximum_tile_count;
    policy.minimum_plausible_elevation_meters = -500.0;
    policy.maximum_plausible_elevation_meters = 9'000.0;
    return policy;
}

/// Longitude whose global pixel x is `global_x`. Exact for the dyadic
/// positions used below, so tile-edge cases are not at the mercy of rounding.
[[nodiscard]]
double longitude_at(double global_x, double world_pixels = grid_world_pixels) noexcept {
    return global_x / world_pixels * 360.0 - 180.0;
}

/// Latitude whose global pixel y is `global_y` (inverse Web Mercator). Only
/// used for positions well inside a pixel, where the last ulp cannot matter.
[[nodiscard]]
double latitude_at(double global_y, double world_pixels = grid_world_pixels) noexcept {
    const double y_fraction = global_y / world_pixels;
    const double mercator = std::numbers::pi_v<double> * (1.0 - 2.0 * y_fraction);
    return std::atan(std::sinh(mercator)) * 180.0 / std::numbers::pi_v<double>;
}

[[nodiscard]]
DemRouteSample at_pixel(
    double global_x,
    double global_y,
    double world_pixels = grid_world_pixels
) noexcept {
    return DemRouteSample{latitude_at(global_y, world_pixels), longitude_at(global_x, world_pixels)};
}

[[nodiscard]]
bool same_key(const DemTileKey& key, std::uint32_t x, std::uint32_t y) noexcept {
    return key.x == x && key.y == y;
}

[[nodiscard]]
bool key_less(const DemTileKey& lhs, const DemTileKey& rhs) noexcept {
    return lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x;
}

void fill_sentinel(std::vector<DemTileKey>& buffer) {
    for (std::size_t index = 0; index < buffer.size(); ++index) {
        buffer[index] = DemTileKey{0xDEAD0000u + static_cast<std::uint32_t>(index), 0xBEEFu};
    }
}

void expect_unchanged(const std::vector<DemTileKey>& buffer, const char* message) {
    for (std::size_t index = 0; index < buffer.size(); ++index) {
        expect(
            buffer[index].x == 0xDEAD0000u + static_cast<std::uint32_t>(index)
                && buffer[index].y == 0xBEEFu,
            message);
    }
}

void expect_zeroed(const DemTilePlanSummary& summary, DemSamplingStatus status, const char* message) {
    expect(summary.status == status, message);
    expect(
        summary.sample_count == 0u
            && summary.projectable_sample_count == 0u
            && summary.invalid_coordinate_count == 0u
            && summary.outside_projection_count == 0u
            && summary.required_tile_count == 0u
            && summary.written_tile_count == 0u,
        message);
}

struct Plan final {
    DemTilePlanSummary summary{};
    std::vector<DemTileKey> tiles;
};

[[nodiscard]]
Plan plan(const std::vector<DemRouteSample>& samples, DemSamplingPolicy policy = make_policy()) {
    Plan result;
    result.tiles.resize(static_cast<std::size_t>(policy.maximum_tile_count));
    result.summary = plan_dem_tiles(
        samples.data(), samples.size(), policy, result.tiles.data(), result.tiles.size());
    result.tiles.resize(static_cast<std::size_t>(result.summary.written_tile_count));
    return result;
}

void expect_tiles(
    const Plan& result,
    std::initializer_list<std::array<std::uint32_t, 2>> expected,
    const char* message
) {
    expect(result.summary.status == DemSamplingStatus::success, message);
    expect(result.tiles.size() == expected.size(), message);
    expect(result.summary.required_tile_count == expected.size(), message);
    std::size_t index = 0;
    for (const auto& key : expected) {
        expect(same_key(result.tiles[index], key[0], key[1]), message);
        ++index;
    }
}

// ---- Contract and validation ----------------------------------------------

void test_plan_empty_input() {
    const DemTilePlanSummary empty = plan_dem_tiles(nullptr, 0u, make_policy(), nullptr, 0u);
    expect_zeroed(empty, DemSamplingStatus::success, "empty route plans no tiles");

    DemSamplingPolicy invalid = make_policy();
    invalid.tile_size = 1u;
    const DemTilePlanSummary rejected = plan_dem_tiles(nullptr, 0u, invalid, nullptr, 0u);
    expect_zeroed(rejected, DemSamplingStatus::invalid_policy, "empty route still validates the policy");
}

void test_plan_validation_failures_leave_output_untouched() {
    const DemRouteSample sample = at_pixel(6.25, 6.25);
    std::vector<DemTileKey> output(8u);

    fill_sentinel(output);
    expect_zeroed(
        plan_dem_tiles(nullptr, 1u, make_policy(), output.data(), output.size()),
        DemSamplingStatus::invalid_input_buffer,
        "null samples with a count");
    expect_unchanged(output, "null samples leave output unchanged");

    expect_zeroed(
        plan_dem_tiles(&sample, 1u, make_policy(), nullptr, 8u),
        DemSamplingStatus::invalid_output_buffer,
        "null output with a capacity");

    fill_sentinel(output);
    expect_zeroed(
        plan_dem_tiles(
            &sample, runplay::max_route_input_samples + 1u, make_policy(), output.data(), output.size()),
        DemSamplingStatus::resource_limit,
        "oversized route is rejected before the buffer is read");
    expect_unchanged(output, "resource limit leaves output unchanged");

    std::vector<DemSamplingPolicy> invalid_policies;
    auto with = [&invalid_policies](auto mutate) {
        DemSamplingPolicy policy = make_policy();
        mutate(policy);
        invalid_policies.push_back(policy);
    };
    with([](DemSamplingPolicy& p) { p.zoom = runplay::dem_maximum_zoom + 1u; });
    with([](DemSamplingPolicy& p) { p.tile_size = runplay::dem_minimum_tile_size - 1u; });
    with([](DemSamplingPolicy& p) { p.tile_size = runplay::dem_maximum_tile_size + 1u; });
    with([](DemSamplingPolicy& p) { p.maximum_tile_count = 0u; });
    with([](DemSamplingPolicy& p) { p.maximum_tile_count = runplay::dem_maximum_tile_count + 1u; });
    with([](DemSamplingPolicy& p) { p.minimum_plausible_elevation_meters = quiet_nan; });
    with([](DemSamplingPolicy& p) { p.maximum_plausible_elevation_meters = infinity; });
    with([](DemSamplingPolicy& p) { p.maximum_plausible_elevation_meters = -500.0; });
    with([](DemSamplingPolicy& p) { p.maximum_plausible_elevation_meters = -600.0; });
    for (const DemSamplingPolicy& policy : invalid_policies) {
        fill_sentinel(output);
        expect_zeroed(
            plan_dem_tiles(&sample, 1u, policy, output.data(), output.size()),
            DemSamplingStatus::invalid_policy,
            "invalid policy is rejected");
        expect_unchanged(output, "invalid policy leaves output unchanged");
    }

    DemSamplingPolicy boundary = make_policy(runplay::dem_maximum_zoom, runplay::dem_maximum_tile_size);
    boundary.maximum_tile_count = runplay::dem_maximum_tile_count;
    std::vector<DemTileKey> large_output(4u);
    const DemTilePlanSummary accepted =
        plan_dem_tiles(&sample, 1u, boundary, large_output.data(), large_output.size());
    expect(accepted.status == DemSamplingStatus::success, "inclusive policy bounds are accepted");
}

// ---- Footprints ------------------------------------------------------------

void test_plan_interior_point_needs_one_tile() {
    // Pixel position (6.25, 6.25): bilinear corners at columns 5-6 and rows
    // 5-6, all inside tile (1, 1).
    const Plan result = plan({at_pixel(6.25, 6.25)});
    expect_tiles(result, {{1u, 1u}}, "interior point needs its own tile only");
    expect(result.summary.projectable_sample_count == 1u, "interior point is projectable");
}

void test_plan_tile_edges() {
    // Exactly on the vertical edge between tile columns 0 and 1: the corners
    // are pixel columns 3 and 4, weighted equally.
    expect_tiles(
        plan({at_pixel(4.0, 6.25)}),
        {{0u, 1u}, {1u, 1u}},
        "a sample on a tile edge needs both neighbouring tiles");

    // A quarter pixel inside tile 0: column 4 still carries weight.
    expect_tiles(
        plan({at_pixel(3.75, 6.25)}),
        {{0u, 1u}, {1u, 1u}},
        "within half a pixel of an edge the neighbour carries weight");

    // Exactly on the centre of the edge pixel: the neighbour's weight is zero,
    // so the neighbouring tile is not needed.
    expect_tiles(
        plan({at_pixel(3.5, 6.25)}),
        {{0u, 1u}},
        "a pixel-centre sample needs no zero-weight neighbour");

    // Tile corner: longitude -90 is the column-3/4 edge, and the equator is
    // the row-7/8 edge between tile rows 1 and 2.
    expect_tiles(
        plan({DemRouteSample{0.0, -90.0}}),
        {{0u, 1u}, {1u, 1u}, {0u, 2u}, {1u, 2u}},
        "a sample on a tile corner needs all four tiles, in (y, x) order");
}

void test_plan_antimeridian_wraps_columns() {
    for (const double longitude : {180.0, -180.0, longitude_at(15.9), longitude_at(0.1)}) {
        expect_tiles(
            plan({DemRouteSample{latitude_at(6.25), longitude}}),
            {{0u, 1u}, {3u, 1u}},
            "the antimeridian pairs the last and first tile columns");
    }

    // Zoom 0 is a single tile, so wrapping stays inside it.
    DemSamplingPolicy single = make_policy(0u, 4u);
    expect_tiles(
        plan({DemRouteSample{10.0, 180.0}, DemRouteSample{-10.0, -179.0}}, single),
        {{0u, 0u}},
        "zoom 0 wraps within its only tile");
}

void test_plan_pole_guards() {
    const Plan outside = plan({
        DemRouteSample{85.06, 10.0},
        DemRouteSample{-85.06, 10.0},
        DemRouteSample{90.0, 10.0},
        DemRouteSample{-90.0, 10.0},
    });
    expect(outside.summary.status == DemSamplingStatus::success, "outside projection is not an error");
    expect(outside.summary.outside_projection_count == 4u, "beyond the Mercator limit has no tile");
    expect(outside.summary.projectable_sample_count == 0u, "no projectable samples");
    expect(outside.summary.required_tile_count == 0u, "no tiles for polar samples");

    // Exactly at the limit the sample sits on the world edge; rows clamp to
    // the first (or last) row instead of wrapping across the pole.
    const double limit = runplay::dem_web_mercator_max_latitude_degrees;
    expect_tiles(
        plan({DemRouteSample{limit, longitude_at(6.25)}}),
        {{1u, 0u}},
        "the northern limit reads only the top tile row");
    expect_tiles(
        plan({DemRouteSample{-limit, longitude_at(6.25)}}),
        {{1u, 3u}},
        "the southern limit reads only the bottom tile row");
}

void test_plan_invalid_coordinates_need_no_tiles() {
    const Plan result = plan({
        DemRouteSample{quiet_nan, 10.0},
        DemRouteSample{10.0, infinity},
        DemRouteSample{90.5, 10.0},
        DemRouteSample{10.0, 180.5},
        DemRouteSample{10.0, -180.0001},
        at_pixel(6.25, 6.25),
    });
    expect(result.summary.invalid_coordinate_count == 5u, "invalid coordinates are counted");
    expect(result.summary.projectable_sample_count == 1u, "the valid sample is projectable");
    expect(result.summary.sample_count == 6u, "every sample is counted");
    expect_tiles(result, {{1u, 1u}}, "invalid coordinates need no tile");
}

// ---- Output ordering, budget, capacity ---------------------------------------

void test_plan_output_is_sorted_and_unique() {
    // Tile centres visited out of order, with repeats.
    const Plan result = plan({
        at_pixel(14.0, 14.0),
        at_pixel(2.0, 2.0),
        at_pixel(10.0, 6.0),
        at_pixel(2.0, 2.0),
        at_pixel(14.0, 14.0),
        at_pixel(6.0, 10.0),
    });
    expect_tiles(
        result,
        {{0u, 0u}, {2u, 1u}, {1u, 2u}, {3u, 3u}},
        "tiles are distinct and strictly ascending by (y, x)");
}

void test_plan_tile_budget() {
    const std::vector<DemRouteSample> five_tiles{
        at_pixel(2.0, 2.0),
        at_pixel(6.0, 2.0),
        at_pixel(10.0, 2.0),
        at_pixel(14.0, 2.0),
        at_pixel(2.0, 6.0),
    };

    std::vector<DemTileKey> output(8u);
    fill_sentinel(output);
    const DemTilePlanSummary exceeded = plan_dem_tiles(
        five_tiles.data(), five_tiles.size(), make_policy(grid_zoom, grid_tile_size, 4u),
        output.data(), output.size());
    expect(exceeded.status == DemSamplingStatus::tile_budget_exceeded, "budget of four rejects five tiles");
    expect(exceeded.sample_count == 5u, "budget failure reports the sample count");
    expect(exceeded.required_tile_count == 5u, "budget failure reports budget + 1 as a lower bound");
    expect(
        exceeded.projectable_sample_count == 0u && exceeded.written_tile_count == 0u,
        "budget failure leaves other counts zero");
    expect_unchanged(output, "budget failure leaves output unchanged");

    expect(
        plan(five_tiles, make_policy(grid_zoom, grid_tile_size, 5u)).summary.status
            == DemSamplingStatus::success,
        "a budget equal to the need succeeds");
}

void test_plan_insufficient_capacity_writes_nothing() {
    const DemRouteSample corner{0.0, -90.0};
    std::vector<DemTileKey> output(3u);
    fill_sentinel(output);
    const DemTilePlanSummary short_buffer =
        plan_dem_tiles(&corner, 1u, make_policy(), output.data(), output.size());
    expect(short_buffer.status == DemSamplingStatus::insufficient_output_capacity, "three slots for four tiles");
    expect(short_buffer.required_tile_count == 4u, "insufficient capacity reports the exact need");
    expect(short_buffer.projectable_sample_count == 1u, "insufficient capacity keeps exact counts");
    expect(short_buffer.written_tile_count == 0u, "nothing written");
    expect_unchanged(output, "insufficient capacity leaves output unchanged");

    const DemTilePlanSummary probe = plan_dem_tiles(&corner, 1u, make_policy(), nullptr, 0u);
    expect(probe.status == DemSamplingStatus::insufficient_output_capacity, "null output with zero capacity");
    expect(probe.required_tile_count == 4u, "null output still reports the need");
}

// ---- Scale and extremes ------------------------------------------------------

void test_plan_large_route_is_deterministic_and_bounded() {
    // A 100,000-point random walk at zoom 12 with 256-pixel tiles, roughly a
    // long run's footprint.
    std::vector<DemRouteSample> route;
    route.reserve(100'000u);
    std::uint64_t state = 0x9E3779B97F4A7C15ULL;
    double latitude = 46.5;
    double longitude = 7.9;
    for (std::size_t index = 0; index < 100'000u; ++index) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        const double step = static_cast<double>(state >> 40) / static_cast<double>(1ULL << 24);
        latitude += (step - 0.45) * 0.0004;
        longitude += (step - 0.40) * 0.0006;
        route.push_back(DemRouteSample{latitude, longitude});
    }

    const DemSamplingPolicy policy = make_policy(12u, 256u, 4'096u);
    const Plan first = plan(route, policy);
    const Plan second = plan(route, policy);
    expect(first.summary.status == DemSamplingStatus::success, "large route plans");
    expect(first.summary.projectable_sample_count == route.size(), "every walk point is projectable");
    expect(first.tiles.size() == second.tiles.size(), "planning is deterministic");
    for (std::size_t index = 0; index < first.tiles.size(); ++index) {
        expect(same_key(second.tiles[index], first.tiles[index].x, first.tiles[index].y), "same tiles");
        expect(first.tiles[index].x < 4'096u && first.tiles[index].y < 4'096u, "keys inside the zoom-12 grid");
        if (index > 0u) {
            expect(key_less(first.tiles[index - 1u], first.tiles[index]), "strictly ascending");
        }
    }
}

void test_plan_extreme_grids() {
    // Zoom 24 with 4,096-pixel tiles: the largest grid the policy accepts.
    const Plan fine = plan(
        {DemRouteSample{-33.8568, 151.2153}},
        make_policy(runplay::dem_maximum_zoom, runplay::dem_maximum_tile_size, 8u));
    expect(fine.summary.status == DemSamplingStatus::success, "finest grid plans");
    expect(!fine.tiles.empty() && fine.tiles.size() <= 4u, "one footprint needs one to four tiles");
    for (const DemTileKey& key : fine.tiles) {
        expect(key.x < (1u << 24) && key.y < (1u << 24), "keys inside the zoom-24 grid");
    }

    // Zoom 0 with 2-pixel tiles: every footprint stays in the only tile.
    expect_tiles(
        plan(
            {DemRouteSample{0.0, 0.0}, DemRouteSample{60.0, 179.9}, DemRouteSample{-60.0, -179.9}},
            make_policy(0u, runplay::dem_minimum_tile_size, 4u)),
        {{0u, 0u}},
        "coarsest grid has one tile");
}

}  // namespace

void run_dem_elevation_sampling_tests() {
    test_plan_empty_input();
    test_plan_validation_failures_leave_output_untouched();
    test_plan_interior_point_needs_one_tile();
    test_plan_tile_edges();
    test_plan_antimeridian_wraps_columns();
    test_plan_pole_guards();
    test_plan_invalid_coordinates_need_no_tiles();
    test_plan_output_is_sorted_and_unique();
    test_plan_tile_budget();
    test_plan_insufficient_capacity_writes_nothing();
    test_plan_large_route_is_deterministic_and_bounded();
    test_plan_extreme_grids();
}
