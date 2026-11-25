import Foundation
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

/// Pins the Swift constrained-DTW path solver to a golden digest. The corpus
/// and digest are those of the former Swift-versus-C++ differential test.
@Suite struct RouteAlignmentDtwGoldenTests {
    private typealias Fixture = RunPlayRouteAlignmentDtwBridgeTests.Fixture

    private enum Observation: Equatable {
        case path([RunPlayRouteAlignmentDtwPathCell], radius: Int, cellCount: Int, costBits: UInt64)
        case resourceLimit
        case noPath
        case invalidInput
        case invalidPolicy

        init(_ run: () throws -> RunPlayRouteAlignmentDtwResult) throws {
            do {
                switch try run() {
                case .success(let path, let radius, let cells, let cost):
                    self = .path(path, radius: radius, cellCount: cells, costBits: cost.bitPattern)
                case .resourceLimit: self = .resourceLimit
                case .noPath: self = .noPath
                }
            } catch RunPlayRouteAlignmentDtwBridgeError.invalidInputContract {
                self = .invalidInput
            } catch RunPlayRouteAlignmentDtwBridgeError.invalidPolicy {
                self = .invalidPolicy
            }
        }

        // The existing digest tags double as corpus coverage categories.
        var category: UInt8 {
            switch self {
            case .path: 0
            case .resourceLimit: 1
            case .noPath: 2
            case .invalidInput: 3
            case .invalidPolicy: 4
            }
        }

        func append(to digest: inout FNV1a64) {
            digest.append(byte: category)
            switch self {
            case .path(let path, let radius, let cells, let bits):
                digest.append(word: UInt64(radius))
                digest.append(word: UInt64(cells))
                digest.append(word: UInt64(path.count))
                digest.append(word: bits)
                for cell in path {
                    digest.append(word: UInt64(cell.primaryIndex))
                    digest.append(word: UInt64(cell.comparisonIndex))
                    digest.append(byte: cell.step.rawValue)
                }
            case .resourceLimit, .noPath, .invalidInput, .invalidPolicy:
                break
            }
        }
    }

