#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif
import RunPlayEngine
import Testing

@Suite struct TrainingLoadTests {
    private static let referencePolicy = TrainingLoadPolicy(
        restingHeartRateBPM: 50, maximumHeartRateBPM: 150,
        coefficientMultiplier: 0.64, coefficientExponent: 1.92,
        zoneLowerBoundsBPM: [0, 100, 120, 140, 160]
    )

    private func sample(_ rate: Double, _ seconds: Double) -> TrainingLoadSample {
        TrainingLoadSample(heartRateBPM: rate, weightSeconds: seconds, hasHeartRate: 1)
    }

    private func missing(_ seconds: Double) -> TrainingLoadSample {
        TrainingLoadSample(heartRateBPM: 0, weightSeconds: seconds, hasHeartRate: 0)
    }

    private func compute(
        _ samples: [TrainingLoadSample],
        policy: TrainingLoadPolicy = referencePolicy
    ) throws(TrainingLoadError) -> TrainingLoadSummary {
        try TrainingLoadKernel.compute(samples.span, policy: policy)
    }

    private func near(
        _ actual: Double,
        _ expected: Double,
        _ tolerance: Double = 1e-12,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) <= tolerance * (expected > 0 ? expected : 1),
                sourceLocation: sourceLocation)
    }

    @Test func test_single_interval_hand_computed() throws {
        let summary = try compute([sample(100, 60)])
        near(summary.totalTRIMP, 0.32 * exp(1.92 * 0.5))
        near(summary.totalTRIMP, 0.835_742_871_496_999_0, 1e-9)
        #expect(summary.meanHeartRateBPM == 100)
        #expect(summary.hasMeanHeartRate == 1)
        #expect(summary.validHeartRateSeconds == 60)
        #expect(summary.coveredSeconds == 60)
        #expect(summary.validIntervalCount == 1)
        #expect(summary.totalIntervalCount == 1)
        #expect(summary.zoneSeconds[1] == 60)
    }

    @Test func test_steady_hour_scales_linearly() throws {
        near(try compute([sample(100, 3600)]).totalTRIMP, 19.2 * exp(0.96))
    }

    @Test func test_mixed_intervals_sum() throws {
        let summary = try compute([sample(100, 600), sample(130, 600)])
        let easy = 10.0 * 0.5 * 0.64 * exp(1.92 * 0.5)
        let hard = 10.0 * 0.8 * 0.64 * exp(1.92 * 0.8)
        near(summary.totalTRIMP, easy + hard)
        near(summary.meanHeartRateBPM, 115)
        #expect(summary.zoneSeconds[1] == 600)
        #expect(summary.zoneSeconds[2] == 600)
    }

    @Test func test_zone_boundaries() throws {
        let summary = try compute([
            sample(95, 100), sample(100, 10), sample(119, 20), sample(120, 30), sample(139, 40),
            sample(140, 50), sample(159, 60), sample(160, 70), sample(200, 80), sample(30, 90),
        ])
        let zone = summary.zoneSeconds
        #expect(zone[0] == 190)
        #expect(zone[1] == 30)
        #expect(zone[2] == 70)
        #expect(zone[3] == 110)
        #expect(zone[4] == 150)
        let sum = zone[0] + zone[1] + zone[2] + zone[3] + zone[4]
        #expect(sum == summary.validHeartRateSeconds)
    }

    @Test func test_nonzero_zone1_floor() throws {
        var policy = Self.referencePolicy
        policy.zoneLowerBoundsBPM = [100, 110, 120, 130, 140]
        let summary = try compute([sample(50, 30), sample(145, 30)], policy: policy)
        #expect(summary.zoneSeconds[0] == 30)
        #expect(summary.zoneSeconds[4] == 30)
    }

    @Test func test_hr_gap_intervals() throws {
        let summary = try compute([sample(100, 300), missing(120), sample(140, 300)])
        #expect(summary.coveredSeconds == 720)
        #expect(summary.validHeartRateSeconds == 600)
        #expect(summary.validIntervalCount == 2)
        #expect(summary.totalIntervalCount == 3)
        near(summary.meanHeartRateBPM, 120)
        let easy = 5.0 * 0.5 * 0.64 * exp(0.96)
        let threshold = 5.0 * 0.9 * 0.64 * exp(1.92 * 0.9)
        near(summary.totalTRIMP, easy + threshold)
    }

    @Test func test_zero_weight_intervals() throws {
        for weight in [0.0, -0.0] {
            let summary = try compute([sample(100, weight), missing(weight)])
            #expect(summary.totalIntervalCount == 2)
            #expect(summary.validIntervalCount == 1)
            #expect(summary.coveredSeconds.bitPattern == 0)
            #expect(summary.totalTRIMP.bitPattern == 0)
            #expect(summary.hasMeanHeartRate == 0)
        }
    }

    @Test func test_reserve_clamping() throws {
        let below = try compute([sample(40, 600)])
        #expect(below.totalTRIMP == 0)
        #expect(below.validHeartRateSeconds == 600)
        #expect(below.zoneSeconds[0] == 600)

        let above = try compute([sample(200, 600)])
        near(above.totalTRIMP, 10.0 * 1.0 * 0.64 * exp(1.92))
    }

    @Test func test_empty_input() throws {
        let summary = try compute([])
        #expect(summary.totalTRIMP == 0)
        #expect(summary.hasMeanHeartRate == 0)
        #expect(summary.totalIntervalCount == 0)
    }

    @Test func test_female_coefficients() throws {
        var policy = Self.referencePolicy
        policy.coefficientMultiplier = 0.86
        policy.coefficientExponent = 1.67
        near(try compute([sample(100, 60)], policy: policy).totalTRIMP, 0.5 * 0.86 * exp(1.67 * 0.5))
    }

    @Test func test_invalid_policies() {
        let mutations: [(inout TrainingLoadPolicy) -> Void] = [
            { $0.restingHeartRateBPM = 160 },
            { $0.restingHeartRateBPM = 0 },
            { $0.maximumHeartRateBPM = .nan },
            { $0.coefficientMultiplier = 0 },
            { $0.coefficientMultiplier = -0.64 },
            { $0.coefficientExponent = 0 },
            { $0.zoneLowerBoundsBPM[2] = .nan },
            { $0.zoneLowerBoundsBPM[0] = 100 },
            { $0.zoneLowerBoundsBPM[3] = 130; $0.zoneLowerBoundsBPM[2] = 135 },
        ]
        for mutate in mutations {
            var policy = Self.referencePolicy
            mutate(&policy)
            #expect(throws: TrainingLoadError.invalidPolicy) { try compute([sample(100, 60)], policy: policy) }
        }
    }

    @Test func test_invalid_input_contracts() throws {
        let nonfinite: [Double] = [.infinity, -.infinity, .nan, -.nan, .signalingNaN, -.signalingNaN]
        for value in nonfinite {
            #expect(throws: TrainingLoadError.invalidInputContract) { try compute([sample(100, value)]) }
            #expect(throws: TrainingLoadError.invalidInputContract) { try compute([sample(value, 60)]) }
        }
        for input in [
            sample(100, -1), sample(100, -.leastNonzeroMagnitude),
            TrainingLoadSample(heartRateBPM: 100, weightSeconds: 60, hasHeartRate: 2),
            sample(0, 60), sample(-0.0, 60), sample(-5, 60),
        ] {
            #expect(throws: TrainingLoadError.invalidInputContract) { try compute([input]) }
        }
        let extremes = try compute([
            sample(.leastNonzeroMagnitude, .leastNonzeroMagnitude),
            sample(.greatestFiniteMagnitude, 0),
            missing(.greatestFiniteMagnitude),
        ])
        #expect(extremes.totalIntervalCount == 3)
        #expect(extremes.validIntervalCount == 2)
        #expect(extremes.coveredSeconds == .greatestFiniteMagnitude)
        #expect(extremes.validHeartRateSeconds == .leastNonzeroMagnitude)
    }

    @Test func test_error_after_partial_pass() {
        #expect(throws: TrainingLoadError.invalidInputContract) {
            try compute([sample(100, 600), missing(60), sample(.nan, 60)])
        }
    }

    @Test func test_fractional_weights() throws {
        near(try compute([sample(100, 0.5)]).totalTRIMP, (0.5 / 60) * 0.5 * 0.64 * exp(0.96))
    }
}
