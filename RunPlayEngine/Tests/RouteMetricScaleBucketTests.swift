import Testing
import RunPlayEngine
import RunPlayEngineTestSupport

/// Ports `RouteMetricScaleBucketTests.cpp` case for case, with the same names
/// and expected literals.
///
/// Unrepresentable by construction (kept in the C++ tests until PR 10):
/// null input, output or workspace with a nonzero count; an output or workspace
/// capacity below the sample count; and the "no-scale leaves the caller's
/// workspace untouched" byte checks. A `Span` cannot pair a positive count with
/// null storage, and the kernel owns its output and workspace.
@Suite
struct RouteMetricScaleBucketTests {
    private typealias Sample = RouteMetricScaleBucketSample
    private typealias Policy = RouteMetricScaleBucketPolicy
    private typealias Output = RouteMetricScaleBucketOutputSample
    private typealias Result = RouteMetricScaleBucketResult

    private static func policy(
        _ lower: Double = 0.0, _ upper: Double = 1.0, _ span: Double = 0.0,
        _ minimum: UInt64 = 1, _ buckets: Int64 = 7
    ) -> Policy {
        Policy(
            lowerQuantile: lower, upperQuantile: upper, minimumScaleSpan: span,
            minimumValidIntervalCount: minimum, bucketCount: buckets
        )
    }

    private static func sample(_ metric: Double, _ weight: Double, _ present: UInt8 = 1) -> Sample {
        Sample(metricValue: metric, weightMeters: weight, hasMetricValue: present)
    }

    private static func assign(_ input: [Sample], _ requested: Policy = policy()) throws(RouteMetricScaleBucketError) -> Result {
        try RouteMetricScaleBuckets.assign(samples: input.span, policy: requested)
    }

    private static func rejects(
        _ error: RouteMetricScaleBucketError, _ input: [Sample], _ requested: Policy = policy(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: error, sourceLocation: sourceLocation) { try assign(input, requested) }
    }

    @Test func test_boundaries_and_no_write() throws {
        let empty = try Self.assign([], Policy())
        #expect(empty.sampleCount == 0, "empty buffers succeed")
        #expect(empty.samples.isEmpty && empty.sampleCount == 0, "empty capacity is zero")

        Self.rejects(.invalidInputContract, [Self.sample(1.0, 1.0, 2)])
        Self.rejects(.invalidInputContract, [Self.sample(1.0, -1.0)])
        Self.rejects(.invalidInputContract, [Self.sample(1.0, -Double.infinity)])
        Self.rejects(.invalidInputContract, [Self.sample(1.0, Double.nan)])

        // Engine ceiling enforced; the Swift error is typed and returns no result.
        let oversized = [Sample](repeating: Self.sample(1.0, 1.0), count: EngineRouteLimits.maxRouteInputSamples + 1)
        Self.rejects(.resourceLimit, oversized)
    }

    @Test func test_workspace_lifetime_and_reuse() throws {
        let input = [Self.sample(1.0, 1.0), Self.sample(2.0, 1.0), Self.sample(3.0, 1.0)]
        var result = try Self.assign(input, Self.policy(0.0, 1.0, 0.0, 99, 7))
        #expect(!result.hasScale, "min-count no-scale")
        for item in result.samples {
            #expect(item.bucketIndex == -1 && item.hasNormalizedValue == 0, "no-scale output")
        }

        result = try Self.assign(input, Self.policy(0.0, 1.0))
        #expect(result.hasScale, "workspace valid-scale")
        #expect(result.lowerBound == 1.0 && result.median == 2.0 && result.upperBound == 3.0, "workspace quantiles")
        #expect(result.samples[0].bucketIndex == 0 && result.samples[2].bucketIndex == 6, "workspace buckets")

        // A second call reuses nothing from the first and rewrites every output.
        let second = [Self.sample(10.0, 2.0), Self.sample(20.0, 2.0), Self.sample(30.0, 2.0)]
        result = try Self.assign(second, Self.policy(0.0, 1.0))
        #expect(result.hasScale, "reused workspace succeeds")
        #expect(result.lowerBound == 10.0 && result.upperBound == 30.0, "reused workspace quantiles")
        #expect(result.samples[0].metricValue == 10.0 && result.samples[2].metricValue == 30.0, "reused output rewritten")
    }

