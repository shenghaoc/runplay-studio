import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

/// Raw-corpus fixture. RoutePoint/WorkoutTimeline normalize some
/// non-finite values before the engine, so those contracts are observed below Core.
struct SegmentDetectorRawParitySample {
    var distance: Double = 0
    var elapsed: Double = 0
    var active: Double = 0
    var ascent: Double = 0
    var descent: Double = 0
    var reliableCount: Double = 0
    var continuityGroup: Int32 = 0
    var reliableRun: Int32 = -1
}

enum SegmentDetectorRawParityObservation: Equatable {
    case outcome([RunPlaySegmentWindowCandidate], UInt64, UInt64)
    case resourceLimit
    case invalidConfiguration
    case invalidInputContract
}

enum SegmentDetectionSwiftObserver {
    static func observeRaw(
        _ fixture: [SegmentDetectorRawParitySample], configuration: SegmentDetectorSearchConfiguration
    ) throws -> SegmentDetectorRawParityObservation {
        let samples = fixture.map { raw in
            var sample = SegmentDetectionSample()
            sample.distance = raw.distance
            sample.elapsed = raw.elapsed
            sample.active = raw.active
            sample.ascent = raw.ascent
            sample.descent = raw.descent
            sample.reliableCount = raw.reliableCount
            sample.continuityGroup = raw.continuityGroup
            sample.reliableRun = raw.reliableRun
            return sample
        }
        do {
            let result = try SegmentDetection.search(samples.span, configuration: RunPlaySegmentDetectorAdapter.engineConfiguration(configuration))
            var output: [RunPlaySegmentWindowCandidate] = []
            for i in 0..<result.candidateCount {
                let raw = result.candidates[i]
                guard let kind = RunPlaySegmentWindowKind(rawValue: raw.kind.rawValue) else {
                    throw RunPlaySegmentDetectorBridgeError.engineContractViolation
                }
                output.append(.init(kind: kind, startDistanceMeters: raw.start, endDistanceMeters: raw.end, selectionValue: raw.value))
            }
            return .outcome(output, result.paceEvaluationCount, result.elevationEvaluationCount)
        } catch SegmentDetectionError.resourceLimit {
            return .resourceLimit
        } catch SegmentDetectionError.invalidConfiguration {
            return .invalidConfiguration
        } catch SegmentDetectionError.invalidInputContract {
            return .invalidInputContract
        } catch SegmentDetectionError.internalFailure {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }
    }
}

/// The deterministic corpus behind the segment-detection golden digest. It is
/// the corpus of the former Swift-versus-C++ differential test, unchanged.
enum SegmentDetectionGoldenCorpus {
    typealias Observation = SegmentDetectorRawParityObservation

    struct CorpusResult {
        var swift: UInt64
        var caseCount: Int
    }


    private static func observation(_ result: RunPlaySegmentWindowSearchResult) -> Observation {
        .outcome(result.candidates, UInt64(result.paceEvaluationCount), UInt64(result.elevationEvaluationCount))
    }

    private static func geographyRoute(latitude: Double, longitude: Double) -> [RoutePoint] {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        return (0..<8).map { i in
            let distance = Double(i) * 200
            let elapsed = Double(i) * 60
            return RoutePoint(
                timestamp: date.addingTimeInterval(elapsed),
                latitude: latitude, longitude: longitude, altitudeMeters: 10 + Double(i),
                distanceFromStartMeters: distance, elapsedSeconds: elapsed, routeSegmentIndex: 0
            )
        }
    }

    /// Runs the whole corpus through the Swift engine and digests every case.
    static func runCorpus() throws -> CorpusResult {
        var swiftDigest = FNV1a64()
        var caseCount = 0

        func record(swift: Observation) {
            Self.append(swift, to: &swiftDigest)
            caseCount += 1
        }

        func routeCase(_ points: [RoutePoint]) throws {
            let timeline = WorkoutTimeline(routePoints: points)
            let elevation = ElevationProfile(routePoints: points)
            let config = RunPlaySegmentDetectorBridgeTests.makeDefaultConfig(
                points: points, timeline: timeline, elevationProfile: elevation
            )
            let swift = try RunPlaySegmentDetectorAdapter.search(
                routePoints: points, timeline: timeline, elevationProfile: elevation, configuration: config,
                cancellationCheckStride: 2_048, isCancelled: { false }
            )
            record(swift: observation(swift))
        }

        for index in 0..<SegmentDetectorParityFixtures.generatedFixtureCount {
            try routeCase(SegmentDetectorParityFixtures.generatedFixture(index: index))
        }
        let geography: [(String, Double, Double)] = [
            ("antimeridian east", 0, 179.999), ("antimeridian west", 0, -179.999),
            ("north pole", 90, 0), ("south pole", -90, 0),
            ("northern Web Mercator edge", 85.0511287798066, 0),
            ("southern Web Mercator edge", -85.0511287798066, 0),
        ]
        for (_, latitude, longitude) in geography {
            try routeCase(geographyRoute(latitude: latitude, longitude: longitude))
        }
        for (_, samples, configuration) in Self.rawParityFixtures() {
            record(swift: try SegmentDetectionSwiftObserver.observeRaw(samples, configuration: configuration))
        }
        return CorpusResult(swift: swiftDigest.value, caseCount: caseCount)
    }