    private static func bitCorpus() -> [Fixture] {
        var cases = RunPlayRouteAlignmentDtwBridgeTests.makeGeneratedFixtures(count: 1_200)
        var rng = SplitMix64(seed: 0x6474_772d_7377_6966)
        func projected(x: Double, z: Double = 0, progress: Double = 0, heading: Double? = nil) -> RouteAlignmentSample {
            RouteAlignmentSample(
                xMeters: x, zMeters: z, distanceFromStartMeters: 0, routeSegmentIndex: 0,
                elapsedSeconds: nil, headingRadians: heading, normalizedProgress: progress
            )
        }
        func fixture(
            _ name: String, _ a: [RouteAlignmentSample], _ b: [RouteAlignmentSample],
            meters: Double = 40_000, interval: Double = 20, policy: RouteAlignmentPolicy = .default
        ) -> Fixture {
            Fixture(name: name, primary: a, comparison: b, primaryRouteDistanceMeters: meters,
                    comparisonRouteDistanceMeters: meters, effectiveSampleIntervalMeters: interval, policy: policy)
        }
        let zero = projected(x: 0)
        cases.append(fixture("empty primary", [], [zero]))
        cases.append(fixture("empty comparison", [zero], []))
        cases.append(fixture("both empty", [], []))
        cases.append(fixture("one point, signed zeros", [zero], [projected(x: -0.0, z: -0.0, progress: -0.0)]))
        for (name, value): (String, Double) in [
            ("nan", .nan), ("+inf", .infinity), ("-inf", -.infinity),
            ("subnormal", .leastNonzeroMagnitude), ("negative subnormal", -.leastNonzeroMagnitude),
        ] {
            cases.append(fixture(name + " x", [projected(x: value)], [zero]))
            cases.append(fixture(name + " z", [zero], [projected(x: 0, z: value)]))
            cases.append(fixture(name + " progress", [projected(x: 0, progress: value)], [zero]))
            cases.append(fixture(name + " heading", [zero], [projected(x: 0, heading: value)]))
            cases.append(fixture(name + " distance", [zero], [zero], meters: value))
        }
        for invalid: Double in [.nan, .infinity, -.infinity] {
            cases.append(fixture("invalid band policy", [zero], [zero], policy: RouteAlignmentPolicy(bandWidthFraction: invalid)))
        }
        cases.append(fixture(
            "finite cost above unreachable sentinel", [zero], [projected(x: 1e308)],
            policy: RouteAlignmentPolicy(maximumSpatialCost: 1e308)
        ))
        cases.append(fixture(
            "finite band width overflows by multiplication", [zero, zero], [zero, zero],
            policy: RouteAlignmentPolicy(bandWidthFraction: .greatestFiniteMagnitude)
        ))
        // DTW accepts only local metre coordinates, not latitude/longitude.
        // Stable, synthetic metre fixtures represent offsets across the
        // antimeridian and projected pole/Mercator extremes, without libm in
        // corpus construction or geo policy at the DTW boundary.
        for (name, x, z): (String, Double, Double) in [
            ("antimeridian", 22.25, 0), ("poles", 0, 10_007_543.5), ("Mercator limit", 0, 9_457_000),
        ] {
            cases.append(fixture(name, [projected(x: -x, z: -z)], [projected(x: x, z: z)]))
        }
        for i in 0..<48 {
            let count = 1 + Int(rng.next() % 31)
            let points = (0..<count).map { index in
                projected(
                    x: Double(Int(rng.next() % 4096) - 2048) / 8,
                    z: Double(Int(rng.next() % 2048) - 1024) / 4,
                    progress: Double(index) / Double(max(1, count - 1)),
                    heading: index.isMultiple(of: 3) ? Double(Int(rng.next() % 2048) - 1024) / 256 : nil
                )
            }
            cases.append(fixture("seeded metre route \(i)", points, Array(points.reversed())))
        }
        let route = (0..<2_000).map { projected(x: Double($0) * 20, progress: Double($0) / 1_999) }
        cases.append(fixture("alignment product maximum 2,000", route, route))
        let overBudget = RouteAlignmentPolicy(bandWidthFraction: 1, maximumBandCells: 4_000_000)
        cases.append(fixture("4,000,000-cell estimate rejection", route, route, policy: overBudget))
        let a = (0..<20).map { projected(x: Double($0) * 5, progress: Double($0) / 19) }
        let b = (0..<100).map { projected(x: Double($0), progress: Double($0) / 99) }
        for budget in [179, 180, 210, 211] {
            let policy = RouteAlignmentPolicy(
                bandWidthFraction: 0.01, maximumUnmatchedPrefixSuffixMeters: 400,
                maximumUnmatchedPrefixSuffixFraction: 1, nonDiagonalStepPenalty: 0,
                maximumConsecutiveWarpSteps: 6, spatialDistanceCostScaleMeters: 1,
                maximumSpatialCost: 1e9, headingPenaltyWeight: 0, progressPenaltyWeight: 0,
                maximumBandCells: budget
            )
            cases.append(fixture("packed budget \(budget)", a, b, meters: 400, interval: 100, policy: policy))
        }
        return cases
    }

    private static func observeSwift(_ fixture: Fixture) throws -> Observation {
        try Observation {
            try RunPlayRouteAlignmentDtwAdapter.solve(
                primary: fixture.primary, comparison: fixture.comparison,
                primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                policy: fixture.policy, isCancelled: { false }
            )
        }
    }

    // Derived from the C++ kernel before its removal. The Swift solver was
    // asserted bit-identical to it on every fixture of this corpus.
    private static var golden: UInt64? {
        #if os(macOS) && arch(arm64)
        0x9fc7_5d5e_35cb_3762
        #elseif os(Linux) && arch(x86_64)
        0x8a94_d3cb_d385_aa8c
        #else
        nil
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

    @Test(.enabled(if: RouteAlignmentDtwGoldenTests.golden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        let expected = try #require(Self.golden)
        var digest = FNV1a64()
        for fixture in Self.bitCorpus() {
            try Self.observeSwift(fixture).append(to: &digest)
        }
        #expect(digest.value == expected)
    }

    /// The corpus keeps its size and reaches every outcome category.
    @Test func corpusCoversEveryOutcomeCategory() throws {
        let corpus = Self.bitCorpus()
        #expect(corpus.count == 1_291)
        var categories = Set<UInt8>()
        for fixture in corpus {
            categories.insert(try Self.observeSwift(fixture).category)
        }
        #expect(categories == [0, 1, 2, 3, 4])
    }
}
