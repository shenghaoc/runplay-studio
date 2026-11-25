import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

// Native oracle for differential tests and release measurements only.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Transitional C++ reference for DEM tile planning and bilinear sampling. It
/// exists only here: Core production code calls the Swift engine through
/// `RunPlayDemElevationBridge`. Each native call is made through one helper;
/// Swift owns every buffer, and C++ retains nothing and calls back into nothing.
enum RunPlayDemElevationCppBridge {
    struct PlanObservation {
        var error: DemTilePlanError?
        var result: DemTilePlanResult
    }

    struct SampleObservation {
        var error: DemSamplingError?
        var result: DemSamplingResult
    }

    private static func nativePolicy(_ policy: DemSamplingPolicy) -> runplay.DemSamplingPolicy {
        var native = runplay.DemSamplingPolicy()
        native.zoom = policy.zoom
        native.tile_size = policy.tileSize
        native.maximum_tile_count = policy.maximumTileCount
        native.minimum_plausible_elevation_meters = policy.minimumPlausibleElevationMeters
        native.maximum_plausible_elevation_meters = policy.maximumPlausibleElevationMeters
        return native
    }

    private static func nativeSamples(_ samples: [DemRouteSample]) -> ContiguousArray<runplay.DemRouteSample> {
        var native = ContiguousArray<runplay.DemRouteSample>()
        native.reserveCapacity(samples.count)
        for sample in samples {
            var value = runplay.DemRouteSample()
            value.latitude_degrees = sample.latitudeDegrees
            value.longitude_degrees = sample.longitudeDegrees
            native.append(value)
        }
        return native
    }

    /// The one native planning call site.
    private static func planCall(
        _ samples: UnsafeBufferPointer<runplay.DemRouteSample>, _ policy: runplay.DemSamplingPolicy,
        _ output: UnsafeMutableBufferPointer<runplay.DemTileKey>
    ) -> runplay.DemTilePlanSummary {
        runplay.plan_dem_tiles(samples.baseAddress, samples.count, policy, output.baseAddress, output.count)
    }

    /// The one native sampling call site.
    private static func sampleCall(
        _ samples: UnsafeBufferPointer<runplay.DemRouteSample>, _ policy: runplay.DemSamplingPolicy,
        _ keys: UnsafeBufferPointer<runplay.DemTileKey>, _ heights: UnsafeBufferPointer<runplay.DemTileHeightSample>,
        _ output: UnsafeMutableBufferPointer<runplay.DemElevationOutputSample>
    ) -> runplay.DemSamplingSummary {
        runplay.sample_dem_elevations(
            samples.baseAddress, samples.count, policy, keys.baseAddress, keys.count,
            heights.baseAddress, heights.count, output.baseAddress, output.count
        )
    }

