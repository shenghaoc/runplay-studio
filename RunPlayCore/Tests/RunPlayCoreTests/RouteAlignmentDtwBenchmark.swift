import XCTest
@testable import RunPlayCore

/// Reproducible release benchmark for the constrained-DTW path solver.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Run through
/// `scripts/run-route-alignment-dtw-benchmark.sh`, which always builds release;
/// debug timings for a band-packed dynamic-programming sweep are meaningless.
///
/// Two timings are reported, as one `BenchmarkBaselineLine` per case:
///
///   1. the complete Swift adapter, including conversion and validation, per
///      fixture and summed over all fixtures
///   2. the complete production `ConstrainedDynamicTimeWarpingAligner`
///
/// The timings are an absolute Swift baseline. There is no reference
/// implementation and no ratio gate.
///
/// Every fixture is deterministic. Randomness comes from a fixed-seed linear
/// congruential generator, never from `arc4random`, `SystemRandomNumberGenerator`,
/// or wall-clock state, so two runs on one machine compare like for like.
final class RouteAlignmentDtwBenchmark: XCTestCase {
    private static let benchmarkName = "RouteAlignmentDtwBenchmark"
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

        let workouts = Self.makeAlignerWorkouts()
        let aligner = ConstrainedDynamicTimeWarpingAligner()
        let primaryContext = WorkoutAnalysisContext(workout: workouts.primary)
        let comparisonContext = WorkoutAnalysisContext(workout: workouts.comparison)

        var swiftSamples = [[Double]](repeating: [], count: fixtures.count)
        var alignerSamples: [Double] = []

        var swiftObservations = [SolveObservation?](repeating: nil, count: fixtures.count)
        var alignerAvailable = false
        var alignerSampleCount = 0

        let total = Self.warmupIterations + Self.measuredIterations
        for iteration in 0..<total {
            for (index, fixture) in fixtures.enumerated() {
                var swiftResult: RunPlayRouteAlignmentDtwResult?
                let swiftElapsed = try Self.timeThrowing {
                    swiftResult = try RunPlayRouteAlignmentDtwAdapter.solve(
                        primary: fixture.primary,
                        comparison: fixture.comparison,
                        primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                        comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                        effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                        policy: fixture.policy,
                        isCancelled: { false }
                    )
                }

                let observation = Self.observe(try XCTUnwrap(swiftResult))
                if let previous = swiftObservations[index] {
                    XCTAssertEqual(observation, previous, "\(fixture.name): repeated solves differ")
                }
                swiftObservations[index] = observation

                guard iteration >= Self.warmupIterations else { continue }
                swiftSamples[index].append(swiftElapsed)
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

        var bandCells = [Int](repeating: 0, count: fixtures.count)
        for (index, fixture) in fixtures.enumerated() {
            guard let swift = swiftObservations[index] else {
                return XCTFail("Missing observation for fixture \(fixture.name)")
            }
            bandCells[index] = swift.bandCellCount
        }
        XCTAssertGreaterThan(alignerSampleCount, 0)

        let swiftMedians = swiftSamples.map(Self.median)
        let alignerMedian = Self.median(alignerSamples)
        let peak = Self.peakResidentMemoryBytes()

        var lines: [String] = []
        for (index, fixture) in fixtures.enumerated() {
            lines.append(BenchmarkBaselineLine.make(
                Self.benchmarkName,
                "adapter-\(fixture.name)",
                counts: [
                    "primary_samples": fixture.primary.count,
                    "comparison_samples": fixture.comparison.count,
                    "band_cells": bandCells[index],
                ],
                iterations: Self.measuredIterations,
                medianMilliseconds: swiftMedians[index]
            ))
        }
        lines.append(BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "adapter-all-fixtures",
            counts: ["fixtures": fixtures.count, "band_cells": bandCells.reduce(0, +)],
            iterations: Self.measuredIterations,
            medianMilliseconds: swiftMedians.reduce(0, +)
        ))
        lines.append(BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "aligner",
            counts: ["primary_samples": alignerSampleCount, "available": alignerAvailable ? 1 : 0],
            iterations: Self.measuredIterations,
            medianMilliseconds: alignerMedian
        ))
        lines.append(BenchmarkBaselineLine.memory(Self.benchmarkName, "peak-rss", bytes: peak))

