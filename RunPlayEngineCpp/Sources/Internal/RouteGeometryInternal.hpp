#pragma once

// Internal pairwise route geometry helpers. Not part of the public engine
// boundary and must not be installed under include/.

#include "RunPlayEngineCpp/Geodesy.hpp"
#include "RunPlayEngineCpp/RouteInterop.hpp"

namespace runplay {
namespace internal {

/// One pairwise coordinate-derived step between two same-segment samples.
///
/// Invalid coordinates yield positive zero, matching Swift
/// `GeoDistance.distanceMeters`. Callers that need segment-boundary zeros must
/// apply that rule before invoking this helper.
[[nodiscard]]
inline double pairwise_coordinate_step_meters(
    const RouteInputSample& previous,
    const RouteInputSample& current
) noexcept {
    if (!is_valid_coordinate(previous.latitude, previous.longitude)
        || !is_valid_coordinate(current.latitude, current.longitude)) {
        return 0.0;
    }
    return haversine_distance_meters(
        previous.latitude,
        previous.longitude,
        current.latitude,
        current.longitude);
}

/// Distance between two samples without the invalid-coordinate zero repair.
///
/// Used by quality evidence that needs the same Haversine result Swift
/// obtains after stage-1 validation has already accepted coordinates.
[[nodiscard]]
inline double pairwise_haversine_meters(
    const RouteInputSample& first,
    const RouteInputSample& second
) noexcept {
    return haversine_distance_meters(
        first.latitude,
        first.longitude,
        second.latitude,
        second.longitude);
}

}  // namespace internal
}  // namespace runplay