    @Test func test_quantiles_scale_and_weights() throws {
        let input = [
            Self.sample(3.0, 1.0), Self.sample(1.0, 1.0), Self.sample(2.0, 2.0),
            Self.sample(2.0, 1.0), Self.sample(99.0, 0.0), Self.sample(0.0, 3.0, 0),
        ]
        var result = try Self.assign(input, Self.policy(0.0, 1.0))
        #expect(result.hasScale, "weighted fixture has scale")
        #expect(result.lowerBound == 1.0, "quantile zero")
        #expect(result.median == 2.0, "weighted median")
        #expect(result.upperBound == 3.0, "quantile one")
        #expect(result.validIntervalCount == 4, "valid weighted count")
        #expect(result.validCoverageDistanceMeters == 5.0, "valid coverage")
        for index in result.samples.indices {
            #expect(result.samples[index].sourceIndex == UInt64(index), "source order restored")
        }

        result = try Self.assign(input, Self.policy(-10.0, 10.0))
        #expect(result.lowerBound == 1.0 && result.upperBound == 3.0, "finite quantiles clamp")
        result = try Self.assign(input, Self.policy(Double.nan, 1.0))
        #expect(!result.hasScale, "nan quantile means no scale")
        result = try Self.assign(input, Self.policy(0.0, Double.infinity))
        #expect(!result.hasScale, "infinite quantile means no scale")

        let huge = Double.greatestFiniteMagnitude
        result = try Self.assign([Self.sample(1.0, huge), Self.sample(2.0, huge), Self.sample(3.0, huge)])
        #expect(result.hasScale, "scaled huge weights have scale")
        #expect(result.median == 2.0, "scaled huge weights keep median")
        #expect(result.validCoverageDistanceMeters == Double.infinity, "finite weight overflow yields positive infinite coverage")
        #expect(result.validIntervalCount == 3, "finite overflow still counts three valid intervals")

        result = try Self.assign([Self.sample(5.0, 3.0), Self.sample(5.0, 1.0), Self.sample(5.0, 2.0)])
        #expect(result.lowerBound == 5.0 && result.median == 5.0 && result.upperBound == 5.0, "equal values retain scale")
    }

    @Test func test_positive_infinite_weight_semantics() throws {
        let posInf = Double.infinity
        let negZero = -0.0

        var result = try Self.assign([Self.sample(7.0, posInf)])
        #expect(!result.hasScale, "only +inf weight yields no scale")
        #expect(result.validIntervalCount == 1, "valid count includes +inf weight")
        #expect(result.validCoverageDistanceMeters == posInf, "coverage includes +inf weight")
        #expect(result.samples[0].bucketIndex == -1, "only +inf weight is no-data")

        result = try Self.assign([Self.sample(1.0, posInf), Self.sample(2.0, 1.0), Self.sample(3.0, 1.0)], Self.policy(0.0, 1.0))
        #expect(result.hasScale, "finite eligible weights still form a scale")
        #expect(result.lowerBound == 2.0 && result.median == 2.0 && result.upperBound == 3.0, "quantiles ignore +inf weight")
        #expect(result.validIntervalCount == 3, "valid count includes +inf and finite")
        #expect(result.samples[0].hasNormalizedValue == 1, "present +inf-weight value still buckets")

        result = try Self.assign([Self.sample(4.0, negZero), Self.sample(5.0, 1.0), Self.sample(6.0, 1.0)], Self.policy(0.0, 1.0))
        #expect(result.validIntervalCount == 2, "negative zero is not valid")
        #expect(result.hasScale, "negative zero does not block scale")
    }

