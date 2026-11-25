import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

@Suite struct TrainingLoadGoldenTests {
    private typealias Parity = TrainingLoadParity

    private static func corpus() -> [([Parity.Sample], Parity.Policy)] {
        let policy = Parity.Policy()
        var female = policy
        female.multiplier = 0.86
        female.exponent = 1.67
        var floor = policy
        floor.zones = [100, 110, 120, 130, 140]
        var invalid = policy
        invalid.zones[2] = .nan
        var fixtures: [([Parity.Sample], Parity.Policy)] = [
            ([], policy),
            ([.init(rate: 100, weight: 60)], policy),
            ([.init(rate: 100, weight: 3600)], policy),
            ([.init(rate: 100, weight: 600), .init(rate: 130, weight: 600)], policy),
            ([.init(rate: 50, weight: 30), .init(rate: 145, weight: 30)], floor),
            ([.init(rate: 100, weight: 300), .init(rate: 0, weight: 120, flag: 0),
              .init(rate: 140, weight: 300)], policy),
            ([.init(rate: 100, weight: 0), .init(rate: 0, weight: 0, flag: 0)], policy),
            ([.init(rate: 40, weight: 600), .init(rate: 200, weight: 600)], policy),
            ([.init(rate: 100, weight: 60)], female),
            ([.init(rate: 100, weight: 0.5)], policy),
            ([.init(rate: .nan, weight: 1, flag: 0)], policy),
            ([.init(rate: .leastNonzeroMagnitude, weight: .leastNonzeroMagnitude)], policy),
            ([.init(rate: 100, weight: .leastNonzeroMagnitude)], policy),
            ([.init(rate: 100, weight: 60), .init(rate: .nan, weight: 60)], policy),
            ([.init(rate: 100, weight: 60)], invalid),
            ([], invalid),
            ([.init(rate: 100, weight: 60, flag: 2)], policy),
        ]
        let zoneFixture: [(Double, Double)] = [
            (95, 100), (100, 10), (119, 20), (120, 30), (139, 40), (140, 50),
            (159, 60), (160, 70), (200, 80), (30, 90),
        ]
        fixtures.append((zoneFixture.map { .init(rate: $0.0, weight: $0.1) }, policy))
        for invalidValue: Double in [.nan, .infinity, -.infinity, -1] {
            fixtures.append(([.init(rate: 100, weight: invalidValue)], policy))
            fixtures.append(([.init(rate: invalidValue, weight: 1)], policy))
        }
        var generator = SplitMix64(seed: 0xb001_1158_ef00_4112)
        for count in [1, 2, 31, 2047, 2048, 2049, 32_000, 999_999, 1_000_000] {
            let samples = (0..<count).map { _ in
                let value = generator.next()
                return Parity.Sample(
                    rate: 20 + Double(value % 880) / 4,
                    weight: Double((value >> 12) % 100) / 8,
                    flag: value.isMultiple(of: 11) ? 0 : 1
                )
            }
            fixtures.append((samples, count.isMultiple(of: 2) ? female : policy))
        }
        return fixtures
    }

    private static func append(_ output: Parity.Output, to digest: inout FNV1a64) {
        digest.append(byte: output.status)
        for bits in output.numericBits { digest.append(word: bits) }
        digest.append(word: output.validCount)
        digest.append(word: output.totalCount)
        digest.append(byte: output.hasMean)
    }

    // Derived from the C++ kernel before its removal, for each supported
    // architecture/libm. The Swift kernel was asserted bit-identical to it.
    private static var golden: UInt64? {
        #if os(macOS) && arch(arm64)
        0x5f0b901dbff1e55f
        #elseif os(Linux) && arch(x86_64)
        // Independently captured from the native oracle in Linux CI run 45279292266.
        0x5f0b901dbff1e55f
        #else
        nil
        #endif
    }

    /// Fails when a platform condition leaves `golden` nil on a platform that
    /// pins it, which would otherwise disable the golden test silently.
    @Test func goldenIsPinnedOnPinnedPlatforms() {
        #expect(
            !GoldenPlatform.current.pinsKernelGoldens || Self.golden != nil,
            "\(GoldenPlatform.unpinnedMessage("golden"))"
        )
    }

    @Test(.enabled(if: TrainingLoadGoldenTests.golden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        let golden = try #require(Self.golden)
        var digest = FNV1a64()
        for (samples, policy) in Self.corpus() {
            Self.append(Parity.swift(samples, policy: policy), to: &digest)
        }
        #expect(digest.value == golden)
    }
}

/// Test-facing raw inputs and outputs for the golden corpus.
/// This bypasses Core's production input guards so kernel errors are observable.
private enum TrainingLoadParity {
    struct Sample {
        let rate: Double
        let weight: Double
        var flag: UInt8 = 1
    }

    struct Policy {
        var resting = 50.0
        var maximum = 150.0
        var multiplier = 0.64
        var exponent = 1.92
        var zones = [0.0, 100.0, 120.0, 140.0, 160.0]
    }

    struct Output {
        let status: UInt8
        // TRIMP, mean, five zones, valid seconds, covered seconds.
        let numericBits: [UInt64]
        let validCount: UInt64
        let totalCount: UInt64
        let hasMean: UInt8
    }

    static func swift(_ samples: [Sample], policy: Policy) -> Output {
        let input = samples.map {
            TrainingLoadSample(heartRateBPM: $0.rate, weightSeconds: $0.weight, hasHeartRate: $0.flag)
        }
        let policy = RunPlayEngine.TrainingLoadPolicy(
            restingHeartRateBPM: policy.resting, maximumHeartRateBPM: policy.maximum,
            coefficientMultiplier: policy.multiplier, coefficientExponent: policy.exponent,
            zoneLowerBoundsBPM: [policy.zones[0], policy.zones[1], policy.zones[2], policy.zones[3], policy.zones[4]]
        )
        do throws(TrainingLoadError) {
            let output = try TrainingLoadKernel.compute(input.span, policy: policy)
            return Output(
                status: 0,
                numericBits: [
                    output.totalTRIMP, output.meanHeartRateBPM, output.zoneSeconds[0],
                    output.zoneSeconds[1], output.zoneSeconds[2], output.zoneSeconds[3],
                    output.zoneSeconds[4], output.validHeartRateSeconds, output.coveredSeconds,
                ].map(\.bitPattern),
                validCount: output.validIntervalCount, totalCount: output.totalIntervalCount,
                hasMean: output.hasMeanHeartRate
            )
        } catch {
            let code: UInt8
            switch error {
            case .invalidPolicy: code = 2
            case .invalidInputContract: code = 3
            case .internalFailure: code = 4
            }
            return Output(
                status: code, numericBits: Array(repeating: 0, count: 9),
                validCount: 0, totalCount: 0, hasMean: 0
            )
        }
    }
}
