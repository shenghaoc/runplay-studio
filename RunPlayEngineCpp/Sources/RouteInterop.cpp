#include "RunPlayEngineCpp/RouteInterop.hpp"

#include <bit>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>

namespace runplay {
namespace {

static_assert(sizeof(double) == sizeof(std::uint64_t));
static_assert(std::numeric_limits<double>::is_iec559);

constexpr std::uint64_t digest_offset = 14695981039346656037ULL;
constexpr std::uint64_t digest_prime = 1099511628211ULL;

void mix_word(std::uint64_t& state, std::uint64_t word) noexcept {
    state = (state ^ word) * digest_prime;
}

void mix_optional_double(
    std::uint64_t& state,
    const std::optional<double>& value,
    std::uint64_t& value_count
) noexcept {
    mix_word(state, value.has_value() ? 1u : 0u);
    if (value.has_value()) {
        ++value_count;
        mix_word(state, std::bit_cast<std::uint64_t>(*value));
    }
}

RouteBatchInspection empty_inspection(RouteInteropStatus status) noexcept {
    return RouteBatchInspection{
        /*.status=*/status,
        /*.sample_count=*/0u,
        /*.altitude_value_count=*/0u,
        /*.speed_value_count=*/0u,
        /*.pace_value_count=*/0u,
        /*.heart_rate_value_count=*/0u,
        /*.cadence_value_count=*/0u,
        /*.horizontal_accuracy_value_count=*/0u,
        /*.segment_transition_count=*/0u,
        /*.first_source_index=*/std::nullopt,
        /*.last_source_index=*/std::nullopt,
        /*.field_digest=*/digest_offset,
    };
}

}  // namespace

RouteBatchInspection inspect_route_batch(
    const RouteInputSample* samples,
    std::size_t sample_count
) noexcept {
    if (samples == nullptr && sample_count != 0u) {
        return empty_inspection(RouteInteropStatus::invalid_buffer);
    }
    if (sample_count > max_route_input_samples) {
        return empty_inspection(RouteInteropStatus::resource_limit);
    }
    if (sample_count == 0u) {
        return empty_inspection(RouteInteropStatus::success);
    }

    const std::span<const RouteInputSample> route(samples, sample_count);
    RouteBatchInspection result = empty_inspection(RouteInteropStatus::success);
    result.sample_count = static_cast<std::uint64_t>(route.size());
    result.first_source_index = route.front().source_index;
    result.last_source_index = route.back().source_index;

    for (std::size_t index = 0u; index < route.size(); ++index) {
        const RouteInputSample& sample = route[index];
        if (index > 0u
            && sample.route_segment_index != route[index - 1u].route_segment_index) {
            ++result.segment_transition_count;
        }

        mix_word(result.field_digest, sample.source_index);
        mix_word(
            result.field_digest,
            std::bit_cast<std::uint64_t>(
                sample.timestamp_seconds_since_reference_date));
        mix_word(result.field_digest, std::bit_cast<std::uint64_t>(sample.latitude));
        mix_word(result.field_digest, std::bit_cast<std::uint64_t>(sample.longitude));
        mix_optional_double(
            result.field_digest,
            sample.altitude_meters,
            result.altitude_value_count);
        mix_word(
            result.field_digest,
            std::bit_cast<std::uint64_t>(sample.distance_from_start_meters));
        mix_word(
            result.field_digest,
            std::bit_cast<std::uint64_t>(sample.elapsed_seconds));
        mix_optional_double(
            result.field_digest,
            sample.speed_meters_per_second,
            result.speed_value_count);
        mix_optional_double(
            result.field_digest,
            sample.pace_seconds_per_kilometer,
            result.pace_value_count);
        mix_optional_double(
            result.field_digest,
            sample.heart_rate_bpm,
            result.heart_rate_value_count);
        mix_optional_double(
            result.field_digest,
            sample.cadence,
            result.cadence_value_count);
        mix_optional_double(
            result.field_digest,
            sample.horizontal_accuracy,
            result.horizontal_accuracy_value_count);
        mix_word(
            result.field_digest,
            std::bit_cast<std::uint64_t>(sample.route_segment_index));
    }

    return result;
}

}  // namespace runplay
