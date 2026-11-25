import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
import XCTest
@testable import RunPlayCore

// Native oracle for differential tests and release measurements only.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Transitional C++ reference for the segment-window search. It exists only
/// here: Core production code calls the Swift engine through
/// `RunPlaySegmentDetectorAdapter`. One native call per search; Swift owns
/// every buffer, and C++ retains nothing and calls back into nothing.

enum RunPlaySegmentDetectorCppBridge {
    // Canonical personal-record window lengths, sourced from the engine
    // constants so Swift record identity and the native searches can never
    // drift. Internal because the public model re-exposes them as
    // `PersonalRecordCategory.nominalWindowDistanceMeters`.
    static let personalRecordOneMileMeters = runplay.personal_record_one_mile_meters
    static let personalRecordFiveKmMeters = runplay.personal_record_five_km_meters
    static let personalRecordTenKmMeters = runplay.personal_record_ten_km_meters
    static let personalRecordHalfMarathonMeters = runplay.personal_record_half_marathon_meters
    static let personalRecordMarathonMeters = runplay.personal_record_marathon_meters

    static func search(
        routePoints: [RoutePoint],
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        configuration: SegmentDetectorSearchConfiguration,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlaySegmentWindowSearchResult {
        let count = routePoints.count

        // Product limit
        guard count <= WorkoutImportResourceLimits.maxRoutePointCount else {
            throw RunPlaySegmentDetectorBridgeError.resourceLimit
        }

        // Empty / one-point route
        if count <= 1 {
            return RunPlaySegmentWindowSearchResult(
                candidates: [],
                paceEvaluationCount: 0,
                elevationEvaluationCount: 0
            )
        }

        return try searchNative(
            routePoints: routePoints,
            timeline: timeline,
            elevationProfile: elevationProfile,
            configuration: configuration,
            cancellationCheckStride: max(1, cancellationCheckStride),
            isCancelled: isCancelled
        )
    }

    private static func searchNative(
        routePoints: [RoutePoint],
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        configuration: SegmentDetectorSearchConfiguration,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlaySegmentWindowSearchResult {
        let count = routePoints.count

        let samples = try RunPlaySegmentDetectorAdapter.pack(
            routePoints: routePoints, timeline: timeline, elevationProfile: elevationProfile,
            cancellationCheckStride: cancellationCheckStride, isCancelled: isCancelled
        ) { distance, elapsed, active, ascent, descent, reliableCount, group, run in
            var sample = runplay.SegmentDetectionSample()
            sample.distance_meters = distance
            sample.elapsed_seconds = elapsed
            sample.active_seconds = active
            sample.cumulative_ascent_meters = ascent
            sample.cumulative_descent_meters = descent
            sample.reliable_interval_count = reliableCount
            sample.continuity_group = group
            sample.reliable_elevation_run = run
            return sample
        }

        // Native configuration
        let nativeConfig = nativeConfiguration(configuration)

        // Allocate exactly one slot per candidate kind
        var output = ContiguousArray<runplay.SegmentWindowCandidate>(
            repeating: runplay.SegmentWindowCandidate(),
            count: Int(runplay.segment_detection_max_candidate_count)
        )

        // Cancellation check before native call
        try checkCancellation(isCancelled: isCancelled)

        // One native call
        let summary = samples.withUnsafeBufferPointer { samplesBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                callNative(samplesBuffer, configuration: nativeConfig, output: outputBuffer)
            }
        }

        // Cancellation check after native call
        try checkCancellation(isCancelled: isCancelled)

        // Validate result
        switch summary.status {
        case .success:
            break
        case .resource_limit:
            throw RunPlaySegmentDetectorBridgeError.resourceLimit
        case .invalid_configuration:
            throw RunPlaySegmentDetectorBridgeError.invalidConfiguration
        case .invalid_input_contract:
            throw RunPlaySegmentDetectorBridgeError.invalidInputContract
        case .invalid_input_buffer,
             .invalid_output_buffer,
             .insufficient_output_capacity,
             .internal_failure:
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        default:
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }

        guard summary.sample_count == UInt64(count) else {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }

        let maximumCandidateCount = Int(runplay.segment_detection_max_candidate_count)
        guard summary.candidate_count <= UInt64(maximumCandidateCount) else {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }
        let candidateCount = Int(summary.candidate_count)
        guard summary.required_output_capacity == UInt64(maximumCandidateCount) else {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }

        var candidates: [RunPlaySegmentWindowCandidate] = []
        candidates.reserveCapacity(candidateCount)
        for index in 0..<candidateCount {
            let candidate = output[index]
            guard let kind = RunPlaySegmentWindowKind(rawValue: candidate.kind.rawValue) else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }
            candidates.append(RunPlaySegmentWindowCandidate(
                kind: kind, startDistanceMeters: candidate.start_distance_meters,
                endDistanceMeters: candidate.end_distance_meters, selectionValue: candidate.selection_value
            ))
        }
        return try RunPlaySegmentDetectorAdapter.validateCandidates(
            candidates, timeline: timeline, configuration: configuration,
            paceEvaluations: summary.pace_window_evaluation_count,
            elevationEvaluations: summary.elevation_window_evaluation_count
        )
    }

