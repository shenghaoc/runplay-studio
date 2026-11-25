import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

// Native oracle for differential tests and release measurements only.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Transitional C++ reference for the route-metric scale/bucket kernel. It
/// exists only here: Core production code calls the Swift engine through
/// `RunPlayRouteMetricScaleBucketBridge`. One native call per assignment;
/// Swift owns every buffer, and C++ retains nothing and calls back into nothing.
enum RunPlayRouteMetricScaleBucketCppBridge {
    /// Raw observation of one native call, expressed in engine value types so a
    /// Swift result and a C++ result compare field by field.
    struct Observation {
        var error: RouteMetricScaleBucketError?
        var result: RouteMetricScaleBucketResult
    }

    static func observe(
        _ samples: [RouteMetricScaleBucketSample], policy: RouteMetricScaleBucketPolicy
    ) -> Observation {
        var input = ContiguousArray<runplay.RouteMetricScaleBucketInputSample>()
        input.reserveCapacity(samples.count)
        for sample in samples {
            var native = runplay.RouteMetricScaleBucketInputSample()
            native.metric_value = sample.metricValue
            native.weight_meters = sample.weightMeters
            native.has_metric_value = sample.hasMetricValue
            input.append(native)
        }
        var nativePolicy = runplay.RouteMetricScaleBucketPolicy()
        nativePolicy.lower_quantile = policy.lowerQuantile
        nativePolicy.upper_quantile = policy.upperQuantile
        nativePolicy.minimum_scale_span = policy.minimumScaleSpan
        nativePolicy.minimum_valid_interval_count = policy.minimumValidIntervalCount
        nativePolicy.bucket_count = policy.bucketCount

        var workspace = ContiguousArray<runplay.RouteMetricScaleBucketWorkspaceSample>(
            repeating: runplay.RouteMetricScaleBucketWorkspaceSample(), count: input.count
        )
        var output = ContiguousArray<runplay.RouteMetricScaleBucketOutputSample>(
            repeating: runplay.RouteMetricScaleBucketOutputSample(), count: input.count
        )
        let summary = input.withUnsafeBufferPointer { inputBuffer in
            workspace.withUnsafeMutableBufferPointer { workspaceBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    runplay.assign_route_metric_scale_buckets(
                        inputBuffer.baseAddress, inputBuffer.count, nativePolicy,
                        workspaceBuffer.baseAddress, workspaceBuffer.count,
                        outputBuffer.baseAddress, outputBuffer.count
                    )
                }
            }
        }

        var result = RouteMetricScaleBucketResult()
        switch summary.status {
        case .success: break
        case .resource_limit: return Observation(error: .resourceLimit, result: result)
        case .invalid_policy: return Observation(error: .invalidPolicy, result: result)
        case .invalid_input_contract: return Observation(error: .invalidInputContract, result: result)
        case .internal_failure: return Observation(error: .internalFailure, result: result)
        default:
            // Buffer and capacity statuses are unrepresentable in Swift; typed
            // buffers sized here can never produce them, so reaching one is a test bug.
            Issue.record("unexpected native status \(summary.status)")
            return Observation(error: .internalFailure, result: result)
        }
        result.sampleCount = summary.sample_count
        result.validIntervalCount = summary.valid_interval_count
        result.noDataIntervalCount = summary.no_data_interval_count
        result.validCoverageDistanceMeters = summary.valid_coverage_distance_meters
        result.lowerBound = summary.lower_bound
        result.median = summary.median
        result.upperBound = summary.upper_bound
        result.hasScale = summary.has_scale == 1
        result.samples = output.map { native in
            var sample = RouteMetricScaleBucketOutputSample()
            sample.sourceIndex = native.source_index
            sample.metricValue = native.metric_value
            sample.weightMeters = native.weight_meters
            sample.normalizedValue = native.normalized_value
            sample.bucketIndex = native.bucket_index
            sample.hasMetricValue = native.has_metric_value
            sample.hasNormalizedValue = native.has_normalized_value
            return sample
        }
        return Observation(error: nil, result: result)
    }

    /// Complete C++ path from Core values, for release measurements only:
    /// conversion, one native call and translation back into Core results.
    static func assign(
        metricValues: [Double?], weightsMeters: [Double], lowerQuantile: Double, upperQuantile: Double,
        minimumScaleSpan: Double, minimumValidIntervalCount: Int, bucketCount: Int
    ) throws -> RunPlayRouteMetricScaleBucketResult {
        var input = [RouteMetricScaleBucketSample]()
        input.reserveCapacity(metricValues.count)
        for index in metricValues.indices {
            input.append(.init(
                metricValue: metricValues[index] ?? 0, weightMeters: weightsMeters[index],
                hasMetricValue: metricValues[index] == nil ? 0 : 1
            ))
        }
        let policy = RouteMetricScaleBucketPolicy(
            lowerQuantile: lowerQuantile, upperQuantile: upperQuantile, minimumScaleSpan: minimumScaleSpan,
            minimumValidIntervalCount: UInt64(minimumValidIntervalCount), bucketCount: Int64(bucketCount)
        )
        let observation = observe(input, policy: policy)
        guard observation.error == nil else { throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation }
        let result = observation.result
        let scale = result.hasScale
            ? RunPlayRouteMetricNumericScale(lowerBound: result.lowerBound, median: result.median, upperBound: result.upperBound)
            : nil
        let assignments = result.samples.map { item in
            item.hasNormalizedValue == 0
                ? RunPlayRouteMetricBucketAssignment(normalizedValue: nil, bucketIndex: nil)
                : RunPlayRouteMetricBucketAssignment(normalizedValue: item.normalizedValue, bucketIndex: Int(item.bucketIndex))
        }
        return RunPlayRouteMetricScaleBucketResult(
            scale: scale, assignments: assignments,
            validCoverageDistanceMeters: result.validCoverageDistanceMeters,
            validIntervalCount: Int(result.validIntervalCount), noDataIntervalCount: Int(result.noDataIntervalCount)
        )
    }
}

