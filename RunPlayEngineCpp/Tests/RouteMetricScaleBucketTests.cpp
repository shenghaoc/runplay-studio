#include "TestSupport.hpp"

#include "RunPlayEngineCpp/RouteInterop.hpp"
#include "RunPlayEngineCpp/RouteMetricScaleBuckets.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <type_traits>
#include <vector>

namespace {
using namespace runplay;

static_assert(__cplusplus >= 202302L);
static_assert(std::is_standard_layout_v<RouteMetricScaleBucketInputSample>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketInputSample>);
static_assert(std::is_standard_layout_v<RouteMetricScaleBucketPolicy>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketPolicy>);
static_assert(std::is_standard_layout_v<RouteMetricScaleBucketOutputSample>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketOutputSample>);
static_assert(std::is_standard_layout_v<RouteMetricScaleBucketSummary>);
static_assert(std::is_trivially_copyable_v<RouteMetricScaleBucketSummary>);
static_assert(noexcept(assign_route_metric_scale_buckets(nullptr, 0U, {}, nullptr, 0U)));

RouteMetricScaleBucketPolicy policy(
    double lower = 0.0,
    double upper = 1.0,
    double span = 0.0,
    std::uint64_t minimum = 1U,
    std::int32_t buckets = 7
) {
    RouteMetricScaleBucketPolicy value{};
    value.lower_quantile = lower;
    value.upper_quantile = upper;
    value.minimum_scale_span = span;
    value.minimum_valid_interval_count = minimum;
    value.bucket_count = buckets;
    return value;
}

RouteMetricScaleBucketInputSample sample(
    double metric,
    double weight,
    std::uint8_t present = 1U
) {
    RouteMetricScaleBucketInputSample value{};
    value.metric_value = metric;
    value.weight_meters = weight;
    value.has_metric_value = present;
    return value;
}

template <std::size_t Count>
RouteMetricScaleBucketSummary assign(
    const std::array<RouteMetricScaleBucketInputSample, Count>& input,
    std::array<RouteMetricScaleBucketOutputSample, Count>& output,
    RouteMetricScaleBucketPolicy requested = policy()
) {
    return assign_route_metric_scale_buckets(
        input.data(), input.size(), requested, output.data(), output.size()
    );
}

void expect_unchanged(
    const RouteMetricScaleBucketOutputSample& before,
    const RouteMetricScaleBucketOutputSample& after,
    const char* message
) {
    expect(std::memcmp(&before, &after, sizeof(before)) == 0, message);
}

void test_boundaries_and_no_write() {
    const auto empty = assign_route_metric_scale_buckets(nullptr, 0U, {}, nullptr, 0U);
    expect(empty.status == RouteMetricScaleBucketStatus::success, "empty buffers succeed");
    expect(empty.required_output_capacity == 0U, "empty capacity is zero");

    const std::array input{sample(1.0, 1.0)};
    RouteMetricScaleBucketOutputSample sentinel{};
    std::memset(&sentinel, 0x5A, sizeof(sentinel));
    auto output = sentinel;
    auto summary = assign_route_metric_scale_buckets(nullptr, 1U, policy(), &output, 1U);
    expect(summary.status == RouteMetricScaleBucketStatus::invalid_input_buffer, "null input rejected");
    expect_unchanged(sentinel, output, "null input writes nothing");

    summary = assign_route_metric_scale_buckets(input.data(), 1U, policy(), nullptr, 1U);
    expect(summary.status == RouteMetricScaleBucketStatus::invalid_output_buffer, "null output rejected");

    summary = assign_route_metric_scale_buckets(input.data(), 1U, policy(), &output, 0U);
    expect(summary.status == RouteMetricScaleBucketStatus::insufficient_output_capacity, "capacity rejected");
    expect(summary.required_output_capacity == 1U, "exact capacity reported");
    expect_unchanged(sentinel, output, "capacity failure writes nothing");

    const std::array malformed{sample(1.0, 1.0, 2U)};
    summary = assign_route_metric_scale_buckets(malformed.data(), 1U, policy(), &output, 1U);
    expect(summary.status == RouteMetricScaleBucketStatus::invalid_input_contract, "presence byte rejected");
    expect_unchanged(sentinel, output, "presence failure writes nothing");

    const std::array negative{sample(1.0, -1.0)};
    summary = assign_route_metric_scale_buckets(negative.data(), 1U, policy(), &output, 1U);
    expect(summary.status == RouteMetricScaleBucketStatus::invalid_input_contract, "negative weight rejected");
    expect_unchanged(sentinel, output, "negative weight writes nothing");

    const std::array nonfinite{sample(1.0, std::numeric_limits<double>::infinity())};
    summary = assign_route_metric_scale_buckets(nonfinite.data(), 1U, policy(), &output, 1U);
    expect(summary.status == RouteMetricScaleBucketStatus::invalid_input_contract, "nonfinite weight rejected");
    expect_unchanged(sentinel, output, "nonfinite weight writes nothing");

    summary = assign_route_metric_scale_buckets(
        input.data(), max_route_input_samples + 1U, policy(), &output,
        max_route_input_samples + 1U
    );
    expect(summary.status == RouteMetricScaleBucketStatus::resource_limit, "engine ceiling enforced");
    expect_unchanged(sentinel, output, "resource failure writes nothing");
}

void test_quantiles_scale_and_weights() {
    const std::array input{
        sample(3.0, 1.0), sample(1.0, 1.0), sample(2.0, 2.0),
        sample(2.0, 1.0), sample(99.0, 0.0), sample(0.0, 3.0, 0U)
    };
    std::array<RouteMetricScaleBucketOutputSample, input.size()> output{};
    auto summary = assign(input, output, policy(0.0, 1.0));
    expect(summary.status == RouteMetricScaleBucketStatus::success, "weighted fixture succeeds");
    expect(summary.has_scale == 1U, "weighted fixture has scale");
    expect(summary.lower_bound == 1.0, "quantile zero");
    expect(summary.median == 2.0, "weighted median");
    expect(summary.upper_bound == 3.0, "quantile one");
    expect(summary.valid_interval_count == 4U, "valid weighted count");
    expect(summary.valid_coverage_distance_meters == 5.0, "valid coverage");
    for (std::size_t index = 0; index < output.size(); ++index) {
        expect(output[index].source_index == index, "source order restored");
    }

    summary = assign(input, output, policy(-10.0, 10.0));
    expect(summary.lower_bound == 1.0 && summary.upper_bound == 3.0, "finite quantiles clamp");
    summary = assign(input, output, policy(std::numeric_limits<double>::quiet_NaN(), 1.0));
    expect(summary.has_scale == 0U, "nan quantile means no scale");
    summary = assign(input, output, policy(0.0, std::numeric_limits<double>::infinity()));
    expect(summary.has_scale == 0U, "infinite quantile means no scale");

    const double huge = std::numeric_limits<double>::max();
    const std::array huge_input{sample(1.0, huge), sample(2.0, huge), sample(3.0, huge)};
    std::array<RouteMetricScaleBucketOutputSample, huge_input.size()> huge_output{};
    summary = assign(huge_input, huge_output);
    expect(summary.has_scale == 1U, "scaled huge weights have scale");
    expect(summary.median == 2.0, "scaled huge weights keep median");

    const std::array duplicate_input{
        sample(5.0, 3.0), sample(5.0, 1.0), sample(5.0, 2.0)
    };
    std::array<RouteMetricScaleBucketOutputSample, duplicate_input.size()> duplicate_output{};
    summary = assign(duplicate_input, duplicate_output);
    expect(summary.lower_bound == 5.0 && summary.median == 5.0 && summary.upper_bound == 5.0,
           "equal values retain scale");
}

void test_scale_normalization_and_buckets() {
    const std::array input{
        sample(-10.0, 1.0), sample(0.0, 1.0), sample(5.0, 1.0),
        sample(10.0, 1.0), sample(20.0, 1.0),
        sample(std::numeric_limits<double>::quiet_NaN(), 0.0),
        sample(0.0, 0.0, 0U)
    };
    std::array<RouteMetricScaleBucketOutputSample, input.size()> output{};
    auto summary = assign(input, output, policy(0.2, 0.8, 0.0, 1U, 7));
    expect(summary.has_scale == 1U, "normalization fixture has scale");
    expect(summary.lower_bound == -10.0 && summary.upper_bound == 10.0, "scale bounds exact");
    expect(output[0].normalized_value == 0.0 && output[0].bucket_index == 0, "normalized zero");
    expect(output[2].normalized_value == 0.75 && output[2].bucket_index == 5, "middle bucket");
    expect(output[3].normalized_value == 1.0 && output[3].bucket_index == 6, "normalized one");
    expect(output[4].normalized_value == 1.0 && output[4].bucket_index == 6, "above scale clamps");
    expect(output[5].normalized_value == 0.5 && output[5].bucket_index == 3, "present nan normalizes to midpoint");
    expect(output[6].has_normalized_value == 0U && output[6].bucket_index == -1, "missing remains no data");
    expect(summary.no_data_interval_count == 1U, "no-data counts bucket state");

    summary = assign(input, output, policy(0.2, 0.8, 21.0));
    expect(summary.has_scale == 0U && summary.no_data_interval_count == input.size(), "span gate no scale");
    for (const auto& item : output) {
        expect(item.has_normalized_value == 0U && item.bucket_index == -1, "no scale clears all buckets");
    }

    summary = assign(input, output, policy(0.2, 0.8, std::numeric_limits<double>::quiet_NaN()));
    expect(summary.has_scale == 1U, "nan minimum span follows Swift max semantics");
    summary = assign(input, output, policy(0.2, 0.8, std::numeric_limits<double>::infinity()));
    expect(summary.has_scale == 0U, "positive infinite span means no scale");
    summary = assign(input, output, policy(0.2, 0.8, 0.0, 99U));
    expect(summary.has_scale == 0U, "minimum count gate");

    const std::array equal{sample(4.0, 1.0), sample(4.0, 2.0)};
    std::array<RouteMetricScaleBucketOutputSample, equal.size()> equal_output{};
    summary = assign(equal, equal_output, policy(0.0, 1.0, 1e-12));
    expect(summary.has_scale == 1U, "equal scale meets exact tolerance");
    expect(equal_output[0].normalized_value == 0.5, "equal scale normalizes midpoint");
    summary = assign(equal, equal_output, policy(0.0, 1.0, 1.0000001e-12));
    expect(summary.has_scale == 0U, "equal scale above tolerance rejected");

    summary = assign(equal, equal_output, policy(0.0, 1.0, 0.0, 0U, 1));
    expect(equal_output[0].bucket_index == 1, "bucket count below two clamps to two");
}

void test_determinism_and_large_inputs() {
    constexpr std::size_t ordinary_count = 100'000U;
    std::vector<RouteMetricScaleBucketInputSample> input(ordinary_count);
    std::vector<RouteMetricScaleBucketOutputSample> first(ordinary_count);
    std::vector<RouteMetricScaleBucketOutputSample> second(ordinary_count);
    for (std::size_t index = 0; index < ordinary_count; ++index) {
        const double metric = static_cast<double>(index % 97U) - 48.0;
        input[index] = sample(metric, index % 11U == 0U ? 0.0 : 1.0);
    }
    auto one = assign_route_metric_scale_buckets(
        input.data(), input.size(), policy(), first.data(), first.size()
    );
    const auto two = assign_route_metric_scale_buckets(
        input.data(), input.size(), policy(), second.data(), second.size()
    );
    expect(one.status == RouteMetricScaleBucketStatus::success, "100k succeeds");
    expect(std::memcmp(first.data(), second.data(), first.size() * sizeof(first[0])) == 0,
           "repeated 100k output deterministic");
    expect(one.status == two.status
        && one.sample_count == two.sample_count
        && one.valid_interval_count == two.valid_interval_count
        && one.no_data_interval_count == two.no_data_interval_count
        && one.required_output_capacity == two.required_output_capacity
        && one.valid_coverage_distance_meters == two.valid_coverage_distance_meters
        && one.lower_bound == two.lower_bound
        && one.median == two.median
        && one.upper_bound == two.upper_bound
        && one.has_scale == two.has_scale,
        "repeated summary deterministic");

    constexpr std::size_t product_count = 1'000'000U;
    input.assign(product_count, sample(8.0, 1.0));
    first.assign(product_count, RouteMetricScaleBucketOutputSample{});
    one = assign_route_metric_scale_buckets(
        input.data(), input.size(), policy(), first.data(), first.size()
    );
    expect(one.status == RouteMetricScaleBucketStatus::success, "one million succeeds");
    expect(one.sample_count == product_count, "one million count exact");
    expect(first.front().source_index == 0U, "one million first source");
    expect(first.back().source_index == product_count - 1U, "one million last source");
}

}  // namespace

void run_route_metric_scale_bucket_tests() {
    test_boundaries_and_no_write();
    test_quantiles_scale_and_weights();
    test_scale_normalization_and_buckets();
    test_determinism_and_large_inputs();
}
