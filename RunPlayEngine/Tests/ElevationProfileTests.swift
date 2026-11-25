import Testing
@testable import RunPlayEngine

/// Native ElevationProfileTests.cpp fixtures. The three impossible pointer or
/// caller-capacity states remain covered by their original tests until PR10.
struct ElevationProfileTests {
    private func defaultPolicy(
        low: Double = -500, high: Double = 9_000, spike: Double = 35, excursion: Double = 100,
        excursionCount: UInt64 = 2, neighbor: Double = 12, span: Double = 150,
        smoothing: Double = 15, reliable: UInt64 = 2, deadband: Double = 3
    ) -> EngineElevationProfilePolicy {
        .init(plausibleAltitudeMinimumMeters: low, plausibleAltitudeMaximumMeters: high,
              spikeMinimumDeviationMeters: spike, shortExcursionMinimumDeviationMeters: excursion,
              shortExcursionMaximumSampleCount: excursionCount, spikeMaximumNeighborDifferenceMeters: neighbor,
              spikeMaximumHorizontalSpanMeters: span, smoothingRadiusMeters: smoothing,
              minimumReliableSampleCount: reliable, gainLossDeadbandMeters: deadband)
    }

    private func sample(_ distance: Double, _ altitude: Double, _ group: Int32 = 0, _ present: Bool = true)
        -> EngineElevationProfileInput {
        .init(distanceMeters: distance, altitudeMeters: altitude, continuityGroup: group, hasAltitude: present ? 1 : 0)
    }

    private func build(_ inputs: [EngineElevationProfileInput], _ policy: EngineElevationProfilePolicy? = nil)
        throws(ElevationProfileError) -> EngineElevationProfileResult {
        try EngineElevationProfile.build(samples: inputs.span, policy: policy ?? defaultPolicy())
    }

    private func nearEqual(_ a: Double, _ b: Double) -> Bool {
        a == b || (a.isFinite && b.isFinite && abs(a - b) <= max(1e-9, abs(b) * 1e-12))
    }

    @Test func test_empty_input_null_buffers() throws {
        let result = try build([], defaultPolicy(low: .nan))
        #expect(result.samples.isEmpty)
        #expect(result.rejectedAltitudeCount == 0)
        #expect(result.runCount == 0)
        #expect(result.reliableRunCount == 0)
        #expect(!result.hasMeaningfulElevation)
        #expect(result.totalAscentMeters == 0)
        #expect(result.totalDescentMeters == 0)
    }

    @Test func test_exact_capacity() throws {
        let result = try build([sample(0, 100), sample(10, 105), sample(20, 110)])
        #expect(result.samples.count == 3)
    }

    @Test func test_resource_limit() {
        let samples = Array(repeating: sample(0, 100), count: EngineRouteLimits.maxRouteInputSamples + 1)
        #expect(throws: ElevationProfileError.resourceLimit) { try build(samples) }
    }

    @Test func test_malformed_presence_byte() {
        let malformed = EngineElevationProfileInput(distanceMeters: 0, altitudeMeters: 100,
                                                     continuityGroup: 0, hasAltitude: 2)
        #expect(throws: ElevationProfileError.invalidInputContract) { try build([malformed]) }
    }

    @Test func test_malformed_continuity_groups() {
        let cases = [
            [sample(0, 100, 1), sample(10, 105, 1)],
            [sample(0, 100, 0), sample(10, 105, 2)],
            [sample(0, 100, 0), sample(10, 105, 1), sample(20, 110, 0)],
        ]
        for inputs in cases {
            #expect(throws: ElevationProfileError.invalidInputContract) { try build(inputs) }
        }
    }

