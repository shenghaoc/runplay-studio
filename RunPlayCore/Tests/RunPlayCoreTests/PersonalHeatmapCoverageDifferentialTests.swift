import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

// Native oracle for differential tests and release measurements only.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Transitional C++ reference for per-workout personal heatmap coverage. It
/// exists only here: Core production code calls the Swift engine through
/// `RunPlayPersonalHeatmapCoverageBridge`. The C++ boundary is capacity
/// negotiated, so this bridge asks once with no output capacity, reads
/// `required_cell_count`, allocates exactly that and calls again. Swift owns
/// every buffer; C++ retains nothing and calls back into nothing.
enum RunPlayPersonalHeatmapCoverageCppBridge {
    struct Observation {
        var error: PersonalHeatmapCoverageError?
        var result: PersonalHeatmapCoverageResult
        var nativeCallCount: Int
    }

    /// The one native call site: every observation and measurement goes through it.
    static func nativeCall(
        _ input: UnsafeBufferPointer<runplay.PersonalHeatmapRouteSample>,
        cellSizeMeters: Double, maximumIntervalMeters: Double, maximumCellsPerInterval: Int,
        output: UnsafeMutableBufferPointer<runplay.PersonalHeatmapCellIndex>
    ) -> runplay.PersonalHeatmapCoverageSummary {
        runplay.compute_personal_heatmap_workout_coverage(
            input.baseAddress, input.count, cellSizeMeters, maximumIntervalMeters,
            maximumCellsPerInterval, output.baseAddress, output.count
        )
    }

    static func observe(
        _ samples: [PersonalHeatmapRouteSample], cellSizeMeters: Double,
        maximumIntervalMeters: Double, maximumCellsPerInterval: UInt
    ) -> Observation {
        var input = ContiguousArray<runplay.PersonalHeatmapRouteSample>()
        input.reserveCapacity(samples.count)
        for sample in samples {
            input.append(runplay.PersonalHeatmapRouteSample(
                latitude: sample.latitude, longitude: sample.longitude, route_segment_index: sample.routeSegmentIndex
            ))
        }

        func call(_ output: inout ContiguousArray<runplay.PersonalHeatmapCellIndex>) -> runplay.PersonalHeatmapCoverageSummary {
            input.withUnsafeBufferPointer { inputBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    nativeCall(
                        inputBuffer, cellSizeMeters: cellSizeMeters, maximumIntervalMeters: maximumIntervalMeters,
                        maximumCellsPerInterval: Int(bitPattern: maximumCellsPerInterval), output: outputBuffer
                    )
                }
            }
        }

        var output = ContiguousArray<runplay.PersonalHeatmapCellIndex>()
        var summary = call(&output)
        var calls = 1
        if summary.status == .insufficient_output_capacity {
            output = ContiguousArray(repeating: runplay.PersonalHeatmapCellIndex(), count: Int(summary.required_cell_count))
            summary = call(&output)
            calls += 1
        }

        var result = PersonalHeatmapCoverageResult()
        switch summary.status {
        case .success: break
        case .invalid_configuration: return Observation(error: .invalidConfiguration, result: result, nativeCallCount: calls)
        case .invalid_input_contract: return Observation(error: .invalidInputContract, result: result, nativeCallCount: calls)
        case .internal_failure: return Observation(error: .internalFailure, result: result, nativeCallCount: calls)
        default:
            Issue.record("unexpected native status \(summary.status)")
            return Observation(error: .internalFailure, result: result, nativeCallCount: calls)
        }
        result.validProjectedPointCount = summary.valid_projected_point_count
        result.effectiveSegmentCount = summary.effective_segment_count
        result.invalidIntervalCount = summary.invalid_interval_count
        result.cells = output.prefix(Int(summary.written_cell_count)).map {
            PersonalHeatmapCellIndex(x: $0.x, y: $0.y)
        }
        return Observation(error: nil, result: result, nativeCallCount: calls)
    }
}

extension RunPlayPersonalHeatmapCoverageCppBridge {
    /// Complete C++ pass for release measurements: convert the routes, then per
    /// workout make one native call with an initial output capacity, renegotiate
    /// once if it was too small, and count the cells directly into `counts`.
    /// This reproduces the shape of the pre-migration production path.
    static func completeAccumulate(
        workoutRoutes: [[RoutePoint]], cellSizeMeters: Double, maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int, into counts: inout [PersonalHeatmapCellID: Int]
    ) -> Int {
        var samples = ContiguousArray<runplay.PersonalHeatmapRouteSample>()
        var ranges: [Range<Int>] = []
        for route in workoutRoutes {
            let start = samples.count
            for point in route {
                samples.append(runplay.PersonalHeatmapRouteSample(
                    latitude: point.latitude, longitude: point.longitude,
                    route_segment_index: Int64(point.routeSegmentIndex)
                ))
            }
            ranges.append(start..<samples.count)
        }

        var retries = 0
        for range in ranges where !range.isEmpty {
            let initialCapacity = max(64, min(262_144, min(range.count, 131_072) * 2))
            var output = ContiguousArray<runplay.PersonalHeatmapCellIndex>(
                repeating: runplay.PersonalHeatmapCellIndex(), count: initialCapacity
            )
            func call() -> runplay.PersonalHeatmapCoverageSummary {
                samples.withUnsafeBufferPointer { sampleBuffer in
                    output.withUnsafeMutableBufferPointer { outBuffer in
                        nativeCall(
                            UnsafeBufferPointer(rebasing: sampleBuffer[range]),
                            cellSizeMeters: cellSizeMeters, maximumIntervalMeters: maximumIntervalMeters,
                            maximumCellsPerInterval: maximumCellsPerInterval, output: outBuffer
                        )
                    }
                }
            }
            var summary = call()
            if summary.status == .insufficient_output_capacity {
                retries += 1
                output = ContiguousArray(repeating: runplay.PersonalHeatmapCellIndex(), count: Int(summary.required_cell_count))
                summary = call()
            }
            guard summary.status == .success else { continue }
            for index in 0..<Int(summary.written_cell_count) {
                counts[PersonalHeatmapCellID(x: output[index].x, y: output[index].y), default: 0] += 1
            }
        }
        return retries
    }
}

