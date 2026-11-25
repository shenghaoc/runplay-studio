internal import CxxStdlib
import RunPlayEngine
internal import RunPlayEngineCpp
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

@Suite(.serialized)
struct ElevationProfileDifferentialTests {
    private static let cppGolden: UInt64? = {
        #if os(macOS) && arch(arm64)
        0xd785f68271f42c6d
        #elseif os(Linux) && arch(x86_64)
        // Captured from the C++ oracle in hosted Linux CI run 45327248501.
        0xd785f68271f42c6d
        #else
        nil
        #endif
    }()

    private struct Row: Equatable {
        var altitude: UInt64
        var ascent: UInt64
        var descent: UInt64
        var signed: UInt64
        var intervals: UInt64
        var run: Int32
        var reliableRun: Int32
        var present: UInt8
        var rejected: UInt8
    }

    private struct Observation: Equatable {
        var status: UInt8
        var rejected: UInt64 = 0
        var runs: UInt64 = 0
        var reliableRuns: UInt64 = 0
        var meaningful: UInt8 = 0
        var ascent: UInt64 = 0
        var descent: UInt64 = 0
        var rows: [Row] = []
    }

    @Test func comparesNativeOutputs() {
        var nativeDigest = FNV1a64()
        fixtures { label, samples, policy in
            let native = Self.cpp(samples, policy)
            let swift = Self.swift(samples, policy)
            #expect(native.untouched, Comment(rawValue: label))
            #expect(native.validCounts, Comment(rawValue: label))
            let equal = native.value == swift
            #expect(equal, Comment(rawValue: label))
            Self.append(native.value, into: &nativeDigest)
        }
        print("ELEVATION_PROFILE_CPP_GOLDEN=\(String(nativeDigest.value, radix: 16))")
    }

    @Test(.enabled(if: cppGolden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        let expected = try #require(Self.cppGolden)
        var digest = FNV1a64()
        fixtures { _, samples, policy in
            Self.append(Self.swift(samples, policy), into: &digest)
        }
        #expect(digest.value == expected)
    }

    private static func append(_ value: Observation, into digest: inout FNV1a64) {
        digest.append(byte: value.status)
        digest.append(word: value.rejected)
        digest.append(word: value.runs)
        digest.append(word: value.reliableRuns)
        digest.append(byte: value.meaningful)
        digest.append(word: value.ascent)
        digest.append(word: value.descent)
        digest.append(word: UInt64(value.rows.count))
        for row in value.rows {
            digest.append(word: row.altitude)
            digest.append(word: row.ascent)
            digest.append(word: row.descent)
            digest.append(word: row.signed)
            digest.append(word: row.intervals)
            digest.append(word: UInt64(UInt32(bitPattern: row.run)))
            digest.append(word: UInt64(UInt32(bitPattern: row.reliableRun)))
            digest.append(byte: row.present)
            digest.append(byte: row.rejected)
        }
    }

    private static func swift(_ samples: [EngineElevationProfileInput],
                              _ policy: EngineElevationProfilePolicy) -> Observation {
        do throws(ElevationProfileError) {
            let result = try EngineElevationProfile.build(samples: samples.span, policy: policy)
            return .init(status: 0, rejected: UInt64(result.rejectedAltitudeCount),
                         runs: UInt64(result.runCount), reliableRuns: UInt64(result.reliableRunCount),
                         meaningful: result.hasMeaningfulElevation ? 1 : 0,
                         ascent: result.totalAscentMeters.bitPattern, descent: result.totalDescentMeters.bitPattern,
                         rows: result.samples.map {
                Row(altitude: $0.correctedAltitudeMeters.bitPattern, ascent: $0.cumulativeAscentMeters.bitPattern,
                    descent: $0.cumulativeDescentMeters.bitPattern, signed: $0.cumulativeSignedChangeMeters.bitPattern,
                    intervals: $0.reliableIntervalCount.bitPattern, run: $0.runIdentifier, reliableRun: $0.reliableRunIdentifier,
                    present: $0.hasCorrectedAltitude ? 1 : 0, rejected: $0.sourceAltitudeWasRejected ? 1 : 0)
            })
        } catch {
            switch error {
            case .invalidPolicy: return .init(status: 4)
            case .invalidInputContract: return .init(status: 5)
            case .resourceLimit: return .init(status: 6)
            }
        }
    }

    private static func cpp(_ samples: [EngineElevationProfileInput],
                            _ policy: EngineElevationProfilePolicy) -> (value: Observation, untouched: Bool, validCounts: Bool) {
        let inputs = samples.map { sample in
            var value = runplay.ElevationProfileInputSample()
            value.distance_meters = sample.distanceMeters
            value.altitude_meters = sample.altitudeMeters
            value.continuity_group = sample.continuityGroup
            value.has_altitude = sample.hasAltitude
            return value
        }
        var cppPolicy = runplay.ElevationProfilePolicy()
        cppPolicy.plausible_altitude_minimum_meters = policy.plausibleAltitudeMinimumMeters
        cppPolicy.plausible_altitude_maximum_meters = policy.plausibleAltitudeMaximumMeters
        cppPolicy.spike_minimum_deviation_meters = policy.spikeMinimumDeviationMeters
        cppPolicy.short_excursion_minimum_deviation_meters = policy.shortExcursionMinimumDeviationMeters
        cppPolicy.short_excursion_maximum_sample_count = policy.shortExcursionMaximumSampleCount
        cppPolicy.spike_maximum_neighbor_difference_meters = policy.spikeMaximumNeighborDifferenceMeters
        cppPolicy.spike_maximum_horizontal_span_meters = policy.spikeMaximumHorizontalSpanMeters
        cppPolicy.smoothing_radius_meters = policy.smoothingRadiusMeters
        cppPolicy.minimum_reliable_sample_count = policy.minimumReliableSampleCount
        cppPolicy.gain_loss_deadband_meters = policy.gainLossDeadbandMeters
        var sentinel = runplay.ElevationProfileOutputSample()
        sentinel.corrected_altitude_meters = 12345
        sentinel.cumulative_ascent_meters = 99
        sentinel.cumulative_descent_meters = 88
        sentinel.cumulative_signed_change_meters = 77
        sentinel.reliable_interval_count = 66
        sentinel.run_identifier = 42
        sentinel.reliable_run_identifier = 42
        sentinel.has_corrected_altitude = 7
        sentinel.source_altitude_was_rejected = 7
        func row(_ value: runplay.ElevationProfileOutputSample) -> Row {
            Row(altitude: value.corrected_altitude_meters.bitPattern, ascent: value.cumulative_ascent_meters.bitPattern,
                descent: value.cumulative_descent_meters.bitPattern, signed: value.cumulative_signed_change_meters.bitPattern,
                intervals: value.reliable_interval_count.bitPattern, run: value.run_identifier,
                reliableRun: value.reliable_run_identifier, present: value.has_corrected_altitude,
                rejected: value.source_altitude_was_rejected)
        }
        var output = Array(repeating: sentinel, count: samples.count)
        let summary = inputs.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { buffer in
                runplay.build_elevation_profile(input.baseAddress, input.count, cppPolicy, buffer.baseAddress, buffer.count)
            }
        }
        let success = summary.status == .success
        let status: UInt8
        switch summary.status {
        case .success: status = 0
        case .invalid_input_buffer: status = 1
        case .invalid_output_buffer: status = 2
        case .insufficient_output_capacity: status = 3
        case .invalid_policy: status = 4
        case .invalid_input_contract: status = 5
        case .resource_limit: status = 6
        case .internal_failure: status = 7
        default: status = 255
        }
        let value = Observation(status: status, rejected: summary.rejected_altitude_count, runs: summary.run_count,
                                reliableRuns: summary.reliable_run_count, meaningful: summary.has_meaningful_elevation,
                                ascent: summary.total_ascent_meters.bitPattern, descent: summary.total_descent_meters.bitPattern,
                                rows: success ? output.map(row) : [])
        let untouched = success || output.allSatisfy { row($0) == row(sentinel) }
        let validCounts = summary.sample_count == (success ? UInt64(samples.count) : 0)
            && summary.required_output_capacity == UInt64(samples.count)
        return (value, untouched, validCounts)
    }

