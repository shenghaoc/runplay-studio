import XCTest
@testable import RunPlayCore

/// Reproducible release benchmark for the combined route-quality geometry kernel.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Run through
/// `scripts/run-route-quality-benchmark.sh` in release mode. Each case prints
/// one `BenchmarkBaselineLine`: an absolute Swift timing with no ratio gate.
final class RouteQualityPipelineBenchmark: XCTestCase {
    private static let benchmarkName = "RouteQualityPipelineBenchmark"
    private static let pointCount = 100_000
    private static let productLimitCount = 1_000_000
    private static let warmupIterations = 5
    private static let measuredIterations = 20

    func testRouteQualityPipelineBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1",
            "Set RUNPLAY_BENCHMARK=1 to run the release benchmark."
        )

        let points = Self.makeFixture(Self.pointCount)
        let policy = RouteQualityPolicy.runningDefault
        let distancePolicy: RouteDistancePolicy = .useSuppliedDistancesPerSegment
        let processor = RouteQualityProcessor(policy: policy)

        var bridgeSamples: [Double] = []
        var processSamples: [Double] = []

        var bridgeDistance = 0.0
        var processDistance = 0.0

        let total = Self.warmupIterations + Self.measuredIterations
        for iteration in 0..<total {
            let bridgeElapsed = try Self.timeThrowing {
                let result = try RunPlayRouteQualityBridge.process(
                    points,
                    policy: policy,
                    distancePolicy: distancePolicy,
                    cancellationCheckStride: policy.cancellationCheckStride,
                    isCancelled: { false }
                )
                bridgeDistance = result.routePoints.last?.distanceFromStartMeters ?? 0
            }
            let processElapsed = try Self.timeThrowing {
                let result = try processor.process(
                    points,
                    distancePolicy: distancePolicy,
                    isCancelled: { false }
                )
                processDistance = result.routePoints.last?.distanceFromStartMeters ?? 0
            }

            guard iteration >= Self.warmupIterations else { continue }
            bridgeSamples.append(bridgeElapsed)
            processSamples.append(processElapsed)
        }

        XCTAssertGreaterThan(bridgeDistance, 0)
        XCTAssertGreaterThan(processDistance, 0)

        let adapterLine = BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "adapter",
            counts: ["points": Self.pointCount],
            iterations: Self.measuredIterations,
            medianMilliseconds: Self.median(bridgeSamples)
        )
        let processorLine = BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "processor",
            counts: ["points": Self.pointCount],
            iterations: Self.measuredIterations,
            medianMilliseconds: Self.median(processSamples)
        )

        print("""

        RunPlay route-quality geometry benchmark
        fixture: \(Self.pointCount) points, mixed segments/outliers/gaps/supplied
        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations, medians in ms
        \(adapterLine)
        \(processorLine)
        """)

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.runProductLimitProbe()
        }
    }

    // Complete Swift bridge: model conversion + engine call + projection.
    func testSwiftEngineRouteQualityCompleteBridgeBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1",
            "Set RUNPLAY_BENCHMARK=1 to run the release benchmark."
        )
        try Self.measureCompleteBridge(
            "complete-bridge-supplied-distances",
            count: Self.pointCount, warmup: Self.warmupIterations, measured: Self.measuredIterations,
            distancePolicy: .useSuppliedDistancesPerSegment
        )
        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.measureCompleteBridge(
                "complete-bridge-coordinate-distances",
                count: Self.productLimitCount, warmup: 1, measured: 3, distancePolicy: .computeFromCoordinates
            )
        }
    }

    private static func measureCompleteBridge(
        _ caseName: String,
        count: Int, warmup: Int, measured: Int, distancePolicy: RouteDistancePolicy
    ) throws {
        let points = makeFixture(count)
        let policy = RouteQualityPolicy.runningDefault
        var swiftSamples: [Double] = []
        var reference: UInt64?

        for iteration in 0..<(warmup + measured) {
            var distance: UInt64 = 0
            let elapsed = try timeThrowing {
                let result = try RunPlayRouteQualityBridge.process(
                    points, policy: policy, distancePolicy: distancePolicy,
                    cancellationCheckStride: policy.cancellationCheckStride, isCancelled: { false }
                )
                distance = result.routePoints.last?.distanceFromStartMeters.bitPattern ?? 0
            }
            if let reference {
                XCTAssertEqual(distance, reference)
            }
            reference = distance
            guard iteration >= warmup else { continue }
            swiftSamples.append(elapsed)
        }

        print(BenchmarkBaselineLine.make(
            benchmarkName,
            caseName,
            counts: ["points": count],
            iterations: measured,
            medianMilliseconds: median(swiftSamples)
        ))
    }

    private static func runProductLimitProbe() throws {
        let points = makeFixture(productLimitCount)
        let policy = RouteQualityPolicy.runningDefault
        let iterations = 3
        var samples: [Double] = []
        for _ in 0..<iterations {
            let elapsed = try timeThrowing {
                _ = try RunPlayRouteQualityBridge.process(
                    points, policy: policy, distancePolicy: .computeFromCoordinates,
                    cancellationCheckStride: policy.cancellationCheckStride, isCancelled: { false }
                )
            }
            samples.append(elapsed)
        }
        let peak = Self.peakResidentMemoryBytes()
        print(BenchmarkBaselineLine.make(
            benchmarkName,
            "product-limit-adapter",
            counts: ["points": productLimitCount],
            iterations: iterations,
            medianMilliseconds: median(samples),
            maximumMilliseconds: samples.max() ?? 0
        ))
        print(BenchmarkBaselineLine.memory(benchmarkName, "product-limit-peak-rss", bytes: peak))
    }

    private static func makeFixture(_ count: Int) -> [RoutePoint] {
        var points: [RoutePoint] = []
        points.reserveCapacity(count)
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        for index in 0..<count {
            let segment = index / max(1, count / 4)
            let metres = Double(index)
            var latitude = metres / 111_132.0
            let longitude = Double(segment) * 0.01
            var timestampOffset = Double(index)
            var supplied = metres
            var accuracy: Double? = 8

            if index > 10, index % 5_000 == 100 {
                latitude += 4_500.0 / 111_132.0
                accuracy = 250
            }
            if index > 20, index % 12_500 == 0 {
                latitude += 1_200.0 / 111_132.0
                timestampOffset += 1
            }
            if segment == 2, index % 17 == 0 {
                supplied = -1
            }

            points.append(
                RoutePoint(
                    timestamp: base.addingTimeInterval(timestampOffset),
                    latitude: latitude,
                    longitude: longitude,
                    distanceFromStartMeters: supplied,
                    elapsedSeconds: Double(index),
                    horizontalAccuracy: accuracy,
                    routeSegmentIndex: segment
                )
            )
        }
        return points
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

    /// Peak resident size via the Mach task API. RunPlayCore is cross-platform,
    /// so the probe reports `nil` where that API does not exist.
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