/// Compares the Swift kernel with the unchanged C++ kernel.
///
/// Every field is bit-identical, with one deliberate exception. The C++ result
/// for equal-weight `+0` and `-0` metrics depends on the C++ library (libc++
/// selects `-0`, libstdc++ `+0`). Swift's stable sort is deterministic on every
/// platform. For those cases only, the comparison asserts numeric equality.
@Suite(.serialized)
struct RouteMetricScaleBucketDifferentialTests {
    typealias Sample = RouteMetricScaleBucketSample
    typealias Policy = RouteMetricScaleBucketPolicy
    typealias Case = (name: String, samples: [Sample], policy: Policy)

    // MARK: Corpus

    private static func policy(
        _ lower: Double = 0, _ upper: Double = 1, _ span: Double = 0,
        _ minimum: UInt64 = 1, _ buckets: Int64 = 7
    ) -> Policy {
        Policy(lowerQuantile: lower, upperQuantile: upper, minimumScaleSpan: span,
               minimumValidIntervalCount: minimum, bucketCount: buckets)
    }

    private static func s(_ metric: Double, _ weight: Double, _ present: UInt8 = 1) -> Sample {
        Sample(metricValue: metric, weightMeters: weight, hasMetricValue: present)
    }

    /// The kernel reads no coordinates, so antimeridian, pole and Web Mercator
    /// cases do not apply. Its edges are numeric: empty, one point, NaN, ±inf,
    /// subnormals, ±0, the 64-bit bucket domain, the product limit and the
    /// engine ceiling.
    static func corpus() -> [Case] {
        var cases: [Case] = []
        func add(_ name: String, _ samples: [Sample], _ policy: Policy = policy()) {
            cases.append((name, samples, policy))
        }
        let inf = Double.infinity, nan = Double.nan
        let witnessBase: [Double] = [0, 1, 0, 2]
        add("empty", [], Policy())
        add("one point", [s(1, 1)])
        add("one absent", [s(0, 1, 0)])
        add("weighted fixture", [s(3, 1), s(1, 1), s(2, 2), s(2, 1), s(99, 0), s(0, 3, 0)])
        add("normalization fixture", [s(-10, 1), s(0, 1), s(5, 1), s(10, 1), s(20, 1), s(nan, 0), s(0, 0, 0)],
            policy(0.2, 0.8, 0, 1, 7))
        add("huge weights", [s(1, .greatestFiniteMagnitude), s(2, .greatestFiniteMagnitude), s(3, .greatestFiniteMagnitude)])
        add("positive infinite weight only", [s(7, inf)])
        add("positive infinite weight mixed", [s(1, inf), s(2, 1), s(3, 1)])
        add("negative zero weight", [s(4, -0.0), s(5, 1), s(6, 1)])
        add("duplicates", [s(5, 3), s(5, 1), s(5, 2)])
        add("equal scale tolerance", [s(4, 1), s(4, 2)], policy(0, 1, 1e-12))
        add("equal scale above tolerance", [s(4, 1), s(4, 2)], policy(0, 1, 1.0000001e-12))
        add("nonfinite metrics", [s(nan, 1), s(inf, 1), s(-inf, 1), s(1, 1), s(2, 1)])
        add("subnormal metrics", [s(.leastNonzeroMagnitude, 1), s(-.leastNonzeroMagnitude, 1), s(0, 1), s(1, 1)])
        add("invalid presence byte", [s(1, 1, 2)])
        add("invalid negative weight", [s(1, -1)])
        add("invalid negative infinite weight", [s(1, -inf)])
        add("invalid NaN weight", [s(1, nan)])
        let pair = [s(0, 1), s(1, 1)]
        let policies: [(String, Policy)] = [
            ("NaN lower", policy(nan, 1)), ("infinite upper", policy(0, inf)),
            ("out of range quantiles", policy(-10, 10)),
            ("NaN span", policy(0, 1, nan)), ("infinite span", policy(0, 1, inf)),
            ("negative infinite span", policy(0, 1, -inf)),
            ("huge minimum count", policy(0, 1, 0, .max)), ("zero minimum count", policy(0, 1, 0, 0)),
            ("bucket count 0", policy(0, 1, 0, 1, 0)), ("bucket count 1", policy(0, 1, 0, 1, 1)),
            ("bucket count 2", policy(0, 1, 0, 1, 2)), ("negative bucket count", policy(0, 1, 0, 1, -5)),
            ("bucket count Int64.min", policy(0, 1, 0, 1, .min)),
            ("bucket count above Int32", policy(0, 1, 0, 1, Int64(Int32.max) + 1)),
            ("bucket count Int64.max", policy(0, 1, 0, 1, .max)),
        ]
        for (name, value) in policies { add("policy " + name, pair, value) }
        add("nextDown(1) with Int64.max buckets", [s(0, 1), s(1.0.nextDown, 1), s(1, 1)], policy(0, 1, 0, 1, .max))

        // Signed-zero ties: the only inputs where the C++ result is platform-dependent.
        let witness = (0..<32).map { s($0 == 26 ? -0.0 : witnessBase[$0 % 4], 1) }
        add("signed-zero witness", witness, policy(0, 1, 0, 1, 5))
        add("signed-zero witness reversed", Array(witness.reversed()), policy(0, 1, 0, 1, 5))
        add("signed-zero negative zero last", (0..<32).map { s($0 == 30 ? -0.0 : witnessBase[$0 % 4], 1) }, policy(0, 1, 0, 1, 5))
        add("signed-zero negative zero first", (0..<32).map { s($0 == 0 ? -0.0 : witnessBase[$0 % 4], 1) }, policy(0, 1, 0, 1, 5))
        add("signed-zero all negative zero", [s(-0.0, 1), s(-0.0, 1), s(1, 1)])
        add("signed-zero two zeros", [s(0.0, 2), s(-0.0, 2), s(5, 1)], policy(0, 1))
        add("signed-zero distinct weights", [s(0.0, 1), s(-0.0, 2), s(3, 1)], policy(0, 1))
        add("signed-zero median", [s(-0.0, 1), s(0.0, 1), s(3, 1)], policy(0, 1))

        // Seeded corpus: sizes, values, weights and policies drawn from edge pools.
        var rng = SplitMix64(seed: 0x7363_616c_6562_6b74)
        // 1e-320 as an exact subnormal: a literal underflows with a warning on Linux.
        let subnormal = Double(bitPattern: 2024)
        let metricPool: [Double] = [0, -0.0, 1, -1, 2, 3.5, -100, 100, subnormal, -subnormal, 1e300, -1e300, .nan, .infinity, -.infinity]
        let weightPool: [Double] = [0, -0.0, 1, 1, 1, 2, 0.5, 10, subnormal, 1e300, .greatestFiniteMagnitude, .infinity]
        let quantiles: [Double] = [0, 0.05, 0.2, 0.5, 0.8, 0.95, 1, -1, 2, .nan, .infinity]
        let spans: [Double] = [0, 0, 1e-12, 1, 21, .nan, .infinity, -.infinity]
        let bucketCounts: [Int64] = [7, 7, 2, 3, 1, 0, -3, 100, Int64(Int32.max) + 1, .max, .min]
        func pick<T>(_ pool: [T], _ rng: inout SplitMix64) -> T { pool[Int(rng.next() % UInt64(pool.count))] }
        for index in 0..<600 {
            let size = Int(rng.next() % (index.isMultiple(of: 50) ? 4_000 : 40))
            var samples: [Sample] = []
            samples.reserveCapacity(size)
            for _ in 0..<size {
                var weight = pick(weightPool, &rng)
                if rng.next() % 400 == 0 { weight = pick([-1.0, -.infinity, .nan], &rng) }
                let present: UInt8 = rng.next() % 7 == 0 ? 0 : (rng.next() % 500 == 0 ? 2 : 1)
                samples.append(s(pick(metricPool, &rng), weight, present))
            }
            let minimum: UInt64 = rng.next() % 5 == 0 ? UInt64(size) + 1 : rng.next() % 4
            add("seeded \(index)", samples, policy(
                pick(quantiles, &rng), pick(quantiles, &rng), pick(spans, &rng), minimum, pick(bucketCounts, &rng)
            ))
        }
        // Product-limit sizes and the engine ceiling edge.
        add("100k deterministic", (0..<100_000).map { s(Double($0 % 97) - 48, $0 % 11 == 0 ? 0 : 1) })
        add("one million constant", [Sample](repeating: s(8, 1), count: 1_000_000))
        add("ceiling", [Sample](repeating: s(8, 1), count: EngineRouteLimits.maxRouteInputSamples))
        add("ceiling plus one", [Sample](repeating: s(8, 1), count: EngineRouteLimits.maxRouteInputSamples + 1))
        return cases
    }

