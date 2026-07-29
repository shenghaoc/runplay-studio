import XCTest
@testable import RunPlayCore

/// Reproducible release benchmark for the combined route-quality geometry cutover.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Run through
/// `scripts/run-route-quality-benchmark.sh` in release mode.
final class RouteQualityPipelineBenchmark: XCTestCase {
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

        var oracleSamples: [Double] = []
        var bridgeSamples: [Double] = []
        var nativeSamples: [Double] = []
        var processSamples: [Double] = []

        var oracleDistance = 0.0
        var bridgeDistance = 0.0
        var processDistance = 0.0

        let total = Self.warmupIterations + Self.measuredIterations
        for iteration in 0..<total {
            let oracleElapsed = try Self.timeThrowing {
                let result = try SwiftRouteQualityGeometryOracle.process(
                    points,
                    policy: policy,
                    distancePolicy: distancePolicy
                )
                oracleDistance = result.routePoints.last?.distanceFromStartMeters ?? 0
            }
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
            // Diagnostic only: includes conversion because the public
            // production path always does. True kernel isolation still
            // lives in native C++ tests.
            let nativeElapsed = try Self.timeThrowing {
                try RunPlayRouteQualityBridge.invokeNativeKernelForBenchmark(
                    points,
                    policy: policy,
                    distancePolicy: distancePolicy
                )
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
            oracleSamples.append(oracleElapsed)
            bridgeSamples.append(bridgeElapsed)
            nativeSamples.append(nativeElapsed)
            processSamples.append(processElapsed)
        }

        XCTAssertEqual(
            bridgeDistance,
            oracleDistance,
            accuracy: max(1e-6, abs(oracleDistance) * 1e-12)
        )
        XCTAssertGreaterThan(processDistance, 0)

        let oracleMedian = Self.median(oracleSamples)
        let bridgeMedian = Self.median(bridgeSamples)
        let nativeMedian = Self.median(nativeSamples)
        let processMedian = Self.median(processSamples)
        let ratio = bridgeMedian / max(oracleMedian, 1e-12)

        print("""

        RunPlay route-quality geometry benchmark
        fixture: \(Self.pointCount) points, mixed segments/outliers/gaps/supplied
        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations, medians
        complete Swift stages 2–4 oracle: \(Self.format(oracleMedian)) ms
        complete combined bridge:         \(Self.format(bridgeMedian)) ms
        native path (incl. conversion):   \(Self.format(nativeMedian)) ms
        complete RouteQualityProcessor:   \(Self.format(processMedian)) ms
        bridge / oracle ratio:            \(String(format: "%.3f", ratio))
        merge gate: combined bridge <= ~1.25× Swift stages 2–4
        """)

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.runProductLimitProbe()
        }
    }

    private static func runProductLimitProbe() throws {
        let points = makeFixture(productLimitCount)
        let policy = RouteQualityPolicy.runningDefault
        var nativeSamples: [Double] = []
        for _ in 0..<3 {
            let elapsed = try timeThrowing {
                try RunPlayRouteQualityBridge.invokeNativeKernelForBenchmark(
                    points,
                    policy: policy,
                    distancePolicy: .computeFromCoordinates
                )
            }
            nativeSamples.append(elapsed)
        }
        let peak = Self.peakResidentMemoryBytes()
        print("""
        product-limit native probe (\(productLimitCount) points)
        native median: \(format(median(nativeSamples))) ms
        native max:    \(format(nativeSamples.max() ?? 0)) ms
        peak RSS:      \(peak.map { "\($0) bytes" } ?? "unavailable")
        """)
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

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }

    private static func peakResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.resident_size
    }
}
