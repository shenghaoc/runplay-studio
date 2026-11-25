import Foundation
import Testing
@testable import RunPlayCore

/// Release-mode elevation profile benchmarks.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Always intended to run in release.
@Suite(
    "ElevationProfile benchmarks",
    .serialized,
    .disabled(if: ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] != "1")
)
struct ElevationProfileBenchmark {

    @Test("E1 ordinary 1,000-point workout")
    func e1Ordinary() throws {
        try runSuite(name: "E1", count: 1_000, warmups: 5, measurements: 20)
    }

    @Test("E2 100,000 dense altitude points")
    func e2Dense() throws {
        try runSuite(name: "E2", count: 100_000, warmups: 2, measurements: 5)
    }

    @Test("E7 1,000,000-point product limit",
          .enabled(if: ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1"))
    func e7ProductLimit() throws {
        try runSuite(name: "E7", count: 1_000_000, warmups: 1, measurements: 3)
    }

    private func runSuite(
        name: String,
        count: Int,
        warmups: Int,
        measurements: Int
    ) throws {
        let points = makeClimb(count: count)
        let policy = RouteQualityPolicy.runningDefault
        func measure(swift: Bool) throws -> Double {
            let clock = ContinuousClock()
            let elapsed = try clock.measure {
                if swift {
                    _ = try RunPlayElevationProfileBridge.build(
                        routePoints: points, policy: policy, isCancelled: { false }
                    )
                } else {
                    _ = try ElevationProfileCppBenchmarkOracle.build(
                        routePoints: points, policy: policy, isCancelled: { false }
                    )
                }
            }
            let parts = elapsed.components
            return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) * 1e-15
        }
        var native: [Double] = []
        var swift: [Double] = []
        for iteration in 0..<(warmups + measurements) {
            let swiftFirst = iteration.isMultiple(of: 2)
            let first = try measure(swift: swiftFirst)
            let second = try measure(swift: !swiftFirst)
            if iteration >= warmups {
                swift.append(swiftFirst ? first : second)
                native.append(swiftFirst ? second : first)
            }
        }
        let nativeMedian = native.sorted()[measurements / 2]
        let swiftMedian = swift.sorted()[measurements / 2]
        let ratio = swiftMedian / nativeMedian
        print("ElevationProfileBenchmark \(name) count=\(count) cpp_ms=\(nativeMedian) swift_ms=\(swiftMedian) ratio=\(ratio)")
        #expect(nativeMedian > 0)
        #expect(swiftMedian > 0)
        #expect(ratio <= 1.10)
    }

    private func makeClimb(count: Int) -> [RoutePoint] {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        var points: [RoutePoint] = []
        points.reserveCapacity(count)

        for index in 0..<count {
            let value = Double(index)
            let altitude = 100 + Double(index % 500) * 0.02

            points.append(RoutePoint(
                timestamp: base.addingTimeInterval(value),
                latitude: 37 + value * 0.000001,
                longitude: -122,
                altitudeMeters: altitude,
                distanceFromStartMeters: value,
                elapsedSeconds: value,
                routeSegmentIndex: 0
            ))
        }

        return points
    }
}