    /// `true` when equal-weight eligible metrics include both `+0` and `-0`.
    /// Only then can the order of tied sort keys change a selected quantile's bits.
    static func hasSignedZeroTie(_ samples: [Sample]) -> Bool {
        var positive = Set<UInt64>(), negative = Set<UInt64>()
        for sample in samples
        where sample.hasMetricValue == 1 && sample.metricValue == 0 && sample.weightMeters.isFinite && sample.weightMeters > 0 {
            if sample.metricValue.sign == .minus {
                negative.insert(sample.weightMeters.bitPattern)
            } else {
                positive.insert(sample.weightMeters.bitPattern)
            }
        }
        return !positive.isDisjoint(with: negative)
    }

    // MARK: Comparison

    private static func swiftObservation(_ samples: [Sample], _ policy: Policy) -> RunPlayRouteMetricScaleBucketCppBridge.Observation {
        do {
            return .init(error: nil, result: try RouteMetricScaleBuckets.assign(samples: samples.span, policy: policy))
        } catch {
            return .init(error: error, result: RouteMetricScaleBucketResult())
        }
    }

    /// Returns `nil` when the observations agree, otherwise the first difference.
    static func difference(
        swift: RunPlayRouteMetricScaleBucketCppBridge.Observation,
        cpp: RunPlayRouteMetricScaleBucketCppBridge.Observation,
        numericOnly: Bool
    ) -> String? {
        if swift.error != cpp.error { return "error \(String(describing: swift.error)) vs \(String(describing: cpp.error))" }
        if swift.error != nil { return nil }
        let a = swift.result, b = cpp.result
        func same(_ x: Double, _ y: Double) -> Bool { numericOnly ? x == y : x.bitPattern == y.bitPattern }
        guard a.sampleCount == b.sampleCount, a.validIntervalCount == b.validIntervalCount,
              a.noDataIntervalCount == b.noDataIntervalCount, a.hasScale == b.hasScale,
              a.samples.count == b.samples.count
        else { return "counts" }
        // Coverage is accumulated in source order and never depends on the sort.
        guard a.validCoverageDistanceMeters.bitPattern == b.validCoverageDistanceMeters.bitPattern else { return "coverage" }
        guard same(a.lowerBound, b.lowerBound), same(a.median, b.median), same(a.upperBound, b.upperBound) else { return "scale" }
        for index in a.samples.indices {
            let x = a.samples[index], y = b.samples[index]
            guard x.sourceIndex == y.sourceIndex, x.hasMetricValue == y.hasMetricValue,
                  x.hasNormalizedValue == y.hasNormalizedValue, x.bucketIndex == y.bucketIndex,
                  x.metricValue.bitPattern == y.metricValue.bitPattern,
                  x.weightMeters.bitPattern == y.weightMeters.bitPattern,
                  same(x.normalizedValue, y.normalizedValue)
            else { return "sample \(index)" }
        }
        return nil
    }