    @Test func test_scale_normalization_and_buckets() throws {
        let input = [
            Self.sample(-10.0, 1.0), Self.sample(0.0, 1.0), Self.sample(5.0, 1.0),
            Self.sample(10.0, 1.0), Self.sample(20.0, 1.0),
            Self.sample(Double.nan, 0.0),
            Self.sample(0.0, 0.0, 0),
        ]
        var result = try Self.assign(input, Self.policy(0.2, 0.8, 0.0, 1, 7))
        #expect(result.hasScale, "normalization fixture has scale")
        #expect(result.lowerBound == -10.0 && result.upperBound == 10.0, "scale bounds exact")
        let out = result.samples
        #expect(out[0].normalizedValue == 0.0 && out[0].bucketIndex == 0, "normalized zero")
        #expect(out[2].normalizedValue == 0.75 && out[2].bucketIndex == 5, "middle bucket")
        #expect(out[3].normalizedValue == 1.0 && out[3].bucketIndex == 6, "normalized one")
        #expect(out[4].normalizedValue == 1.0 && out[4].bucketIndex == 6, "above scale clamps")
        #expect(out[5].normalizedValue == 0.5 && out[5].bucketIndex == 3, "present nan normalizes to midpoint")
        #expect(out[6].hasNormalizedValue == 0 && out[6].bucketIndex == -1, "missing remains no data")
        #expect(result.noDataIntervalCount == 1, "no-data counts bucket state")

        result = try Self.assign(input, Self.policy(0.2, 0.8, 21.0))
        #expect(!result.hasScale && result.noDataIntervalCount == UInt64(input.count), "span gate no scale")

        result = try Self.assign(input, Self.policy(0.2, 0.8, Double.nan))
        #expect(result.hasScale, "nan minimum span follows Swift max semantics")
        result = try Self.assign(input, Self.policy(0.2, 0.8, Double.infinity))
        #expect(!result.hasScale, "positive infinite span means no scale")
        result = try Self.assign(input, Self.policy(0.2, 0.8, -Double.infinity))
        #expect(result.hasScale, "negative infinite span follows Swift max semantics")
        result = try Self.assign(input, Self.policy(0.2, 0.8, 0.0, 99))
        #expect(!result.hasScale, "minimum count gate")

        let equal = [Self.sample(4.0, 1.0), Self.sample(4.0, 2.0)]
        result = try Self.assign(equal, Self.policy(0.0, 1.0, 1e-12))
        #expect(result.hasScale, "equal scale meets exact tolerance")
        #expect(result.samples[0].normalizedValue == 0.5, "equal scale normalizes midpoint")
        result = try Self.assign(equal, Self.policy(0.0, 1.0, 1.0000001e-12))
        #expect(!result.hasScale, "equal scale above tolerance rejected")

        result = try Self.assign(equal, Self.policy(0.0, 1.0, 0.0, 0, 1))
        #expect(result.samples[0].bucketIndex == 1, "bucket count below two clamps to two")
    }

    @Test func test_64bit_bucket_domain() throws {
        let input = [Self.sample(0.0, 1.0), Self.sample(1.0, 1.0)]

        var result = try Self.assign(input, Self.policy(0.0, 1.0, 0.0, 1, 2))
        #expect(result.samples[0].bucketIndex == 0 && result.samples[1].bucketIndex == 1, "bucket count 2 extremes")

        result = try Self.assign(input, Self.policy(0.0, 1.0, 0.0, 1, 7))
        #expect(result.samples[0].bucketIndex == 0 && result.samples[1].bucketIndex == 6, "bucket count 7 extremes")

        let aboveInt32 = Int64(Int32.max) + 1
        result = try Self.assign(input, Self.policy(0.0, 1.0, 0.0, 1, aboveInt32))
        #expect(result.samples[1].bucketIndex == aboveInt32 - 1, "large count upper bucket")

        let int64Max = Int64.max
        result = try Self.assign(input, Self.policy(0.0, 1.0, 0.0, 1, int64Max))
        #expect(result.samples[1].bucketIndex == int64Max - 1, "INT64_MAX upper bucket is count-1")

        let nearOne = [Self.sample(0.0, 1.0), Self.sample(1.0.nextDown, 1.0), Self.sample(1.0, 1.0)]
        result = try Self.assign(nearOne, Self.policy(0.0, 1.0, 0.0, 1, int64Max))
        let scaled = 1.0.nextDown * Double(int64Max)
        let expectedMid = min(int64Max - 1, Int64(scaled))
        #expect(result.samples[1].bucketIndex == expectedMid, "nextDown(1) safe cast")
        #expect(result.samples[2].bucketIndex == int64Max - 1, "normalized 1 → count-1")
    }

