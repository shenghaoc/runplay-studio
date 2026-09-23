#include "RunPlayEngineCpp/RunPlayEngine.hpp"
#include "TestSupport.hpp"

#include <algorithm>
#include <array>
#include <bit>
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
static_assert(
    noexcept(runplay::sample_dem_elevations(
        nullptr, 0u, runplay::DemSamplingPolicy{}, nullptr, 0u, nullptr, 0u, nullptr, 0u)),
    "sample_dem_elevations must remain noexcept at the Swift boundary");

namespace {

using runplay::DemRouteSample;
using runplay::DemSamplingPolicy;
using runplay::DemSamplingStatus;
using runplay::DemTileKey;
using runplay::DemElevationOutputSample;
using runplay::DemSampleStatus;
using runplay::DemSamplingSummary;
using runplay::DemTileHeightSample;
using runplay::DemTilePlanSummary;
using runplay::plan_dem_tiles;
using runplay::sample_dem_elevations;

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

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

struct TileSet final {
    std::vector<DemTileKey> keys;
    std::vector<DemTileHeightSample> heights;
};

/// Heights for `keys` (already ascending by (y, x)), where the pixel at global
/// column c and row r holds `height_at(c, r)`.
template <typename HeightAt>
TileSet make_tiles(const std::vector<DemTileKey>& keys, std::uint32_t tile_size, HeightAt height_at) {
    TileSet set;
    set.keys = keys;
    set.heights.reserve(keys.size() * tile_size * tile_size);
    for (const DemTileKey& key : keys) {
        for (std::uint32_t row = 0u; row < tile_size; ++row) {
            for (std::uint32_t column = 0u; column < tile_size; ++column) {
                const std::int64_t global_column =
                    static_cast<std::int64_t>(key.x) * tile_size + column;
                const std::int64_t global_row = static_cast<std::int64_t>(key.y) * tile_size + row;
                set.heights.push_back(DemTileHeightSample{height_at(global_column, global_row)});
            }
        }
    }
    return set;
}

[[nodiscard]]
std::vector<DemTileKey> all_tiles(std::uint32_t zoom) {
    std::vector<DemTileKey> keys;
    const std::uint32_t side = 1u << zoom;
    for (std::uint32_t y = 0u; y < side; ++y) {
        for (std::uint32_t x = 0u; x < side; ++x) {
            keys.push_back(DemTileKey{x, y});
        }
    }
    return keys;
}

/// A plane in pixel space: exact in single precision on the small test grid,
/// and reproduced exactly by bilinear interpolation.
[[nodiscard]]
float planar_height(std::int64_t column, std::int64_t row) noexcept {
    return static_cast<float>(100.0 + 0.5 * static_cast<double>(column) - 0.25 * static_cast<double>(row));
}

/// The plane's value at a sample whose global pixel position is (x, y): pixel
/// centres sit half a pixel in from their corners.
[[nodiscard]]
double planar_expected(double global_x, double global_y) noexcept {
    return 100.0 + 0.5 * (global_x - 0.5) - 0.25 * (global_y - 0.5);
}

struct Sampled final {
    DemSamplingSummary summary{};
    std::vector<DemElevationOutputSample> outputs;
};

[[nodiscard]]
Sampled sample(
    const std::vector<DemRouteSample>& samples,
    const TileSet& tiles,
    DemSamplingPolicy policy = make_policy()
) {
    Sampled result;
    result.outputs.resize(samples.size());
    result.summary = sample_dem_elevations(
        samples.data(), samples.size(), policy,
        tiles.keys.data(), tiles.keys.size(),
        tiles.heights.data(), tiles.heights.size(),
        result.outputs.data(), result.outputs.size());
    for (const DemElevationOutputSample& output : result.outputs) {
        const bool sampled = output.status == DemSampleStatus::sampled;
        expect(output.has_elevation == (sampled ? 1u : 0u), "has_elevation mirrors the sampled status");
        expect(sampled || output.elevation_meters == 0.0, "no elevation value without a sample");
    }
    return result;
}

[[nodiscard]]
bool near(double value, double expected, double tolerance = 1e-9) noexcept {
    return std::isfinite(value) && std::abs(value - expected) <= tolerance;
}

void fill_output_sentinel(std::vector<DemElevationOutputSample>& buffer) {
    for (std::size_t index = 0; index < buffer.size(); ++index) {
        buffer[index].elevation_meters = -777.0 - static_cast<double>(index);
        buffer[index].status = DemSampleStatus::implausible_height;
        buffer[index].has_elevation = 7u;
    }
}

void expect_output_unchanged(const std::vector<DemElevationOutputSample>& buffer, const char* message) {
    for (std::size_t index = 0; index < buffer.size(); ++index) {
        expect(
            buffer[index].elevation_meters == -777.0 - static_cast<double>(index)
                && buffer[index].status == DemSampleStatus::implausible_height
                && buffer[index].has_elevation == 7u,
            message);
    }
}

void expect_sampling_failure(
    const DemSamplingSummary& summary,
    DemSamplingStatus status,
    std::size_t sample_count,
    const char* message
) {
    expect(summary.status == status, message);
    expect(
        summary.sample_count == 0u && summary.sampled_count == 0u
            && summary.invalid_coordinate_count == 0u && summary.outside_projection_count == 0u
            && summary.missing_tile_count == 0u && summary.implausible_height_count == 0u,
        message);
    expect(summary.required_output_capacity == sample_count, message);
}

void test_sample_contract() {
    const TileSet grid = make_tiles(all_tiles(grid_zoom), grid_tile_size, planar_height);
    const DemSamplingSummary empty = sample_dem_elevations(
        nullptr, 0u, make_policy(), grid.keys.data(), grid.keys.size(),
        grid.heights.data(), grid.heights.size(), nullptr, 0u);
    expect(empty.status == DemSamplingStatus::success, "empty route samples nothing");
    expect(empty.sample_count == 0u && empty.required_output_capacity == 0u, "empty counts");

    DemSamplingPolicy invalid = make_policy();
    invalid.zoom = runplay::dem_maximum_zoom + 1u;
    expect_sampling_failure(
        sample_dem_elevations(nullptr, 0u, invalid, nullptr, 0u, nullptr, 0u, nullptr, 0u),
        DemSamplingStatus::invalid_policy, 0u, "empty route still validates the policy");

    const DemTileKey unsorted[2] = {DemTileKey{1u, 0u}, DemTileKey{0u, 0u}};
    const std::vector<DemTileHeightSample> heights(2u * 16u);
    expect_sampling_failure(
        sample_dem_elevations(nullptr, 0u, make_policy(), unsorted, 2u, heights.data(), heights.size(), nullptr, 0u),
        DemSamplingStatus::invalid_tile_directory, 0u, "empty route still validates the directory");
}

void test_sample_validation_failures_leave_output_untouched() {
    const TileSet grid = make_tiles(all_tiles(grid_zoom), grid_tile_size, planar_height);
    const std::vector<DemRouteSample> route{at_pixel(6.25, 6.25), at_pixel(9.5, 3.0)};
    std::vector<DemElevationOutputSample> output(route.size());
    const auto run = [&](const DemRouteSample* samples, std::size_t count, DemSamplingPolicy policy,
                         const DemTileKey* keys, std::size_t key_count,
                         const DemTileHeightSample* heights, std::size_t height_count,
                         DemElevationOutputSample* out, std::size_t capacity) {
        fill_output_sentinel(output);
        return sample_dem_elevations(samples, count, policy, keys, key_count, heights, height_count, out, capacity);
    };
    const DemTileKey* keys = grid.keys.data();
    const std::size_t key_count = grid.keys.size();
    const DemTileHeightSample* heights = grid.heights.data();
    const std::size_t height_count = grid.heights.size();

    expect_sampling_failure(
        run(nullptr, 2u, make_policy(), keys, key_count, heights, height_count, output.data(), output.size()),
        DemSamplingStatus::invalid_input_buffer, 2u, "null samples with a count");
    expect_output_unchanged(output, "null samples leave output unchanged");
    expect_sampling_failure(
        run(route.data(), 2u, make_policy(), nullptr, key_count, heights, height_count, output.data(), output.size()),
        DemSamplingStatus::invalid_input_buffer, 2u, "null tiles with a count");
    expect_output_unchanged(output, "null tiles leave output unchanged");
    expect_sampling_failure(
        run(route.data(), 2u, make_policy(), keys, key_count, nullptr, height_count, output.data(), output.size()),
        DemSamplingStatus::invalid_input_buffer, 2u, "null heights with a count");
    expect_output_unchanged(output, "null heights leave output unchanged");
    expect_sampling_failure(
        run(route.data(), 2u, make_policy(), keys, key_count, heights, height_count, nullptr, 2u),
        DemSamplingStatus::invalid_output_buffer, 2u, "null output with a capacity");
    expect_sampling_failure(
        run(route.data(), 2u, make_policy(), keys, key_count, heights, height_count, output.data(), 1u),
        DemSamplingStatus::insufficient_output_capacity, 2u, "capacity below the sample count");
    expect_output_unchanged(output, "short capacity leaves output unchanged");
    expect_sampling_failure(
        run(route.data(), runplay::max_route_input_samples + 1u, make_policy(), keys, key_count, heights,
            height_count, output.data(), runplay::max_route_input_samples + 1u),
        DemSamplingStatus::resource_limit, runplay::max_route_input_samples + 1u,
        "oversized route is rejected before the buffers are read");
    expect_output_unchanged(output, "resource limit leaves output unchanged");

    DemSamplingPolicy bad_policy = make_policy();
    bad_policy.minimum_plausible_elevation_meters = 9'000.0;
    expect_sampling_failure(
        run(route.data(), 2u, bad_policy, keys, key_count, heights, height_count, output.data(), output.size()),
        DemSamplingStatus::invalid_policy, 2u, "inverted plausible range");
    expect_output_unchanged(output, "invalid policy leaves output unchanged");

    // Directory contract violations.
    const auto directory_failure = [&](const std::vector<DemTileKey>& bad_keys, std::size_t bad_height_count,
                                       DemSamplingPolicy policy, const char* message) {
        const std::vector<DemTileHeightSample> bad_heights(bad_height_count);
        expect_sampling_failure(
            run(route.data(), 2u, policy, bad_keys.data(), bad_keys.size(),
                bad_heights.data(), bad_heights.size(), output.data(), output.size()),
            DemSamplingStatus::invalid_tile_directory, 2u, message);
        expect_output_unchanged(output, message);
    };
    directory_failure({DemTileKey{1u, 1u}, DemTileKey{0u, 1u}}, 32u, make_policy(), "keys out of (y, x) order");
    directory_failure({DemTileKey{1u, 1u}, DemTileKey{1u, 1u}}, 32u, make_policy(), "duplicate keys");
    directory_failure({DemTileKey{4u, 0u}}, 16u, make_policy(), "x outside the zoom-2 grid");
    directory_failure({DemTileKey{0u, 4u}}, 16u, make_policy(), "y outside the zoom-2 grid");
    directory_failure({DemTileKey{0u, 0u}}, 15u, make_policy(), "too few heights for one tile");
    directory_failure({DemTileKey{0u, 0u}}, 17u, make_policy(), "too many heights for one tile");
    directory_failure(
        {DemTileKey{0u, 0u}, DemTileKey{1u, 0u}}, 32u, make_policy(grid_zoom, grid_tile_size, 1u),
        "more tiles than the budget");
}

void test_sample_bilinear_exactness() {
    const TileSet grid = make_tiles(all_tiles(grid_zoom), grid_tile_size, planar_height);

    // Pixel centres return the stored pixel exactly.
    const Sampled centres = sample({DemRouteSample{0.0, longitude_at(5.5)}}, grid);
    // Latitude 0 is global y 8.0: halfway between rows 7 and 8.
    expect(centres.outputs[0].elevation_meters == planar_expected(5.5, 8.0), "pixel-centre column, row midpoint");

    // Dyadic positions along the equator are exact, including tile edges and
    // the tile corner at longitude -90 / latitude 0.
    for (const double global_x : {0.75, 3.5, 3.75, 4.0, 4.25, 7.875, 8.0, 12.5, 15.25}) {
        const Sampled result = sample({DemRouteSample{0.0, longitude_at(global_x)}}, grid);
        expect(result.outputs[0].status == DemSampleStatus::sampled, "equator samples");
        expect(
            result.outputs[0].elevation_meters == planar_expected(global_x, 8.0),
            "bilinear reproduces the plane exactly at dyadic positions");
    }

    // Away from the equator the latitude round trip is inexact, so compare
    // with a tolerance.
    for (const double global_y : {1.3, 3.9, 4.0, 6.25, 11.7, 14.2}) {
        const DemRouteSample point = at_pixel(6.3, global_y);
        const Sampled result = sample({point}, grid);
        expect(result.outputs[0].status == DemSampleStatus::sampled, "off-equator samples");
        expect(near(result.outputs[0].elevation_meters, planar_expected(6.3, global_y), 1e-6), "plane off the equator");
    }
    expect(sample({at_pixel(6.25, 6.25)}, grid).summary.sampled_count == 1u, "summary counts the sample");
}

void test_sample_missing_tiles_fall_back_per_point() {
    std::vector<DemTileKey> keys = all_tiles(grid_zoom);
    std::erase_if(keys, [](const DemTileKey& key) { return key.x == 1u && key.y == 1u; });
    const TileSet partial = make_tiles(keys, grid_tile_size, planar_height);

    const Sampled result = sample(
        {
            at_pixel(2.25, 6.25),  // inside tile (0, 1)
            at_pixel(4.0, 6.25),   // on the edge with the missing tile (1, 1)
            at_pixel(6.25, 6.25),  // inside the missing tile
            at_pixel(3.5, 6.25),   // centre of the edge pixel: the missing neighbour has zero weight
            at_pixel(10.25, 6.25), // inside tile (2, 1)
        },
        partial);
    expect(result.summary.status == DemSamplingStatus::success, "missing tiles are not an error");
    expect(result.outputs[0].status == DemSampleStatus::sampled, "a point inside a present tile is sampled");
    expect(result.outputs[1].status == DemSampleStatus::missing_tile, "a point needing the missing tile falls back");
    expect(result.outputs[2].status == DemSampleStatus::missing_tile, "a point inside the missing tile falls back");
    expect(result.outputs[3].status == DemSampleStatus::sampled, "a zero-weight missing neighbour is not needed");
    expect(near(result.outputs[3].elevation_meters, planar_expected(3.5, 6.25), 1e-6), "edge-pixel centre value");
    expect(result.outputs[4].status == DemSampleStatus::sampled, "points after a fallback are unaffected");
    expect(result.summary.sampled_count == 3u && result.summary.missing_tile_count == 2u, "per-status counts");
}

void test_sample_implausible_heights() {
    // Pixels (5, 5) NaN, (6, 5) +inf, (5, 6) above the range, (6, 6) below it:
    // tile (1, 1), columns 5-6, rows 5-6.
    const auto height_at = [](std::int64_t column, std::int64_t row) -> float {
        if (column == 5 && row == 5) return std::numeric_limits<float>::quiet_NaN();
        if (column == 6 && row == 5) return std::numeric_limits<float>::infinity();
        if (column == 9 && row == 5) return 9'500.0f;
        if (column == 9 && row == 9) return -600.0f;
        if (column == 11 && row == 11) return std::numeric_limits<float>::quiet_NaN();
        return planar_height(column, row);
    };
    std::vector<DemTileKey> keys = all_tiles(grid_zoom);
    std::erase_if(keys, [](const DemTileKey& key) { return key.x == 3u && key.y == 3u; });
    const TileSet tiles = make_tiles(keys, grid_tile_size, height_at);

    const Sampled result = sample(
        {
            at_pixel(6.0, 5.75),    // reads (5, 5) NaN and (6, 5) +inf
            at_pixel(9.75, 5.75),   // reads (9, 5) above the range
            at_pixel(9.75, 9.75),   // reads (9, 9) below the range
            at_pixel(5.5, 5.5),     // centre of the NaN pixel: its weight is one
            at_pixel(4.5, 4.5),     // centre of (4, 4): the NaN pixel has zero weight
            at_pixel(12.25, 12.25), // reads NaN pixel (11, 11) and missing tile (3, 3)
        },
        tiles);
    expect(result.outputs[0].status == DemSampleStatus::implausible_height, "non-finite corner heights");
    expect(result.outputs[1].status == DemSampleStatus::implausible_height, "a corner above the plausible range");
    expect(result.outputs[2].status == DemSampleStatus::implausible_height, "a corner below the plausible range");
    expect(result.outputs[3].status == DemSampleStatus::implausible_height, "a full-weight NaN pixel");
    expect(result.outputs[4].status == DemSampleStatus::sampled, "zero-weight corners are never read");
    expect(result.outputs[5].status == DemSampleStatus::missing_tile, "missing outranks implausible");
    expect(result.summary.implausible_height_count == 4u, "implausible count");
}

void test_sample_antimeridian() {
    const TileSet grid = make_tiles(all_tiles(grid_zoom), grid_tile_size, planar_height);
    const double last_column = static_cast<double>(planar_height(15, 7) + planar_height(15, 8)) / 2.0;
    const double first_column = static_cast<double>(planar_height(0, 7) + planar_height(0, 8)) / 2.0;

    const Sampled east = sample({DemRouteSample{0.0, 180.0}}, grid);
    const Sampled west = sample({DemRouteSample{0.0, -180.0}}, grid);
    expect(east.outputs[0].status == DemSampleStatus::sampled, "longitude 180 samples");
    expect(
        east.outputs[0].elevation_meters == west.outputs[0].elevation_meters,
        "+-180 name the same meridian and give the same height");
    expect(
        east.outputs[0].elevation_meters == (last_column + first_column) / 2.0,
        "the antimeridian interpolates between the last and first columns");

    // A quarter pixel east of the antimeridian: the first column carries 0.75.
    const Sampled near_west = sample({DemRouteSample{0.0, longitude_at(0.25)}}, grid);
    expect(
        near(near_west.outputs[0].elevation_meters, last_column + (first_column - last_column) * 0.75),
        "fractional weight across the antimeridian");
}

void test_sample_pole_guards() {
    const TileSet grid = make_tiles(all_tiles(grid_zoom), grid_tile_size, planar_height);
    const double limit = runplay::dem_web_mercator_max_latitude_degrees;
    const Sampled result = sample(
        {
            DemRouteSample{limit, longitude_at(6.25)},
            DemRouteSample{-limit, longitude_at(6.25)},
            DemRouteSample{85.06, 10.0},
            DemRouteSample{-90.0, 10.0},
            DemRouteSample{quiet_nan, 10.0},
        },
        grid);
    // At the limit the rows clamp: only the edge row is read.
    const double top_row = static_cast<double>(planar_height(5, 0))
        + (static_cast<double>(planar_height(6, 0)) - static_cast<double>(planar_height(5, 0))) * 0.75;
    const double bottom_row = static_cast<double>(planar_height(5, 15))
        + (static_cast<double>(planar_height(6, 15)) - static_cast<double>(planar_height(5, 15))) * 0.75;
    expect(result.outputs[0].status == DemSampleStatus::sampled, "the northern limit samples");
    expect(near(result.outputs[0].elevation_meters, top_row), "the northern limit reads only the top row");
    expect(near(result.outputs[1].elevation_meters, bottom_row), "the southern limit reads only the bottom row");
    expect(result.outputs[2].status == DemSampleStatus::outside_projection, "beyond the limit");
    expect(result.outputs[3].status == DemSampleStatus::outside_projection, "the pole itself");
    expect(result.outputs[4].status == DemSampleStatus::invalid_coordinate, "invalid coordinate");
    expect(
        result.summary.sampled_count == 2u && result.summary.outside_projection_count == 2u
            && result.summary.invalid_coordinate_count == 1u,
        "per-status counts sum to the sample count");
}

// ---- The property the two-call design depends on --------------------------

struct SplitMix64 final {
    std::uint64_t state;