    /// Plans with a capacity equal to the tile budget, as the pre-migration bridge did.
    static func observePlan(_ samples: [DemRouteSample], policy: DemSamplingPolicy) -> PlanObservation {
        let input = nativeSamples(samples)
        let capacity = Int(min(max(policy.maximumTileCount, 1), UInt64(EngineDemLimits.maximumTileCount)))
        var output = ContiguousArray(repeating: runplay.DemTileKey(), count: capacity)
        let summary = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                planCall(inputBuffer, nativePolicy(policy), outputBuffer)
            }
        }
        var result = DemTilePlanResult()
        switch summary.status {
        case .success: break
        case .tile_budget_exceeded: return PlanObservation(error: .tileBudgetExceeded, result: result)
        case .resource_limit: return PlanObservation(error: .resourceLimit, result: result)
        case .invalid_policy: return PlanObservation(error: .invalidPolicy, result: result)
        case .internal_failure: return PlanObservation(error: .internalFailure, result: result)
        default:
            Issue.record("unexpected native planning status \(summary.status)")
            return PlanObservation(error: .internalFailure, result: result)
        }
        result.sampleCount = summary.sample_count
        result.projectableSampleCount = summary.projectable_sample_count
        result.invalidCoordinateCount = summary.invalid_coordinate_count
        result.outsideProjectionCount = summary.outside_projection_count
        result.tiles = output.prefix(Int(summary.written_tile_count)).map { DemTileKey(x: $0.x, y: $0.y) }
        return PlanObservation(error: nil, result: result)
    }

    static func observeSample(
        _ samples: [DemRouteSample], policy: DemSamplingPolicy, tiles: [DemTileKey], heights: [Float]
    ) -> SampleObservation {
        let input = nativeSamples(samples)
        var keys = ContiguousArray<runplay.DemTileKey>()
        for key in tiles {
            var native = runplay.DemTileKey()
            native.x = key.x
            native.y = key.y
            keys.append(native)
        }
        var nativeHeights = ContiguousArray<runplay.DemTileHeightSample>()
        nativeHeights.reserveCapacity(heights.count)
        for height in heights {
            var native = runplay.DemTileHeightSample()
            native.height_meters = height
            nativeHeights.append(native)
        }
        var output = ContiguousArray(repeating: runplay.DemElevationOutputSample(), count: samples.count)
        let summary = input.withUnsafeBufferPointer { inputBuffer in
            keys.withUnsafeBufferPointer { keyBuffer in
                nativeHeights.withUnsafeBufferPointer { heightBuffer in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        sampleCall(inputBuffer, nativePolicy(policy), keyBuffer, heightBuffer, outputBuffer)
                    }
                }
            }
        }
        var result = DemSamplingResult()
        switch summary.status {
        case .success: break
        case .resource_limit: return SampleObservation(error: .resourceLimit, result: result)
        case .invalid_policy: return SampleObservation(error: .invalidPolicy, result: result)
        case .invalid_tile_directory: return SampleObservation(error: .invalidTileDirectory, result: result)
        case .internal_failure: return SampleObservation(error: .internalFailure, result: result)
        default:
            Issue.record("unexpected native sampling status \(summary.status)")
            return SampleObservation(error: .internalFailure, result: result)
        }
        result.sampleCount = summary.sample_count
        result.sampledCount = summary.sampled_count
        result.invalidCoordinateCount = summary.invalid_coordinate_count
        result.outsideProjectionCount = summary.outside_projection_count
        result.missingTileCount = summary.missing_tile_count
        result.implausibleHeightCount = summary.implausible_height_count
        result.samples = output.map { native in
            var sample = DemElevationOutputSample()
            sample.elevationMeters = native.elevation_meters
            switch native.status {
            case .sampled: sample.status = .sampled
            case .invalid_coordinate: sample.status = .invalidCoordinate
            case .outside_projection: sample.status = .outsideProjection
            case .missing_tile: sample.status = .missingTile
            case .implausible_height: sample.status = .implausibleHeight
            @unknown default: sample.status = .invalidCoordinate
            }
            sample.hasElevation = native.has_elevation
            return sample
        }
        return SampleObservation(error: nil, result: result)
    }

    /// Complete C++ path from Core values, for release measurements only: the
    /// same conversion, planning, tile hand-off, directory validation and
    /// translation as the production adapter, with the native kernels.
    static func sampleElevations(
        routePoints: [RoutePoint], grid: RunPlayDemSamplingGrid,
        loadTiles: ([RunPlayDemTileKey]) throws -> [RunPlayDemDecodedTile]
    ) throws -> RunPlayDemSamplingOutcome {
        let samples = routePoints.map { DemRouteSample(latitudeDegrees: $0.latitude, longitudeDegrees: $0.longitude) }
        let policy = DemSamplingPolicy(
            zoom: UInt32(grid.zoom), tileSize: UInt32(grid.tileSize), maximumTileCount: UInt64(grid.maximumTileCount),
            minimumPlausibleElevationMeters: grid.plausibleElevationMeters.lowerBound,
            maximumPlausibleElevationMeters: grid.plausibleElevationMeters.upperBound
        )
        let plan = observePlan(samples, policy: policy)
        if plan.error == .tileBudgetExceeded { return .tileBudgetExceeded(minimumRequiredTileCount: grid.maximumTileCount + 1) }
        guard plan.error == nil else { throw RunPlayDemElevationBridgeError.engineContractViolation }
        let plannedTiles = plan.result.tiles.map { RunPlayDemTileKey(x: $0.x, y: $0.y) }

        let loaded = plannedTiles.isEmpty ? [] : try loadTiles(plannedTiles)
        let planned = Set(plannedTiles)
        var seen = Set<RunPlayDemTileKey>()
        for tile in loaded {
            guard planned.contains(tile.key), seen.insert(tile.key).inserted,
                  tile.heightsMeters.count == grid.tileSize * grid.tileSize
            else { throw RunPlayDemElevationBridgeError.invalidLoadedTiles }
        }
        let directory = loaded.sorted { $0.key < $1.key }
        var keys: [DemTileKey] = []
        var heights: [Float] = []
        heights.reserveCapacity(directory.count * grid.tileSize * grid.tileSize)
        for tile in directory {
            keys.append(DemTileKey(x: tile.key.x, y: tile.key.y))
            heights.append(contentsOf: tile.heightsMeters)
        }

        let observation = observeSample(samples, policy: policy, tiles: keys, heights: heights)
        guard observation.error == nil else { throw RunPlayDemElevationBridgeError.engineContractViolation }
        var elevations: [Double?] = []
        var statuses: [RunPlayDemSampleStatus] = []
        elevations.reserveCapacity(samples.count)
        statuses.reserveCapacity(samples.count)
        for output in observation.result.samples {
            switch output.status {
            case .sampled: elevations.append(output.elevationMeters); statuses.append(.sampled)
            case .invalidCoordinate: elevations.append(nil); statuses.append(.invalidCoordinate)
            case .outsideProjection: elevations.append(nil); statuses.append(.outsideProjection)
            case .missingTile: elevations.append(nil); statuses.append(.missingTile)
            case .implausibleHeight: elevations.append(nil); statuses.append(.implausibleHeight)
            }
        }
        let r = observation.result
        return .sampled(RunPlayDemSamplingResult(
            elevationsMeters: elevations, statuses: statuses, plannedTiles: plannedTiles,
            loadedTileCount: directory.count, sampledCount: Int(r.sampledCount),
            invalidCoordinateCount: Int(r.invalidCoordinateCount), outsideProjectionCount: Int(r.outsideProjectionCount),
            missingTileCount: Int(r.missingTileCount), implausibleHeightCount: Int(r.implausibleHeightCount)
        ))
    }
}

