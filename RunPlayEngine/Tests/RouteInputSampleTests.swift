import Testing
@testable import RunPlayEngine

struct RouteInputSampleTests {
    // A fixture-only observation of the value where the old test exercised the now-dead C++ batch API.
    // No batch inspection, status or digest is exposed by the Swift engine.
    private func observe(_ samples: borrowing Span<EngineRouteInputSample>) -> Observation {
        var result = Observation(count: samples.count)
        for i in samples.indices {
            let sample = samples[i]
            if i > 0 && sample.routeSegmentIndex != samples[i - 1].routeSegmentIndex {
                result.transitions += 1
            }
            if i == 0 { result.first = sample.sourceIndex }
            result.last = sample.sourceIndex
            result.append(sample.sourceIndex)
            result.append(sample.timestampSecondsSinceReferenceDate.bitPattern)
            result.append(sample.latitude.bitPattern)
            result.append(sample.longitude.bitPattern)
            let fields = [
                sample.altitudeMeters, sample.demAltitudeMeters, sample.speedMetersPerSecond,
                sample.paceSecondsPerKilometer, sample.heartRateBPM, sample.cadence, sample.powerWatts,
                sample.groundContactTimeMilliseconds, sample.verticalOscillationMillimeters,
                sample.verticalRatioPercent, sample.stanceTimeBalancePercent, sample.stepLengthMeters,
                sample.horizontalAccuracy,
            ]
            for j in fields.indices {
                if j == 2 {
                    result.append(sample.distanceFromStartMeters.bitPattern)
                    result.append(sample.elapsedSeconds.bitPattern)
                }
                let value = fields[j]
                result.append(value == nil ? 0 : 1)
                if let value {
                    result.optionCounts[j] += 1
                    result.append(value.bitPattern)
                }
            }
            result.append(UInt64(bitPattern: sample.routeSegmentIndex))
        }
        return result
    }

    private struct Observation {
        var count: Int
        var first: UInt64?
        var last: UInt64?
        var transitions = 0
        var optionCounts = Array(repeating: 0, count: 13)
        var digest: UInt64 = 14_695_981_039_346_656_037

        mutating func append(_ word: UInt64) {
            digest = (digest ^ word) &* 1_099_511_628_211
        }
    }

    private func makeSample(
        _ source: UInt64, _ segment: Int64, altitude: Double? = nil, dem: Double? = nil
    ) -> EngineRouteInputSample {
        let scalar = Double(source)
        return EngineRouteInputSample(
            sourceIndex: source, timestampSecondsSinceReferenceDate: 1000.0 + scalar,
            latitude: 1.0 + scalar, longitude: -2.0 - scalar, altitudeMeters: altitude, demAltitudeMeters: dem,
            distanceFromStartMeters: 10.0 * scalar, elapsedSeconds: 2.0 * scalar, routeSegmentIndex: segment
        )
    }

    @Test func test_empty_batch() {
        let empty: [EngineRouteInputSample] = []
        let result = observe(empty.span)
        #expect(result.count == 0)
        #expect(result.optionCounts == Array(repeating: 0, count: 13))
        #expect(result.transitions == 0)
        #expect(result.first == nil)
        #expect(result.last == nil)
        #expect(result.digest == 14_695_981_039_346_656_037)
    }

    @Test func test_invalid_and_bounded_inputs() {
        // Null plus nonzero length, and a falsely oversized extent, cannot be made through a safe Span.
        // The two original C++ cases stay in RouteInteropTests.cpp until the C++ removal PR.
        #expect(EngineRouteLimits.maxRouteInputSamples == 1_250_000)
        let one = [makeSample(0, 0)]
        #expect(observe(one.span).count == 1)
    }

    @Test func test_complete_sample_and_explicit_digest() {
        let samples = [EngineRouteInputSample(
            sourceIndex: 7, timestampSecondsSinceReferenceDate: 123.5, latitude: 1.25, longitude: -2.5,
            altitudeMeters: 30.0, demAltitudeMeters: 28.75, distanceFromStartMeters: 100.0, elapsedSeconds: 20.0,
            speedMetersPerSecond: 5.0, paceSecondsPerKilometer: 200.0, heartRateBPM: 150.0, cadence: 180.0,
            powerWatts: 245.5, groundContactTimeMilliseconds: 251.25, verticalOscillationMillimeters: 9.75,
            verticalRatioPercent: 6.25, stanceTimeBalancePercent: 49.75, stepLengthMeters: 1.125,
            horizontalAccuracy: 3.0, routeSegmentIndex: -2
        )]
        let result = observe(samples.span)
        #expect(result.count == 1)
        #expect(result.optionCounts == Array(repeating: 1, count: 13))
        #expect(result.transitions == 0)
        #expect(result.first == 7)
        #expect(result.last == 7)
        #expect(result.digest == 13_922_378_483_449_810_303)
    }

    @Test func test_dem_altitude_participates_in_digest() {
        let a = [makeSample(3, 0)]
        let b = [makeSample(3, 0, dem: 0.0)]
        let c = [makeSample(3, 0, altitude: 41.5)]
        let d = [makeSample(3, 0, dem: 41.5)]
        let absent = observe(a.span)
        let zero = observe(b.span)
        let recordedTwin = observe(c.span)
        let demTwin = observe(d.span)
        #expect(absent.optionCounts[1] == 0)
        #expect(zero.optionCounts[1] == 1)
        #expect(demTwin.optionCounts[1] == 1)
        #expect(demTwin.optionCounts[0] == 0)
        #expect(absent.digest != zero.digest)
        #expect(recordedTwin.digest != demTwin.digest)
    }

    @Test func test_absent_optionals_and_segment_transitions() {
        let samples = [makeSample(0, 0), makeSample(1, 0), makeSample(2, 1),
                       makeSample(3, 1), makeSample(4, 1), makeSample(5, 2)]
        let first = observe(samples.span)
        let second = observe(samples.span)
        #expect(first.count == 6)
        #expect(first.optionCounts == Array(repeating: 0, count: 13))
        #expect(first.transitions == 2)
        #expect(first.first == 0)
        #expect(first.last == 5)
        #expect(first.digest == second.digest)
    }

    @Test func test_large_heap_backed_batch() {
        let count = 100_000
        let samples = (0..<count).map { makeSample(UInt64($0), Int64($0 / 25_000)) }
        let result = observe(samples.span)
        #expect(result.count == count)
        #expect(result.transitions == 3)
        #expect(result.first == 0)
        #expect(result.last == UInt64(count - 1))
    }
}
