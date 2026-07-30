import Foundation
import XCTest
@testable import RunPlayCore

/// Release-only comparison of the former Swift aggregation shape with the
/// production hash, reservation policy, and direct native-buffer consumption.
///
/// The optimized sample is the bounded reservation time plus the direct
/// consumption/counting time reported from the production Interop body. Native
/// execution and output allocation are intentionally excluded from this
/// isolated aggregation measurement.
final class PersonalHeatmapAggregationBenchmark: XCTestCase {
    private static let warmupIterations = 5
    private static let measuredIterations = 20
    private static let cellSizeMeters = 10.0
    private static let maximumIntervalMeters = 50_000.0
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testPersonalHeatmapAggregationBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "RUNPLAY_HEATMAP_AGGREGATION_BENCHMARK"
            ] == "1",
            "Set RUNPLAY_HEATMAP_AGGREGATION_BENCHMARK=1 to run the release benchmark."
        )

        var rows: [String] = []
        for fixture in Self.fixtures() {
            let result = try Self.run(fixture)
            rows.append(
                "| \(fixture.key) \(fixture.name) "
                + "| \(result.updateCount) "
                + "| \(result.uniqueCellCount) "
                + "| \(result.capacityHint) "
                + "| \(Self.format(result.baselineMedian)) "
                + "| \(Self.format(result.baselineP90)) "
                + "| \(Self.format(result.optimizedMedian)) "
                + "| \(Self.format(result.optimizedP90)) "
                + "| \(String(format: "%.3f", result.ratio))× |"
            )
        }

        print("""

        <!-- BEGIN RUNPLAY HEATMAP AGGREGATION BENCHMARK -->

        ## RunPlay Personal Heatmap isolated aggregation benchmark

        Baseline uses a test-only two-field synthesized `Hashable`, no
        dictionary reservation, and materialized per-workout arrays.
        Optimized uses `PersonalHeatmapCellID`, the production bounded
        reservation policy, and direct consumption from the native output
        buffer. Optimized timings include reservation plus direct
        consumption/counting; native execution and native output allocation are
        excluded.

        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations.

        | Fixture | Updates | Unique | Reserve hint | Baseline median ms | Baseline p90 ms | Optimized median ms | Optimized p90 ms | Ratio |
        |---|---:|---:|---:|---:|---:|---:|---:|---:|
        \(rows.joined(separator: "\n"))

        <!-- END RUNPLAY HEATMAP AGGREGATION BENCHMARK -->
        """)
    }

    private struct BaselineCellKey: Hashable {
        let x: Int64
        let y: Int64
    }

    private struct Fixture {
        let key: String
        let name: String
        let routes: [[RoutePoint]]
        let maximumRenderedCellCount: Int
    }

    private struct Result {
        let updateCount: Int
        let uniqueCellCount: Int
        let capacityHint: Int
        let baselineMedian: Double
        let baselineP90: Double
        let optimizedMedian: Double
        let optimizedP90: Double

        var ratio: Double {
            optimizedMedian / max(baselineMedian, 1e-12)
        }
    }

    private static func run(_ fixture: Fixture) throws -> Result {
        let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: fixture.routes,
            isCancelled: { false }
        )

        var baselineArrays: [[BaselineCellKey]] = []
        baselineArrays.reserveCapacity(fixture.routes.count)
        var expectedCounts: [PersonalHeatmapCellID: Int] = [:]
        var updateCount = 0

        for workoutIndex in fixture.routes.indices {
            let coverage = try batch.coverage(
                workoutIndex: workoutIndex,
                cellSizeMeters: cellSizeMeters,
                maximumIntervalMeters: maximumIntervalMeters,
                maximumCellsPerInterval: PersonalHeatmapGridTraversal.defaultMaximumCellsPerInterval,
                isCancelled: { false }
            )
            let baselineCells = coverage.cells.map {
                BaselineCellKey(x: $0.x, y: $0.y)
            }
            baselineArrays.append(baselineCells)
            updateCount += baselineCells.count
            for cell in coverage.cells {
                expectedCounts[cell, default: 0] += 1
            }
        }

        let cappedPointCount = PersonalHeatmapAggregationCapacityPolicy
            .cappedRoutePointCount(
                routePointCounts: fixture.routes.lazy.map(\.count)
            )
        let capacityHint = PersonalHeatmapAggregationCapacityPolicy.initialHint(
            cappedTotalRoutePointCount: cappedPointCount,
            maximumRenderedCellCount: fixture.maximumRenderedCellCount
        )

        var baselineSamples: [Double] = []
        var optimizedSamples: [Double] = []
        let iterationCount = warmupIterations + measuredIterations

        for iteration in 0..<iterationCount {
            let baselineStart = ContinuousClock.now
            var baselineCounts: [BaselineCellKey: Int] = [:]
            for cells in baselineArrays {
                for cell in cells {
                    baselineCounts[cell, default: 0] += 1
                }
            }
            let baselineNanoseconds = nanoseconds(
                from: baselineStart,
                to: ContinuousClock.now
            )

            var optimizedCounts: [PersonalHeatmapCellID: Int] = [:]
            let reservationStart = ContinuousClock.now
            optimizedCounts.reserveCapacity(capacityHint)
            var optimizedNanoseconds = nanoseconds(
                from: reservationStart,
                to: ContinuousClock.now
            )

            for workoutIndex in fixture.routes.indices {
                let result = try batch.profiledAccumulateCoverage(
                    workoutIndex: workoutIndex,
                    cellSizeMeters: cellSizeMeters,
                    maximumIntervalMeters: maximumIntervalMeters,
                    maximumCellsPerInterval: PersonalHeatmapGridTraversal.defaultMaximumCellsPerInterval,
                    into: &optimizedCounts,
                    isCancelled: { false }
                )
                optimizedNanoseconds +=
                    result.profile.directCellConsumptionAndCountingNanoseconds
            }

            XCTAssertEqual(baselineCounts.count, expectedCounts.count)
            XCTAssertEqual(
                baselineCounts.values.reduce(0, +),
                expectedCounts.values.reduce(0, +)
            )
            XCTAssertEqual(optimizedCounts, expectedCounts)

            guard iteration >= warmupIterations else { continue }
            baselineSamples.append(Double(baselineNanoseconds) / 1_000_000)
            optimizedSamples.append(Double(optimizedNanoseconds) / 1_000_000)
        }

        return Result(
            updateCount: updateCount,
            uniqueCellCount: expectedCounts.count,
            capacityHint: capacityHint,
            baselineMedian: median(baselineSamples),
            baselineP90: percentile(baselineSamples, fraction: 0.9),
            optimizedMedian: median(optimizedSamples),
            optimizedP90: percentile(optimizedSamples, fraction: 0.9)
        )
    }

    private static func fixtures() -> [Fixture] {
        let representativeUnique = (0..<100).map { corridorIndex in
            corridor(
                latitude: -24.75 + Double(corridorIndex) * 0.5,
                startLongitude: -10,
                longitudeSpan: 0.269,
                seed: corridorIndex
            )
        }
        let representative = (0..<3).flatMap { _ in representativeUnique }

        let shared = corridor(
            latitude: 1.30,
            startLongitude: 103.80,
            longitudeSpan: 0.269,
            seed: 500
        )
        let highOverlap = Array(repeating: shared, count: 100)

        let lowOverlap = (0..<100).map { corridorIndex in
            corridor(
                latitude: -24.75 + Double(corridorIndex) * 0.5,
                startLongitude: 20,
                longitudeSpan: 0.269,
                seed: 1_000 + corridorIndex
            )
        }

        let tinyUnique = (0..<100).map { index in
            [
                point(
                    latitude: -5 + Double(index / 10) * 0.01,
                    longitude: -5 + Double(index % 10) * 0.01,
                    index: index
                )
            ]
        }
        let manyTiny = (0..<20).flatMap { _ in tinyUnique }

        let negativeIndexes = (0..<100).map { corridorIndex in
            corridor(
                latitude: -45 + Double(corridorIndex) * 0.2,
                startLongitude: -100,
                longitudeSpan: 0.09,
                seed: 2_000 + corridorIndex
            )
        }

        return [
            Fixture(
                key: "R",
                name: "≈900k updates / ≈300k unique",
                routes: representative,
                maximumRenderedCellCount: 5_000
            ),
            Fixture(
                key: "H",
                name: "high overlap",
                routes: highOverlap,
                maximumRenderedCellCount: 5_000
            ),
            Fixture(
                key: "L",
                name: "low overlap",
                routes: lowOverlap,
                maximumRenderedCellCount: 5_000
            ),
            Fixture(
                key: "T",
                name: "many tiny workouts",
                routes: manyTiny,
                maximumRenderedCellCount: 5_000
            ),
            Fixture(
                key: "N",
                name: "negative cell indexes",
                routes: negativeIndexes,
                maximumRenderedCellCount: 5_000
            )
        ]
    }

    private static func corridor(
        latitude: Double,
        startLongitude: Double,
        longitudeSpan: Double,
        seed: Int,
        pointCount: Int = 1_000
    ) -> [RoutePoint] {
        precondition(pointCount >= 2)
        return (0..<pointCount).map { pointIndex in
            let fraction = Double(pointIndex) / Double(pointCount - 1)
            return point(
                latitude: latitude,
                longitude: startLongitude + longitudeSpan * fraction,
                index: seed * pointCount + pointIndex
            )
        }
    }

    private static func point(
        latitude: Double,
        longitude: Double,
        index: Int
    ) -> RoutePoint {
        RoutePoint(
            timestamp: origin.addingTimeInterval(Double(index)),
            latitude: latitude,
            longitude: longitude,
            routeSegmentIndex: 0
        )
    }

    private static func nanoseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> UInt64 {
        let components = start.duration(to: end).components
        let value = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        return value > 0 ? UInt64(value) : 0
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func percentile(
        _ values: [Double],
        fraction: Double
    ) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
