#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace runplay {

// ---------------------------------------------------------------------------
// Tile grid
// ---------------------------------------------------------------------------
//
// DEM tiles form the XYZ ("slippy map") Web Mercator grid used by z/x/y tile
// folders: at zoom `z` the world is 2^z × 2^z square tiles of `tile_size`
// pixels, x grows eastward from the antimeridian and y grows southward from the
// north edge (not TMS). Pixels are areas; the elevation of pixel (i, j) is the
// terrain height at the pixel centre, so bilinear interpolation runs between
// pixel centres and a point within half a pixel of a tile edge needs the
// neighbouring tile. Columns wrap across the antimeridian; rows clamp at the
// Web Mercator latitude limit and never wrap across a pole.
//
// C++ performs no file I/O and no image decoding. Swift decodes tiles, then
// passes coordinates and decoded heights through Swift-owned buffers.

/// Largest supported zoom. At zoom 24 with 4,096-pixel tiles the global pixel
/// grid is 2^36 pixels wide, well inside the 2^53 range in which a double holds
/// every integer exactly, so pixel coordinates stay exact.
inline constexpr std::uint32_t dem_maximum_zoom = 24;

inline constexpr std::uint32_t dem_minimum_tile_size = 2;
inline constexpr std::uint32_t dem_maximum_tile_size = 4'096;

/// Engine ceiling on distinct tiles in one pass. It bounds the planner's
/// internal tile set; Swift budgets far lower, by decoded bytes.
inline constexpr std::uint64_t dem_maximum_tile_count = 65'536;

/// Web Mercator latitude limit, atan(sinh(pi)) in degrees. A coordinate beyond
/// it has no tile.
inline constexpr double dem_web_mercator_max_latitude_degrees = 85.0511287798066;

// ---------------------------------------------------------------------------
// Input sample — one per route point (caller-owned)
// ---------------------------------------------------------------------------

/// One route coordinate in source order. A coordinate is valid when both
/// values are finite, latitude is within ±90 and longitude within ±180
/// (inclusive); ±180 name the same meridian.
struct DemRouteSample final {
    double latitude_degrees{0};
    double longitude_degrees{0};
};

static_assert(std::is_standard_layout_v<DemRouteSample>);
static_assert(std::is_trivially_copyable_v<DemRouteSample>);
static_assert(std::is_nothrow_default_constructible_v<DemRouteSample>);
static_assert(std::is_nothrow_copy_constructible_v<DemRouteSample>);
static_assert(std::is_nothrow_copy_assignable_v<DemRouteSample>);

// ---------------------------------------------------------------------------
// Tile key — planner output and sampler tile directory entry
// ---------------------------------------------------------------------------

/// One tile address at the policy zoom: 0 <= x, y < 2^zoom. Every tile list
/// crossing the boundary is strictly ascending by (y, x): north to south, then
/// west to east.
struct DemTileKey final {
    std::uint32_t x{0};
    std::uint32_t y{0};
};

static_assert(std::is_standard_layout_v<DemTileKey>);
static_assert(std::is_trivially_copyable_v<DemTileKey>);
static_assert(std::is_nothrow_default_constructible_v<DemTileKey>);
static_assert(std::is_nothrow_copy_constructible_v<DemTileKey>);
static_assert(std::is_nothrow_copy_assignable_v<DemTileKey>);

// ---------------------------------------------------------------------------
// Policy — shared by planning and sampling so both use one grid
// ---------------------------------------------------------------------------

/// `zoom` <= `dem_maximum_zoom`; `tile_size` within
/// [`dem_minimum_tile_size`, `dem_maximum_tile_size`];
/// `maximum_tile_count` within [1, `dem_maximum_tile_count`]; the plausible
/// elevation bounds are finite with minimum < maximum. Every call validates
/// the whole policy, including fields it does not use.
struct DemSamplingPolicy final {
    std::uint32_t zoom{0};
    std::uint32_t tile_size{0};
    std::uint64_t maximum_tile_count{0};

    double minimum_plausible_elevation_meters{0};
    double maximum_plausible_elevation_meters{0};
};

static_assert(std::is_standard_layout_v<DemSamplingPolicy>);
static_assert(std::is_trivially_copyable_v<DemSamplingPolicy>);
static_assert(std::is_nothrow_default_constructible_v<DemSamplingPolicy>);
static_assert(std::is_nothrow_copy_constructible_v<DemSamplingPolicy>);
static_assert(std::is_nothrow_copy_assignable_v<DemSamplingPolicy>);

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

enum class DemSamplingStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_output_buffer,
    insufficient_output_capacity,
    invalid_policy,
    /// Planning only: the route needs more than `maximum_tile_count` tiles.
    tile_budget_exceeded,
    resource_limit,
    allocation_failure,
    internal_failure,
};

// ---------------------------------------------------------------------------
// Tile planning
// ---------------------------------------------------------------------------

/// Counts from one planning pass.
///
/// - `success`: every count is exact and `written_tile_count ==
///   required_tile_count`.
/// - `insufficient_output_capacity`: the whole route was planned, so every
///   count is exact, but `written_tile_count` is zero.
/// - `tile_budget_exceeded`: planning stops at the first tile beyond the
///   budget. `sample_count` is exact, `required_tile_count` is
///   `maximum_tile_count + 1` (a lower bound), and every other count is zero.
/// - Any other failure: every count is zero.
struct DemTilePlanSummary final {
    DemSamplingStatus status{DemSamplingStatus::success};

    std::uint64_t sample_count{0};
    std::uint64_t projectable_sample_count{0};
    std::uint64_t invalid_coordinate_count{0};
    std::uint64_t outside_projection_count{0};

    std::uint64_t required_tile_count{0};
    std::uint64_t written_tile_count{0};
};

static_assert(std::is_standard_layout_v<DemTilePlanSummary>);
static_assert(std::is_trivially_copyable_v<DemTilePlanSummary>);
static_assert(std::is_nothrow_default_constructible_v<DemTilePlanSummary>);
static_assert(std::is_nothrow_copy_constructible_v<DemTilePlanSummary>);
static_assert(std::is_nothrow_copy_assignable_v<DemTilePlanSummary>);

/// Lists every tile whose pixels a bilinear sample of the route will read.
///
/// samples        Swift-owned, immutable, borrowed synchronously
/// output_tiles   Swift-owned, mutable, borrowed synchronously
///
/// The listed tiles are exactly those holding a bilinear corner with non-zero
/// weight for some projectable sample, so decoding them is sufficient for
/// sampling: planning and sampling share one footprint rule. Invalid
/// coordinates and coordinates beyond the Web Mercator limit need no tile.
/// On success `written_tile_count == required_tile_count` keys are written,
/// strictly ascending by (y, x). On any other status the output buffer is left
/// completely unchanged. C++ retains no pointer and performs no callback;
/// internal storage is bounded by `maximum_tile_count`, never by route length.
///
/// Empty input allows null buffers and returns success with no tiles.
[[nodiscard]]
DemTilePlanSummary plan_dem_tiles(
    const DemRouteSample* samples,
    std::size_t sample_count,
    DemSamplingPolicy policy,
    DemTileKey* output_tiles,
    std::size_t output_capacity
) noexcept;

}  // namespace runplay
