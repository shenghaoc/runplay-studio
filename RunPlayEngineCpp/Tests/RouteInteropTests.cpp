#include "RunPlayEngineCpp/RunPlayEngine.hpp"
#include "TestSupport.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <type_traits>
#include <vector>

static_assert(
    noexcept(runplay::inspect_route_batch(nullptr, 0u)),
    "inspect_route_batch must remain noexcept at the Swift boundary");
static_assert(std::is_standard_layout_v<runplay::RouteInputSample>);
static_assert(std::is_copy_constructible_v<runplay::RouteInputSample>);

namespace {

runplay::RouteInputSample make_sample(
    std::uint64_t source_index,
    std::int64_t segment_index
) {
    const double scalar = static_cast<double>(source_index);
    return runplay::RouteInputSample{
        source_index,
        1000.0 + scalar,
        1.0 + scalar,
        -2.0 - scalar,
        std::nullopt,
        10.0 * scalar,
        2.0 * scalar,
        std::nullopt,
        std::nullopt,
        std::nullopt,
        std::nullopt,
        std::nullopt,
        segment_index,
    };
}

void test_empty_batch() {
    const runplay::RouteBatchInspection result =
        runplay::inspect_route_batch(nullptr, 0u);
    expect(result.status == runplay::RouteInteropStatus::success, "empty status");
    expect(result.sample_count == 0u, "empty sample count");
    expect(result.altitude_value_count == 0u, "empty altitude count");
    expect(result.speed_value_count == 0u, "empty speed count");
    expect(result.pace_value_count == 0u, "empty pace count");
    expect(result.heart_rate_value_count == 0u, "empty heart-rate count");
    expect(result.cadence_value_count == 0u, "empty cadence count");
    expect(
        result.horizontal_accuracy_value_count == 0u,
        "empty horizontal-accuracy count");
    expect(result.segment_transition_count == 0u, "empty segment transitions");
    expect(!result.first_source_index.has_value(), "empty first index");
    expect(!result.last_source_index.has_value(), "empty last index");
    expect(
        result.field_digest == 14695981039346656037ULL,
        "empty digest must be the offset basis");
}

void test_invalid_and_bounded_inputs() {
    const runplay::RouteBatchInspection invalid =
        runplay::inspect_route_batch(nullptr, 1u);
    expect(
        invalid.status == runplay::RouteInteropStatus::invalid_buffer,
        "null non-empty buffer must be invalid");

    const runplay::RouteInputSample sample = make_sample(0u, 0);
    const runplay::RouteBatchInspection too_large =
        runplay::inspect_route_batch(
            &sample,
            runplay::max_route_input_samples + 1u);
    expect(
        too_large.status == runplay::RouteInteropStatus::resource_limit,
        "oversized count must be rejected before traversing the buffer");
}

void test_complete_sample_and_explicit_digest() {
    const runplay::RouteInputSample sample{
        7u,
        123.5,
        1.25,
        -2.5,
        std::optional<double>{30.0},
        100.0,
        20.0,
        std::optional<double>{5.0},
        std::optional<double>{200.0},
        std::optional<double>{150.0},
        std::optional<double>{180.0},
        std::optional<double>{3.0},
        -2,
    };

    const runplay::RouteBatchInspection result =
        runplay::inspect_route_batch(&sample, 1u);
    expect(result.status == runplay::RouteInteropStatus::success, "complete status");
    expect(result.sample_count == 1u, "complete sample count");
    expect(result.altitude_value_count == 1u, "complete altitude count");
    expect(result.speed_value_count == 1u, "complete speed count");
    expect(result.pace_value_count == 1u, "complete pace count");
    expect(result.heart_rate_value_count == 1u, "complete heart-rate count");
    expect(result.cadence_value_count == 1u, "complete cadence count");
    expect(
        result.horizontal_accuracy_value_count == 1u,
        "complete horizontal-accuracy count");
    expect(result.segment_transition_count == 0u, "complete segment transitions");
    expect(result.first_source_index == 7u, "complete first source index");
    expect(result.last_source_index == 7u, "complete last source index");
    expect(
        result.field_digest == 2357175563209802308ULL,
        "complete fixture digest must match the independent constant");
}

void test_absent_optionals_and_segment_transitions() {
    const std::array<runplay::RouteInputSample, 6> samples{
        make_sample(0u, 0),
        make_sample(1u, 0),
        make_sample(2u, 1),
        make_sample(3u, 1),
        make_sample(4u, 1),
        make_sample(5u, 2),
    };

    const runplay::RouteBatchInspection first =
        runplay::inspect_route_batch(samples.data(), samples.size());
    const runplay::RouteBatchInspection second =
        runplay::inspect_route_batch(samples.data(), samples.size());
    expect(first.status == runplay::RouteInteropStatus::success, "segmented status");
    expect(first.sample_count == samples.size(), "segmented sample count");
    expect(first.altitude_value_count == 0u, "absent altitude count");
    expect(first.speed_value_count == 0u, "absent speed count");
    expect(first.pace_value_count == 0u, "absent pace count");
    expect(first.heart_rate_value_count == 0u, "absent heart-rate count");
    expect(first.cadence_value_count == 0u, "absent cadence count");
    expect(
        first.horizontal_accuracy_value_count == 0u,
        "absent horizontal-accuracy count");
    expect(first.segment_transition_count == 2u, "segment transition count");
    expect(first.first_source_index == 0u, "segmented first source index");
    expect(first.last_source_index == 5u, "segmented last source index");
    expect(first.field_digest == second.field_digest, "digest must be repeatable");
}

void test_large_heap_backed_batch() {
    constexpr std::size_t sample_count = 100'000u;
    std::vector<runplay::RouteInputSample> samples;
    samples.reserve(sample_count);
    for (std::size_t index = 0u; index < sample_count; ++index) {
        samples.push_back(make_sample(
            static_cast<std::uint64_t>(index),
            static_cast<std::int64_t>(index / 25'000u)));
    }

    const runplay::RouteBatchInspection result =
        runplay::inspect_route_batch(samples.data(), samples.size());
    expect(result.status == runplay::RouteInteropStatus::success, "large status");
    expect(result.sample_count == sample_count, "large sample count");
    expect(result.segment_transition_count == 3u, "large segment transitions");
    expect(result.first_source_index == 0u, "large first source index");
    expect(
        result.last_source_index == sample_count - 1u,
        "large last source index");
}

}  // namespace

void run_route_interop_tests() {
    test_empty_batch();
    test_invalid_and_bounded_inputs();
    test_complete_sample_and_explicit_digest();
    test_absent_optionals_and_segment_transitions();
    test_large_heap_backed_batch();
}