    private func fixtures(_ visit: (String, [EngineElevationProfileInput], EngineElevationProfilePolicy) -> Void) {
        func policy(low: Double = -500, smoothing: Double = 15) -> EngineElevationProfilePolicy {
            .init(plausibleAltitudeMinimumMeters: low, plausibleAltitudeMaximumMeters: 9_000,
                  spikeMinimumDeviationMeters: 35, shortExcursionMinimumDeviationMeters: 100,
                  shortExcursionMaximumSampleCount: 2, spikeMaximumNeighborDifferenceMeters: 12,
                  spikeMaximumHorizontalSpanMeters: 150, smoothingRadiusMeters: smoothing,
                  minimumReliableSampleCount: 2, gainLossDeadbandMeters: 3)
        }
        func sample(_ distance: Double, _ altitude: Double, _ group: Int32 = 0, _ present: UInt8 = 1)
            -> EngineElevationProfileInput {
            .init(distanceMeters: distance, altitudeMeters: altitude, continuityGroup: group, hasAltitude: present)
        }
        visit("empty beats invalid policy", [], policy(low: .nan))
        visit("one", [sample(0, 100)], policy())
        visit("invalid policy", [sample(0, 100)], policy(low: .nan))
        visit("presence byte", [sample(0, 100, 0, 2)], policy())
        visit("group jump", [sample(0, 100), sample(1, 100, 2)], policy())
        visit("specials and boundaries", [sample(0, -500), sample(10, 9_000), sample(20, .nan), sample(.nan, .infinity),
              sample(.infinity, -.infinity), sample(-.infinity, 0, 1, 0),
              sample(.leastNonzeroMagnitude, -.leastNonzeroMagnitude, 1), sample(-0.0, -0.0, 1)], policy())
        visit("distance-weighted fill", [sample(0, 100), sample(5, 200), sample(20, 110), sample(30, 111)], policy(smoothing: 0))
        visit("short excursion", [sample(0, 100), sample(10, 101), sample(20, 220), sample(30, 225),
                                   sample(40, 102), sample(50, 103)], policy())
        visit("DEM/recorded break", [sample(0, 100), sample(10, 100), sample(20, 1_100, 1),
                                     sample(30, 1_100, 1)], policy())

        var random = SplitMix64(seed: 0x7E57_4205)
        for count in [37, 1_000, 10_000, 1_000_000, EngineRouteLimits.maxRouteInputSamples,
                      EngineRouteLimits.maxRouteInputSamples + 1] {
            let samples = (0..<count).map { index in
                let jitter = Double(random.next() % 500) * 0.01
                let altitude = 100 + Double(index % 500) * 0.02 + jitter
                return sample(Double(index) * 3, altitude, Int32(index / 1_000), index.isMultiple(of: 47) ? 0 : 1)
            }
            visit("seeded \(count)", samples, policy())
        }
    }
}
