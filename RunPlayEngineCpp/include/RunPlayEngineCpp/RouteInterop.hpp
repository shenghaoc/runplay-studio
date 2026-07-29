#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <type_traits>

namespace runplay {

/// Internal safety ceiling for every batch crossing the route boundary.
///
/// This is not the product limit. RunPlay Studio's maximum supported workout
/// length is 1,000,000 route points, enforced in Swift by
/// `WorkoutImportResourceLimits.maxRoutePointCount` at every importer and by a
/// preflight in `RouteQualityProcessor`. This ceiling sits 25% above that so a
/// route the app accepts can never reach the engine boundary and be rejected
/// here; hitting `resource_limit` means a Swift-side limit failed to run, not
/// that the user's workout is too long.
///
/// Raising the product limit requires raising this value to preserve the
/// margin. `WorkoutImportResourceLimitsTests` asserts the relationship.
inline constexpr std::size_t max_route_input_samples = 1'250'000;

/// Concrete aliases keep supported `std::optional` specializations nameable
/// from Swift 6.3, where unspecialized C++ class templates are unavailable.
using RouteOptionalDouble = std::optional<double>;
using RouteOptionalSourceIndex = std::optional<std::uint64_t>;

/// One route sample copied from Swift into a contiguous, Swift-owned buffer.
///
/// `source_index` maps back to the original Swift array offset. Timestamps are
/// exact `Date.timeIntervalSinceReferenceDate` values with no rounding.
struct RouteInputSample final {
    std::uint64_t source_index;
    double timestamp_seconds_since_reference_date;
    double latitude;
    double longitude;
    RouteOptionalDouble altitude_meters;
    double distance_from_start_meters;
    double elapsed_seconds;
    RouteOptionalDouble speed_meters_per_second;
    RouteOptionalDouble pace_seconds_per_kilometer;
    RouteOptionalDouble heart_rate_bpm;
    RouteOptionalDouble cadence;
    RouteOptionalDouble horizontal_accuracy;
    std::int64_t route_segment_index;

    constexpr RouteInputSample(
        std::uint64_t source_index_value,
        double timestamp_seconds_since_reference_date_value,
        double latitude_value,
        double longitude_value,
        RouteOptionalDouble altitude_meters_value,
        double distance_from_start_meters_value,
        double elapsed_seconds_value,
        RouteOptionalDouble speed_meters_per_second_value,
        RouteOptionalDouble pace_seconds_per_kilometer_value,
        RouteOptionalDouble heart_rate_bpm_value,
        RouteOptionalDouble cadence_value,
        RouteOptionalDouble horizontal_accuracy_value,
        std::int64_t route_segment_index_value
    ) noexcept
        : source_index(source_index_value),
          timestamp_seconds_since_reference_date(
              timestamp_seconds_since_reference_date_value),
          latitude(latitude_value),
          longitude(longitude_value),
          altitude_meters(altitude_meters_value),
          distance_from_start_meters(distance_from_start_meters_value),
          elapsed_seconds(elapsed_seconds_value),
          speed_meters_per_second(speed_meters_per_second_value),
          pace_seconds_per_kilometer(pace_seconds_per_kilometer_value),
          heart_rate_bpm(heart_rate_bpm_value),
          cadence(cadence_value),
          horizontal_accuracy(horizontal_accuracy_value),
          route_segment_index(route_segment_index_value) {}
};

static_assert(std::is_standard_layout_v<RouteInputSample>);
static_assert(std::is_copy_constructible_v<RouteInputSample>);

enum class RouteInteropStatus : std::uint8_t {
    success,
    invalid_buffer,
    resource_limit,
};

/// Compact pure-value evidence returned after inspecting one complete route.
struct RouteBatchInspection final {
    RouteInteropStatus status;
    std::uint64_t sample_count;

    std::uint64_t altitude_value_count;
    std::uint64_t speed_value_count;
    std::uint64_t pace_value_count;
    std::uint64_t heart_rate_value_count;
    std::uint64_t cadence_value_count;
    std::uint64_t horizontal_accuracy_value_count;

    std::uint64_t segment_transition_count;
    RouteOptionalSourceIndex first_source_index;
    RouteOptionalSourceIndex last_source_index;

    std::uint64_t field_digest;
};

static_assert(std::is_standard_layout_v<RouteBatchInspection>);
static_assert(std::is_copy_constructible_v<RouteBatchInspection>);

/// Inspects a complete route through one synchronous borrowed-buffer call.
///
/// `samples` is borrowed only for this call and is never stored. A null pointer
/// is valid only when `sample_count` is zero.
[[nodiscard]]
RouteBatchInspection inspect_route_batch(
    const RouteInputSample* samples,
    std::size_t sample_count
) noexcept;

}  // namespace runplay
