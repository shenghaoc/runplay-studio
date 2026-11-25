import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

/// Pins the Swift route-metric scale/bucket kernel to a golden digest.
///
/// The corpus and digest are those of the former Swift-versus-C++ differential
/// test. Every field was bit-identical to the C++ kernel, with one deliberate
/// exception: the C++ result for equal-weight `+0` and `-0` metrics depended on
/// the C++ library (libc++ selected `-0`, libstdc++ `+0`). Swift's stable sort
/// is deterministic on every platform.
@Suite(.serialized)
struct RouteMetricScaleBucketGoldenTests {
    typealias Sample = RouteMetricScaleBucketSample
    typealias Policy = RouteMetricScaleBucketPolicy
    typealias Case = (name: String, samples: [Sample], policy: Policy)

    /// Raw observation of one engine call.
    struct Observation {
        var error: RouteMetricScaleBucketError?
        var result: RouteMetricScaleBucketResult
    }


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

        // Signed-zero ties: the only inputs where the former C++ result was platform-dependent.
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

    // MARK: Observation

    private static func swiftObservation(_ samples: [Sample], _ policy: Policy) -> Observation {
        do {
            return .init(error: nil, result: try RouteMetricScaleBuckets.assign(samples: samples.span, policy: policy))
        } catch {
            return .init(error: error, result: RouteMetricScaleBucketResult())
        }
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
    /// depended on the platform, so a C++-derived digest would too. The Swift
    /// result is the same on every platform, so one digest covers them all.
    static let swiftGolden: UInt64? = 0x757b_d6c5_bb30_9e07

    /// Fails when a platform condition leaves `swiftGolden` nil on a platform that
    /// pins it, which would otherwise disable the golden test silently.
    @Test func goldenIsPinnedOnPinnedPlatforms() {
        #expect(
            !GoldenPlatform.current.pinsKernelGoldens || Self.swiftGolden != nil,
            "\(GoldenPlatform.unpinnedMessage("swiftGolden"))"
        )
    }

    @Test(.enabled(if: RouteMetricScaleBucketGoldenTests.swiftGolden != nil))
    func swiftMatchesGolden() throws {
        #expect(Self.swiftDigest() == (try #require(Self.swiftGolden)))
    }

    @Test func captureSwiftDigest() {
        print("SCALE_BUCKET_SWIFT_FNV1A64 \(String(Self.swiftDigest(), radix: 16)) \(Self.platformTag)")
    }

    /// The 32-sample witness: equal weights, `-0` at index 26 among `+0`.
    /// The former C++ kernel selected `-0` on libc++ and `+0` on libstdc++. The Swift result is the
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