    fileprivate static func append(_ outcome: SegmentDetectorRawParityObservation, to digest: inout FNV1a64) {
        switch outcome {
        case .outcome(let candidates, let pace, let elevation):
            digest.append(byte: 0)
            digest.append(word: UInt64(candidates.count))
            digest.append(word: pace)
            digest.append(word: elevation)
            for c in candidates {
                digest.append(byte: c.kind.rawValue)
                digest.append(word: c.startDistanceMeters.bitPattern)
                digest.append(word: c.endDistanceMeters.bitPattern)
                digest.append(word: c.selectionValue.bitPattern)
            }
        case .resourceLimit: digest.append(byte: 1)
        case .invalidConfiguration: digest.append(byte: 2)
        case .invalidInputContract: digest.append(byte: 3)
        }
    }

    fileprivate typealias RawCase = (String, [SegmentDetectorRawParitySample], SegmentDetectorSearchConfiguration)

    fileprivate static func rawParityFixtures() -> [RawCase] {
        func config(step: Double = 50, budget: UInt64 = 32_000) -> SegmentDetectorSearchConfiguration {
            SegmentDetectorSearchConfiguration(
                fastest400mDistanceMeters: 400, fastest400mStepMeters: step,
                oneKilometerDistanceMeters: 1_000, oneKilometerStepMeters: step,
                oneMileStepMeters: step, fiveKilometerStepMeters: step, tenKilometerStepMeters: step,
                halfMarathonStepMeters: step, marathonStepMeters: step,
                minimumValidPaceSecondsPerKilometer: 120, maximumValidPaceSecondsPerKilometer: 1_200,
                elevationEnabled: true, elevationWindowDistanceMeters: 500, elevationStepMeters: step,
                maximumEvaluationsPerSearch: budget
            )
        }
        var fixtures: [RawCase] = [
            ("empty", [], config()), ("one sample", [.init()], config()), ("invalid configuration", [.init()], config(step: .nan)),
            ("evaluation budget 1", [.init(), .init(distance: 1_000, elapsed: 300, active: 300)], config(budget: 1)),
            ("evaluation quotient past UInt64", [.init(), .init(distance: 1e20, elapsed: 1e12, active: 1e12)], config(step: 1)),
        ]
        for (name, value): (String, Double) in [
            ("NaN", .nan), ("+infinity", .infinity), ("-infinity", -.infinity),
            ("subnormal", .leastNonzeroMagnitude), ("negative subnormal", -.leastNonzeroMagnitude),
        ] {
            fixtures.append((name + " distance", [.init(), .init(distance: value)], config()))
            fixtures.append((name + " active clock", [.init(), .init(distance: 1_000, elapsed: 300, active: value)], config()))
        }

        // The segment kernel sees derived distance/clocks only. Synthetic
        // geographic edges also exercise the full RoutePoint→Core adapter path
        // in the geography cases above; none of those coordinates enter the kernel.
        var rng = SplitMix64(seed: 0x7365_676d_656e_7473)
        for index in 0..<64 {
            let n = 2 + Int(rng.next() % 120)
            var route: [SegmentDetectorRawParitySample] = [.init(reliableRun: 0)]
            for i in 1..<n {
                let before = route[i - 1]
                let pause = i.isMultiple(of: 23)
                let stationary = i.isMultiple(of: 11)
                let increment = pause || stationary ? 0 : Double(5 + rng.next() % 1_000)
                let active = pause ? 0 : increment * (0.2 + Double(rng.next() % 30) / 100) + (stationary ? 10 : 0)
                var sample = before
                sample.distance += increment
                sample.elapsed += pause ? 150 : active
                sample.active += active
                sample.ascent += Double(rng.next() % 25)
                sample.descent += Double(rng.next() % 12)
                sample.reliableCount += pause ? 0 : 1
                sample.continuityGroup += pause ? 1 : 0
                sample.reliableRun += pause ? 1 : 0
                route.append(sample)
            }
            fixtures.append(("seeded compact route \(index)", route, config()))
        }

        let productCount = WorkoutImportResourceLimits.maxRoutePointCount
        var product = [SegmentDetectorRawParitySample](repeating: .init(), count: productCount)
        product[productCount - 1] = .init(distance: 42_195, elapsed: 12_658.5, active: 12_658.5)
        fixtures.append(("product ceiling", product, config(step: 250)))
        return fixtures
    }
}

/// Pins the corpus digest of the former C++ kernel's results. The Swift engine
/// alone must reproduce it, so the check runs in every configuration. A
/// platform without a captured digest shows as skipped rather than passed.
@Suite("Segment detection golden")
struct SegmentDetectionGoldenTests {
    static var golden: UInt64? {
        #if os(macOS) && arch(arm64)
        return 0xb16f_d7b1_3acd_a34d
        #elseif os(Linux) && arch(x86_64)
        // Captured from the former C++ kernel in hosted Linux CI run 45327250481.
        return 0xb16f_d7b1_3acd_a34d
        #else
        return nil
        #endif
    }

    // Derived from the C++ kernel before its removal; the Swift engine was
    // asserted bit-identical to it on every case of this corpus.
    /// Fails when a platform condition leaves `golden` nil on a platform that
    /// pins it, which would otherwise disable the golden test silently.
    @Test func goldenIsPinnedOnPinnedPlatforms() {
        #expect(
            !GoldenPlatform.current.pinsKernelGoldens || Self.golden != nil,
            "\(GoldenPlatform.unpinnedMessage("golden"))"
        )
    }

    @Test(.enabled(if: SegmentDetectionGoldenTests.golden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        let expected = try #require(Self.golden)
        let result = try SegmentDetectionGoldenCorpus.runCorpus()
        #expect(result.swift == expected)
    }
}
