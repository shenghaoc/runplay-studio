import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

/// Pins the Swift DEM tile-planning and bilinear-sampling kernels to a golden
/// digest. The corpus and digest are those of the former Swift-versus-C++
/// differential test, where every field was bit-identical: tile lists, counts,
/// statuses, errors and elevation bits.
@Suite(.serialized)
struct DemElevationGoldenTests {
    struct PlanObservation {
        var error: DemTilePlanError?
        var result: DemTilePlanResult
    }

    struct SampleObservation {
        var error: DemSamplingError?
        var result: DemSamplingResult
    }

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

    // MARK: Observation

    private static func swiftPlan(_ item: Case) -> PlanObservation {
        do { return .init(error: nil, result: try DemTilePlanning.plan(samples: item.samples.span, policy: item.policy)) }
        catch { return .init(error: error, result: DemTilePlanResult()) }
    }

    private static func swiftSample(_ item: Case) -> SampleObservation {
        do {
            return .init(error: nil, result: try DemElevationSampling.sample(
                samples: item.samples.span, policy: item.policy, tiles: item.tiles.span, tileHeights: item.heights.span
            ))
        } catch { return .init(error: error, result: DemSamplingResult()) }
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

    private static func append(_ plan: PlanObservation,
                               _ sample: SampleObservation, to digest: inout FNV1a64) {
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

    /// Derived from the C++ kernels before their removal, on each platform.
    /// `tan` and `asinh` come from the platform libm, so the macOS and Linux
    /// digests may differ. The Swift kernels were asserted bit-identical to C++.
    static var golden: UInt64? {
        #if os(macOS) && arch(arm64)
        return 0xb616_cb83_6cfb_1f80
        #elseif os(Linux) && arch(x86_64)
        // Captured from the C++ oracle in hosted Linux CI run 45529868142, on the
        // swift:6.3.3 image, before the C++ kernel was removed.
        return 0x1dbe_5710_d6bf_0e27
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

    @Test(.enabled(if: DemElevationGoldenTests.golden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        #expect(Self.swiftDigest() == (try #require(Self.golden)))
    }

    @Test func captureDigests() {
        print("DEM_SWIFT_FNV1A64 \(String(Self.swiftDigest(), radix: 16)) \(Self.platformTag)")
    }
}
