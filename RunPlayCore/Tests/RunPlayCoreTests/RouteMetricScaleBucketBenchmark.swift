import Foundation
import XCTest
@testable import RunPlayCore

final class RouteMetricScaleBucketBenchmark: XCTestCase {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1"
    }

    func testReleaseBenchmark() throws {
        try XCTSkipUnless(enabled, "Set RUNPLAY_BENCHMARK=1")
        let includeProductLimit =
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1"
        let memoryBefore = processMemorySnapshot()
        print("\n<!-- BEGIN RUNPLAY ROUTE METRIC SCALE BUCKET BENCHMARK -->")
        print("\n# Route metric scale/bucket benchmark\n")
        print("| Fixture | Swift oracle ms | Complete bridge ms | Conversion ms | Native ms | Translation ms | Production profile ms |")
        print("|---|---:|---:|---:|---:|---:|---:|")

        try runFixture(
            label: "R1 1k pace",
            count: 1_000,
            warmups: 5,
            iterations: 20,
            workout: fixture(pointCount: 1_001, seed: 91_001),
            mode: .pace
        )
        try runFixture(
            label: "R2 100k pace",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: HotspotProfilingFixtures.c1(),
            mode: .pace
        )
        try runFixture(
            label: "R3 100k HR gaps",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: HotspotProfilingFixtures.c2(),
            mode: .heartRate,
            gaps: true
        )
        try runFixture(
            label: "R4 100k elevation",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: fixture(pointCount: 100_001, seed: 91_004, altitudeHeavy: true),
            mode: .correctedElevation
        )
        try runFixture(
            label: "R5 100k no scale",
            count: 100_000,
            warmups: 2,
            iterations: 5,
            workout: HotspotProfilingFixtures.c1(),
            mode: .pace,
            policy: RouteMetricColorPolicy(minimumValidIntervalCount: 200_000)
        )
        try runFixture(
            label: "R6 100k duplicates/zero",
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
                label: "R7 1M pace",
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
            let probe = try timings(iterations: 3) {
                _ = try builder.probe(routePoints: product.routePoints, context: context)
            }
            print("\nR8 complete three-mode product-limit probe median ms: \(format(median(probe)))")
        } else {
            print("\n_R7/R8 skipped; set RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1._")
        }

        let memoryAfter = processMemorySnapshot()
        print("Resident before/after: \(memoryBefore.residentBytes) / \(memoryAfter.residentBytes)")
        print("High-water before/after: \(memoryBefore.highWaterResidentBytes) / \(memoryAfter.highWaterResidentBytes)")
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
            _ = oracle(metrics, weights, policy)
            _ = try bridge(metrics, weights, policy)
        }
        let oracleTimes = timings(iterations: iterations) {
            _ = oracle(metrics, weights, policy)
        }
        var reports: [RunPlayRouteMetricScaleBucketBenchmarkReport] = []
        let bridgeTimes = try timings(iterations: iterations) {
            reports.append(try RunPlayRouteMetricScaleBucketBridge.assignCollectingBenchmarkReport(
                metricValues: metrics,
                weightsMeters: weights,
                lowerQuantile: policy.lowerQuantile,
                upperQuantile: policy.upperQuantile,
                minimumScaleSpan: mode == .correctedElevation ? policy.minimumElevationSpanMeters : 0,
                minimumValidIntervalCount: policy.minimumValidIntervalCount,
                bucketCount: policy.bucketCount,
                cancellationCheckStride: policy.cancellationStride,
                isCancelled: { false }
            ))
        }

        let context = WorkoutAnalysisContext(workout: workout)
        let builder = RouteMetricProfileBuilder()
        for _ in 0..<warmups {
            _ = try builder.build(workout: workout, context: context, mode: mode, policy: policy)
        }
        let productionTimes = try timings(iterations: iterations) {
            _ = try builder.build(workout: workout, context: context, mode: mode, policy: policy)
        }
        let conversions = reports.map(\.inputConversionMilliseconds)
        let native = reports.map(\.nativeKernelMilliseconds)
        let translations = reports.map(\.outputTranslationMilliseconds)
        print("| \(label) | \(format(median(oracleTimes))) | \(format(median(bridgeTimes))) | \(format(median(conversions))) | \(format(median(native))) | \(format(median(translations))) | \(format(median(productionTimes))) |")
        print("Native maximum \(label): \(format(native.max() ?? 0)) ms")
    }

    private func oracle(
        _ metrics: [Double?],
        _ weights: [Double],
        _ policy: RouteMetricColorPolicy
    ) -> SwiftRouteMetricScaleBucketOracle.Result {
        SwiftRouteMetricScaleBucketOracle.assign(
            metricValues: metrics,
            weightsMeters: weights,
            lowerQuantile: policy.lowerQuantile,
            upperQuantile: policy.upperQuantile,
            minimumScaleSpan: 0,
            minimumValidIntervalCount: policy.minimumValidIntervalCount,
            bucketCount: policy.bucketCount
        )
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

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
