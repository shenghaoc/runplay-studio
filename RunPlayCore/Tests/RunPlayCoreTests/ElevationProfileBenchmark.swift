import Foundation
import Testing
@testable import RunPlayCore

/// Release-mode elevation profile benchmarks.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Always intended to run in release.
@Suite("ElevationProfile benchmarks", .disabled(if: ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] != "1"))
struct ElevationProfileBenchmark {

    @Test("E1 ordinary 1,000-point workout")
    func e1Ordinary() throws {
        try runSuite(name: "E1", count: 1_000, warmups: 5, measurements: 20)
    }

    @Test("E2 100,000 dense altitude points")
    func e2Dense() throws {
        try runSuite(name: "E2", count: 100_000, warmups: 2, measurements: 5)
    }

    @Test("E7 1,000,000-point product limit")
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

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        func measure(_ body: () throws -> Void) rethrows -> Double {
            for _ in 0..<warmups {
                try body()
            }
            var samples: [Double] = []
            samples.reserveCapacity(measurements)
            for _ in 0..<measurements {
                let start = DispatchTime.now().uptimeNanoseconds
                try body()
                let end = DispatchTime.now().uptimeNanoseconds
                samples.append(Double(end - start) / 1_000_000.0)
            }
            return median(samples)
        }

        let oracleMs = measure {
            _ = SwiftElevationProfileOracle.build(routePoints: points, policy: policy)
        }
        let bridgeMs = try measure {
            _ = try RunPlayElevationProfileBridge.build(
                routePoints: points,
                policy: policy,
                isCancelled: { false }
            )
        }
        let productionMs = try measure {
            _ = try ElevationProfile.build(
                routePoints: points,
                policy: policy,
                isCancelled: { false }
            )
        }

        let ratio = oracleMs > 0 ? bridgeMs / oracleMs : 0
        print(
            """
            ElevationProfileBenchmark \(name):
              oracle_ms=\(String(format: "%.3f", oracleMs))
              bridge_ms=\(String(format: "%.3f", bridgeMs))
              production_ms=\(String(format: "%.3f", productionMs))
              bridge_over_oracle=\(String(format: "%.3f", ratio))
            """
        )

        #expect(bridgeMs > 0)
        #expect(productionMs > 0)
        if count >= 100_000 {
            #expect(bridgeMs <= oracleMs * 1.05)
        }
    }

    private func makeClimb(count: Int) -> [RoutePoint] {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        return (0..<count).map { index in
            RoutePoint(
                timestamp: base.addingTimeInterval(Double(index)),
                latitude: 37.0 + Double(index) * 0.000001,
                longitude: -122.0,
                altitudeMeters: 100.0 + Double(index % 500) * 0.02,
                distanceFromStartMeters: Double(index),
                elapsedSeconds: Double(index),
                routeSegmentIndex: 0
            )
        }
    }
}
