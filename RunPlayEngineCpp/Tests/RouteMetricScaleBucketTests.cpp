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
static_assert(std::is_same_v<
    decltype(RouteMetricScaleBucketPolicy{}.bucket_count),
    std::int64_t
>);
static_assert(std::is_same_v<
    decltype(RouteMetricScaleBucketOutputSample{}.bucket_index),
    std::int64_t
>);

RouteMetricScaleBucketPolicy policy(
    double lower = 0.0,
    double upper = 1.0,
    double span = 0.0,
    std::uint64_t minimum = 1U,
    std::int64_t buckets = 7
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

    const std::array negative_inf{sample(1.0, -std::numeric_limits<double>::infinity())};
    summary = assign_route_metric_scale_buckets(negative_inf.data(), 1U, policy(), &output, 1U);
    expect(
        summary.status == RouteMetricScaleBucketStatus::invalid_input_contract,
        "negative infinite weight rejected"
    );
    expect_unchanged(sentinel, output, "negative infinite weight writes nothing");

    const std::array nan_weight{sample(1.0, std::numeric_limits<double>::quiet_NaN())};
    summary = assign_route_metric_scale_buckets(nan_weight.data(), 1U, policy(), &output, 1U);
    expect(summary.status == RouteMetricScaleBucketStatus::invalid_input_contract, "NaN weight rejected");
    expect_unchanged(sentinel, output, "NaN weight writes nothing");

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
    expect(
        summary.valid_coverage_distance_meters == std::numeric_limits<double>::infinity(),
        "finite weight overflow yields positive infinite coverage"
    );
    expect(summary.valid_interval_count == 3U, "finite overflow still counts three valid intervals");

    const std::array duplicate_input{
        sample(5.0, 3.0), sample(5.0, 1.0), sample(5.0, 2.0)
    };
    std::array<RouteMetricScaleBucketOutputSample, duplicate_input.size()> duplicate_output{};
    summary = assign(duplicate_input, duplicate_output);
    expect(summary.lower_bound == 5.0 && summary.median == 5.0 && summary.upper_bound == 5.0,
           "equal values retain scale");
}