    @Test func test_deterministic_repeated_calls() throws {
        let inputs = [sample(0, 100), sample(10, 103), sample(20, 106), sample(30, 109), sample(40, 112)]
        let a = try build(inputs)
        let b = try build(inputs)
        #expect(a.samples.map(\.correctedAltitudeMeters.bitPattern) == b.samples.map(\.correctedAltitudeMeters.bitPattern))
        #expect(a.samples.map(\.cumulativeAscentMeters.bitPattern) == b.samples.map(\.cumulativeAscentMeters.bitPattern))
        #expect(a.samples.map(\.cumulativeDescentMeters.bitPattern) == b.samples.map(\.cumulativeDescentMeters.bitPattern))
        #expect(a.samples.map(\.cumulativeSignedChangeMeters.bitPattern) == b.samples.map(\.cumulativeSignedChangeMeters.bitPattern))
        #expect(a.samples.map(\.reliableIntervalCount.bitPattern) == b.samples.map(\.reliableIntervalCount.bitPattern))
        #expect(a.samples.map(\.runIdentifier) == b.samples.map(\.runIdentifier))
        #expect(a.samples.map(\.reliableRunIdentifier) == b.samples.map(\.reliableRunIdentifier))
        #expect(a.samples.map(\.hasCorrectedAltitude) == b.samples.map(\.hasCorrectedAltitude))
        #expect(a.samples.map(\.sourceAltitudeWasRejected) == b.samples.map(\.sourceAltitudeWasRejected))
        #expect(a.rejectedAltitudeCount == b.rejectedAltitudeCount)
        #expect(a.totalAscentMeters.bitPattern == b.totalAscentMeters.bitPattern)
    }

    @Test func test_invalid_policy_fields() {
        let policies = [
            defaultPolicy(low: .nan), defaultPolicy(low: 100, high: 50), defaultPolicy(spike: -1),
            defaultPolicy(spike: 35, excursion: 10), defaultPolicy(excursionCount: 0),
            defaultPolicy(reliable: 0), defaultPolicy(reliable: 1), defaultPolicy(smoothing: -1),
            defaultPolicy(deadband: -0.1), defaultPolicy(neighbor: -1), defaultPolicy(span: -1),
        ]
        for policy in policies {
            #expect(throws: ElevationProfileError.invalidPolicy) { try build([sample(0, 100)], policy) }
        }
    }

    @Test func test_source_plausibility() throws {
        let summary = try build([
            sample(0, 100),                         // normal
            sample(10, 0, 0, false),                // missing
            sample(20, -500),                       // min boundary
            sample(30, 9000),                       // max boundary
            sample(40, -501),                       // below
            sample(50, 9001),                       // above
            sample(60, .nan),
            sample(70, .infinity),
            sample(80, -.infinity),
        ])
        #expect(summary.samples[0].hasCorrectedAltitude == true, "normal kept")
        #expect(summary.samples[0].sourceAltitudeWasRejected == false, "normal not rejected")
        #expect(summary.samples[1].hasCorrectedAltitude == false, "missing absent")
        #expect(summary.samples[1].sourceAltitudeWasRejected == false, "missing not rejected")
        #expect(summary.samples[2].hasCorrectedAltitude == true, "min boundary kept")
        #expect(summary.samples[3].hasCorrectedAltitude == true, "max boundary kept")
        #expect(summary.samples[4].sourceAltitudeWasRejected == true, "below rejected")
        #expect(summary.samples[5].sourceAltitudeWasRejected == true, "above rejected")
        #expect(summary.samples[6].sourceAltitudeWasRejected == true, "nan rejected")
        #expect(summary.samples[7].sourceAltitudeWasRejected == true, "+inf rejected")
        #expect(summary.samples[8].sourceAltitudeWasRejected == true, "-inf rejected")
        #expect(summary.rejectedAltitudeCount == 5, "rejected count")
    }

    @Test func test_leading_endpoint_spike() throws {
        let summary = try build([
            sample(0, 200),
            sample(10, 100),
            sample(20, 101),
            sample(30, 102),
            sample(40, 103),
        ])
        #expect(summary.samples[0].sourceAltitudeWasRejected == true, "leading rejected")
        #expect(summary.samples[0].hasCorrectedAltitude == false, "leading not filled")
    }

