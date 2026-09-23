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
    /// Sampling only: the tile directory breaks its contract (order, key
    /// range, count, or the height buffer's size).
    invalid_tile_directory,
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

// ---------------------------------------------------------------------------
// Tile heights — decoded by Swift (caller-owned)
// ---------------------------------------------------------------------------

/// One decoded pixel height in metres. For the tile at directory position k
/// the heights occupy [k * tile_size^2, (k + 1) * tile_size^2), row-major
/// from the tile's north-west pixel. Single precision is exact for Terrarium
/// data: every Terrarium height is a multiple of 1/256 m within +-32,768 m.
/// Non-finite values are allowed and read as unusable heights.
struct DemTileHeightSample final {
    float height_meters{0};
};

static_assert(std::is_standard_layout_v<DemTileHeightSample>);
static_assert(std::is_trivially_copyable_v<DemTileHeightSample>);
static_assert(std::is_nothrow_default_constructible_v<DemTileHeightSample>);
static_assert(std::is_nothrow_copy_constructible_v<DemTileHeightSample>);
static_assert(std::is_nothrow_copy_assignable_v<DemTileHeightSample>);

// ---------------------------------------------------------------------------
// Sampling output — one entry per input coordinate
// ---------------------------------------------------------------------------

/// Why a coordinate has, or lacks, a DEM elevation. When several reasons
/// apply, the first in this order is reported.
enum class DemSampleStatus : std::uint8_t {
    /// Every non-zero-weight corner was present and plausible.
    sampled,
    invalid_coordinate,
    outside_projection,
    /// A tile holding a non-zero-weight corner is not in the directory.
    missing_tile,
    /// A non-zero-weight corner height is non-finite or outside the policy's
    /// plausible range.
    implausible_height,
};

/// `has_elevation` is 1 exactly when `status` is `sampled`; otherwise
/// `elevation_meters` is 0 and carries no meaning.
struct DemElevationOutputSample final {
    double elevation_meters{0};
    DemSampleStatus status{DemSampleStatus::invalid_coordinate};
    std::uint8_t has_elevation{0};
};

static_assert(std::is_standard_layout_v<DemElevationOutputSample>);
static_assert(std::is_trivially_copyable_v<DemElevationOutputSample>);
static_assert(std::is_nothrow_default_constructible_v<DemElevationOutputSample>);
static_assert(std::is_nothrow_copy_constructible_v<DemElevationOutputSample>);
static_assert(std::is_nothrow_copy_assignable_v<DemElevationOutputSample>);

/// Counts from one sampling pass. On success the five per-status counts sum
/// to `sample_count`. On failure every count is zero except
/// `required_output_capacity`, which is always `sample_count`.
struct DemSamplingSummary final {
    DemSamplingStatus status{DemSamplingStatus::success};

    std::uint64_t sample_count{0};
    std::uint64_t sampled_count{0};
    std::uint64_t invalid_coordinate_count{0};
    std::uint64_t outside_projection_count{0};
    std::uint64_t missing_tile_count{0};
    std::uint64_t implausible_height_count{0};

    std::uint64_t required_output_capacity{0};
};

static_assert(std::is_standard_layout_v<DemSamplingSummary>);
static_assert(std::is_trivially_copyable_v<DemSamplingSummary>);
static_assert(std::is_nothrow_default_constructible_v<DemSamplingSummary>);
static_assert(std::is_nothrow_copy_constructible_v<DemSamplingSummary>);
static_assert(std::is_nothrow_copy_assignable_v<DemSamplingSummary>);

// ---------------------------------------------------------------------------
// Bilinear sampling
// ---------------------------------------------------------------------------

/// Bilinearly samples Swift-decoded tile heights at every route coordinate.
///
/// samples          Swift-owned, immutable, borrowed synchronously
/// tiles            Swift-owned, immutable: the tiles present, strictly
///                  ascending by (y, x), keys inside the zoom's grid, at most
///                  `maximum_tile_count` of them
/// tile_heights     Swift-owned, immutable: exactly
///                  `tile_count * tile_size^2` heights in directory order
/// output_samples   Swift-owned, mutable, borrowed synchronously
///
/// A tile absent from the directory is missing: each coordinate falls back on
/// its own, and a missing tile is never an error. Bilinear interpolation runs
/// between pixel centres and reads only corners with non-zero weight, using
/// the same footprint rule as `plan_dem_tiles`, so directory tiles beyond the
/// plan are never needed. On success exactly `sample_count` entries are
/// written. Every contract check runs before the first output write, so on any
/// failure status the output buffer is left completely unchanged. C++ retains
/// no pointer, performs no callback, and allocates nothing.
///
/// Empty input allows null sample and output buffers.
[[nodiscard]]
DemSamplingSummary sample_dem_elevations(
    const DemRouteSample* samples,
    std::size_t sample_count,
    DemSamplingPolicy policy,
    const DemTileKey* tiles,
    std::size_t tile_count,
    const DemTileHeightSample* tile_heights,
    std::size_t tile_height_count,
    DemElevationOutputSample* output_samples,
    std::size_t output_capacity
) noexcept;

}  // namespace runplay
