import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

/// Pins the Swift personal heatmap coverage kernel to a golden digest. The
/// corpus and digest are those of the former Swift-versus-C++ differential
/// test. Every output is an integer: cells, counts and error cases.
@Suite(.serialized)
struct PersonalHeatmapCoverageGoldenTests {
    typealias Sample = PersonalHeatmapRouteSample
    typealias Case = (name: String, samples: [Sample], cell: Double, interval: Double, maximumCells: UInt)

    /// Raw observation of one engine call.
    struct Observation {
        var error: PersonalHeatmapCoverageError?
        var result: PersonalHeatmapCoverageResult
    }


    // MARK: Corpus

    private static func s(_ latitude: Double, _ longitude: Double, _ segment: Int64 = 0) -> Sample {
        Sample(latitude: latitude, longitude: longitude, routeSegmentIndex: segment)
    }

    static func largeRoute(count: Int) -> [Sample] {
        var route: [Sample] = []
        route.reserveCapacity(count)
        for index in 0..<count {
            let offset = Double(index) * 0.000_004
            route.append(Sample(
                latitude: 37.7749 + offset * 0.5, longitude: -122.4194 + offset,
                routeSegmentIndex: Int64(index / 100_000)
            ))
        }
        return route
    }

    static let cases: [Case] = corpus()

    static func corpus() -> [Case] {
        var cases: [Case] = []
        func add(_ name: String, _ samples: [Sample], _ cell: Double = 10, _ interval: Double = 500, _ cells: UInt = 10_000) {
            cases.append((name, samples, cell, interval, cells))
        }
        let nan = Double.nan, inf = Double.infinity
        add("empty", [])
        add("one point", [s(37.7749, -122.4194)])
        add("projection fixture", [
            s(0, 0), s(85.05112878, 180), s(-85.05112878, -180), s(89, 45), s(-89, -45),
            s(100, 0), s(0, 200), s(nan, 0), s(0, inf),
        ], 10, 50_000)
        add("segments fixture", [s(0, 0), s(0.001, 0.001), s(100, 100), s(0.002, 0.002), s(0.003, 0.003, 1), s(0.004, 0.004, -5)])
        add("traversal loop", [s(0, 0), s(0, 0.001), s(0.001, 0.001), s(0, 0)])
        add("oversized interval", [s(0, 0), s(1, 1)])
        add("duplicate points", [s(1, 1), s(1, 1), s(1, 1)])
        add("antimeridian east to west", [s(0, 179.9999), s(0, -179.9999)], 10, 1e9)
        add("antimeridian step", [s(0, 179.9990), s(0, 179.9999), s(0, 180), s(0, -180), s(0, -179.9999)], 10, 1e9)
        add("north pole clamp", [s(90, 0), s(90, 90), s(89.99, 10)], 10, 1e9)
        add("south pole clamp", [s(-90, 0), s(-90, -90), s(-89.99, 10)], 10, 1e9)
        add("web mercator limit", [s(85.05112878, 0), s(85.0511287798066, 1), s(85.0511287799, -1), s(-85.05112878, 0)], 10, 1e9)
        add("signed zero", [s(-0.0, -0.0), s(0.0, 0.0), s(0.0, -0.0)])
        // 1e-320 and 1e-310 as exact subnormals: a literal underflows with a warning on Linux.
        let tiny = Double(bitPattern: 2024), small = Double(bitPattern: 20_240_225_330_731)
        add("subnormal coordinates", [s(tiny, tiny), s(-tiny, -tiny), s(0, small)])
        add("nonfinite coordinates", [s(nan, nan), s(inf, 0), s(0, -inf), s(-inf, inf)])
        let line = [s(0, 0), s(0, 0.03)]
        for (name, cell, interval, cells) in [
            ("zero cell", 0.0, 500.0, UInt(10_000)), ("negative cell", -1.0, 500.0, 10_000), ("NaN cell", nan, 500, 10_000),
            ("infinite cell", inf, 500, 10_000), ("zero interval", 10, 0, 10_000), ("NaN interval", 10, nan, 10_000),
            ("infinite interval", 10, inf, 10_000), ("zero max cells", 10, 500, 0),
            ("max cells 1", 1, 5_000, 1), ("max cells 2", 1, 5_000, 2), ("max cells 3", 1, 5_000, 3),
            ("max cells 10", 1, 5_000, 10), ("max cells UInt.max", 1, 5_000, UInt.max),
            ("tiny cell", 1e-9, 5_000, 100), ("huge cell", 1e12, 5_000, 10_000), ("cell 1e-12", 1e-12, 5_000, 100),
            ("cell 1 m long line", 1, 5_000, 10_000), ("cell 1000 m", 1000, 5_000, 10_000),
        ] as [(String, Double, Double, UInt)] {
            add("config " + name, line, cell, interval, cells)
        }
        add("empty with bad config", [], 0)

        // Seeded random walks with glitches, segment changes and edge coordinates.
        var rng = SplitMix64(seed: 0x6865_6174_6d61_7073)
        let startLats: [Double] = [0, -0.0, 37.7749, 85.05112878, -85.05112878, 89.9, -89.9, 60, -33.9]
        let startLons: [Double] = [0, 179.99, -179.99, 180, -180, -122.4194, 151.2, 90]
        let steps: [Double] = [0, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 0.01, 0.1]
        let cellSizes: [Double] = [1, 5, 10, 10, 50, 100, 1_000, 1e-3, 1e7, 1e12, 0, -1, .nan, .infinity]
        let intervals: [Double] = [10, 500, 500, 50_000, 1e6, 1e9, 0, .nan, .infinity]
        let maxCells: [UInt] = [0, 1, 2, 3, 10, 10_000, 10_000, UInt.max]
        func pick<T>(_ pool: [T], _ rng: inout SplitMix64) -> T { pool[Int(rng.next() % UInt64(pool.count))] }
        for index in 0..<500 {
            let count = Int(rng.next() % (index.isMultiple(of: 40) ? 3_000 : 60))
            var latitude = pick(startLats, &rng), longitude = pick(startLons, &rng)
            var segment: Int64 = 0
            var samples: [Sample] = []
            samples.reserveCapacity(count)
            for _ in 0..<count {
                let step = pick(steps, &rng)
                latitude += (Double(rng.next() % 2001) - 1_000) / 1_000 * step
                longitude += (Double(rng.next() % 2001) - 1_000) / 1_000 * step
                if rng.next() % 50 == 0 { segment += Int64(rng.next() % 3) - 1 }
                var sample = s(latitude, longitude, segment)
                switch rng.next() % 120 {
                case 0: sample.latitude = .nan
                case 1: sample.longitude = .infinity
                case 2: sample.latitude = 91
                case 3: sample.longitude = -181
                default: break
                }
                samples.append(sample)
            }
            var cell = pick(cellSizes, &rng), interval = pick(intervals, &rng), limit = pick(maxCells, &rng)
            // Keep the work per case bounded: a small cell with a long interval and an
            // unbounded cell budget would traverse billions of cells in a debug build.
            if cell < 100 { limit = min(limit, 100_000) }
            if cell < 10 { interval = interval.isFinite ? min(interval, 100_000) : interval }
            add("seeded \(index)", samples, cell, interval, limit)
        }

        // A large route in every run.
        add("three hundred thousand points", largeRoute(count: 300_000), 10, 500)
        return cases
    }

