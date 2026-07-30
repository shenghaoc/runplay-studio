import XCTest
@testable import RunPlayCore

/// Merge gate for the personal heatmap coverage C++23 cutover: the complete
/// production builder against the complete pre-migration Swift builder oracle.
///
/// The two extra timings this benchmark prints are **independent diagnostics**,
/// not additive components of the measured production build. Input conversion is
/// timed on a batch prepared separately from the one `PersonalHeatmapBuilder`
/// builds internally, and the native coverage total is timed once at the final
/// effective cell size rather than across every adaptive pass. That diagnostic
/// deliberately uses the historical array-returning bridge and is not the
/// production aggregation path. Adding the diagnostics to each other, or
/// subtracting them from the production total, produces a meaningless number.
///
/// For an additive phase decomposition taken from one production-equivalent
/// orchestration — including every adaptive pass, and native execution split
/// from output allocation and direct native-buffer counting — use
/// `PersonalHeatmapPipelineProfile` via
/// `scripts/run-personal-heatmap-profile.sh`.
final class PersonalHeatmapCoverageBenchmark: XCTestCase {
    private static let workoutCount = 250
    private static let pointsPerWorkout = 1_000
    private static let productLimitPointCount = 1_000_000
    private static let warmupIterations = 5
    private static let measuredIterations = 20

    func testPersonalHeatmapCoverageBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1",
            "Set RUNPLAY_BENCHMARK=1 to run the release benchmark."
        )

        let workouts = Self.makeWorkoutsFixture(count: Self.workoutCount, pointsPerWorkout: Self.pointsPerWorkout)
        let config = PersonalHeatmapConfiguration(
            cellSizeMeters: 5.0, // Small initial size to force adaptive coarsening
            maximumRenderedCellCount: 500
        )

        let oracleBuilder = SwiftPersonalHeatmapBuilderOracle()
        let prodBuilder = PersonalHeatmapBuilder()

        var oracleSamples: [Double] = []
        var prodSamples: [Double] = []
        var nativeCallTotalSamples: [Double] = []
        var conversionSamples: [Double] = []

        var oracleCellCount = 0
        var prodCellCount = 0

        let totalIterations = Self.warmupIterations + Self.measuredIterations
        for iteration in 0..<totalIterations {
            let oracleElapsed = try Self.timeThrowing {
                let snapshot = try oracleBuilder.build(workouts: workouts, configuration: config)
                oracleCellCount = snapshot.cells.count
            }

            // The merge-gate value: the complete public production builder and
            // nothing else. Diagnostics are timed afterwards, outside this
            // measurement, so they can never inflate the gated number.
            var effectiveCellSize = config.cellSizeMeters
            let prodElapsed = try Self.timeThrowing {
                let snapshot = try prodBuilder.build(workouts: workouts, configuration: config)
                prodCellCount = snapshot.cells.count
                effectiveCellSize = snapshot.configuration.cellSizeMeters
            }

            // Independent diagnostic 1: cost of one input conversion, on a
            // batch prepared separately from the builder's own.
            var prepared: RunPlayPersonalHeatmapPreparedBatch?
            let conversionElapsed = try Self.timeThrowing {
                prepared = try RunPlayPersonalHeatmapCoverageBridge.prepare(
                    workoutRoutes: workouts.map { $0.routePoints },
                    isCancelled: { false }
                )
            }

            // Independent diagnostic 2: one coverage sweep at the final
            // effective cell size only. The builder performs one sweep per
            // adaptive pass, so this is a lower bound on its native work, not
            // the native share of the production total.
            let nativeTotalElapsed = try Self.timeThrowing {
                guard let prepared else { return }
                for i in 0..<prepared.workoutCount {
                    _ = try prepared.coverage(
                        workoutIndex: i,
                        cellSizeMeters: effectiveCellSize,
                        maximumIntervalMeters: config.maximumIntervalMeters,
                        maximumCellsPerInterval: PersonalHeatmapGridTraversal.defaultMaximumCellsPerInterval,
                        isCancelled: { false }
                    )
                }
            }

            guard iteration >= Self.warmupIterations else { continue }
            oracleSamples.append(oracleElapsed)
            prodSamples.append(prodElapsed)
            conversionSamples.append(conversionElapsed)
            nativeCallTotalSamples.append(nativeTotalElapsed)
        }

        XCTAssertEqual(prodCellCount, oracleCellCount)

        let oracleMedian = Self.median(oracleSamples)
        let prodMedian = Self.median(prodSamples)
        let conversionMedian = Self.median(conversionSamples)
        let nativeTotalMedian = Self.median(nativeCallTotalSamples)
        let ratio = prodMedian / max(oracleMedian, 1e-12)
        let peak = Self.peakResidentMemoryBytes()

        print("""

        <!-- BEGIN RUNPLAY HEATMAP COVERAGE BENCHMARK -->

        RunPlay personal heatmap route coverage benchmark
        fixture: \(Self.workoutCount) workouts, \(Self.pointsPerWorkout) points/workout
        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations, medians
        complete Swift builder oracle:     \(Self.format(oracleMedian)) ms
        complete C++ production builder:   \(Self.format(prodMedian)) ms
        production / oracle ratio:         \(String(format: "%.3f", ratio))
        merge gate: complete production builder <= ~1.25× Swift builder oracle

        independent diagnostics -- NOT additive components of the production total
        one separate input conversion:     \(Self.format(conversionMedian)) ms
        historical array coverage sweep:  \(Self.format(nativeTotalMedian)) ms
        resident RSS after benchmark:      \(peak.map { "\($0) bytes" } ?? "unavailable")
        additive phase attribution lives in scripts/run-personal-heatmap-profile.sh

        <!-- END RUNPLAY HEATMAP COVERAGE BENCHMARK -->
        """)

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.runProductLimitProbe()
        }
    }

    private static func runProductLimitProbe() throws {
        let singleWorkout = makeWorkoutsFixture(count: 1, pointsPerWorkout: productLimitPointCount)
        let prepared = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: singleWorkout.map { $0.routePoints },
            isCancelled: { false }
        )

        var nativeSamples: [Double] = []
        for _ in 0..<5 {
            let elapsed = try timeThrowing {
                _ = try prepared.coverage(
                    workoutIndex: 0,
                    cellSizeMeters: 50.0,
                    maximumIntervalMeters: 500.0,
                    maximumCellsPerInterval: PersonalHeatmapGridTraversal.defaultMaximumCellsPerInterval,
                    isCancelled: { false }
                )
            }
            nativeSamples.append(elapsed)
        }

        let nativeMedian = median(nativeSamples)
        let nativeMax = nativeSamples.max() ?? 0
        let peak = peakResidentMemoryBytes()

        print("""
        product-limit native probe (\(productLimitPointCount) points)
        native median: \(format(nativeMedian)) ms
        native max:    \(format(nativeMax)) ms
        peak RSS:      \(peak.map { "\($0) bytes" } ?? "unavailable")
        """)
    }

    private static func makeWorkoutsFixture(count: Int, pointsPerWorkout: Int) -> [RunWorkout] {
        var workouts: [RunWorkout] = []
        workouts.reserveCapacity(count)

        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

        for w in 0..<count {
            let id = UUID()
            var points: [RoutePoint] = []
            points.reserveCapacity(pointsPerWorkout)

            var lat = 37.7749 + Double(w % 10) * 0.005
            var lon = -122.4194 + Double(w / 10) * 0.005
            var segment = 0

            for p in 0..<pointsPerWorkout {
                if p > 0 && p % 250 == 0 {
                    segment += 1
                }

                if p == 100 {
                    // Invalid lat coordinate
                    points.append(RoutePoint(
                        timestamp: baseDate.addingTimeInterval(Double(p)),
                        latitude: 200.0,
                        longitude: lon,
                        routeSegmentIndex: segment
                    ))
                    continue
                }

                if p == 300 {
                    // Oversized interval
                    lat += 0.1
                } else {
                    lat += 0.00005 * (p % 2 == 0 ? 1.0 : -0.5)
                    lon += 0.00005 * (p % 3 == 0 ? 1.0 : -0.2)
                }

                points.append(RoutePoint(
                    timestamp: baseDate.addingTimeInterval(Double(p)),
                    latitude: lat,
                    longitude: lon,
                    routeSegmentIndex: segment
                ))
            }

            let workout = RunWorkout(
                id: id,
                metadata: WorkoutMetadata(startDate: baseDate.addingTimeInterval(Double(w * 3600))),
                routePoints: points,
                summary: RunSummary(totalDistanceMeters: Double(pointsPerWorkout) * 5.0)
            )
            workouts.append(workout)
        }

        return workouts
    }

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
        return info.resident_size
        #else
        return nil
        #endif
    }
}