/// Compares the Swift kernel with the unchanged C++ kernel. Every output is an
/// integer, so the comparison is exact: cells, counts and error cases.
@Suite(.serialized)
struct PersonalHeatmapCoverageDifferentialTests {
    typealias Sample = PersonalHeatmapRouteSample
    typealias Case = (name: String, samples: [Sample], cell: Double, interval: Double, maximumCells: UInt)

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

    struct Outcome {
        let name: String
        let swift: RunPlayPersonalHeatmapCoverageCppBridge.Observation
        let cpp: RunPlayPersonalHeatmapCoverageCppBridge.Observation
    }

    /// Both kernels over the whole corpus, computed once and shared by the tests.
    static let outcomes: [Outcome] = cases.map { item in
        Outcome(
            name: item.name,
            swift: swiftObservation(item),
            cpp: RunPlayPersonalHeatmapCoverageCppBridge.observe(
                item.samples, cellSizeMeters: item.cell, maximumIntervalMeters: item.interval,
                maximumCellsPerInterval: item.maximumCells
            )
        )
    }

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

        // A large route in every run; the one-million-point product limit runs
        // in `productLimitMatches` when RUNPLAY_BENCHMARK_PRODUCT_LIMIT=1.
        add("three hundred thousand points", largeRoute(count: 300_000), 10, 500)
        return cases
    }

    // MARK: Comparison

    private static func swiftObservation(_ item: Case) -> RunPlayPersonalHeatmapCoverageCppBridge.Observation {
        do {
            let result = try PersonalHeatmapCoverage.compute(
                samples: item.samples.span, cellSizeMeters: item.cell,
                maximumIntervalMeters: item.interval, maximumCellsPerInterval: item.maximumCells
            )
            return .init(error: nil, result: result, nativeCallCount: 1)
        } catch {
            return .init(error: error, result: PersonalHeatmapCoverageResult(), nativeCallCount: 1)
        }
    }

    static func difference(
        _ swift: RunPlayPersonalHeatmapCoverageCppBridge.Observation,
        _ cpp: RunPlayPersonalHeatmapCoverageCppBridge.Observation
    ) -> String? {
        if swift.error != cpp.error { return "error \(String(describing: swift.error)) vs \(String(describing: cpp.error))" }
        if swift.error != nil { return nil }
        let a = swift.result, b = cpp.result
        guard a.validProjectedPointCount == b.validProjectedPointCount,
              a.effectiveSegmentCount == b.effectiveSegmentCount,
              a.invalidIntervalCount == b.invalidIntervalCount
        else { return "counts" }
        guard a.cells.count == b.cells.count else { return "cell count \(a.cells.count) vs \(b.cells.count)" }
        for index in a.cells.indices where a.cells[index] != b.cells[index] { return "cell \(index)" }
        return nil
    }

    @Test func cppAndSwiftMatch() {
        var negotiated = 0
        for outcome in Self.outcomes {
            if outcome.cpp.nativeCallCount > 1 { negotiated += 1 }
            if let difference = Self.difference(outcome.swift, outcome.cpp) { Issue.record("\(outcome.name): \(difference)") }
        }
        print("HEATMAP_CASES \(Self.platformTag) cases=\(Self.outcomes.count) capacityNegotiated=\(negotiated)")
    }

    /// The same comparison at the one-million-point product limit.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1"))
    func productLimitMatches() {
        let item: Case = ("one million points", Self.largeRoute(count: 1_000_000), 10, 500, 10_000)
        let swift = Self.swiftObservation(item)
        let cpp = RunPlayPersonalHeatmapCoverageCppBridge.observe(
            item.samples, cellSizeMeters: item.cell, maximumIntervalMeters: item.interval,
            maximumCellsPerInterval: item.maximumCells
        )
        #expect(Self.difference(swift, cpp) == nil)
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

    private static func append(_ observation: RunPlayPersonalHeatmapCoverageCppBridge.Observation, to digest: inout FNV1a64) {
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

    /// Captured from the unchanged C++ kernel on each platform. `tan` and `log`
    /// come from the platform libm, so the macOS and Linux digests may differ.
    /// This Swift-only test survives removal of the live native differential.
    static var cppGolden: UInt64? {
        #if os(macOS) && arch(arm64)
        return 0x6260_5260_1523_f8d8
        #elseif os(Linux) && arch(x86_64)
        // Captured from the C++ oracle in hosted Linux CI run 45347320979.
        return 0x6260_5260_1523_f8d8
        #else
        return nil
        #endif
    }

    @Test(.enabled(if: PersonalHeatmapCoverageDifferentialTests.cppGolden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        #expect(Self.swiftDigest() == (try #require(Self.cppGolden)))
    }

    @Test func captureDigests() {
        var cppDigest = FNV1a64()
        for outcome in Self.outcomes { Self.append(outcome.cpp, to: &cppDigest) }
        print("HEATMAP_NATIVE_FNV1A64 \(String(cppDigest.value, radix: 16)) \(Self.platformTag)")
        print("HEATMAP_SWIFT_FNV1A64 \(String(Self.swiftDigest(), radix: 16)) \(Self.platformTag)")
    }
}