/// Compares the Swift kernels with the unchanged C++ kernels. Every field is
/// bit-identical: tile lists, counts, statuses, errors and elevation bits.
@Suite(.serialized)
struct DemElevationDifferentialTests {
    struct Case {
        let name: String
        let samples: [DemRouteSample]
        let policy: DemSamplingPolicy
        let tiles: [DemTileKey]
        let heights: [Float]
    }

    // MARK: Corpus

    private static func policy(
        _ zoom: UInt32, _ tileSize: UInt32, _ budget: UInt64 = 4_096, _ low: Double = -500, _ high: Double = 9_000
    ) -> DemSamplingPolicy {
        DemSamplingPolicy(zoom: zoom, tileSize: tileSize, maximumTileCount: budget,
                          minimumPlausibleElevationMeters: low, maximumPlausibleElevationMeters: high)
    }

    private static func unit(_ rng: inout SplitMix64) -> Double { Double(rng.next() >> 11) / Double(UInt64(1) << 53) }

    private static func heights(for keys: [DemTileKey], tileSize: UInt32, _ rng: inout SplitMix64, glitches: Bool) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(keys.count * Int(tileSize * tileSize))
        for _ in 0..<(keys.count * Int(tileSize * tileSize)) {
            var value = Float(Int(rng.next() % 3_000) - 400)
            if glitches {
                switch rng.next() % 200 {
                case 0: value = .nan
                case 1: value = .infinity
                case 2: value = 9_500
                case 3: value = -600
                default: break
                }
            }
            values.append(value)
        }
        return values
    }

    static func corpus() -> [Case] {
        var cases: [Case] = []
        var rng = SplitMix64(seed: 0x6465_6d73_616d_706c)
        let zooms: [(UInt32, UInt32)] = [(0, 2), (1, 3), (2, 4), (3, 5), (5, 8), (8, 16), (12, 16), (12, 64), (24, 2), (24, 8)]
        let limit = EngineDemLimits.webMercatorMaximumLatitudeDegrees

        // Fixed edge routes on a tiny grid: tile edges, corners, antimeridian, poles, invalid coordinates.
        let edge: [DemRouteSample] = [
            .init(latitudeDegrees: 0, longitudeDegrees: -90), .init(latitudeDegrees: 0, longitudeDegrees: 180),
            .init(latitudeDegrees: 0, longitudeDegrees: -180), .init(latitudeDegrees: limit, longitudeDegrees: 0),
            .init(latitudeDegrees: -limit, longitudeDegrees: 0), .init(latitudeDegrees: 85.06, longitudeDegrees: 10),
            .init(latitudeDegrees: -90, longitudeDegrees: 10), .init(latitudeDegrees: .nan, longitudeDegrees: 0),
            .init(latitudeDegrees: 0, longitudeDegrees: .infinity), .init(latitudeDegrees: 90.5, longitudeDegrees: 0),
            .init(latitudeDegrees: 0, longitudeDegrees: 180.5), .init(latitudeDegrees: Double(bitPattern: 2024), longitudeDegrees: -Double(bitPattern: 2024)),
            .init(latitudeDegrees: -0.0, longitudeDegrees: -0.0), .init(latitudeDegrees: 10, longitudeDegrees: 179.9999),
            .init(latitudeDegrees: 10, longitudeDegrees: -179.9999),
        ]
        cases.append(Case(name: "empty", samples: [], policy: policy(2, 4, 64), tiles: [], heights: []))
        cases.append(Case(name: "empty invalid policy", samples: [], policy: policy(2, 1, 64), tiles: [], heights: []))
        cases.append(Case(name: "edge routes, whole grid", samples: edge, policy: policy(2, 4, 64),
                          tiles: allTiles(2), heights: heights(for: allTiles(2), tileSize: 4, &rng, glitches: false)))
        cases.append(Case(name: "edge routes, glitchy heights", samples: edge, policy: policy(2, 4, 64),
                          tiles: allTiles(2), heights: heights(for: allTiles(2), tileSize: 4, &rng, glitches: true)))

        // Invalid policies and directories.
        let sample = DemRouteSample(latitudeDegrees: 10, longitudeDegrees: 10)
        let invalidPolicies: [(String, DemSamplingPolicy)] = [
            ("zoom 25", policy(25, 4)), ("tile size 1", policy(2, 1)), ("tile size 4097", policy(2, 4_097)),
            ("budget 0", policy(2, 4, 0)), ("budget 65537", policy(2, 4, 65_537)),
            ("NaN minimum", policy(2, 4, 64, .nan)), ("infinite maximum", policy(2, 4, 64, -500, .infinity)),
            ("equal range", policy(2, 4, 64, -500, -500)), ("inverted range", policy(2, 4, 64, -500, -600)),
        ]
        for (name, value) in invalidPolicies {
            cases.append(Case(name: "invalid policy " + name, samples: [sample], policy: value, tiles: [], heights: []))
        }
        let grid = allTiles(2)
        let gridHeights = heights(for: grid, tileSize: 4, &rng, glitches: false)
        let sixteen = Array(gridHeights.prefix(16))
        let badDirectories: [(String, [DemTileKey], [Float])] = [
            ("out of order", [.init(x: 1, y: 1), .init(x: 0, y: 1)], Array(gridHeights.prefix(32))),
            ("duplicate", [.init(x: 1, y: 1), .init(x: 1, y: 1)], Array(gridHeights.prefix(32))),
            ("x outside grid", [.init(x: 4, y: 0)], sixteen), ("y outside grid", [.init(x: 0, y: 4)], sixteen),
            ("too few heights", [.init(x: 0, y: 0)], Array(sixteen.prefix(15))),
            ("too many heights", [.init(x: 0, y: 0)], sixteen + [0]),
        ]
        for (name, keys, values) in badDirectories {
            cases.append(Case(name: "invalid directory " + name, samples: [sample], policy: policy(2, 4, 64), tiles: keys, heights: values))
        }
        cases.append(Case(name: "directory above budget", samples: [sample], policy: policy(2, 4, 1),
                          tiles: [.init(x: 0, y: 0), .init(x: 1, y: 0)], heights: Array(gridHeights.prefix(32))))
        let five = [(2.0, 2.0), (6.0, 2.0), (10.0, 2.0), (14.0, 2.0), (2.0, 6.0)].map { x, y in
            DemRouteSample(latitudeDegrees: atan(sinh(Double.pi * (1 - 2 * y / 16))) * 180 / Double.pi, longitudeDegrees: x / 16 * 360 - 180)
        }
        for budget: UInt64 in [4, 5] {
            cases.append(Case(name: "tile budget \(budget)", samples: five, policy: policy(2, 4, budget),
                              tiles: [], heights: []))
        }

        // Seeded routes over many grids; the directory is the planned tiles, some missing, some glitchy.
        for index in 0..<120 {
            let (zoom, tileSize) = zooms[Int(rng.next() % UInt64(zooms.count))]
            var latitude = -60.0 + 120.0 * unit(&rng)
            var longitude = rng.next() % 3 == 0 ? 179.0 + unit(&rng) : -180.0 + 360.0 * unit(&rng)
            var route: [DemRouteSample] = []
            for _ in 0..<Int(rng.next() % 150) {
                latitude = min(max(latitude + (unit(&rng) - 0.5) * 0.3, -limit), limit)
                longitude += unit(&rng) * 0.02
                if longitude > 180 { longitude -= 360 }
                var point = DemRouteSample(latitudeDegrees: latitude, longitudeDegrees: longitude)
                switch rng.next() % 90 {
                case 0: point.latitudeDegrees = .nan
                case 1: point.longitudeDegrees = 181
                case 2: point.latitudeDegrees = 89
                case 3: point.latitudeDegrees = limit
                case 4: point.longitudeDegrees = 180
                default: break
                }
                route.append(point)
            }
            let value = policy(zoom, tileSize, 4_096, -500, 9_000)
            let planned = (try? DemTilePlanning.plan(samples: route.span, policy: value))?.tiles ?? []
            let present = planned.filter { _ in rng.next() % 6 != 0 }
            cases.append(Case(name: "seeded \(index) z\(zoom)/\(tileSize)", samples: route, policy: value, tiles: present,
                              heights: heights(for: present, tileSize: tileSize, &rng, glitches: index.isMultiple(of: 3))))
        }

        // A large route: planning is bounded by the tile budget, not by route length.
        var large: [DemRouteSample] = []
        large.reserveCapacity(100_000)
        var latitude = 46.5, longitude = 7.9
        for _ in 0..<100_000 {
            latitude += (unit(&rng) - 0.45) * 0.0004
            longitude += (unit(&rng) - 0.40) * 0.0006
            large.append(DemRouteSample(latitudeDegrees: latitude, longitudeDegrees: longitude))
        }
        let largePolicy = policy(12, 64, 4_096)
        let largeTiles = (try? DemTilePlanning.plan(samples: large.span, policy: largePolicy))?.tiles ?? []
        cases.append(Case(name: "100k route", samples: large, policy: largePolicy, tiles: largeTiles,
                          heights: heights(for: largeTiles, tileSize: 64, &rng, glitches: false)))
        return cases
    }

    private static func allTiles(_ zoom: UInt32) -> [DemTileKey] {
        var keys: [DemTileKey] = []
        for y in 0..<(UInt32(1) << zoom) { for x in 0..<(UInt32(1) << zoom) { keys.append(DemTileKey(x: x, y: y)) } }
        return keys
    }

    static let cases: [Case] = corpus()

    // MARK: Comparison

    private static func swiftPlan(_ item: Case) -> RunPlayDemElevationCppBridge.PlanObservation {
        do { return .init(error: nil, result: try DemTilePlanning.plan(samples: item.samples.span, policy: item.policy)) }
        catch { return .init(error: error, result: DemTilePlanResult()) }
    }

    private static func swiftSample(_ item: Case) -> RunPlayDemElevationCppBridge.SampleObservation {
        do {
            return .init(error: nil, result: try DemElevationSampling.sample(
                samples: item.samples.span, policy: item.policy, tiles: item.tiles.span, tileHeights: item.heights.span
            ))
        } catch { return .init(error: error, result: DemSamplingResult()) }
    }

    static func planDifference(_ a: RunPlayDemElevationCppBridge.PlanObservation, _ b: RunPlayDemElevationCppBridge.PlanObservation) -> String? {
        if a.error != b.error { return "plan error \(String(describing: a.error)) vs \(String(describing: b.error))" }
        if a.error != nil { return nil }
        guard a.result.sampleCount == b.result.sampleCount, a.result.projectableSampleCount == b.result.projectableSampleCount,
              a.result.invalidCoordinateCount == b.result.invalidCoordinateCount,
              a.result.outsideProjectionCount == b.result.outsideProjectionCount
        else { return "plan counts" }
        return a.result.tiles == b.result.tiles ? nil : "plan tiles"
    }

    static func sampleDifference(_ a: RunPlayDemElevationCppBridge.SampleObservation, _ b: RunPlayDemElevationCppBridge.SampleObservation) -> String? {
        if a.error != b.error { return "sample error \(String(describing: a.error)) vs \(String(describing: b.error))" }
        if a.error != nil { return nil }
        let x = a.result, y = b.result
        guard x.sampleCount == y.sampleCount, x.sampledCount == y.sampledCount,
              x.invalidCoordinateCount == y.invalidCoordinateCount, x.outsideProjectionCount == y.outsideProjectionCount,
              x.missingTileCount == y.missingTileCount, x.implausibleHeightCount == y.implausibleHeightCount,
              x.samples.count == y.samples.count
        else { return "sample counts" }
        for index in x.samples.indices {
            let p = x.samples[index], q = y.samples[index]
            if p.status != q.status || p.hasElevation != q.hasElevation
                || p.elevationMeters.bitPattern != q.elevationMeters.bitPattern { return "sample \(index)" }
        }
        return nil
    }

    struct Outcome {
        let name: String
        let swiftPlan: RunPlayDemElevationCppBridge.PlanObservation
        let cppPlan: RunPlayDemElevationCppBridge.PlanObservation
        let swiftSample: RunPlayDemElevationCppBridge.SampleObservation
        let cppSample: RunPlayDemElevationCppBridge.SampleObservation
    }

    /// Both kernels over the whole corpus, computed once and shared by the tests.
    static let outcomes: [Outcome] = cases.map { item in
        Outcome(
            name: item.name,
            swiftPlan: swiftPlan(item), cppPlan: RunPlayDemElevationCppBridge.observePlan(item.samples, policy: item.policy),
            swiftSample: swiftSample(item),
            cppSample: RunPlayDemElevationCppBridge.observeSample(item.samples, policy: item.policy, tiles: item.tiles, heights: item.heights)
        )
    }

    @Test func cppAndSwiftMatch() {
        for outcome in Self.outcomes {
            if let difference = Self.planDifference(outcome.swiftPlan, outcome.cppPlan) { Issue.record("\(outcome.name): \(difference)") }
            if let difference = Self.sampleDifference(outcome.swiftSample, outcome.cppSample) { Issue.record("\(outcome.name): \(difference)") }
        }
        print("DEM_CASES \(Self.platformTag) cases=\(Self.outcomes.count)")
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

    private static func append(_ plan: RunPlayDemElevationCppBridge.PlanObservation,
                               _ sample: RunPlayDemElevationCppBridge.SampleObservation, to digest: inout FNV1a64) {
        func code(_ error: DemTilePlanError?) -> UInt8 {
            switch error { case nil: 0; case .invalidPolicy?: 1; case .tileBudgetExceeded?: 2; case .resourceLimit?: 3; case .internalFailure?: 4 }
        }
        func code(_ error: DemSamplingError?) -> UInt8 {
            switch error { case nil: 0; case .invalidPolicy?: 1; case .invalidTileDirectory?: 2; case .resourceLimit?: 3; case .internalFailure?: 4 }
        }
        digest.append(byte: code(plan.error))
        if plan.error == nil {
            digest.append(word: plan.result.sampleCount)
            digest.append(word: plan.result.projectableSampleCount)
            digest.append(word: plan.result.invalidCoordinateCount)
            digest.append(word: plan.result.outsideProjectionCount)
            for tile in plan.result.tiles { digest.append(word: tile.x); digest.append(word: tile.y) }
        }
        digest.append(byte: code(sample.error))
        if sample.error == nil {
            digest.append(word: sample.result.sampledCount)
            digest.append(word: sample.result.missingTileCount)
            digest.append(word: sample.result.implausibleHeightCount)
            for item in sample.result.samples {
                digest.append(byte: item.status.rawValue)
                digest.append(word: item.elevationMeters.bitPattern)
            }
        }
    }

    static func swiftDigest() -> UInt64 {
        var digest = FNV1a64()
        for item in cases { append(swiftPlan(item), swiftSample(item), to: &digest) }
        return digest.value
    }

    /// Captured from the unchanged C++ kernels on each platform. `tan` and `asinh`
    /// come from the platform libm, so the macOS and Linux digests may differ.
    static var cppGolden: UInt64? {
        #if os(macOS) && arch(arm64)
        return 0xb616_cb83_6cfb_1f80
        #elseif os(Linux) && arch(x86_64)
        // Captured from the C++ oracle in hosted Linux CI run 45529868142, on
        // the swift:6.3.3 image. The swift:6.4.0-resolute image gave
        // 0xdf51_84b9_a336_44d9: its libm differs, and both engines moved together.
        return 0x1dbe_5710_d6bf_0e27
        #else
        return nil
        #endif
    }

    @Test(.enabled(if: DemElevationDifferentialTests.cppGolden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        #expect(Self.swiftDigest() == (try #require(Self.cppGolden)))
    }

    @Test func captureDigests() {
        var cppDigest = FNV1a64()
        for outcome in Self.outcomes { Self.append(outcome.cppPlan, outcome.cppSample, to: &cppDigest) }
        print("DEM_NATIVE_FNV1A64 \(String(cppDigest.value, radix: 16)) \(Self.platformTag)")
        print("DEM_SWIFT_FNV1A64 \(String(Self.swiftDigest(), radix: 16)) \(Self.platformTag)")
    }
}
