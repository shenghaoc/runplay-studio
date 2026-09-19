#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace runplay {

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

inline constexpr std::size_t segment_detection_max_candidate_count = 10;

// Number of independent pace-window searches per invocation: the fastest 400 m
// search, the combined 1 km search, and the five personal-record windows.
// Exposed so Swift can validate the summed pace evaluation budget exactly.
inline constexpr std::size_t segment_pace_search_count = 7;

// Canonical personal-record window lengths. Swift passes these same constants
// so both sides share one source of truth for record identity.
inline constexpr double personal_record_one_mile_meters = 1'609.344;
inline constexpr double personal_record_five_km_meters = 5'000.0;
inline constexpr double personal_record_ten_km_meters = 10'000.0;
inline constexpr double personal_record_half_marathon_meters = 21'097.5;
inline constexpr double personal_record_marathon_meters = 42'195.0;

// ---------------------------------------------------------------------------
// Input sample — one-to-one with route points
// ---------------------------------------------------------------------------

struct SegmentDetectionSample final {
    double distance_meters{0};
    double elapsed_seconds{0};
    double active_seconds{0};

    double cumulative_ascent_meters{0};
    double cumulative_descent_meters{0};
    double reliable_interval_count{0};

    std::int32_t continuity_group{0};
    std::int32_t reliable_elevation_run{-1};
};

static_assert(std::is_standard_layout_v<SegmentDetectionSample>);
static_assert(std::is_trivially_copyable_v<SegmentDetectionSample>);
static_assert(std::is_nothrow_default_constructible_v<SegmentDetectionSample>);
static_assert(std::is_nothrow_copy_constructible_v<SegmentDetectionSample>);

// ---------------------------------------------------------------------------
// Search configuration — all values computed by Swift
// ---------------------------------------------------------------------------

struct SegmentDetectionConfiguration final {
    double fastest_400m_distance_meters{400};
    double fastest_400m_step_meters{50};

    double one_kilometer_distance_meters{1'000};
    double one_kilometer_step_meters{50};

    double one_mile_distance_meters{personal_record_one_mile_meters};
    double one_mile_step_meters{50};

    double five_kilometer_distance_meters{personal_record_five_km_meters};
    double five_kilometer_step_meters{50};

    double ten_kilometer_distance_meters{personal_record_ten_km_meters};
    double ten_kilometer_step_meters{50};

    double half_marathon_distance_meters{personal_record_half_marathon_meters};
    double half_marathon_step_meters{50};

    double marathon_distance_meters{personal_record_marathon_meters};
    double marathon_step_meters{50};

    double minimum_valid_pace_seconds_per_kilometer{120};
    double maximum_valid_pace_seconds_per_kilometer{1'200};

    double elevation_window_distance_meters{0};
    double elevation_step_meters{0};

    std::uint64_t maximum_evaluations_per_search{0};
    std::uint8_t elevation_enabled{0};
};

static_assert(std::is_standard_layout_v<SegmentDetectionConfiguration>);
static_assert(std::is_trivially_copyable_v<SegmentDetectionConfiguration>);
static_assert(std::is_nothrow_default_constructible_v<SegmentDetectionConfiguration>);
static_assert(std::is_nothrow_copy_constructible_v<SegmentDetectionConfiguration>);

// ---------------------------------------------------------------------------
// Candidate kind
// ---------------------------------------------------------------------------

enum class SegmentWindowKind : std::uint8_t {
    fastest_400m = 0,
    fastest_1km = 1,
    slowest_1km = 2,
    biggest_climb = 3,
    biggest_descent = 4,
    fastest_one_mile = 5,
    fastest_5km = 6,
    fastest_10km = 7,
    fastest_half_marathon = 8,
    fastest_marathon = 9,
};

// ---------------------------------------------------------------------------
// Candidate output
// ---------------------------------------------------------------------------

struct SegmentWindowCandidate final {
    SegmentWindowKind kind{
        SegmentWindowKind::fastest_400m
    };

    double start_distance_meters{0};
    double end_distance_meters{0};

    double selection_value{0};
};

static_assert(std::is_standard_layout_v<SegmentWindowCandidate>);
static_assert(std::is_trivially_copyable_v<SegmentWindowCandidate>);
static_assert(std::is_nothrow_default_constructible_v<SegmentWindowCandidate>);
static_assert(std::is_nothrow_copy_constructible_v<SegmentWindowCandidate>);

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

enum class SegmentDetectionStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_output_buffer,
    insufficient_output_capacity,
    invalid_configuration,
    invalid_input_contract,
    resource_limit,
    internal_failure,
};

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

struct SegmentDetectionSummary final {
    SegmentDetectionStatus status{
        SegmentDetectionStatus::success
    };

    std::uint64_t sample_count{0};
    std::uint64_t candidate_count{0};

    std::uint64_t pace_window_evaluation_count{0};
    std::uint64_t elevation_window_evaluation_count{0};

    std::uint64_t required_output_capacity{0};
};

static_assert(std::is_standard_layout_v<SegmentDetectionSummary>);
static_assert(std::is_trivially_copyable_v<SegmentDetectionSummary>);
static_assert(std::is_nothrow_copy_constructible_v<SegmentDetectionSummary>);

// ---------------------------------------------------------------------------
// Bulk function
// ---------------------------------------------------------------------------

/// Bulk window search for the ten bounded segment-detection highlights.
///
/// The five original segment kinds (fastest 400 m, fastest/slowest 1 km,
/// biggest climb/descent) are joined by five fixed-distance personal-record
/// windows (fastest 1 mile, 5 km, 10 km, half marathon, marathon). Every pace
/// search is a distance-stepped sweep whose evaluation count is bounded by the
/// spare distance beyond the window, not by the window length, and each search
/// is independently capped by maximum_evaluations_per_search. A window longer
/// than the route is simply not attempted: it is omitted from the output, never
/// returned as a zero-valued candidate.
///
/// samples          Swift-owned, immutable, borrowed synchronously
/// output_candidates Swift-owned, mutable, borrowed synchronously
///
/// C++ retains no pointer, performs no callback, and allocates no
/// route-sized storage. On any non-success status the output buffer is
/// left byte-for-byte unchanged and candidate_count is zero.
[[nodiscard]]
SegmentDetectionSummary detect_segment_windows(
    const SegmentDetectionSample* samples,
    std::size_t sample_count,
    SegmentDetectionConfiguration configuration,
    SegmentWindowCandidate* output_candidates,
    std::size_t output_capacity
) noexcept;

}  // namespace runplay
