import XCTest
@testable import RunPlayCore

final class TrainingLoadCalculatorTests: XCTestCase {

    private let profile = AthleteProfile(
        restingHeartRateBPM: 50,
        maximumHeartRateBPM: 150
    )

    /// Training load reads heart rate through `HeartRateSample`, the shape
    /// both representations reduce to, so these fixtures build samples
    /// directly rather than route points. A sample carries no coordinates:
    /// load is a function of time and rate alone.
    private func sample(
        elapsed: Double,
        rate: Double?,
        segment: Int = 0
    ) -> HeartRateSample {
        HeartRateSample(
            elapsedSeconds: elapsed,
            heartRateBPM: rate,
            segmentIndex: segment
        )
    }

    // MARK: - Measured loads

    /// 20 minutes of steady rate 100 (reserve exactly 0.5): TRIMP is
    /// 20 × 0.5 × 0.64 × e^0.96, matching the native fixture through the
    /// calculator's interval construction (mean of endpoint rates).
    func testMeasuredSteadyRun() throws {
        var samples: [HeartRateSample] = []
        for index in 0...40 {
            samples.append(sample(elapsed: Double(index) * 30, rate: 100))
        }
        let snapshot = try TrainingLoadCalculator.compute(
            heartRateSamples: samples,
            activeSeconds: 1_200,
            averageSpeedMetersPerSecond: 3,
            profile: profile,
            referenceYear: 2026
        )
        XCTAssertEqual(snapshot.kind, .measured)
        XCTAssertEqual(snapshot.banisterTRIMP, 20 * 0.5 * 0.64 * exp(0.96), accuracy: 1e-12)
        XCTAssertEqual(snapshot.validHeartRateSeconds, 1_200)
        XCTAssertEqual(snapshot.coveredActiveSeconds, 1_200)
        XCTAssertEqual(snapshot.meanHeartRateBPM, 100)
        XCTAssertEqual(snapshot.zoneSeconds, [0, 1_200, 0, 0, 0])
        XCTAssertNil(snapshot.estimateBasis)
        XCTAssertNil(snapshot.assumedHeartRateReserve)
        XCTAssertTrue(snapshot.isCurrent(for: profile))
        XCTAssertFalse(snapshot.isCurrent(for: AthleteProfile()))
    }

    /// A recording gap is a segment boundary: the interval between the last
    /// point of one segment and the first of the next carries no weight, so
    /// paused time adds nothing to covered or valid seconds.
    func testPauseSpanningSegmentsAddsNoWeight() throws {
        let samples = [
            sample(elapsed: 0, rate: 100),
            sample(elapsed: 600, rate: 100, segment: 0),
            sample(elapsed: 3_000, rate: 100, segment: 1),
            sample(elapsed: 3_600, rate: 100, segment: 1),
        ]
        let snapshot = try TrainingLoadCalculator.compute(
            heartRateSamples: samples,
            activeSeconds: 1_200,
            averageSpeedMetersPerSecond: 3,
            profile: profile,
            referenceYear: 2026
        )
        XCTAssertEqual(snapshot.kind, .measured)
        XCTAssertEqual(snapshot.coveredActiveSeconds, 1_200)
        XCTAssertEqual(snapshot.validHeartRateSeconds, 1_200)
        // 20 active minutes at reserve 0.5, none of the 40 paused minutes.
        XCTAssertEqual(snapshot.banisterTRIMP, 20 * 0.5 * 0.64 * exp(0.96), accuracy: 1e-12)
    }

    /// A heart-rate gap inside one segment: intervals touching missing rates
    /// contribute covered time but no load, exactly like the native no-rate
    /// fixtures. With default zones from maximum 150 the bounds are
    /// 0/90/105/120/135, so rate 100 sits in zone 2 and rate 140 in zone 5.
    func testHRGapWithinSegmentCountsAsCoveredOnly() throws {
        let samples = [
            sample(elapsed: 0, rate: 100),
            sample(elapsed: 600, rate: 100),
            sample(elapsed: 1_200, rate: nil),
            sample(elapsed: 1_800, rate: 140),
            sample(elapsed: 2_400, rate: 140),
        ]
        let snapshot = try TrainingLoadCalculator.compute(
            heartRateSamples: samples,
            activeSeconds: 2_400,
            averageSpeedMetersPerSecond: 3,
            profile: profile,
            referenceYear: 2026
        )
        XCTAssertEqual(snapshot.kind, .measured)
        // Valid intervals: 0–600 (mean 100) and 1800–2400 (mean 140); the
        // two gap intervals carry no rate. 1200 valid of 2400 covered is
        // exactly the 50% floor, which counts as measured.
        XCTAssertEqual(snapshot.coveredActiveSeconds, 2_400)
        XCTAssertEqual(snapshot.validHeartRateSeconds, 1_200)
        let easy = 10 * 0.5 * 0.64 * exp(0.96)
        let hard = 10 * 0.9 * 0.64 * exp(1.92 * 0.9)
        XCTAssertEqual(snapshot.banisterTRIMP, easy + hard, accuracy: 1e-12)
        XCTAssertEqual(snapshot.zoneSeconds, [0, 600, 0, 0, 600])
    }