void test_positive_infinite_weight_semantics() {
    const double pos_inf = std::numeric_limits<double>::infinity();
    const double neg_zero = -0.0;

    // Only +inf weight: valid for coverage, not quantile-eligible → no scale.
    const std::array only_inf{sample(7.0, pos_inf)};
    std::array<RouteMetricScaleBucketOutputSample, only_inf.size()> only_inf_out{};
    auto summary = assign(only_inf, only_inf_out);
    expect(summary.status == RouteMetricScaleBucketStatus::success, "+inf weight accepted");
    expect(summary.has_scale == 0U, "only +inf weight yields no scale");
    expect(summary.valid_interval_count == 1U, "valid count includes +inf weight");
    expect(
        summary.valid_coverage_distance_meters == pos_inf,
        "coverage includes +inf weight"
    );
    expect(only_inf_out[0].bucket_index == -1, "only +inf weight is no-data");
    expect(
        only_inf_out[0].weight_meters == pos_inf
            && std::signbit(only_inf_out[0].weight_meters) == false,
        "+inf weight bit pattern preserved"
    );

    // +inf weight plus finite eligible weights: scale from finite only.
    const std::array mixed{
        sample(1.0, pos_inf),
        sample(2.0, 1.0),
        sample(3.0, 1.0)
    };
    std::array<RouteMetricScaleBucketOutputSample, mixed.size()> mixed_out{};
    summary = assign(mixed, mixed_out, policy(0.0, 1.0));
    expect(summary.has_scale == 1U, "finite eligible weights still form a scale");
    expect(summary.lower_bound == 2.0 && summary.median == 2.0 && summary.upper_bound == 3.0,
           "quantiles ignore +inf weight");
    expect(summary.valid_interval_count == 3U, "valid count includes +inf and finite");
    expect(summary.valid_coverage_distance_meters == pos_inf, "mixed coverage is +inf");
    expect(mixed_out[0].has_normalized_value == 1U, "present +inf-weight value still buckets");
    expect(mixed_out[0].bucket_index == 0, "present +inf-weight maps to scale lower");
    expect(mixed_out[1].bucket_index == 0, "finite lower bucket");
    expect(mixed_out[2].bucket_index == 6, "finite upper bucket");

    // Negative zero is accepted and echoed exactly; not valid or eligible.
    const std::array neg_zero_input{sample(4.0, neg_zero), sample(5.0, 1.0), sample(6.0, 1.0)};
    std::array<RouteMetricScaleBucketOutputSample, neg_zero_input.size()> neg_zero_out{};
    summary = assign(neg_zero_input, neg_zero_out, policy(0.0, 1.0));
    expect(summary.status == RouteMetricScaleBucketStatus::success, "negative zero weight accepted");
    expect(summary.valid_interval_count == 2U, "negative zero is not valid");
    expect(
        std::signbit(neg_zero_out[0].weight_meters)
            && neg_zero_out[0].weight_meters == 0.0,
        "negative zero weight bit pattern preserved"
    );
    expect(summary.has_scale == 1U, "negative zero does not block scale");
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
    summary = assign(input, output, policy(0.2, 0.8, -std::numeric_limits<double>::infinity()));
    expect(summary.has_scale == 1U, "negative infinite span follows Swift max semantics");
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

void test_64bit_bucket_domain() {
    const std::array input{sample(0.0, 1.0), sample(1.0, 1.0)};
    std::array<RouteMetricScaleBucketOutputSample, input.size()> output{};

    // bucketCount = 2
    auto summary = assign(input, output, policy(0.0, 1.0, 0.0, 1U, 2));
    expect(summary.has_scale == 1U, "two-bucket scale");
    expect(output[0].bucket_index == 0 && output[1].bucket_index == 1, "bucket count 2 extremes");

    // bucketCount = 7, normalized midpoint
    summary = assign(input, output, policy(0.0, 1.0, 0.0, 1U, 7));
    expect(output[0].bucket_index == 0 && output[1].bucket_index == 6, "bucket count 7 extremes");

    // Above INT32_MAX
    constexpr std::int64_t above_i32 =
        static_cast<std::int64_t>(std::numeric_limits<std::int32_t>::max()) + 1;
    summary = assign(input, output, policy(0.0, 1.0, 0.0, 1U, above_i32));
    expect(summary.status == RouteMetricScaleBucketStatus::success, "bucketCount > INT32_MAX accepted");
    expect(output[0].bucket_index == 0, "large count lower bucket");
    expect(output[1].bucket_index == above_i32 - 1, "large count upper bucket");

    // INT64_MAX
    constexpr std::int64_t int64_max = std::numeric_limits<std::int64_t>::max();
    summary = assign(input, output, policy(0.0, 1.0, 0.0, 1U, int64_max));
    expect(summary.status == RouteMetricScaleBucketStatus::success, "bucketCount INT64_MAX accepted");
    expect(output[0].bucket_index == 0, "INT64_MAX lower bucket");
    expect(output[1].bucket_index == int64_max - 1, "INT64_MAX upper bucket is count-1");

    // nextafter(1.0, 0.0) with INT64_MAX — must not UB-cast near max
    const std::array near_one{
        sample(0.0, 1.0),
        sample(std::nextafter(1.0, 0.0), 1.0),
        sample(1.0, 1.0)
    };
    std::array<RouteMetricScaleBucketOutputSample, near_one.size()> near_out{};
    summary = assign(near_one, near_out, policy(0.0, 1.0, 0.0, 1U, int64_max));
    expect(summary.has_scale == 1U, "nextafter fixture has scale");
    expect(near_out[0].bucket_index == 0, "normalized 0 → bucket 0");
    // Swift: min(count-1, Int(nextDown(1) * Double(count))) with count = Int.max
    const double scaled =
        std::nextafter(1.0, 0.0) * static_cast<double>(int64_max);
    const std::int64_t expected_mid =
        std::min<std::int64_t>(int64_max - 1, static_cast<std::int64_t>(scaled));
    expect(near_out[1].bucket_index == expected_mid, "nextDown(1) safe cast");
    expect(near_out[2].bucket_index == int64_max - 1, "normalized 1 → count-1");

    // INT32_MAX itself still works
    constexpr std::int64_t i32_max =
        static_cast<std::int64_t>(std::numeric_limits<std::int32_t>::max());
    summary = assign(input, output, policy(0.0, 1.0, 0.0, 1U, i32_max));
    expect(output[1].bucket_index == i32_max - 1, "INT32_MAX upper bucket");
}

void test_no_scale_fast_path() {
    // Guaranteed no-scale via minimum valid count: output must be fully
    // initialized in source order with every interval no-data. The kernel
    // returns before either sort (see assign_route_metric_scale_buckets).
    constexpr std::size_t count = 32;
    std::array<RouteMetricScaleBucketInputSample, count> input{};
    std::array<RouteMetricScaleBucketOutputSample, count> output{};
    for (std::size_t index = 0; index < count; ++index) {
        input[index] = sample(static_cast<double>(index), 1.0 + static_cast<double>(index));
        // Poison output so we can prove a full write occurred.
        std::memset(&output[index], 0xA5, sizeof(output[index]));
    }

    auto summary = assign_route_metric_scale_buckets(
        input.data(),
        input.size(),
        policy(0.0, 1.0, 0.0, count + 1U, 7),
        output.data(),
        output.size()
    );
    expect(summary.status == RouteMetricScaleBucketStatus::success, "no-scale fast path succeeds");
    expect(summary.has_scale == 0U, "no-scale fast path has no scale");
    expect(summary.no_data_interval_count == count, "all intervals no-data");
    expect(summary.valid_interval_count == count, "valid count still reported");
    for (std::size_t index = 0; index < count; ++index) {
        expect(output[index].source_index == index, "fast path keeps source order");
        expect(output[index].metric_value == input[index].metric_value, "metric echoed");
        expect(output[index].weight_meters == input[index].weight_meters, "weight echoed");
        expect(output[index].has_metric_value == 1U, "presence echoed");
        expect(output[index].has_normalized_value == 0U, "normalized absent");
        expect(output[index].bucket_index == -1, "bucket no-data");
        expect(output[index].normalized_value == 0.0, "normalized zeroed");
    }

    // Non-finite lower quantile also takes the fast path.
    summary = assign_route_metric_scale_buckets(
        input.data(),
        input.size(),
        policy(std::numeric_limits<double>::quiet_NaN(), 1.0, 0.0, 1U, 7),
        output.data(),
        output.size()
    );
    expect(summary.has_scale == 0U && summary.no_data_interval_count == count,
           "non-finite quantile fast path");

    // Zero eligible (all missing) takes the fast path.
    std::array<RouteMetricScaleBucketInputSample, 4> missing{
        sample(0.0, 1.0, 0U),
        sample(0.0, 2.0, 0U),
        sample(0.0, 3.0, 0U),
        sample(0.0, 4.0, 0U)
    };
    std::array<RouteMetricScaleBucketOutputSample, 4> missing_out{};
    summary = assign(missing, missing_out);
    expect(summary.has_scale == 0U, "all-missing is no scale");
    expect(summary.valid_interval_count == 0U, "all-missing valid count zero");
    expect(summary.no_data_interval_count == 4U, "all-missing no-data count");
    for (const auto& item : missing_out) {
        expect(item.bucket_index == -1 && item.has_normalized_value == 0U, "all-missing buckets");
    }
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

    // Guaranteed no-scale at 100k must succeed and leave every interval no-data.
    auto no_scale = assign_route_metric_scale_buckets(
        input.data(),
        input.size(),
        policy(0.0, 1.0, 0.0, ordinary_count + 1U, 7),
        first.data(),
        first.size()
    );
    expect(no_scale.status == RouteMetricScaleBucketStatus::success, "100k no-scale succeeds");
    expect(no_scale.has_scale == 0U, "100k no-scale has no scale");
    expect(no_scale.no_data_interval_count == ordinary_count, "100k no-scale all no-data");
    expect(first.front().source_index == 0U && first.back().source_index == ordinary_count - 1U,
           "100k no-scale source order");
    expect(first.front().bucket_index == -1 && first.back().bucket_index == -1,
           "100k no-scale buckets");

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
    test_positive_infinite_weight_semantics();
    test_scale_normalization_and_buckets();
    test_64bit_bucket_domain();
    test_no_scale_fast_path();
    test_determinism_and_large_inputs();
}