    static func nativeConfiguration(_ configuration: SegmentDetectorSearchConfiguration) -> runplay.SegmentDetectionConfiguration {
        var nativeConfig = runplay.SegmentDetectionConfiguration()
        nativeConfig.fastest_400m_distance_meters = configuration.fastest400mDistanceMeters
        nativeConfig.fastest_400m_step_meters = configuration.fastest400mStepMeters
        nativeConfig.one_kilometer_distance_meters = configuration.oneKilometerDistanceMeters
        nativeConfig.one_kilometer_step_meters = configuration.oneKilometerStepMeters
        nativeConfig.one_mile_distance_meters = configuration.oneMileDistanceMeters
        nativeConfig.one_mile_step_meters = configuration.oneMileStepMeters
        nativeConfig.five_kilometer_distance_meters = configuration.fiveKilometerDistanceMeters
        nativeConfig.five_kilometer_step_meters = configuration.fiveKilometerStepMeters
        nativeConfig.ten_kilometer_distance_meters = configuration.tenKilometerDistanceMeters
        nativeConfig.ten_kilometer_step_meters = configuration.tenKilometerStepMeters
        nativeConfig.half_marathon_distance_meters = configuration.halfMarathonDistanceMeters
        nativeConfig.half_marathon_step_meters = configuration.halfMarathonStepMeters
        nativeConfig.marathon_distance_meters = configuration.marathonDistanceMeters
        nativeConfig.marathon_step_meters = configuration.marathonStepMeters
        nativeConfig.minimum_valid_pace_seconds_per_kilometer = configuration.minimumValidPaceSecondsPerKilometer
        nativeConfig.maximum_valid_pace_seconds_per_kilometer = configuration.maximumValidPaceSecondsPerKilometer
        nativeConfig.elevation_window_distance_meters = configuration.elevationWindowDistanceMeters
        nativeConfig.elevation_step_meters = configuration.elevationStepMeters
        nativeConfig.maximum_evaluations_per_search = configuration.maximumEvaluationsPerSearch
        nativeConfig.elevation_enabled = configuration.elevationEnabled ? 1 : 0

        return nativeConfig
    }

    private static func checkCancellation(
        isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }
}