    /// Below the absolute coverage floor (300 s) the load is estimated even
    /// at full relative coverage.
    func testShortRunFallsBackToEstimate() throws {
        let samples = [
            sample(elapsed: 0, rate: 100),
            sample(elapsed: 240, rate: 100),
        ]
        let snapshot = try TrainingLoadCalculator.compute(
            heartRateSamples: samples,
            activeSeconds: 240,
            averageSpeedMetersPerSecond: 3,
            profile: profile,
            referenceYear: 2026
        )
        XCTAssertEqual(snapshot.kind, .estimated)
        XCTAssertEqual(snapshot.estimateBasis, .paceDuration)
        XCTAssertEqual(snapshot.validHeartRateSeconds, 240)
        // 3 m/s = 10.8 km/h → 0.60 band.
        XCTAssertEqual(snapshot.assumedHeartRateReserve, 0.60)
        let minutes = 240.0 / 60
        XCTAssertEqual(snapshot.banisterTRIMP, minutes * 0.60 * 0.64 * exp(1.92 * 0.60), accuracy: 1e-12)
    }

    /// Below the relative coverage floor (50% of covered time) the load is
    /// estimated even with enough absolute valid seconds. Rates on the first
    /// 10 minutes only: valid intervals need both endpoints, so the trailing
    /// strap-less half drags coverage to a third.
    func testSparseHRFallsBackToEstimate() throws {
        var samples: [HeartRateSample] = []
        for index in 0...60 {
            let rate: Double? = index <= 20 ? 100 : nil
            samples.append(sample(elapsed: Double(index) * 30, rate: rate))
        }
        let snapshot = try TrainingLoadCalculator.compute(
            heartRateSamples: samples,
            activeSeconds: 1_800,
            averageSpeedMetersPerSecond: 3,
            profile: profile,
            referenceYear: 2026
        )
        XCTAssertEqual(snapshot.kind, .estimated)
        XCTAssertEqual(snapshot.validHeartRateSeconds, 600)
        XCTAssertEqual(snapshot.coveredActiveSeconds, 1_800)
        XCTAssertGreaterThan(snapshot.validHeartRateSeconds, 300)
        XCTAssertLessThan(
            snapshot.validHeartRateSeconds / snapshot.coveredActiveSeconds,
            TrainingLoadPolicy.minimumMeasuredCoverageFraction
        )
    }

    // MARK: - Estimated loads

    func testPaceDurationEstimateBands() throws {
        // No heart rate at all; vary average speed across the bands.
        let speedsAndReserves: [(Double, Double)] = [
            (1.0, 0.30),   // 3.6 km/h
            (2.0, 0.40),   // 7.2 km/h
            (2.7, 0.50),   // 9.7 km/h
            (3.2, 0.60),   // 11.5 km/h
            (3.7, 0.70),   // 13.3 km/h
            (4.2, 0.75),   // 15.1 km/h — capped
        ]
        for (speed, reserve) in speedsAndReserves {
            let samples = [
                sample(elapsed: 0, rate: nil),
                sample(elapsed: 1_800, rate: nil),
            ]
            let snapshot = try TrainingLoadCalculator.compute(
                heartRateSamples: samples,
                activeSeconds: 1_800,
                averageSpeedMetersPerSecond: speed,
                profile: profile,
                referenceYear: 2026
            )
            XCTAssertEqual(snapshot.kind, .estimated, "speed \(speed)")
            XCTAssertEqual(snapshot.estimateBasis, .paceDuration, "speed \(speed)")
            guard let assumed = snapshot.assumedHeartRateReserve else {
                XCTFail("estimated snapshot must disclose its assumed reserve (speed \(speed))")
                continue
            }
            XCTAssertEqual(assumed, reserve, accuracy: 1e-12, "speed \(speed)")
            XCTAssertNil(snapshot.zoneSeconds, "speed \(speed)")
            XCTAssertNil(snapshot.meanHeartRateBPM, "speed \(speed)")
            XCTAssertEqual(
                snapshot.banisterTRIMP,
                30 * reserve * 0.64 * exp(1.92 * reserve),
                accuracy: 1e-12,
                "speed \(speed)"
            )
        }
    }

