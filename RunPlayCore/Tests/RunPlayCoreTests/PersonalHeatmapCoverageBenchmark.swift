import XCTest
@testable import RunPlayCore

/// Benchmark for personal heatmap coverage: the complete production builder,
/// as an absolute Swift baseline with no ratio gate. Each case prints one
/// `BenchmarkBaselineLine`.
///
/// The two extra timings this benchmark prints are **independent diagnostics**,
/// not additive components of the measured production build. Input conversion is
/// timed on a batch prepared separately from the one `PersonalHeatmapBuilder`
/// builds internally, and the engine coverage total is timed once at the final
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
    private static let benchmarkName = "PersonalHeatmapCoverageBenchmark"
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

        let prodBuilder = PersonalHeatmapBuilder()

        var prodSamples: [Double] = []
        var nativeCallTotalSamples: [Double] = []
        var conversionSamples: [Double] = []

        var prodCellCount = 0
        var referenceCellCount: Int?

        let totalIterations = Self.warmupIterations + Self.measuredIterations
        for iteration in 0..<totalIterations {
            // The baseline value: the complete public production builder and
            // nothing else. Diagnostics are timed afterwards, outside this
            // measurement, so they can never inflate the baseline number.
            var effectiveCellSize = config.cellSizeMeters
            let prodElapsed = try Self.timeThrowing {
                let snapshot = try prodBuilder.build(workouts: workouts, configuration: config)
                prodCellCount = snapshot.cells.count
                effectiveCellSize = snapshot.configuration.cellSizeMeters
            }
            if let referenceCellCount {
                XCTAssertEqual(prodCellCount, referenceCellCount, "repeated builds differ")
            }
            referenceCellCount = prodCellCount

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
            prodSamples.append(prodElapsed)
            conversionSamples.append(conversionElapsed)
            nativeCallTotalSamples.append(nativeTotalElapsed)
        }

        XCTAssertGreaterThan(prodCellCount, 0)

        let counts: KeyValuePairs<String, Int> = [
            "workouts": Self.workoutCount,
            "points_per_workout": Self.pointsPerWorkout,
            "cells": prodCellCount,
        ]
        let builderLine = BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "builder",
            counts: counts,
            iterations: Self.measuredIterations,
            medianMilliseconds: Self.median(prodSamples)
        )
        let conversionLine = BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "diagnostic-input-conversion",
            counts: counts,
            iterations: Self.measuredIterations,
            medianMilliseconds: Self.median(conversionSamples)
        )
        let sweepLine = BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "diagnostic-array-coverage-sweep",
            counts: counts,
            iterations: Self.measuredIterations,
            medianMilliseconds: Self.median(nativeCallTotalSamples)
        )
        let memoryLine = BenchmarkBaselineLine.memory(
            Self.benchmarkName,
            "resident-rss",
            bytes: Self.peakResidentMemoryBytes()
        )

        print("""

        <!-- BEGIN RUNPLAY HEATMAP COVERAGE BENCHMARK -->

        RunPlay personal heatmap route coverage benchmark
        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations, medians in ms
        \(builderLine)
        independent diagnostics -- NOT additive components of the builder total:
        \(conversionLine)
        \(sweepLine)
        \(memoryLine)
        additive phase attribution lives in scripts/run-personal-heatmap-profile.sh
        """)

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.runProductLimitProbe()
        }

        print("""

        <!-- END RUNPLAY HEATMAP COVERAGE BENCHMARK -->
        """)
    }

    private static func runProductLimitProbe() throws {
        let singleWorkout = makeWorkoutsFixture(count: 1, pointsPerWorkout: productLimitPointCount)
        let prepared = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: singleWorkout.map { $0.routePoints },
            isCancelled: { false }
        )

        let iterations = 5
        var nativeSamples: [Double] = []
        for _ in 0..<iterations {
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

        print(BenchmarkBaselineLine.make(
            benchmarkName,
            "product-limit-coverage",
            counts: ["points": productLimitPointCount],
            iterations: iterations,
            medianMilliseconds: median(nativeSamples),
            maximumMilliseconds: nativeSamples.max() ?? 0
        ))
        print(BenchmarkBaselineLine.memory(benchmarkName, "product-limit-resident-rss", bytes: peakResidentMemoryBytes()))
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