    std::uint64_t next() noexcept {
        state += 0x9E3779B97F4A7C15ULL;
        std::uint64_t value = state;
        value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9ULL;
        value = (value ^ (value >> 27)) * 0x94D049BB133111EBULL;
        return value ^ (value >> 31);
    }

    double unit() noexcept {
        return static_cast<double>(next() >> 11) / static_cast<double>(1ULL << 53);
    }
};

/// Seeded routes that stress the footprint: random walks, scattered points,
/// exact tile edges and corners, antimeridian crossings, the latitude limit,
/// and invalid or polar coordinates.
[[nodiscard]]
std::vector<DemRouteSample> property_route(SplitMix64& random, std::uint32_t zoom, std::uint32_t tile_size) {
    std::vector<DemRouteSample> route;
    const double world = static_cast<double>((std::uint64_t{1} << zoom) * tile_size);
    const double tiles = static_cast<double>(std::uint64_t{1} << zoom);
    const double limit = runplay::dem_web_mercator_max_latitude_degrees;

    // A walk that crosses the antimeridian eastward.
    double latitude = -60.0 + 120.0 * random.unit();
    double longitude = 179.0 + random.unit();
    for (int step = 0; step < 200; ++step) {
        latitude = std::clamp(latitude + (random.unit() - 0.5) * 0.4, -limit, limit);
        longitude += random.unit() * 0.02;
        if (longitude > 180.0) {
            longitude -= 360.0;
        }
        route.push_back(DemRouteSample{latitude, longitude});
    }
    // Scattered points anywhere on the projected globe.
    for (int index = 0; index < 200; ++index) {
        route.push_back(DemRouteSample{(random.unit() * 2.0 - 1.0) * limit, random.unit() * 360.0 - 180.0});
    }
    // Exact tile edges and corners along the equator (a tile-row edge when
    // the zoom is positive) and exact vertical tile edges at other latitudes.
    for (int index = 0; index < 64; ++index) {
        const double tile_edge_x = std::floor(random.unit() * tiles) * static_cast<double>(tile_size);
        route.push_back(DemRouteSample{0.0, longitude_at(tile_edge_x, world)});
        route.push_back(DemRouteSample{(random.unit() * 2.0 - 1.0) * 80.0, longitude_at(tile_edge_x, world)});
        route.push_back(DemRouteSample{0.0, longitude_at(tile_edge_x + 0.5, world)});
    }
    // The antimeridian itself, the latitude limit, and coordinates that need
    // no tile.
    route.push_back(DemRouteSample{0.0, 180.0});
    route.push_back(DemRouteSample{0.0, -180.0});
    route.push_back(DemRouteSample{limit, 180.0});
    route.push_back(DemRouteSample{-limit, -180.0});
    route.push_back(DemRouteSample{89.0, 0.0});
    route.push_back(DemRouteSample{quiet_nan, 0.0});
    route.push_back(DemRouteSample{0.0, 181.0});
    return route;
}

void test_sampler_reads_only_planned_tiles() {
    struct Grid final {
        std::uint32_t zoom;
        std::uint32_t tile_size;
    };
    // Tile size changes nothing about the footprint rule beyond being >= 2,
    // so fine zooms use small tiles: a globally scattered route plans hundreds
    // of tiles, and each minimality probe rebuilds every tile's heights.
    const std::array<Grid, 7> grids{
        {{0u, 2u}, {1u, 3u}, {2u, 4u}, {3u, 5u}, {5u, 8u}, {12u, 16u}, {runplay::dem_maximum_zoom, 2u}}};
    SplitMix64 random{0x5EEDu};

    for (const Grid& grid : grids) {
        for (int trial = 0; trial < 4; ++trial) {
            const std::vector<DemRouteSample> route = property_route(random, grid.zoom, grid.tile_size);
            const DemSamplingPolicy policy = make_policy(grid.zoom, grid.tile_size, 4'096u);
            const Plan planned = plan(route, policy);
            expect(planned.summary.status == DemSamplingStatus::success, "property route plans");

            // Deterministic finite heights in range; values are irrelevant to
            // which tiles are read.
            const auto height_at = [](std::int64_t column, std::int64_t row) -> float {
                return static_cast<float>(((column * 7919 + row * 104'729) % 4'001) - 500);
            };
            const TileSet planned_tiles = make_tiles(planned.tiles, grid.tile_size, height_at);
            const Sampled sampled = sample(route, planned_tiles, policy);

            // Every tile the sampler touches is in the planner's returned set:
            // with exactly the planned tiles present, no sample is missing one.
            expect(sampled.summary.status == DemSamplingStatus::success, "property route samples");
            expect(sampled.summary.missing_tile_count == 0u, "sampling never needs a tile the planner omitted");
            expect(
                sampled.summary.sampled_count == planned.summary.projectable_sample_count,
                "every projectable sample is sampled from the planned tiles");
            expect(
                sampled.summary.invalid_coordinate_count == planned.summary.invalid_coordinate_count
                    && sampled.summary.outside_projection_count == planned.summary.outside_projection_count,
                "planning and sampling classify coordinates identically");

            // The plan is also minimal: dropping any one planned tile leaves at
            // least one sample without it.
            const std::size_t probes = std::min<std::size_t>(planned.tiles.size(), 12u);
            for (std::size_t probe = 0; probe < probes; ++probe) {
                std::vector<DemTileKey> without = planned.tiles;
                without.erase(without.begin() + static_cast<std::ptrdiff_t>(probe));
                const Sampled reduced = sample(route, make_tiles(without, grid.tile_size, height_at), policy);
                expect(reduced.summary.missing_tile_count > 0u, "every planned tile is read by some sample");
            }

            // On grids small enough to hold whole, extra tiles change nothing:
            // the sampler reads no tile outside the plan.
            if (grid.zoom <= 3u) {
                const Sampled whole = sample(route, make_tiles(all_tiles(grid.zoom), grid.tile_size, height_at), policy);
                for (std::size_t index = 0; index < route.size(); ++index) {
                    expect(
                        whole.outputs[index].status == sampled.outputs[index].status
                            && std::bit_cast<std::uint64_t>(whole.outputs[index].elevation_meters)
                                == std::bit_cast<std::uint64_t>(sampled.outputs[index].elevation_meters),
                        "tiles outside the plan never influence a sample");
                }
            }
        }
    }
}

void test_sample_large_route() {
    std::vector<DemRouteSample> route;
    route.reserve(100'000u);
    SplitMix64 random{42u};
    double latitude = -33.9;
    double longitude = 151.1;
    for (std::size_t index = 0; index < 100'000u; ++index) {
        latitude += (random.unit() - 0.48) * 0.0003;
        longitude += (random.unit() - 0.45) * 0.0003;
        route.push_back(DemRouteSample{latitude, longitude});
    }
    const DemSamplingPolicy policy = make_policy(12u, 64u, 4'096u);
    const Plan planned = plan(route, policy);
    const auto height_at = [](std::int64_t column, std::int64_t row) -> float {
        return static_cast<float>(((column + 3 * row) % 900) + 10);
    };
    const TileSet tiles = make_tiles(planned.tiles, 64u, height_at);
    const Sampled first = sample(route, tiles, policy);
    const Sampled second = sample(route, tiles, policy);
    expect(first.summary.sampled_count == route.size(), "every point of a covered route is sampled");
    for (std::size_t index = 0; index < route.size(); ++index) {
        expect(
            std::bit_cast<std::uint64_t>(first.outputs[index].elevation_meters)
                == std::bit_cast<std::uint64_t>(second.outputs[index].elevation_meters),
            "sampling is deterministic");
        expect(
            first.outputs[index].elevation_meters >= 10.0 && first.outputs[index].elevation_meters <= 909.0,
            "a bilinear value stays inside its corner range");
    }
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
    test_sample_contract();
    test_sample_validation_failures_leave_output_untouched();
    test_sample_bilinear_exactness();
    test_sample_missing_tiles_fall_back_per_point();
    test_sample_implausible_heights();
    test_sample_antimeridian();
    test_sample_pole_guards();
    test_sampler_reads_only_planned_tiles();
    test_sample_large_route();
}