    @Test func cppAndSwiftMatch() {
        var tieCases: [String] = []
        var bitDifferingTieCases: [String] = []
        var cases = 0
        for item in Self.corpus() {
            let swift = Self.swiftObservation(item.samples, item.policy)
            let cpp = RunPlayRouteMetricScaleBucketCppBridge.observe(item.samples, policy: item.policy)
            let tie = Self.hasSignedZeroTie(item.samples)
            if tie {
                tieCases.append(item.name)
                if Self.difference(swift: swift, cpp: cpp, numericOnly: false) != nil { bitDifferingTieCases.append(item.name) }
            }
            if let difference = Self.difference(swift: swift, cpp: cpp, numericOnly: tie) {
                Issue.record("\(item.name)\(tie ? " (±0 tie, numeric)" : ""): \(difference)")
            }
            cases += 1
        }
        #expect(!tieCases.isEmpty)
        print("SCALE_BUCKET_TIE_CASES \(Self.platformTag) count=\(tieCases.count) \(tieCases.joined(separator: " | "))")
        print("SCALE_BUCKET_TIE_BIT_DIFFERENCES \(Self.platformTag) count=\(bitDifferingTieCases.count) \(bitDifferingTieCases.joined(separator: " | "))")
        print("SCALE_BUCKET_CASES \(Self.platformTag) cases=\(cases)")
    }