    func testDurationOnlyEstimateWithoutUsablePace() throws {
        let samples = [
            sample(elapsed: 0, rate: nil),
            sample(elapsed: 1_800, rate: nil),
        ]
        let snapshot = try TrainingLoadCalculator.compute(
            heartRateSamples: samples,
            activeSeconds: 1_800,
            averageSpeedMetersPerSecond: nil,
            profile: profile,
            referenceYear: 2026
        )
        XCTAssertEqual(snapshot.kind, .estimated)
        XCTAssertEqual(snapshot.estimateBasis, .durationOnly)
        XCTAssertEqual(snapshot.assumedHeartRateReserve, TrainingLoadPolicy.durationOnlyAssumedReserve)
        XCTAssertEqual(
            snapshot.banisterTRIMP,
            30 * 0.5 * 0.64 * exp(1.92 * 0.5),
            accuracy: 1e-12
        )
    }

    func testFemaleCoefficientsFlowThroughEstimate() throws {
        let samples = [
            sample(elapsed: 0, rate: nil),
            sample(elapsed: 1_800, rate: nil),
        ]
        let female = AthleteProfile(
            restingHeartRateBPM: 50,
            maximumHeartRateBPM: 150,
            trimpCoefficientProfile: .standardFemale
        )
        let snapshot = try TrainingLoadCalculator.compute(
            heartRateSamples: samples,
            activeSeconds: 1_800,
            averageSpeedMetersPerSecond: nil,
            profile: female,
            referenceYear: 2026
        )
        XCTAssertEqual(
            snapshot.banisterTRIMP,
            30 * 0.5 * 0.86 * exp(1.67 * 0.5),
            accuracy: 1e-12
        )
        XCTAssertFalse(snapshot.isCurrent(for: profile))
    }

    /// A snapshot records the profile it was computed with; a later profile
    /// edit flips `isCurrent`.
    func testStalenessFollowsProfileSignature() throws {
        let samples = [
            sample(elapsed: 0, rate: 100),
            sample(elapsed: 1_800, rate: 100),
        ]
        let snapshot = try TrainingLoadCalculator.compute(
            heartRateSamples: samples,
            activeSeconds: 1_800,
            averageSpeedMetersPerSecond: 3,
            profile: profile,
            referenceYear: 2026
        )
        XCTAssertTrue(snapshot.isCurrent(for: profile))
        XCTAssertFalse(snapshot.isCurrent(for: AthleteProfile(
            restingHeartRateBPM: 50,
            maximumHeartRateBPM: 151
        )))
    }

    #if DEBUG
    /// Estimated passes make zero native calls; measured passes exactly one.
    ///
    /// Counts come from `NativeCallObserver.observing`, which scopes a tally
    /// to the closure, so a concurrently running test cannot contribute to
    /// these numbers. The observer exists only in DEBUG builds, so this one
    /// test is gated while the rest of the suite still compiles and runs in
    /// the release test build.
    func testMeasuredPassMakesOneNativeCallEstimatedMakesNone() throws {
        let measured = (0...40).map { sample(elapsed: Double($0) * 30, rate: 100) }
        let (_, measuredCounts) = try NativeCallObserver.observing {
            try TrainingLoadCalculator.compute(
                heartRateSamples: measured,
                activeSeconds: 1_200,
                averageSpeedMetersPerSecond: 3,
                profile: profile,
                referenceYear: 2026
            )
        }
        XCTAssertEqual(measuredCounts.trainingLoad, 1)

        let estimated = [sample(elapsed: 0, rate: nil), sample(elapsed: 1_800, rate: nil)]
        let (_, estimatedCounts) = try NativeCallObserver.observing {
            try TrainingLoadCalculator.compute(
                heartRateSamples: estimated,
                activeSeconds: 1_800,
                averageSpeedMetersPerSecond: 3,
                profile: profile,
                referenceYear: 2026
            )
        }
        XCTAssertEqual(estimatedCounts.trainingLoad, 0)
    }
    #endif
}
