import Foundation
import XCTest
@testable import RunPlayCore

/// Reproducible release benchmark for DEM tile planning and bilinear sampling.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Run through
/// `scripts/run-route-quality-benchmark.sh` in release mode, which prints this
/// report after the route-quality one. Tiles are synthetic and decoded once up
/// front, so "tile hand-off" measures only the in-memory hand-off; PNG decoding
/// cost belongs to the Platform tile source, not to this boundary. Each case
/// prints one `BenchmarkBaselineLine`: an absolute Swift timing with no ratio
/// gate.
final class DemElevationSamplingBenchmark: XCTestCase {
    private static let benchmarkName = "DemElevationSamplingBenchmark"
    private static let pointCount = 100_000
    private static let productLimitCount = 1_000_000
    private static let warmupIterations = 3
    private static let measuredIterations = 15
    private static let grid = RunPlayDemSamplingGrid(
        zoom: 12,
        tileSize: 256,
        maximumTileCount: 512,
        plausibleElevationMeters: -500...9_000
    )

    func testDemElevationSamplingBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1",
            "Set RUNPLAY_BENCHMARK=1 to run the release benchmark."
        )

        let points = Self.makeRoute(Self.pointCount)
        let tiles = try Self.syntheticTiles(for: points)
        let loadTiles: ([RunPlayDemTileKey]) -> [RunPlayDemDecodedTile] = { planned in
            planned.compactMap { tiles[$0] }
        }

        var completeSamples: [Double] = []
        var sampledCount = 0

        let total = Self.warmupIterations + Self.measuredIterations
        for iteration in 0..<total {
            let completeElapsed = try Self.timeThrowing {
                let outcome = try RunPlayDemElevationBridge.sampleElevations(
                    routePoints: points,
                    grid: Self.grid,
                    cancellationCheckStride: RouteQualityPolicy.runningDefault.cancellationCheckStride,
                    loadTiles: loadTiles,
                    isCancelled: { false }
                )
                if case .sampled(let result) = outcome {
                    sampledCount = result.sampledCount
                }
            }

            guard iteration >= Self.warmupIterations else { continue }
            completeSamples.append(completeElapsed)
        }

        XCTAssertEqual(sampledCount, Self.pointCount, "every point of the synthetic route is covered")

        // The complete adapter: plan, tile hand-off, and sample.
        let adapterLine = BenchmarkBaselineLine.make(
            Self.benchmarkName,
            "adapter",
            counts: ["points": Self.pointCount, "tiles": tiles.count, "zoom": Self.grid.zoom, "tile_size": Self.grid.tileSize],
            iterations: Self.measuredIterations,
            medianMilliseconds: Self.median(completeSamples)
        )
        print("""

        RunPlay DEM elevation sampling benchmark
        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations, medians in ms
        \(adapterLine)
        """)

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.runProductLimitProbe()
        }
    }

    private static func runProductLimitProbe() throws {
        let points = makeRoute(productLimitCount)
        let tiles = try syntheticTiles(for: points)
        var swiftSamples: [Double] = []
        let loadTiles: ([RunPlayDemTileKey]) -> [RunPlayDemDecodedTile] = { planned in planned.compactMap { tiles[$0] } }
        let warmups = 1
        let iterations = 3
        for iteration in 0..<(warmups + iterations) {
            let swiftElapsed = try timeThrowing {
                _ = try RunPlayDemElevationBridge.sampleElevations(
                    routePoints: points, grid: grid,
                    cancellationCheckStride: RouteQualityPolicy.runningDefault.cancellationCheckStride,
                    loadTiles: loadTiles, isCancelled: { false }
                )
            }
            if iteration >= warmups { swiftSamples.append(swiftElapsed) }
        }
        let memory = processMemorySnapshot()
        print(BenchmarkBaselineLine.make(
            benchmarkName,
            "product-limit-adapter",
            counts: ["points": productLimitCount, "tiles": tiles.count],
            iterations: iterations,
            medianMilliseconds: median(swiftSamples)
        ))
        print(BenchmarkBaselineLine.memory(
            benchmarkName,
            "product-limit-peak-rss",
            bytes: memory.highWaterResidentBytes > 0 ? memory.highWaterResidentBytes : nil
        ))
    }

    /// A long course through the Alps at zoom 12: about 300 km on a slowly
    /// turning heading whatever the point count, so the product-limit probe
    /// reuses the same tiles at ten times the sampling density.
    private static func makeRoute(_ count: Int) -> [RoutePoint] {
        var points: [RoutePoint] = []
        points.reserveCapacity(count)
        var latitude = 46.0
        var longitude = 7.5
        let metresPerDegreeLatitude = 111_132.0
        let stepMetres = 300_000 / Double(count)
        for index in 0..<count {
            let progress = Double(index) / Double(count)
            let heading = 2 * Double.pi * progress * 1.5
            let northMetres = stepMetres * cos(heading)
            let eastMetres = stepMetres * sin(heading)
            latitude += northMetres / metresPerDegreeLatitude
            let metresPerDegreeLongitude = metresPerDegreeLatitude * cos(latitude * .pi / 180)
            longitude += eastMetres / metresPerDegreeLongitude
            let seconds: TimeInterval = 800_000_000 + Double(index)
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                latitude: latitude,
                longitude: longitude,
                elapsedSeconds: Double(index)
            ))
        }
        return points
    }

    /// Plans the route once and builds a smooth synthetic terrain for exactly
    /// the planned tiles.
    private static func syntheticTiles(for points: [RoutePoint]) throws -> [RunPlayDemTileKey: RunPlayDemDecodedTile] {
        var planned: [RunPlayDemTileKey] = []
        _ = try RunPlayDemElevationBridge.sampleElevations(
            routePoints: points,
            grid: grid,
            cancellationCheckStride: 65_536,
            loadTiles: { keys in
                planned = keys
                return []
            },
            isCancelled: { false }
        )
        let size = grid.tileSize
        var tiles: [RunPlayDemTileKey: RunPlayDemDecodedTile] = [:]
        for key in planned {
            var heights: [Float] = []
            heights.reserveCapacity(size * size)
            for row in 0..<size {
                for column in 0..<size {
                    let x = Double(Int(key.x) * size + column)
                    let y = Double(Int(key.y) * size + row)
                    let height = 1_500 + 400 * sin(x / 900) + 300 * cos(y / 700)
                    heights.append(Float(height))
                }
            }
            tiles[key] = RunPlayDemDecodedTile(key: key, heightsMeters: heights)
        }
        return tiles
    }

    private static func timeThrowing(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
