#include "RunPlayEngineCpp/RouteGeometry.hpp"

#include "Internal/RouteGeometryInternal.hpp"

#include <cstddef>
#include <span>

namespace runplay {
namespace {

[[nodiscard]]
RouteStepDistanceSummary empty_summary(
    RouteStepDistanceStatus status
) noexcept {
    return RouteStepDistanceSummary{
        /*.status=*/status,
        /*.sample_count=*/0u,
        /*.segment_transition_count=*/0u,
        /*.invalid_coordinate_pair_count=*/0u,
        /*.total_distance_meters=*/0.0,
    };
}

}  // namespace

RouteStepDistanceSummary compute_route_step_distances(
    const RouteInputSample* samples,
    std::size_t sample_count,
    double* step_distances_meters,
    std::size_t step_distance_capacity
) noexcept {
    if (sample_count > max_route_input_samples) {
        return empty_summary(RouteStepDistanceStatus::resource_limit);
    }
    if (sample_count == 0u) {
        return empty_summary(RouteStepDistanceStatus::success);
    }
    if (samples == nullptr) {
        return empty_summary(RouteStepDistanceStatus::invalid_input_buffer);
    }
    if (step_distances_meters == nullptr) {
        return empty_summary(RouteStepDistanceStatus::invalid_output_buffer);
    }
    if (step_distance_capacity < sample_count) {
        return empty_summary(
            RouteStepDistanceStatus::insufficient_output_capacity);
    }

    const std::span<const RouteInputSample> route(samples, sample_count);
    const std::span<double> steps(step_distances_meters, sample_count);

    RouteStepDistanceSummary result =
        empty_summary(RouteStepDistanceStatus::success);
    result.sample_count = static_cast<std::uint64_t>(route.size());

    steps[0] = 0.0;
    // Left-to-right accumulation of every written step, including zeros and
    // any non-finite haversine results. Do not reorder, compensate, or skip.
    double total_distance_meters = steps[0];

    for (std::size_t index = 1u; index < route.size(); ++index) {
        const RouteInputSample& previous = route[index - 1u];
        const RouteInputSample& current = route[index];

        if (previous.route_segment_index != current.route_segment_index) {
            steps[index] = 0.0;
            ++result.segment_transition_count;
        } else if (
            !is_valid_coordinate(previous.latitude, previous.longitude)
            || !is_valid_coordinate(current.latitude, current.longitude)
        ) {
            steps[index] = 0.0;
            ++result.invalid_coordinate_pair_count;
        } else {
            steps[index] = internal::pairwise_coordinate_step_meters(
                previous,
                current);
        }

        total_distance_meters += steps[index];
    }

    result.total_distance_meters = total_distance_meters;
    return result;
}

}  // namespace runplay