    // MARK: Observation

    private static func swiftObservation(_ item: Case) -> Observation {
        do {
            let result = try PersonalHeatmapCoverage.compute(
                samples: item.samples.span, cellSizeMeters: item.cell,
                maximumIntervalMeters: item.interval, maximumCellsPerInterval: item.maximumCells
            )
            return .init(error: nil, result: result)
        } catch {
            return .init(error: error, result: PersonalHeatmapCoverageResult())
        }
    }

    // MARK: Golden

    static var platformTag: String {
        #if os(macOS) && arch(arm64)
        return "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
        return "linux-x86_64"
        #else
        return "other"
        #endif
    }

    private static func append(_ observation: Observation, to digest: inout FNV1a64) {
        if let error = observation.error {
            digest.append(byte: 1)
            switch error {
            case .invalidConfiguration: digest.append(byte: 1)
            case .invalidInputContract: digest.append(byte: 2)
            case .internalFailure: digest.append(byte: 3)
            }
            return
        }
        let result = observation.result
        digest.append(byte: 0)
        digest.append(word: result.validProjectedPointCount)
        digest.append(word: result.effectiveSegmentCount)
        digest.append(word: result.invalidIntervalCount)
        digest.append(word: UInt64(result.cells.count))
        for cell in result.cells {
            digest.append(word: cell.x)
            digest.append(word: cell.y)
        }
    }

    static func swiftDigest() -> UInt64 {
        var digest = FNV1a64()
        for item in cases { append(swiftObservation(item), to: &digest) }
        return digest.value
    }

    /// Derived from the C++ kernel before its removal, on each platform. `tan`
    /// and `log` come from the platform libm, so the macOS and Linux digests
    /// may differ. The Swift kernel was asserted equal to C++ on every case.
    static var golden: UInt64? {
        #if os(macOS) && arch(arm64)
        return 0x6260_5260_1523_f8d8
        #elseif os(Linux) && arch(x86_64)
        // Captured from the former C++ kernel in hosted Linux CI run 45347320979.
        return 0x6260_5260_1523_f8d8
        #else
        return nil
        #endif
    }

    /// Fails when a platform condition leaves `golden` nil on a platform that
    /// pins it, which would otherwise disable the golden test silently.
    @Test func goldenIsPinnedOnPinnedPlatforms() {
        #expect(
            !GoldenPlatform.current.pinsKernelGoldens || Self.golden != nil,
            "\(GoldenPlatform.unpinnedMessage("golden"))"
        )
    }

    @Test(.enabled(if: PersonalHeatmapCoverageGoldenTests.golden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        #expect(Self.swiftDigest() == (try #require(Self.golden)))
    }

    @Test func captureDigests() {
        print("HEATMAP_SWIFT_FNV1A64 \(String(Self.swiftDigest(), radix: 16)) \(Self.platformTag)")
    }
}