extension RunPlaySegmentDetectorCppBridge {
    static func observeRawForParity(
        _ fixture: [SegmentDetectorRawParitySample], configuration: SegmentDetectorSearchConfiguration
    ) throws -> SegmentDetectorRawParityObservation {
        let samples = fixture.map { raw in
            var sample = runplay.SegmentDetectionSample()
            sample.distance_meters = raw.distance
            sample.elapsed_seconds = raw.elapsed
            sample.active_seconds = raw.active
            sample.cumulative_ascent_meters = raw.ascent
            sample.cumulative_descent_meters = raw.descent
            sample.reliable_interval_count = raw.reliableCount
            sample.continuity_group = raw.continuityGroup
            sample.reliable_elevation_run = raw.reliableRun
            return sample
        }
        var sentinel = runplay.SegmentWindowCandidate()
        sentinel.kind = .fastest_marathon
        sentinel.start_distance_meters = -17
        sentinel.end_distance_meters = -13
        sentinel.selection_value = -11
        var output = ContiguousArray(repeating: sentinel, count: Int(runplay.segment_detection_max_candidate_count))
        let configuration = nativeConfiguration(configuration)
        let summary = samples.withUnsafeBufferPointer { inputs in
            output.withUnsafeMutableBufferPointer { candidates in
                callNative(inputs, configuration: configuration, output: candidates)
            }
        }
        if summary.status != .success {
            guard summary.candidate_count == 0, output.allSatisfy({
                $0.kind == sentinel.kind && $0.start_distance_meters.bitPattern == sentinel.start_distance_meters.bitPattern
                    && $0.end_distance_meters.bitPattern == sentinel.end_distance_meters.bitPattern
                    && $0.selection_value.bitPattern == sentinel.selection_value.bitPattern
            }) else { throw RunPlaySegmentDetectorBridgeError.engineContractViolation }
        }
        switch summary.status {
        case .success:
            guard summary.candidate_count <= UInt64(output.count) else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }
            let candidates = try output.prefix(Int(summary.candidate_count)).map { raw in
                guard let kind = RunPlaySegmentWindowKind(rawValue: raw.kind.rawValue) else {
                    throw RunPlaySegmentDetectorBridgeError.engineContractViolation
                }
                return RunPlaySegmentWindowCandidate(
                    kind: kind, startDistanceMeters: raw.start_distance_meters,
                    endDistanceMeters: raw.end_distance_meters, selectionValue: raw.selection_value
                )
            }
            return .outcome(candidates, summary.pace_window_evaluation_count, summary.elevation_window_evaluation_count)
        case .resource_limit: return .resourceLimit
        case .invalid_configuration: return .invalidConfiguration
        case .invalid_input_contract: return .invalidInputContract
        default: throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }
    }

    private static func callNative(
        _ samples: UnsafeBufferPointer<runplay.SegmentDetectionSample>,
        configuration: runplay.SegmentDetectionConfiguration,
        output: UnsafeMutableBufferPointer<runplay.SegmentWindowCandidate>
    ) -> runplay.SegmentDetectionSummary {
        runplay.detect_segment_windows(samples.baseAddress, samples.count, configuration, output.baseAddress, output.count)
    }
}

/// Transitional raw-corpus fixture. RoutePoint/WorkoutTimeline normalize some
/// non-finite values before the engine, so compare those contracts below Core.
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

final class SegmentDetectionDifferentialTests: XCTestCase {
    typealias Observation = SegmentDetectorRawParityObservation

    struct CorpusResult {
        var native: UInt64
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

