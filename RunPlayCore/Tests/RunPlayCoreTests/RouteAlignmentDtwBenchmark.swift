import XCTest
@testable import RunPlayCore

/// Reproducible release benchmark for the constrained-DTW path cutover.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Run through
/// `scripts/run-route-alignment-dtw-benchmark.sh`, which always builds release;
/// debug timings for a band-packed dynamic-programming sweep are meaningless.
///
/// Four timings are reported:
///
///   1. the complete Swift path oracle (`SwiftConstrainedDtwPathOracle`)
///   2. the complete C++ bridge (`RunPlayRouteAlignmentDtwBridge.solve`),
///      including sample conversion and Swift-side output validation
///   3. the native kernel alone, on already-converted inputs
///   4. the complete production `ConstrainedDynamicTimeWarpingAligner`
///
/// The merge gate is measurement 2 versus measurement 1: the complete bridge is
/// what production actually pays, and the oracle is what it replaced.
/// Measurement 3 is attribution only, and measurement 4 shows how much of a real
/// alignment the solve is at all.
///
/// Every fixture is deterministic. Randomness comes from a fixed-seed linear
/// congruential generator, never from `arc4random`, `SystemRandomNumberGenerator`,
/// or wall-clock state, so two runs on one machine compare like for like.
final class RouteAlignmentDtwBenchmark: XCTestCase {
    private static let warmupIterations = 5
    private static let measuredIterations = 20

    /// Shared synthetic geometry length for the standard fixtures. Sample counts
    /// are derived from it at the production 20 m alignment interval.
    private static let geometryLengthMeters = 40_000.0
    private static let sampleIntervalMeters = 20.0

    /// Maximum-band probe: 8,000 × 8,000 samples with a band width fraction that
    /// keeps the estimated budget (8,000 × 499 = 3,992,000) under the 4,000,000
    /// `maximumBandCells` policy ceiling while packing ~3.93 M real band cells.
    ///
    /// Production sample counts are capped at `maximumSamplesPerRoute` (2,000),
    /// so this deliberately bypasses `RouteAlignmentSampleBuilder` to reach the
    /// engine's cell budget, which no builder-produced pair can reach.
    private static let maximumBandSampleCount = 8_000
    private static let maximumBandWidthFraction = 0.031_12
    private static let maximumBandIterations = 5

    // MARK: - Benchmark

    func testRouteAlignmentDtwBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1",
            "Set RUNPLAY_BENCHMARK=1 to run the release benchmark."
        )

        let fixtures = Self.makeStandardFixtures()
        // Converted once: measurement 3 is the native solve, not the conversion.
        let prepared = try fixtures.map { fixture in
            try RunPlayRouteAlignmentDtwBridge.prepareNativeInputForBenchmark(
                primary: fixture.primary,
                comparison: fixture.comparison
            )
        }

        let workouts = Self.makeAlignerWorkouts()
        let aligner = ConstrainedDynamicTimeWarpingAligner()
        let primaryContext = WorkoutAnalysisContext(workout: workouts.primary)
        let comparisonContext = WorkoutAnalysisContext(workout: workouts.comparison)

        var oracleSamples = [[Double]](repeating: [], count: fixtures.count)
        var bridgeSamples = [[Double]](repeating: [], count: fixtures.count)
        var nativeSamples = [[Double]](repeating: [], count: fixtures.count)
        var alignerSamples: [Double] = []

        var oracleObservations = [SolveObservation?](repeating: nil, count: fixtures.count)
        var bridgeObservations = [SolveObservation?](repeating: nil, count: fixtures.count)
        var nativeBandCells = [Int](repeating: 0, count: fixtures.count)
        var alignerAvailable = false
        var alignerSampleCount = 0

        let total = Self.warmupIterations + Self.measuredIterations
        for iteration in 0..<total {
            for (index, fixture) in fixtures.enumerated() {
                var oracleObservation: SolveObservation?
                let oracleElapsed = Self.timeThrowing {
                    let result = SwiftConstrainedDtwPathOracle.solve(
                        primary: fixture.primary,
                        comparison: fixture.comparison,
                        primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                        comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                        effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                        policy: fixture.policy
                    )
                    oracleObservation = Self.observe(result)
                }

                var bridgeObservation: SolveObservation?
                let bridgeElapsed = try Self.timeThrowing {
                    let result = try RunPlayRouteAlignmentDtwBridge.solve(
                        primary: fixture.primary,
                        comparison: fixture.comparison,
                        primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                        comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                        effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                        policy: fixture.policy,
                        isCancelled: { false }
                    )
                    bridgeObservation = Self.observe(result)
                }

                var nativeReport: RunPlayRouteAlignmentDtwNativeBenchmarkReport?
                let nativeElapsed = try Self.timeThrowing {
                    nativeReport = try RunPlayRouteAlignmentDtwBridge.invokeNativeKernelForBenchmark(
                        prepared[index],
                        primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                        comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                        effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                        policy: fixture.policy
                    )
                }

                oracleObservations[index] = oracleObservation
                bridgeObservations[index] = bridgeObservation
                nativeBandCells[index] = nativeReport?.bandCellCount ?? 0

                guard iteration >= Self.warmupIterations else { continue }
                oracleSamples[index].append(oracleElapsed)
                bridgeSamples[index].append(bridgeElapsed)
                nativeSamples[index].append(nativeElapsed)
            }

            let alignerElapsed = try Self.timeThrowing {
                let snapshot = try aligner.align(
                    primary: workouts.primary,
                    comparison: workouts.comparison,
                    primaryContext: primaryContext,
                    comparisonContext: comparisonContext,
                    policy: .default,
                    isCancelled: { false }
                )
                alignerAvailable = snapshot.availability.isAvailable
                alignerSampleCount = snapshot.diagnostics.primarySampleCount
            }

            guard iteration >= Self.warmupIterations else { continue }
            alignerSamples.append(alignerElapsed)
        }

        // The benchmark is only meaningful while both implementations still agree.
        for (index, fixture) in fixtures.enumerated() {
            guard
                let oracle = oracleObservations[index],
                let bridge = bridgeObservations[index]
            else {
                return XCTFail("Missing observation for fixture \(fixture.name)")
            }
            XCTAssertEqual(bridge.outcome, oracle.outcome, fixture.name)
            XCTAssertEqual(bridge.pathCount, oracle.pathCount, fixture.name)
            XCTAssertEqual(bridge.bandRadius, oracle.bandRadius, fixture.name)
            XCTAssertEqual(bridge.bandCellCount, oracle.bandCellCount, fixture.name)
            XCTAssertEqual(
                bridge.bestEndCost,
                oracle.bestEndCost,
                accuracy: max(1e-9, abs(oracle.bestEndCost) * 1e-12),
                fixture.name
            )
            XCTAssertEqual(nativeBandCells[index], oracle.bandCellCount, fixture.name)
        }
        XCTAssertGreaterThan(alignerSampleCount, 0)

        let oracleMedians = oracleSamples.map(Self.median)
        let bridgeMedians = bridgeSamples.map(Self.median)
        let nativeMedians = nativeSamples.map(Self.median)
        let oracleTotal = oracleMedians.reduce(0, +)
        let bridgeTotal = bridgeMedians.reduce(0, +)
        let nativeTotal = nativeMedians.reduce(0, +)
        let alignerMedian = Self.median(alignerSamples)
        let ratio = bridgeTotal / max(oracleTotal, 1e-12)
        let peak = Self.peakResidentMemoryBytes()

        var rows: [String] = []
        for (index, fixture) in fixtures.enumerated() {
            let fixtureRatio = bridgeMedians[index] / max(oracleMedians[index], 1e-12)
            rows.append(
                Self.pad(fixture.name, 22)
                    + Self.pad("\(fixture.primary.count)x\(fixture.comparison.count)", 14)
                    + Self.padLeft(Self.formatCount(nativeBandCells[index]), 12)
                    + Self.padLeft(Self.format(oracleMedians[index]), 15)
                    + Self.padLeft(Self.format(bridgeMedians[index]), 13)
                    + Self.padLeft(Self.format(nativeMedians[index]), 16)
                    + Self.padLeft(String(format: "%.3f", fixtureRatio), 15)
            )
        }
        let totalRow = Self.pad("all fixtures", 22)
            + Self.pad("", 14)
            + Self.padLeft(Self.formatCount(nativeBandCells.reduce(0, +)), 12)
            + Self.padLeft(Self.format(oracleTotal), 15)
            + Self.padLeft(Self.format(bridgeTotal), 13)
            + Self.padLeft(Self.format(nativeTotal), 16)
            + Self.padLeft(String(format: "%.3f", ratio), 15)

        print("""

        RunPlay constrained-DTW path benchmark
        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations, per-fixture medians in ms
        \(Self.pad("fixture", 22))\(Self.pad("samples", 14))\(Self.padLeft("band cells", 12))\(Self.padLeft("Swift oracle", 15))\(Self.padLeft("C++ bridge", 13))\(Self.padLeft("native kernel", 16))\(Self.padLeft("bridge/oracle", 15))
        \(rows.joined(separator: "\n"))
        \(totalRow)
        complete ConstrainedDynamicTimeWarpingAligner: \(Self.format(alignerMedian)) ms \
        (\(alignerSampleCount)-sample workout pair, available=\(alignerAvailable))
        peak RSS: \(peak.map { "\($0) bytes" } ?? "unavailable")
        merge gate: complete C++ bridge \(Self.format(bridgeTotal)) ms \
        <= ~1.25x complete Swift oracle \(Self.format(oracleTotal)) ms \
        (target ratio <= 1.250, measured \(String(format: "%.3f", ratio)))
        """)

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_MAX_BAND"] == "1" {
            try Self.runMaximumBandProbe()
        }
    }

    // MARK: - Maximum-band probe

    /// Worst-case band probe, opt-in through `RUNPLAY_BENCHMARK_MAX_BAND=1`.
    ///
    /// Allocates a packed band close to the 4,000,000-cell policy ceiling, which
    /// costs roughly 40 MB of engine-side state, so it stays out of ordinary CI
    /// and out of the default benchmark run.
    private static func runMaximumBandProbe() throws {
        let fixture = makeMaximumBandFixture()
        let prepared = try RunPlayRouteAlignmentDtwBridge.prepareNativeInputForBenchmark(
            primary: fixture.primary,
            comparison: fixture.comparison
        )

        var nativeDurations: [Double] = []
        var report: RunPlayRouteAlignmentDtwNativeBenchmarkReport?
        for _ in 0..<maximumBandIterations {
            let elapsed = try timeThrowing {
                report = try RunPlayRouteAlignmentDtwBridge.invokeNativeKernelForBenchmark(
                    prepared,
                    primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                    comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                    effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                    policy: fixture.policy
                )
            }
            nativeDurations.append(elapsed)
        }

        var bridgeObservation: SolveObservation?
        let bridgeElapsed = try timeThrowing {
            let result = try RunPlayRouteAlignmentDtwBridge.solve(
                primary: fixture.primary,
                comparison: fixture.comparison,
                primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                policy: fixture.policy,
                isCancelled: { false }
            )
            bridgeObservation = observe(result)
        }

        let bandCells = report?.bandCellCount ?? 0
        let peak = peakResidentMemoryBytes()

        // Guards the fixture itself: a shape change that quietly stopped filling
        // the band would make the probe report a much cheaper solve.
        XCTAssertEqual(report?.succeeded, true)
        XCTAssertGreaterThan(bandCells, 3_500_000)
        XCTAssertLessThanOrEqual(bandCells, fixture.policy.maximumBandCells)

        print("""

        maximum-band probe (\(fixture.primary.count)x\(fixture.comparison.count) samples, \
        band width fraction \(maximumBandWidthFraction))
        band cells:      \(formatCount(bandCells)) of \(formatCount(fixture.policy.maximumBandCells)) allowed
        band radius:     \(report?.bandRadius ?? 0)
        native solve:    \(report?.writtenPathCount ?? 0) path cells, \
        best end cost \(String(format: "%.6f", report?.bestEndCost ?? 0))
        native median:   \(format(median(nativeDurations))) ms
        native maximum:  \(format(nativeDurations.max() ?? 0)) ms
        complete bridge: \(format(bridgeElapsed)) ms \
        (\(bridgeObservation?.outcome ?? "none"), \(bridgeObservation?.pathCount ?? 0) path cells)
        peak RSS:        \(peak.map { "\($0) bytes" } ?? "unavailable")
        """)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let name: String
        let primary: [RouteAlignmentSample]
        let comparison: [RouteAlignmentSample]
        let primaryRouteDistanceMeters: Double
        let comparisonRouteDistanceMeters: Double
        let effectiveSampleIntervalMeters: Double
        let policy: RouteAlignmentPolicy
    }

    /// 64-bit linear congruential generator with the Knuth MMIX constants.
    ///
    /// Fixed seed, no platform randomness, identical output on every run and
    /// every platform. Only the top 53 bits reach the unit interval, so the weak
    /// low-order bits of an LCG never affect a fixture.
    private struct BenchmarkLCG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func unit() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        /// Uniform in `-magnitude ... magnitude`.
        mutating func symmetric(_ magnitude: Double) -> Double {
            (unit() * 2 - 1) * magnitude
        }
    }

    /// The six standard fixtures the merge gate is measured over.
    ///
    /// Sample counts and route distances stay consistent at the production 20 m
    /// alignment interval, so every fixture is a shape the sample builder could
    /// actually produce.
    private static func makeStandardFixtures() -> [Fixture] {
        var generator = BenchmarkLCG(seed: 0x4454_575F_4245_4E43)
        let policy = RouteAlignmentPolicy.default
        var fixtures: [Fixture] = []

        // 1. Near-identical: the common "same route, same day" comparison.
        let identicalCount = 500
        let identicalDistance = distance(forSampleCount: identicalCount)
        fixtures.append(Fixture(
            name: "near-identical",
            primary: makeRoute(
                sampleCount: identicalCount,
                startFraction: 0,
                endFraction: fraction(identicalDistance),
                routeDistanceMeters: identicalDistance,
                generator: &generator
            ),
            comparison: makeRoute(
                sampleCount: identicalCount,
                startFraction: 0,
                endFraction: fraction(identicalDistance),
                routeDistanceMeters: identicalDistance,
                noiseMeters: 1.5,
                generator: &generator
            ),
            primaryRouteDistanceMeters: identicalDistance,
            comparisonRouteDistanceMeters: identicalDistance,
            effectiveSampleIntervalMeters: sampleIntervalMeters,
            policy: policy
        ))

        // 2. Noisy: consumer-GPS separation on the same roads.
        let noisyCount = 1_000
        let noisyDistance = distance(forSampleCount: noisyCount)
        fixtures.append(Fixture(
            name: "noisy",
            primary: makeRoute(
                sampleCount: noisyCount,
                startFraction: 0,
                endFraction: fraction(noisyDistance),
                routeDistanceMeters: noisyDistance,
                noiseMeters: 6,
                generator: &generator
            ),
            comparison: makeRoute(
                sampleCount: noisyCount,
                startFraction: 0,
                endFraction: fraction(noisyDistance),
                routeDistanceMeters: noisyDistance,
                lateralOffsetMeters: 8,
                noiseMeters: 18,
                generator: &generator
            ),
            primaryRouteDistanceMeters: noisyDistance,
            comparisonRouteDistanceMeters: noisyDistance,
            effectiveSampleIntervalMeters: sampleIntervalMeters,
            policy: policy
        ))

        // 3. Maximum-sample: both routes at `maximumSamplesPerRoute`.
        let maximumCount = 2_000
        let maximumDistance = distance(forSampleCount: maximumCount)
        fixtures.append(Fixture(
            name: "maximum-sample",
            primary: makeRoute(
                sampleCount: maximumCount,
                startFraction: 0,
                endFraction: fraction(maximumDistance),
                routeDistanceMeters: maximumDistance,
                noiseMeters: 4,
                generator: &generator
            ),
            comparison: makeRoute(
                sampleCount: maximumCount,
                startFraction: 0,
                endFraction: fraction(maximumDistance),
                routeDistanceMeters: maximumDistance,
                lateralOffsetMeters: 5,
                noiseMeters: 8,
                generator: &generator
            ),
            primaryRouteDistanceMeters: maximumDistance,
            comparisonRouteDistanceMeters: maximumDistance,
            effectiveSampleIntervalMeters: sampleIntervalMeters,
            policy: policy
        ))

        // 4. Unequal sample counts: one route is half the length of the other at
        //    the same shared interval, so the band is strongly rectangular.
        let longCount = 1_800
        let shortCount = 900
        let longDistance = distance(forSampleCount: longCount)
        let shortDistance = distance(forSampleCount: shortCount)
        fixtures.append(Fixture(
            name: "unequal-counts",
            primary: makeRoute(
                sampleCount: longCount,
                startFraction: 0,
                endFraction: fraction(longDistance),
                routeDistanceMeters: longDistance,
                noiseMeters: 4,
                generator: &generator
            ),
            comparison: makeRoute(
                sampleCount: shortCount,
                startFraction: 0,
                endFraction: fraction(shortDistance),
                routeDistanceMeters: shortDistance,
                noiseMeters: 4,
                generator: &generator
            ),
            primaryRouteDistanceMeters: longDistance,
            comparisonRouteDistanceMeters: shortDistance,
            effectiveSampleIntervalMeters: sampleIntervalMeters,
            policy: policy
        ))

        // 5. Open prefix and suffix: the comparison starts 300 m later and stops
        //    300 m earlier, inside the policy's unmatched-end allowance, so the
        //    open-beginning seeding and open-suffix endpoint search both run.
        let openCount = 1_200
        let openDistance = distance(forSampleCount: openCount)
        let openTrimMeters = 300.0
        let openComparisonDistance = openDistance - 2 * openTrimMeters
        let openComparisonCount = Int(openComparisonDistance / sampleIntervalMeters) + 1
        fixtures.append(Fixture(
            name: "open-prefix-suffix",
            primary: makeRoute(
                sampleCount: openCount,
                startFraction: 0,
                endFraction: fraction(openDistance),
                routeDistanceMeters: openDistance,
                noiseMeters: 3,
                generator: &generator
            ),
            comparison: makeRoute(
                sampleCount: openComparisonCount,
                startFraction: fraction(openTrimMeters),
                endFraction: fraction(openDistance - openTrimMeters),
                routeDistanceMeters: openComparisonDistance,
                noiseMeters: 3,
                generator: &generator
            ),
            primaryRouteDistanceMeters: openDistance,
            comparisonRouteDistanceMeters: openComparisonDistance,
            effectiveSampleIntervalMeters: sampleIntervalMeters,
            policy: policy
        ))

        // 6. Warp-heavy: the comparison advances along the same geometry at a
        //    varying rate, so the optimal path leaves the diagonal repeatedly and
        //    the consecutive-warp limit is exercised.
        let warpCount = 1_500
        let warpDistance = distance(forSampleCount: warpCount)
        fixtures.append(Fixture(
            name: "warp-heavy",
            primary: makeRoute(
                sampleCount: warpCount,
                startFraction: 0,
                endFraction: fraction(warpDistance),
                routeDistanceMeters: warpDistance,
                noiseMeters: 3,
                generator: &generator
            ),
            comparison: makeRoute(
                sampleCount: warpCount,
                startFraction: 0,
                endFraction: fraction(warpDistance),
                routeDistanceMeters: warpDistance,
                noiseMeters: 5,
                warpAmplitude: 0.04,
                generator: &generator
            ),
            primaryRouteDistanceMeters: warpDistance,
            comparisonRouteDistanceMeters: warpDistance,
            effectiveSampleIntervalMeters: sampleIntervalMeters,
            policy: policy
        ))

        return fixtures
    }

    private static func makeMaximumBandFixture() -> Fixture {
        var generator = BenchmarkLCG(seed: 0x4D41_585F_4241_4E44)
        let count = maximumBandSampleCount
        let routeDistance = Double(count - 1) * sampleIntervalMeters
        let policy = RouteAlignmentPolicy(bandWidthFraction: maximumBandWidthFraction)

        return Fixture(
            name: "maximum-band",
            primary: makeRoute(
                sampleCount: count,
                geometryLengthMeters: routeDistance,
                startFraction: 0,
                endFraction: 1,
                routeDistanceMeters: routeDistance,
                noiseMeters: 2,
                generator: &generator
            ),
            comparison: makeRoute(
                sampleCount: count,
                geometryLengthMeters: routeDistance,
                startFraction: 0,
                endFraction: 1,
                routeDistanceMeters: routeDistance,
                lateralOffsetMeters: 4,
                noiseMeters: 2,
                generator: &generator
            ),
            primaryRouteDistanceMeters: routeDistance,
            comparisonRouteDistanceMeters: routeDistance,
            effectiveSampleIntervalMeters: sampleIntervalMeters,
            policy: policy
        )
    }

    private static func distance(forSampleCount count: Int) -> Double {
        Double(count - 1) * sampleIntervalMeters
    }

    private static func fraction(_ meters: Double) -> Double {
        meters / geometryLengthMeters
    }

    /// Samples one gently serpentine synthetic route between two fractions of the
    /// shared geometry.
    ///
    /// Only `xMeters`, `zMeters`, `normalizedProgress`, and `headingRadians`
    /// reach the engine; `distanceFromStartMeters` is kept consistent anyway so
    /// the fixture stays a shape the sample builder could produce.
    private static func makeRoute(
        sampleCount: Int,
        geometryLengthMeters: Double = geometryLengthMeters,
        startFraction: Double,
        endFraction: Double,
        routeDistanceMeters: Double,
        lateralOffsetMeters: Double = 0,
        noiseMeters: Double = 0,
        warpAmplitude: Double = 0,
        generator: inout BenchmarkLCG
    ) -> [RouteAlignmentSample] {
        precondition(sampleCount >= 2, "A benchmark route needs at least two samples")

        var xs = [Double](repeating: 0, count: sampleCount)
        var zs = [Double](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            let progress = Double(index) / Double(sampleCount - 1)
            // A non-uniform advance along the shared geometry forces warp steps.
            let warped = min(1, max(0, progress + warpAmplitude * sin(progress * 4 * .pi)))
            let position = startFraction + warped * (endFraction - startFraction)
            let along = position * geometryLengthMeters
            let noiseX = noiseMeters > 0 ? generator.symmetric(noiseMeters) : 0
            let noiseZ = noiseMeters > 0 ? generator.symmetric(noiseMeters) : 0
            xs[index] = 0.98 * along + lateralOffsetMeters + noiseX
            zs[index] = 220 * sin(position * 6 * .pi) + lateralOffsetMeters + noiseZ
        }

        var samples: [RouteAlignmentSample] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let progress = Double(index) / Double(sampleCount - 1)
            let ahead = min(index + 1, sampleCount - 1)
            let behind = ahead == index ? index - 1 : index
            // Roughly one sample in eleven has no heading, so the engine's
            // has_heading == 0 branch is exercised on every fixture.
            let heading: Double? = index % 11 == 0
                ? nil
                : atan2(zs[ahead] - zs[behind], xs[ahead] - xs[behind])
            samples.append(RouteAlignmentSample(
                xMeters: xs[index],
                zMeters: zs[index],
                distanceFromStartMeters: progress * routeDistanceMeters,
                routeSegmentIndex: 0,
                elapsedSeconds: nil,
                headingRadians: heading,
                normalizedProgress: progress
            ))
        }
        return samples
    }

    /// A workout pair for the complete production aligner: 40 km at 10 m point
    /// spacing, which the sample builder coarsens to the 2,000-sample cap.
    private static func makeAlignerWorkouts() -> (primary: RunWorkout, comparison: RunWorkout) {
        var generator = BenchmarkLCG(seed: 0x414C_474E_5F57_4B54)
        let primary = makeWorkout(noiseMeters: 0, generator: &generator)
        let comparison = makeWorkout(noiseMeters: 4, generator: &generator)
        return (primary, comparison)
    }

    private static func makeWorkout(
        noiseMeters: Double,
        generator: inout BenchmarkLCG
    ) -> RunWorkout {
        let pointSpacingMeters = 10.0
        let pointCount = Int(geometryLengthMeters / pointSpacingMeters) + 1
        let baseLatitude = 37.7749
        let baseLongitude = -122.4194
        let metresPerDegreeLongitude = 111_320.0 * cos(baseLatitude * .pi / 180)
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

        var points: [RoutePoint] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let position = Double(index) / Double(pointCount - 1)
            let along = position * geometryLengthMeters
            let noiseX = noiseMeters > 0 ? generator.symmetric(noiseMeters) : 0
            let noiseZ = noiseMeters > 0 ? generator.symmetric(noiseMeters) : 0
            let x = 0.98 * along + noiseX
            let z = 220 * sin(position * 6 * .pi) + noiseZ
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(along / 3),
                latitude: baseLatitude + z / 111_132.0,
                longitude: baseLongitude + x / metresPerDegreeLongitude,
                distanceFromStartMeters: along,
                elapsedSeconds: along / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
        }
        return RunWorkout(routePoints: points)
    }

    // MARK: - Observations

    /// The comparable part of one solve, shared by the oracle and the bridge so
    /// the benchmark can prove both still produce the same answer.
    private struct SolveObservation: Equatable {
        let outcome: String
        let pathCount: Int
        let bandRadius: Int
        let bandCellCount: Int
        let bestEndCost: Double
    }

    private static func observe(_ result: SwiftConstrainedDtwPathResult) -> SolveObservation {
        switch result {
        case .success(let path, let bandRadius, let bandCellCount, let bestEndCost):
            return SolveObservation(
                outcome: "success",
                pathCount: path.count,
                bandRadius: bandRadius,
                bandCellCount: bandCellCount,
                bestEndCost: bestEndCost
            )
        case .resourceLimit:
            return SolveObservation(
                outcome: "resourceLimit",
                pathCount: 0,
                bandRadius: 0,
                bandCellCount: 0,
                bestEndCost: 0
            )
        case .noPath:
            return SolveObservation(
                outcome: "noPath",
                pathCount: 0,
                bandRadius: 0,
                bandCellCount: 0,
                bestEndCost: 0
            )
        }
    }

    private static func observe(_ result: RunPlayRouteAlignmentDtwResult) -> SolveObservation {
        switch result {
        case .success(let path, let bandRadius, let bandCellCount, let bestEndCost):
            return SolveObservation(
                outcome: "success",
                pathCount: path.count,
                bandRadius: bandRadius,
                bandCellCount: bandCellCount,
                bestEndCost: bestEndCost
            )
        case .resourceLimit:
            return SolveObservation(
                outcome: "resourceLimit",
                pathCount: 0,
                bandRadius: 0,
                bandCellCount: 0,
                bestEndCost: 0
            )
        case .noPath:
            return SolveObservation(
                outcome: "noPath",
                pathCount: 0,
                bandRadius: 0,
                bandCellCount: 0,
                bestEndCost: 0
            )
        }
    }

    // MARK: - Measurement helpers

    private static func timeThrowing(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }

    /// Locale-independent thousands grouping; every count reported here is
    /// non-negative.
    private static func formatCount(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset).isMultiple(of: 3) {
                result.append(",")
            }
            result.append(character)
        }
        return result
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func padLeft(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    /// Peak resident size. RunPlayCore is cross-platform, so the probe uses the
    /// Mach task API on Darwin, `VmHWM` on Linux, and degrades to `nil` anywhere
    /// else rather than reporting a number it cannot support.
    private static func peakResidentMemoryBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.resident_size_max
        #elseif os(Linux)
        // procfs reports a zero stat size, so read the handle to the end rather
        // than asking Foundation to size the file first.
        guard let handle = FileHandle(forReadingAtPath: "/proc/self/status") else {
            return nil
        }
        defer { try? handle.close() }
        guard
            let data = try? handle.readToEnd(),
            let status = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        for line in status.split(separator: "\n") where line.hasPrefix("VmHWM:") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let kilobytes = UInt64(fields[1]) else { return nil }
            return kilobytes * 1024
        }
        return nil
        #else
        return nil
        #endif
    }
}
