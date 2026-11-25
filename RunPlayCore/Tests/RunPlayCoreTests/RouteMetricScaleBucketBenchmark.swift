import Foundation
import XCTest
@testable import RunPlayCore

/// Release benchmark for route-metric scale/bucket finalization.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`; `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1`
/// adds the 1,000,000-point cases. Run through
/// `scripts/run-route-metric-scale-bucket-benchmark.sh`. Each case prints one
/// `BenchmarkBaselineLine`: an absolute Swift timing with no ratio gate.
final class RouteMetricScaleBucketBenchmark: XCTestCase {
    private static let benchmarkName = "RouteMetricScaleBucketBenchmark"

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1"
    }

    func testReleaseBenchmark() throws {
        try XCTSkipUnless(enabled, "Set RUNPLAY_BENCHMARK=1")
        let includeProductLimit =
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1"
        let memoryBefore = processMemorySnapshot()
        print("\n<!-- BEGIN RUNPLAY ROUTE METRIC SCALE BUCKET BENCHMARK -->")
        print("\n# Route metric scale/bucket benchmark (medians in ms)\n")

        try runFixture(
            label: "R1-1k-pace",
            count: 1_000,
            warmups: 5,
            iterations: 20,
            workout: fixture(pointCount: 1_001, seed: 91_001),
            mode: .pace
        )
        try runFixture(
            label: "R2-100k-pace",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: HotspotProfilingFixtures.c1(),
            mode: .pace
        )
        try runFixture(
            label: "R3-100k-heart-rate-gaps",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: HotspotProfilingFixtures.c2(),
            mode: .heartRate,
            gaps: true
        )
        try runFixture(
            label: "R4-100k-elevation",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: fixture(pointCount: 100_001, seed: 91_004, altitudeHeavy: true),
            mode: .correctedElevation
        )
        try runFixture(
            label: "R5-100k-no-scale",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: HotspotProfilingFixtures.c1(),
            mode: .pace,
            policy: RouteMetricColorPolicy(minimumValidIntervalCount: 200_000)
        )
        try runFixture(
            label: "R6-100k-duplicates-zero",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: fixture(pointCount: 100_001, seed: 91_006, step: 0),
            mode: .heartRate,
            duplicates: true
        )

        if includeProductLimit {
            let product = HotspotProfilingFixtures.c5()
            try runFixture(
                label: "R7-1M-pace",
                count: 1_000_000,
                warmups: 1,
                iterations: 3,
                workout: product,
                mode: .pace
            )
            let context = WorkoutAnalysisContext(workout: product)
            let builder = RouteMetricProfileBuilder()
            for _ in 0..<1 {
                _ = try builder.probe(routePoints: product.routePoints, context: context)
            }
            let probeIterations = 3
            let probe = try timings(iterations: probeIterations) {
                _ = try builder.probe(routePoints: product.routePoints, context: context)
            }
            print(BenchmarkBaselineLine.make(
                Self.benchmarkName,
                "R8-1M-three-mode-probe",
                counts: ["points": product.routePoints.count],
                iterations: probeIterations,
                medianMilliseconds: median(probe)
            ))
        } else {
            print("\n_R7/R8 skipped; set RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1._")
        }

        let memoryAfter = processMemorySnapshot()
        print(BenchmarkBaselineLine.memory(Self.benchmarkName, "resident-before", bytes: memoryBefore.residentBytes))
        print(BenchmarkBaselineLine.memory(Self.benchmarkName, "resident-after", bytes: memoryAfter.residentBytes))
        print(BenchmarkBaselineLine.memory(Self.benchmarkName, "high-water-before", bytes: memoryBefore.highWaterResidentBytes))
        print(BenchmarkBaselineLine.memory(Self.benchmarkName, "high-water-after", bytes: memoryAfter.highWaterResidentBytes))
        print("\n<!-- END RUNPLAY ROUTE METRIC SCALE BUCKET BENCHMARK -->\n")
    }

    private func runFixture(
        label: String,
        count: Int,
        warmups: Int,
        iterations: Int,
        workout: RunWorkout,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy = .runningDefault,
        gaps: Bool = false,
        duplicates: Bool = false
    ) throws {
        var metrics: [Double?] = []
        var weights: [Double] = []
        metrics.reserveCapacity(count)
        weights.reserveCapacity(count)
        for index in 0..<count {
            metrics.append(gaps && index.isMultiple(of: 17)
                ? nil
                : Double(duplicates ? index % 11 : index % 997) - 100)
            weights.append(duplicates && index.isMultiple(of: 3) ? 0 : 10)
        }

        for _ in 0..<warmups {
            _ = try bridge(metrics, weights, policy)
        }
        let swiftTimes = try timings(iterations: iterations) {
            _ = try bridge(metrics, weights, policy)
        }
        let result = try bridge(metrics, weights, policy)

        let context = WorkoutAnalysisContext(workout: workout)
        let builder = RouteMetricProfileBuilder()
        for _ in 0..<warmups {
            _ = try builder.build(workout: workout, context: context, mode: mode, policy: policy)
        }
        let productionTimes = try timings(iterations: iterations) {
            _ = try builder.build(workout: workout, context: context, mode: mode, policy: policy)
        }
        let materializationTimes = timings(iterations: iterations) {
            let intervals = materializeIntervals(metrics: metrics, weights: weights, result: result)
            withExtendedLifetime(intervals) {}
        }
        print(BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "\(label)-adapter",
            counts: ["intervals": count],
            iterations: iterations,
            medianMilliseconds: median(swiftTimes)
        ))
        print(BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "\(label)-materialization",
            counts: ["intervals": count],
            iterations: iterations,
            medianMilliseconds: median(materializationTimes)
        ))
        print(BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "\(label)-profile",
            counts: ["points": workout.routePoints.count],
            iterations: iterations,
            medianMilliseconds: median(productionTimes)
        ))
    }

    private func materializeIntervals(
        metrics: [Double?],
        weights: [Double],
        result: RunPlayRouteMetricScaleBucketResult
    ) -> [RouteMetricInterval] {
        var intervals: [RouteMetricInterval] = []
        intervals.reserveCapacity(metrics.count)
        var distance = 0.0
        for index in metrics.indices {
            let start = distance
            distance += weights[index]
            let assignment = result.assignments[index]
            intervals.append(RouteMetricInterval(
                startPointIndex: index,
                endPointIndex: index + 1,
                routeSegmentIndex: 0,
                startDistanceMeters: start,
                endDistanceMeters: distance,
                metricValue: metrics[index],
                normalizedValue: assignment.normalizedValue,
                bucket: assignment.bucketIndex.map(RouteMetricColorBucket.level) ?? .noData
            ))
        }
        return intervals
    }

    private func bridge(
        _ metrics: [Double?],
        _ weights: [Double],
        _ policy: RouteMetricColorPolicy
    ) throws -> RunPlayRouteMetricScaleBucketResult {
        try RunPlayRouteMetricScaleBucketBridge.assign(
            metricValues: metrics,
            weightsMeters: weights,
            lowerQuantile: policy.lowerQuantile,
            upperQuantile: policy.upperQuantile,
            minimumScaleSpan: 0,
            minimumValidIntervalCount: policy.minimumValidIntervalCount,
            bucketCount: policy.bucketCount,
            cancellationCheckStride: policy.cancellationStride,
            isCancelled: { false }
        )
    }

    private func fixture(
        pointCount: Int,
        seed: UInt64,
        step: Double = 10,
        altitudeHeavy: Bool = false
    ) -> RunWorkout {
        HotspotProfilingFixtures.makeWorkout(options: .init(
            pointCount: pointCount,
            stepMetres: step,
            altitudeHeavy: altitudeHeavy,
            seed: seed,
            name: "route-metric-benchmark"
        ))
    }

    private func timings(iterations: Int, operation: () throws -> Void) rethrows -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try operation()
            values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return values
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