    /// Runs the whole corpus through the Swift engine and, when `native` is set,
    /// through C++ as well. Every case hands both observations to `compare`.
    static func runCorpus(
        native: Bool,
        compare: (Observation, Observation, String) -> Void
    ) throws -> CorpusResult {
        var nativeDigest = FNV1a64()
        var swiftDigest = FNV1a64()
        var caseCount = 0

        func record(_ name: String, swift: Observation, cpp: () throws -> Observation) throws {
            Self.append(swift, to: &swiftDigest)
            if native {
                let reference = try cpp()
                compare(swift, reference, name)
                Self.append(reference, to: &nativeDigest)
            }
            caseCount += 1
        }

        func routeCase(_ name: String, _ points: [RoutePoint]) throws {
            let timeline = WorkoutTimeline(routePoints: points)
            let elevation = ElevationProfile(routePoints: points)
            let config = RunPlaySegmentDetectorBridgeTests.makeDefaultConfig(
                points: points, timeline: timeline, elevationProfile: elevation
            )
            let swift = try RunPlaySegmentDetectorAdapter.search(
                routePoints: points, timeline: timeline, elevationProfile: elevation, configuration: config,
                cancellationCheckStride: 2_048, isCancelled: { false }
            )
            try record(name, swift: observation(swift)) {
                observation(try RunPlaySegmentDetectorCppBridge.search(
                    routePoints: points, timeline: timeline, elevationProfile: elevation, configuration: config,
                    cancellationCheckStride: 2_048, isCancelled: { false }
                ))
            }
        }

        for index in 0..<SegmentDetectorParityFixtures.generatedFixtureCount {
            try routeCase("generated route \(index)", SegmentDetectorParityFixtures.generatedFixture(index: index))
        }
        let geography: [(String, Double, Double)] = [
            ("antimeridian east", 0, 179.999), ("antimeridian west", 0, -179.999),
            ("north pole", 90, 0), ("south pole", -90, 0),
            ("northern Web Mercator edge", 85.0511287798066, 0),
            ("southern Web Mercator edge", -85.0511287798066, 0),
        ]
        for (name, latitude, longitude) in geography {
            try routeCase(name, geographyRoute(latitude: latitude, longitude: longitude))
        }
        for (name, samples, configuration) in Self.rawParityFixtures() {
            let swift = try SegmentDetectionSwiftObserver.observeRaw(samples, configuration: configuration)
            try record(name, swift: swift) {
                try RunPlaySegmentDetectorCppBridge.observeRawForParity(samples, configuration: configuration)
            }
        }
        return CorpusResult(native: nativeDigest.value, swift: swiftDigest.value, caseCount: caseCount)
    }

    static var platformTag: String {
        #if os(macOS) && arch(arm64)
        return "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
        return "linux-x86_64"
        #else
        return "other"
        #endif
    }

    func testSwiftSegmentEngineMatchesNativeBitsAndCapturesDigest() throws {
        let result = try Self.runCorpus(native: true) { swift, native, name in
            compareBits(swift, native, name: name)
        }
        print("SEGMENT_NATIVE_FNV1A64 \(String(result.native, radix: 16)) \(Self.platformTag) cases=\(result.caseCount)")
        XCTAssertEqual(result.swift, result.native)
    }

    private func compareBits(
        _ swift: SegmentDetectorRawParityObservation, _ native: SegmentDetectorRawParityObservation, name: String
    ) {
        XCTAssertEqual(swift, native, name)
        guard case .outcome(let s, _, _) = swift, case .outcome(let n, _, _) = native else { return }
        for (a, b) in zip(s, n) {
            XCTAssertEqual(a.startDistanceMeters.bitPattern, b.startDistanceMeters.bitPattern, name)
            XCTAssertEqual(a.endDistanceMeters.bitPattern, b.endDistanceMeters.bitPattern, name)
            XCTAssertEqual(a.selectionValue.bitPattern, b.selectionValue.bitPattern, name)
        }
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

/// Pins the corpus digest of the C++ results. The Swift engine alone must
/// reproduce it, so the check runs in every configuration. A platform without
/// a captured digest shows as skipped rather than passed.
@Suite("Segment detection golden")
struct SegmentDetectionGoldenTests {
    static var golden: UInt64? {
        #if os(macOS) && arch(arm64)
        return 0xb16f_d7b1_3acd_a34d
        #elseif os(Linux) && arch(x86_64)
        // Captured from the C++ oracle in hosted Linux CI run 45327250481.
        return 0xb16f_d7b1_3acd_a34d
        #else
        return nil
        #endif
    }

    // Captured from the unchanged C++ kernel. This Swift-only test survives
    // removal of the live native differential and its marshalling.
    @Test(.enabled(if: SegmentDetectionGoldenTests.golden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        let expected = try #require(Self.golden)
        let result = try SegmentDetectionDifferentialTests.runCorpus(native: false) { _, _, _ in }
        #expect(result.swift == expected)
    }
}