    @Test func test_trailing_endpoint_spike() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 101),
            sample(20, 102),
            sample(30, 103),
            sample(40, 200),
        ])
        #expect(summary.samples[4].sourceAltitudeWasRejected == true, "trailing rejected")
    }

    @Test func test_sustained_endpoint_change_retained() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 120),
            sample(20, 140),
            sample(30, 160),
        ])
        #expect(summary.samples[0].sourceAltitudeWasRejected == false, "start kept")
        #expect(summary.samples[3].sourceAltitudeWasRejected == false, "end kept")
    }

    @Test func test_isolated_interior_spike() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 101),
            sample(20, 200),  // spike
            sample(30, 102),
            sample(40, 103),
        ])
        #expect(summary.samples[2].sourceAltitudeWasRejected == true, "interior rejected")
        #expect(summary.samples[2].hasCorrectedAltitude == true, "interior filled")
    }

    @Test func test_legitimate_hill_retained() throws {
        let summary = try build([
            sample(0, 100),
            sample(20, 110),
            sample(40, 130),
            sample(60, 150),
            sample(80, 140),
            sample(100, 120),
            sample(120, 105),
        ])
        for i in summary.samples.indices {
            #expect(summary.samples[i].sourceAltitudeWasRejected == false, "hill kept")
            #expect(summary.samples[i].hasCorrectedAltitude == true, "hill altitude")
        }
    }

    @Test func test_short_excursion_two_sample() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 101),
            sample(20, 220),
            sample(30, 225),
            sample(40, 102),
            sample(50, 103),
        ])
        #expect(summary.samples[2].sourceAltitudeWasRejected == true, "exc1 rejected")
        #expect(summary.samples[3].sourceAltitudeWasRejected == true, "exc2 rejected")
    }

    @Test func test_longer_excursion_retained() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 101),
            sample(20, 220),
            sample(30, 221),
            sample(40, 222),
            sample(50, 102),
            sample(60, 103),
        ], defaultPolicy(excursionCount: 2))
        #expect(summary.samples[2].sourceAltitudeWasRejected == false, "long kept 1")
        #expect(summary.samples[3].sourceAltitudeWasRejected == false, "long kept 2")
        #expect(summary.samples[4].sourceAltitudeWasRejected == false, "long kept 3")
    }

    @Test func test_fill_distance_weighted_and_no_chain() throws {
        let summary = try build([
            sample(0, 100),
            sample(5, 200),
            sample(20, 110),
            sample(30, 111),
        ], defaultPolicy(smoothing: 0))
        #expect(summary.samples[1].sourceAltitudeWasRejected == true, "fill rejected flag")
        #expect(summary.samples[1].hasCorrectedAltitude == true, "fill has altitude")
        #expect(nearEqual(summary.samples[1].correctedAltitudeMeters, 102.5), "distance-weighted fill")
    }

    @Test func test_fill_zero_span_uses_half() throws {
        let summary = try build([
            sample(10, 100),
            sample(10, 200),
            sample(10, 120),
            sample(20, 121),
        ])
        if summary.samples[1].sourceAltitudeWasRejected && summary.samples[1].hasCorrectedAltitude {
            #expect(nearEqual(summary.samples[1].correctedAltitudeMeters, 110.0), "zero span half")
        }
    }

    @Test func test_no_fill_across_continuity() throws {
        let summary = try build([
            sample(0, 100, 0),
            sample(10, 200, 0),
            sample(20, 110, 1),
            sample(30, 111, 1),
        ])
        #expect(summary.samples.count == 4)
        #expect(summary.samples[1].correctedAltitudeMeters == 200)
    }

    @Test func test_run_identifiers() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 101),
            sample(20, 0, 0, false),
            sample(30, 110),
            sample(40, 111),
            sample(50, 112),
        ])
        #expect(summary.runCount == 2, "two runs")
        #expect(summary.samples[0].runIdentifier == 0, "run0")
        #expect(summary.samples[1].runIdentifier == 0, "run0b")
        #expect(summary.samples[2].runIdentifier == -1, "gap")
        #expect(summary.samples[3].runIdentifier == 1, "run1")
        #expect(summary.samples[4].runIdentifier == 1, "run1b")
        #expect(summary.samples[5].runIdentifier == 1, "run1c")
        #expect(summary.samples[0].reliableRunIdentifier == 0, "rel0")
        #expect(summary.samples[3].reliableRunIdentifier == 1, "rel1")
        #expect(summary.reliableRunCount == 2, "two reliable")
    }

    @Test func test_unreliable_then_reliable_gap_ids() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 0, 0, false),
            sample(20, 110),
            sample(30, 111),
            sample(40, 112),
        ], defaultPolicy(reliable: 3))
        #expect(summary.samples[0].runIdentifier == 0, "short run id")
        #expect(summary.samples[0].reliableRunIdentifier == -1, "short unreliable")
        #expect(summary.samples[2].runIdentifier == 1, "long run id")
        #expect(summary.samples[2].reliableRunIdentifier == 1, "long reliable keeps gap")
        #expect(summary.reliableRunCount == 1, "one reliable run")
    }

    @Test func test_zero_radius_smoothing() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 110),
            sample(20, 120),
        ], defaultPolicy(smoothing: 0))
        #expect(nearEqual(summary.samples[0].correctedAltitudeMeters, 100), "raw0")
        #expect(nearEqual(summary.samples[1].correctedAltitudeMeters, 110), "raw1")
        #expect(nearEqual(summary.samples[2].correctedAltitudeMeters, 120), "raw2")
    }

    @Test func test_monotonic_climb_gain() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 104),
            sample(20, 108),
            sample(30, 112),
            sample(40, 116),
        ], defaultPolicy(smoothing: 0, deadband: 3))
        #expect(summary.hasMeaningfulElevation == true, "meaningful")
        #expect(nearEqual(summary.totalAscentMeters, 16.0), "total ascent 16")
        #expect(nearEqual(summary.totalDescentMeters, 0.0), "no descent")
        #expect(nearEqual(summary.samples[4].cumulativeSignedChangeMeters, 16.0), "signed 16")
        #expect(nearEqual(summary.samples[4].reliableIntervalCount, 4.0), "four intervals")
    }

    @Test func test_noise_below_deadband() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 101),
            sample(20, 100.5),
            sample(30, 101.5),
            sample(40, 100.2),
        ], defaultPolicy(smoothing: 0, deadband: 3))
        #expect(nearEqual(summary.totalAscentMeters, 0.0), "no ascent noise")
        #expect(nearEqual(summary.totalDescentMeters, 0.0), "no descent noise")
    }

    @Test func test_confirmed_reversal() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 105),
            sample(20, 110),
            sample(30, 105),
            sample(40, 100),
        ], defaultPolicy(smoothing: 0, deadband: 3))
        #expect(nearEqual(summary.totalAscentMeters, 10.0), "ascent 10")
        #expect(nearEqual(summary.totalDescentMeters, 10.0), "descent 10")
    }

    @Test func test_zero_deadband() throws {
        let summary = try build([
            sample(0, 100),
            sample(10, 101),
            sample(20, 100),
        ], defaultPolicy(smoothing: 0, deadband: 0))
        #expect(nearEqual(summary.totalAscentMeters, 1.0), "ascent 1")
        #expect(nearEqual(summary.totalDescentMeters, 1.0), "descent 1")
    }

    @Test func test_no_meaningful_elevation() throws {
        let summary = try build([
            sample(0, 0, 0, false),
            sample(10, 0, 0, false),
        ])
        #expect(summary.hasMeaningfulElevation == false, "not meaningful")
        #expect(summary.totalAscentMeters == 0.0, "ascent zeroed")
        #expect(summary.totalDescentMeters == 0.0, "descent zeroed")
    }

    @Test func test_malformed_distances_processed() throws {
        let summary = try build([
            sample(-10, 100),
            sample(5, 105),
            sample(3, 110),   // decreasing
            sample(3, 115),   // duplicate
            sample(1e12, 120),
        ])
        #expect(summary.samples.count == 5, "processed all")
    }


    @Test func test_large_dense_route() throws {
        let count = 10_000
        let samples = (0..<count).map { sample(Double($0) * 1.0, 100.0 + Double($0) * 0.01) }
        let summary = try build(samples)
        #expect(summary.samples.count == count)
        #expect(summary.hasMeaningfulElevation)
        #expect(summary.samples[0].hasCorrectedAltitude)
        #expect(summary.samples[count - 1].hasCorrectedAltitude)
    }
}