    @Test func test_no_scale_fast_path() throws {
        let count = 32
        let input = (0..<count).map { Self.sample(Double($0), 1.0 + Double($0)) }
        let result = try Self.assign(input, Self.policy(0.0, 1.0, 0.0, UInt64(count) + 1, 7))
        #expect(!result.hasScale, "no-scale fast path has no scale")
        #expect(result.noDataIntervalCount == UInt64(count), "all intervals no-data")
        for index in 0..<count {
            #expect(result.samples[index].sourceIndex == UInt64(index), "fast path keeps source order")
            #expect(result.samples[index].bucketIndex == -1, "bucket no-data")
            #expect(result.samples[index].hasNormalizedValue == 0, "normalized absent")
        }
    }

    @Test func test_determinism_and_large_inputs() throws {
        let ordinaryCount = 100_000
        var input = [Sample](repeating: Sample(), count: ordinaryCount)
        for index in 0..<ordinaryCount {
            let metric = Double(index % 97) - 48.0
            input[index] = Self.sample(metric, index % 11 == 0 ? 0.0 : 1.0)
        }
        let one = try Self.assign(input)
        let two = try Self.assign(input)
        for index in 0..<ordinaryCount {
            let a = one.samples[index], b = two.samples[index]
            #expect(a.sourceIndex == b.sourceIndex && a.metricValue.bitPattern == b.metricValue.bitPattern
                && a.weightMeters.bitPattern == b.weightMeters.bitPattern
                && a.normalizedValue.bitPattern == b.normalizedValue.bitPattern
                && a.bucketIndex == b.bucketIndex && a.hasMetricValue == b.hasMetricValue
                && a.hasNormalizedValue == b.hasNormalizedValue, "repeated 100k output deterministic")
        }
        #expect(one.sampleCount == two.sampleCount && one.validIntervalCount == two.validIntervalCount
            && one.noDataIntervalCount == two.noDataIntervalCount && one.lowerBound == two.lowerBound
            && one.median == two.median && one.upperBound == two.upperBound && one.hasScale == two.hasScale,
            "repeated summary deterministic")

        let noScale = try Self.assign(input, Self.policy(0.0, 1.0, 0.0, UInt64(ordinaryCount) + 1, 7))
        #expect(!noScale.hasScale, "100k no-scale has no scale")
        #expect(noScale.noDataIntervalCount == UInt64(ordinaryCount), "100k no-scale all no-data")

        let productCount = 1_000_000
        let product = try Self.assign([Sample](repeating: Self.sample(8.0, 1.0), count: productCount))
        #expect(product.sampleCount == UInt64(productCount), "one million count exact")
        #expect(product.samples.first?.sourceIndex == 0, "one million first source")
        #expect(product.samples.last?.sourceIndex == UInt64(productCount - 1), "one million last source")
    }

    /// The C++ result for equal-weight `+0` and `-0` metrics depends on the C++
    /// library (libc++ selects `-0`, libstdc++ `+0`). Swift's stable sort keeps
    /// source order, so this result is identical on every platform. Intended
    /// behaviour change, recorded in the Kiro design and the PR.
    @Test func test_signed_zero_tie_is_stable_and_platform_independent() throws {
        let base: [Double] = [0.0, 1.0, 0.0, 2.0]
        let input = (0..<32).map { Self.sample($0 == 26 ? -0.0 : base[$0 % 4], 1.0) }
        let result = try Self.assign(input, Self.policy(0.0, 1.0, 0.0, 1, 5))
        #expect(result.hasScale)
        #expect(result.median.bitPattern == 0x0000_0000_0000_0000)
        #expect(result.lowerBound.bitPattern == 0x0000_0000_0000_0000)
        #expect(result.upperBound == 2.0)

        // Moving the -0 to the end of the zero group selects it as the median.
        var last = input
        last[26] = Self.sample(0.0, 1.0)
        last[30] = Self.sample(-0.0, 1.0)
        let moved = try Self.assign(last, Self.policy(0.0, 1.0, 0.0, 1, 5))
        #expect(moved.median.bitPattern == 0x8000_0000_0000_0000, "stable order: source order decides a ±0 tie")
    }
}
