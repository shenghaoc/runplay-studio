import XCTest
@testable import RunPlayCore

/// Release benchmark for personal heatmap coverage: the complete Swift path
/// (conversion, one engine call per workout, direct cell counting). It reports
/// absolute Swift medians; there is no reference engine and no ratio gate.
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Always run in release.
/// `RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1` adds the one-million-point probe.
///
/// The test keeps its former name so the benchmark script filter still matches.
final class PersonalHeatmapEngineBenchmark: XCTestCase {
    func testCompleteSwiftEngineBaseline() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1", "Set RUNPLAY_BENCHMARK=1")
        print("\n<!-- BEGIN RUNPLAY HEATMAP ENGINE BENCHMARK -->")
        try runFixture("H1 250 workouts x 1000 points, cell 50 m", routes: Self.routes(count: 250, points: 1_000), cell: 50, warmups: 3, iterations: 15)
        try runFixture("H2 250 workouts x 1000 points, cell 5 m", routes: Self.routes(count: 250, points: 1_000), cell: 5, warmups: 3, iterations: 15)
        try runFixture("H3 20 workouts x 20000 points, cell 10 m", routes: Self.routes(count: 20, points: 20_000), cell: 10, warmups: 2, iterations: 9)
        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try runFixture("H4 1 workout x 1000000 points, cell 50 m", routes: Self.routes(count: 1, points: 1_000_000), cell: 50, warmups: 1, iterations: 5)
        }
        print("<!-- END RUNPLAY HEATMAP ENGINE BENCHMARK -->\n")
    }

    private func runFixture(_ label: String, routes: [[RoutePoint]], cell: Double, warmups: Int, iterations: Int) throws {
        let interval = 500.0
        let maxCells = PersonalHeatmapGridTraversal.defaultMaximumCellsPerInterval
        func swiftPass() throws -> [PersonalHeatmapCellID: Int] {
            var counts: [PersonalHeatmapCellID: Int] = [:]
            let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(workoutRoutes: routes, isCancelled: { false })
            for index in 0..<batch.workoutCount {
                _ = try batch.accumulateCoverage(
                    workoutIndex: index, cellSizeMeters: cell, maximumIntervalMeters: interval,
                    maximumCellsPerInterval: maxCells, into: &counts, isCancelled: { false }
                )
            }
            return counts
        }
        let reference = try swiftPass()
        XCTAssertFalse(reference.isEmpty, "\(label): no cells")

        var swiftTimes: [Double] = []
        for iteration in 0..<(warmups + iterations) {
            var counts: [PersonalHeatmapCellID: Int] = [:]
            let swiftElapsed = try Self.time { counts = try swiftPass() }
            XCTAssertEqual(counts, reference, "\(label): counts differ between runs")
            if iteration >= warmups { swiftTimes.append(swiftElapsed) }
        }
        let swiftMedian = Self.median(swiftTimes)
        print("HEATMAP_ENGINE \(label) swift=\(String(format: "%.3f", swiftMedian)) ms")
    }

    private static func routes(count: Int, points: Int) -> [[RoutePoint]] {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        return (0..<count).map { workout in
            var lat = 37.7749 + Double(workout % 10) * 0.005
            var lon = -122.4194 + Double(workout / 10) * 0.005
            var segment = 0
            var route: [RoutePoint] = []
            route.reserveCapacity(points)
            for p in 0..<points {
                if p > 0 && p % 250 == 0 { segment += 1 }
                if p == 300 { lat += 0.1 } else {
                    lat += 0.00005 * (p % 2 == 0 ? 1.0 : -0.5)
                    lon += 0.00005 * (p % 3 == 0 ? 1.0 : -0.2)
                }
                route.append(RoutePoint(
                    timestamp: base.addingTimeInterval(Double(p)),
                    latitude: p == 100 ? 200.0 : lat, longitude: lon, routeSegmentIndex: segment
                ))
            }
            return route
        }
    }

    private static func time(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