        print("""

        RunPlay constrained-DTW path benchmark
        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations, medians in ms
        \(lines.joined(separator: "\n"))
        """)

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.runProductLimitProbe()
        }
        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_MAX_BAND"] == "1" {
            try Self.runMaximumBandProbe()
        }
    }

    private static func runProductLimitProbe() throws {
        // A raw product-limit route is compacted before DTW. Deliberately
        // keep its production maximum of 2,000 alignment samples.
        var generator = BenchmarkLCG(seed: 0x4454_575f_314d_494c)
        let pointCount = 1_000_000
        let route = makeWorkout(noiseMeters: 0, pointCount: pointCount, generator: &generator)
        let context = WorkoutAnalysisContext(workout: route)
        let pair = try RouteAlignmentSampleBuilder().build(primary: route, comparison: route)
        let iterations = 3
        var swift: [Double] = []
        for _ in 0..<iterations {
            swift.append(try timeThrowing {
                _ = try RunPlayRouteAlignmentDtwAdapter.solve(
                    primary: pair.primary, comparison: pair.comparison,
                    primaryRouteDistanceMeters: pair.primaryRouteDistanceMeters,
                    comparisonRouteDistanceMeters: pair.comparisonRouteDistanceMeters,
                    effectiveSampleIntervalMeters: pair.effectiveSampleIntervalMeters,
                    policy: .default, isCancelled: { false }
                )
            })
        }
        let aligner = ConstrainedDynamicTimeWarpingAligner()
        var runs: [Double] = []
        var sampleCount = 0
        for _ in 0..<iterations {
            runs.append(try timeThrowing {
                let snapshot = try aligner.align(
                    primary: route, comparison: route, primaryContext: context, comparisonContext: context,
                    policy: .default, isCancelled: { false }
                )
                sampleCount = snapshot.diagnostics.primarySampleCount
            })
        }
        XCTAssertEqual(sampleCount, pair.primary.count)
        XCTAssertGreaterThan(sampleCount, 0)
        XCTAssertLessThanOrEqual(sampleCount, RouteAlignmentPolicy.default.maximumSamplesPerRoute)
        print(BenchmarkBaselineLine.make(
            benchmarkName,
            "product-limit-adapter",
            counts: ["raw_points": pointCount, "compact_samples": pair.primary.count],
            iterations: iterations,
            medianMilliseconds: median(swift)
        ))
        print(BenchmarkBaselineLine.make(
            benchmarkName,
            "product-limit-aligner",
            counts: ["raw_points": pointCount, "compact_samples": sampleCount],
            iterations: iterations,
            medianMilliseconds: median(runs)
        ))
    }

    // MARK: - Maximum-band probe

    /// Worst-case band probe, opt-in through `RUNPLAY_BENCHMARK_MAX_BAND=1`.
    ///
    /// Allocates a packed band close to the 4,000,000-cell policy ceiling, which
    /// costs roughly 40 MB of engine-side state, so it stays out of ordinary CI
    /// and out of the default benchmark run.
    private static func runMaximumBandProbe() throws {
        let fixture = makeMaximumBandFixture()

        var swiftTimes: [Double] = []
        var observation: SolveObservation?
        for _ in 0..<maximumBandIterations {
            var swiftResult: RunPlayRouteAlignmentDtwResult?
            swiftTimes.append(try timeThrowing {
                swiftResult = try RunPlayRouteAlignmentDtwAdapter.solve(
                    primary: fixture.primary, comparison: fixture.comparison,
                    primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                    comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                    effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                    policy: fixture.policy, isCancelled: { false }
                )
            })
            let swift = observe(try XCTUnwrap(swiftResult))
            if let observation {
                XCTAssertEqual(swift, observation)
            }
            observation = swift
        }

        let bandCells = observation?.bandCellCount ?? 0
        let peak = peakResidentMemoryBytes()

        // Guards the fixture itself: a shape change that quietly stopped filling
        // the band would make the probe report a much cheaper solve.
        XCTAssertEqual(observation?.outcome, "success")
        XCTAssertGreaterThan(bandCells, 3_500_000)
        XCTAssertLessThanOrEqual(bandCells, fixture.policy.maximumBandCells)

        print(BenchmarkBaselineLine.make(
            benchmarkName,
            "maximum-band-adapter",
            counts: [
                "primary_samples": fixture.primary.count,
                "comparison_samples": fixture.comparison.count,
                "band_cells": bandCells,
                "band_cell_limit": fixture.policy.maximumBandCells,
                "band_radius": observation?.bandRadius ?? 0,
                "path_cells": observation?.pathCount ?? 0,
            ],
            iterations: maximumBandIterations,
            medianMilliseconds: median(swiftTimes),
            maximumMilliseconds: swiftTimes.max() ?? 0
        ))
        print(BenchmarkBaselineLine.memory(benchmarkName, "maximum-band-peak-rss", bytes: peak))
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

    /// The six standard fixtures the baseline is measured over.
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
        pointCount: Int = 4_001,
        generator: inout BenchmarkLCG
    ) -> RunWorkout {
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

    /// The comparable part of one solve, so repeated solves can be checked for
    /// the same answer.
    private struct SolveObservation: Equatable {
        let outcome: String
        let pathCount: Int
        let bandRadius: Int
        let bandCellCount: Int
        let bestEndCost: Double
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