    // MARK: Golden

    static var platformTag: String {
        #if os(macOS) && arch(arm64)
        return "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
        return "linux-x86_64"
        #else
        return "other"
        #endif
    }

    static func swiftDigest() -> UInt64 {
        var digest = FNV1a64()
        for item in corpus() {
            let observation = swiftObservation(item.samples, item.policy)
            if let error = observation.error {
                digest.append(byte: 1)
                switch error {
                case .invalidPolicy: digest.append(byte: 1)
                case .invalidInputContract: digest.append(byte: 2)
                case .resourceLimit: digest.append(byte: 3)
                case .internalFailure: digest.append(byte: 4)
                }
                continue
            }
            let result = observation.result
            digest.append(byte: 0)
            digest.append(word: result.sampleCount)
            digest.append(word: result.validIntervalCount)
            digest.append(word: result.noDataIntervalCount)
            digest.append(word: result.validCoverageDistanceMeters.bitPattern)
            digest.append(word: result.lowerBound.bitPattern)
            digest.append(word: result.median.bitPattern)
            digest.append(word: result.upperBound.bitPattern)
            digest.append(byte: result.hasScale ? 1 : 0)
            for sample in result.samples {
                digest.append(word: sample.sourceIndex)
                digest.append(word: sample.metricValue.bitPattern)
                digest.append(word: sample.weightMeters.bitPattern)
                digest.append(word: sample.normalizedValue.bitPattern)
                digest.append(word: sample.bucketIndex)
                digest.append(byte: sample.hasMetricValue)
                digest.append(byte: sample.hasNormalizedValue)
            }
        }
        return digest.value
    }

    /// Captured from the Swift kernel, not from C++: the C++ result for ±0 ties
    /// depends on the platform, so a C++-derived digest would too. The Swift
    /// result is the same on every platform, so one digest covers them all.
    static let swiftGolden: UInt64? = 0x757b_d6c5_bb30_9e07

    @Test(.enabled(if: RouteMetricScaleBucketDifferentialTests.swiftGolden != nil))
    func swiftMatchesGolden() throws {
        #expect(Self.swiftDigest() == (try #require(Self.swiftGolden)))
    }

    @Test func captureSwiftDigest() {
        print("SCALE_BUCKET_SWIFT_FNV1A64 \(String(Self.swiftDigest(), radix: 16)) \(Self.platformTag)")
    }

    /// The 32-sample witness: equal weights, `-0` at index 26 among `+0`.
    /// C++ selects `-0` on libc++ and `+0` on libstdc++. The Swift result is the
    /// same on every platform: stable order puts `+0` (index 30) at the median.
    @Test func signedZeroWitnessIsPlatformIndependent() throws {
        let base: [Double] = [0, 1, 0, 2]
        let metrics: [Double?] = (0..<32).map { $0 == 26 ? -0.0 : base[$0 % 4] }
        let result = try RunPlayRouteMetricScaleBucketBridge.assign(
            metricValues: metrics, weightsMeters: Array(repeating: 1, count: 32),
            lowerQuantile: 0, upperQuantile: 1, minimumScaleSpan: 0, minimumValidIntervalCount: 1, bucketCount: 5,
            cancellationCheckStride: 2_048, isCancelled: { false }
        )
        let scale = try #require(result.scale)
        #expect(scale.median.bitPattern == 0x0000_0000_0000_0000)
        #expect(scale.lowerBound.bitPattern == 0x0000_0000_0000_0000)
        #expect(scale.upperBound.bitPattern == 0x4000_0000_0000_0000)
    }
}
