import Foundation
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

// Native oracle for differential tests and release measurements only.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Transitional C++ reference for differential tests and release benchmarks.
///
/// Builds one compact native cost array per route plus one Swift-owned output
/// buffer sized to the proven `n + m + 1` path upper bound, invokes
/// `compute_constrained_dtw_path` exactly once per alignment attempt, and
/// translates the result into pure Swift values.
///
/// There is no native call per dynamic-programming row, cell, or sample, and no
/// callback into Swift. Swift owns every buffer; C++ borrows them synchronously
/// and retains nothing. Cancellation is cooperative and checked around the
/// native call, never inside it.
enum RunPlayRouteAlignmentDtwCppBridge {
    static func solve(
        primary: [RouteAlignmentSample],
        comparison: [RouteAlignmentSample],
        primaryRouteDistanceMeters: Double,
        comparisonRouteDistanceMeters: Double,
        effectiveSampleIntervalMeters: Double,
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool,
        checkUntouchedOutput: Bool = false
    ) throws -> RunPlayRouteAlignmentDtwResult {
        guard !primary.isEmpty, !comparison.isEmpty else {
            throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        }

        let stride = max(1, policy.cancellationStride)

        let nativePrimary = try makeCostSamples(primary, stride: stride, isCancelled: isCancelled)
        let nativeComparison = try makeCostSamples(comparison, stride: stride, isCancelled: isCancelled)

        // A valid DTW path never exceeds n + m + 1 cells, so this bridge never
        // needs a retry. Overflow here would mean the engine could not index the
        // result at all.
        let (sampleSum, sumOverflow) = primary.count.addingReportingOverflow(comparison.count)
        let (pathCapacity, boundOverflow) = sampleSum.addingReportingOverflow(1)
        guard !sumOverflow, !boundOverflow, pathCapacity > 0 else {
            throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        }

        if isCancelled() {
            throw CancellationError()
        }

        let sentinel = checkUntouchedOutput ? runplay.RouteAlignmentDtwPathCell(
            primary_index: 0xfeed_face_0000_0000,
            comparison_index: 0x0bad_c0de_0000_0000,
            step: .comparison_only
        ) : runplay.RouteAlignmentDtwPathCell()
        var outputBuffer = ContiguousArray<runplay.RouteAlignmentDtwPathCell>(
            repeating: sentinel,
            count: pathCapacity
        )

        let summary = invokeNative(
            primary: nativePrimary,
            comparison: nativeComparison,
            primaryRouteDistanceMeters: primaryRouteDistanceMeters,
            comparisonRouteDistanceMeters: comparisonRouteDistanceMeters,
            effectiveSampleIntervalMeters: effectiveSampleIntervalMeters,
            policy: policy,
            outputBuffer: &outputBuffer,
            capacity: pathCapacity
        )

        if isCancelled() {
            throw CancellationError()
        }

        if checkUntouchedOutput, summary.status != .success {
            guard summary.written_path_count == 0, outputBuffer.allSatisfy({
                $0.primary_index == sentinel.primary_index
                    && $0.comparison_index == sentinel.comparison_index
                    && $0.step == sentinel.step
            }) else { throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation }
        }

        switch summary.status {
        case .success:
            break
        case .resource_limit:
            return .resourceLimit
        case .no_path:
            return .noPath
        case .invalid_policy:
            throw RunPlayRouteAlignmentDtwBridgeError.invalidPolicy
        case .invalid_input_contract:
            throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        case .allocation_failure:
            throw RunPlayRouteAlignmentDtwBridgeError.allocationFailure
        case .invalid_primary_buffer,
             .invalid_comparison_buffer,
             .invalid_output_buffer,
             .insufficient_output_capacity,
             .internal_failure:
            // Swift supplied the proven upper bound, so an insufficient-capacity
            // response is an engine contract violation, never a retry signal.
            throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
        @unknown default:
            throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
        }

        let path = try makePath(
            summary: summary,
            outputBuffer: outputBuffer,
            capacity: pathCapacity,
            primaryCount: primary.count,
            comparisonCount: comparison.count,
            stride: stride,
            isCancelled: isCancelled
        )

        return .success(
            path: path,
            bandRadius: Int(summary.band_radius),
            bandCellCount: Int(summary.band_cell_count),
            bestEndCost: summary.best_end_cost
        )
    }

    // MARK: - Conversion

    /// Copies only the four quantities that affect DTW cost. Raw route points,
    /// distances, segment indexes, and elapsed time stay Swift-owned.
    private static func makeCostSamples(
        _ samples: [RouteAlignmentSample],
        stride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> ContiguousArray<runplay.RouteAlignmentCostSample> {
        var result = ContiguousArray<runplay.RouteAlignmentCostSample>()
        result.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            if index % stride == 0, isCancelled() {
                throw CancellationError()
            }
            result.append(runplay.RouteAlignmentCostSample(
                x_meters: sample.xMeters,
                z_meters: sample.zMeters,
                normalized_progress: sample.normalizedProgress,
                heading_radians: sample.headingRadians ?? 0,
                has_heading: sample.headingRadians == nil ? 0 : 1
            ))
        }
        return result
    }

    /// Maps the alignment policy onto the fields the path solver actually reads.
    ///
    /// A negative warp-step or band-cell limit becomes zero, preserving the
    /// Swift comparisons exactly: zero warp steps forbids every non-diagonal
    /// transition, and a zero cell budget always reports a resource limit.
    private static func makeNativePolicy(
        _ policy: RouteAlignmentPolicy
    ) -> runplay.RouteAlignmentDtwPolicy {
        runplay.RouteAlignmentDtwPolicy(
            band_width_fraction: policy.bandWidthFraction,
            maximum_unmatched_prefix_suffix_meters: policy.maximumUnmatchedPrefixSuffixMeters,
            maximum_unmatched_prefix_suffix_fraction: policy.maximumUnmatchedPrefixSuffixFraction,
            non_diagonal_step_penalty: policy.nonDiagonalStepPenalty,
            maximum_consecutive_warp_steps: UInt64(max(0, policy.maximumConsecutiveWarpSteps)),
            spatial_distance_cost_scale_meters: policy.spatialDistanceCostScaleMeters,
            maximum_spatial_cost: policy.maximumSpatialCost,
            heading_penalty_weight: policy.headingPenaltyWeight,
            progress_penalty_weight: policy.progressPenaltyWeight,
            maximum_band_cells: UInt64(max(0, policy.maximumBandCells))
        )
    }

    /// Nested so every temporary C++ value is destroyed before the pure-Swift
    /// result returns to production code.
    private static func invokeNative(
        primary: ContiguousArray<runplay.RouteAlignmentCostSample>,
        comparison: ContiguousArray<runplay.RouteAlignmentCostSample>,
        primaryRouteDistanceMeters: Double,
        comparisonRouteDistanceMeters: Double,
        effectiveSampleIntervalMeters: Double,
        policy: RouteAlignmentPolicy,
        outputBuffer: inout ContiguousArray<runplay.RouteAlignmentDtwPathCell>,
        capacity: Int
    ) -> runplay.RouteAlignmentDtwSummary {
        let nativePolicy = makeNativePolicy(policy)
        return primary.withUnsafeBufferPointer { primaryBuffer in
            comparison.withUnsafeBufferPointer { comparisonBuffer in
                outputBuffer.withUnsafeMutableBufferPointer { output in
                    runplay.compute_constrained_dtw_path(
                        primaryBuffer.baseAddress,
                        primaryBuffer.count,
                        comparisonBuffer.baseAddress,
                        comparisonBuffer.count,
                        primaryRouteDistanceMeters,
                        comparisonRouteDistanceMeters,
                        effectiveSampleIntervalMeters,
                        nativePolicy,
                        output.baseAddress,
                        capacity
                    )
                }
            }
        }
    }

    // MARK: - Output validation

    private static func makePath(
        summary: runplay.RouteAlignmentDtwSummary,
        outputBuffer: ContiguousArray<runplay.RouteAlignmentDtwPathCell>,
        capacity: Int,
        primaryCount: Int,
        comparisonCount: Int,
        stride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> [RunPlayRouteAlignmentDtwPathCell] {
        guard
            summary.primary_sample_count == UInt64(primaryCount),
            summary.comparison_sample_count == UInt64(comparisonCount),
            summary.written_path_count == summary.required_path_count,
            summary.written_path_count > 0,
            summary.written_path_count <= UInt64(capacity),
            let count = Int(exactly: summary.written_path_count)
        else {
            throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
        }

        var path: [RunPlayRouteAlignmentDtwPathCell] = []
        path.reserveCapacity(count)

        var previous: RunPlayRouteAlignmentDtwPathCell?
        for index in 0..<count {
            if index % stride == 0, isCancelled() {
                throw CancellationError()
            }

            let native = outputBuffer[index]
            guard
                let primaryIndex = Int(exactly: native.primary_index),
                let comparisonIndex = Int(exactly: native.comparison_index),
                primaryIndex >= 0, primaryIndex < primaryCount,
                comparisonIndex >= 0, comparisonIndex < comparisonCount
            else {
                throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
            }

            let step: RunPlayRouteAlignmentDtwStepKind
            switch native.step {
            case .diagonal:
                step = .diagonal
            case .primary_only:
                step = .primaryOnly
            case .comparison_only:
                step = .comparisonOnly
            @unknown default:
                throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
            }

            let cell = RunPlayRouteAlignmentDtwPathCell(
                primaryIndex: primaryIndex,
                comparisonIndex: comparisonIndex,
                step: step
            )

            // The later cell's stored step describes the transition that reached
            // it, matching the reconstruction semantics. This rejects decreasing
            // indexes, jumps larger than one, and duplicate adjacent pairs.
            if let last = previous {
                let primaryDelta = primaryIndex - last.primaryIndex
                let comparisonDelta = comparisonIndex - last.comparisonIndex
                let consistent: Bool
                switch step {
                case .diagonal:
                    consistent = primaryDelta == 1 && comparisonDelta == 1
                case .primaryOnly:
                    consistent = primaryDelta == 1 && comparisonDelta == 0
                case .comparisonOnly:
                    consistent = primaryDelta == 0 && comparisonDelta == 1
                }
                guard consistent else {
                    throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
                }
            }

            path.append(cell)
            previous = cell
        }

        return path
    }
}

// MARK: - Benchmark-only diagnostics

/// Benchmark-only projection of one native constrained-DTW solve.
///
/// Deliberately narrower than `RunPlayRouteAlignmentDtwResult`: it reports the
/// engine's own counters without reconstructing or validating a Swift path, so
/// a release benchmark can attribute time to the native solve alone. Production
/// always goes through the Swift adapter.
struct RunPlayRouteAlignmentDtwNativeBenchmarkReport: Equatable, Sendable {
    /// `true` only for engine `success`; `resource_limit` and `no_path` are
    /// reported as `false` rather than thrown, matching `solve`'s treatment of
    /// them as ordinary outcomes.
    let succeeded: Bool
    let bandRadius: Int
    let bandCellCount: Int
    let writtenPathCount: Int
    let bestEndCost: Double
}

/// Benchmark-only handle holding one already-converted native input pair plus
/// the Swift-owned output buffer sized to the proven `n + m + 1` path bound.
///
/// Exists so a release benchmark can time the native solve without the sample
/// conversion and path validation that the production path always performs.
/// Nothing in production constructs or reads this type.
///
/// Buffer ownership is unchanged: Swift owns every buffer, C++ borrows them
/// synchronously inside one call and retains nothing.
final class RunPlayRouteAlignmentDtwPreparedBenchmarkInput {
    fileprivate let nativePrimary: ContiguousArray<runplay.RouteAlignmentCostSample>
    fileprivate let nativeComparison: ContiguousArray<runplay.RouteAlignmentCostSample>
    fileprivate var outputBuffer: ContiguousArray<runplay.RouteAlignmentDtwPathCell>
    fileprivate let pathCapacity: Int

    fileprivate init(
        nativePrimary: ContiguousArray<runplay.RouteAlignmentCostSample>,
        nativeComparison: ContiguousArray<runplay.RouteAlignmentCostSample>,
        pathCapacity: Int
    ) {
        self.nativePrimary = nativePrimary
        self.nativeComparison = nativeComparison
        self.outputBuffer = ContiguousArray<runplay.RouteAlignmentDtwPathCell>(
            repeating: runplay.RouteAlignmentDtwPathCell(),
            count: pathCapacity
        )
        self.pathCapacity = pathCapacity
    }
}

extension RunPlayRouteAlignmentDtwCppBridge {
    /// Diagnostic-only: perform the conversion half of `solve` up front so a
    /// benchmark can time the native solve on its own. Not a production path.
    ///
    /// Uses the same `makeCostSamples` conversion as production with
    /// cancellation disabled, and the same proven `n + m + 1` output bound, so
    /// the prepared state is byte-identical to what `solve` would build.
    static func prepareNativeInputForBenchmark(
        primary: [RouteAlignmentSample],
        comparison: [RouteAlignmentSample]
    ) throws -> RunPlayRouteAlignmentDtwPreparedBenchmarkInput {
        guard !primary.isEmpty, !comparison.isEmpty else {
            throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        }

        let (sampleSum, sumOverflow) = primary.count.addingReportingOverflow(comparison.count)
        let (pathCapacity, boundOverflow) = sampleSum.addingReportingOverflow(1)
        guard !sumOverflow, !boundOverflow, pathCapacity > 0 else {
            throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        }

        let nativePrimary = try makeCostSamples(primary, stride: 1, isCancelled: { false })
        let nativeComparison = try makeCostSamples(comparison, stride: 1, isCancelled: { false })

        return RunPlayRouteAlignmentDtwPreparedBenchmarkInput(
            nativePrimary: nativePrimary,
            nativeComparison: nativeComparison,
            pathCapacity: pathCapacity
        )
    }

    /// Diagnostic-only: invoke the native kernel on already-converted inputs.
    ///
    /// Performs no Swift-side sample conversion and no output validation, so
    /// the measured interval is the engine call itself. Used by release
    /// benchmarks; not a production path.
    @discardableResult
    static func invokeNativeKernelForBenchmark(
        _ prepared: RunPlayRouteAlignmentDtwPreparedBenchmarkInput,
        primaryRouteDistanceMeters: Double,
        comparisonRouteDistanceMeters: Double,
        effectiveSampleIntervalMeters: Double,
        policy: RouteAlignmentPolicy
    ) throws -> RunPlayRouteAlignmentDtwNativeBenchmarkReport {
        let summary = invokeNative(
            primary: prepared.nativePrimary,
            comparison: prepared.nativeComparison,
            primaryRouteDistanceMeters: primaryRouteDistanceMeters,
            comparisonRouteDistanceMeters: comparisonRouteDistanceMeters,
            effectiveSampleIntervalMeters: effectiveSampleIntervalMeters,
            policy: policy,
            outputBuffer: &prepared.outputBuffer,
            capacity: prepared.pathCapacity
        )

        switch summary.status {
        case .success:
            return RunPlayRouteAlignmentDtwNativeBenchmarkReport(
                succeeded: true,
                bandRadius: Int(clamping: summary.band_radius),
                bandCellCount: Int(clamping: summary.band_cell_count),
                writtenPathCount: Int(clamping: summary.written_path_count),
                bestEndCost: summary.best_end_cost
            )
        case .resource_limit, .no_path:
            return RunPlayRouteAlignmentDtwNativeBenchmarkReport(
                succeeded: false,
                bandRadius: Int(clamping: summary.band_radius),
                bandCellCount: Int(clamping: summary.band_cell_count),
                writtenPathCount: 0,
                bestEndCost: 0
            )
        case .invalid_policy:
            throw RunPlayRouteAlignmentDtwBridgeError.invalidPolicy
        case .invalid_input_contract:
            throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        case .allocation_failure:
            throw RunPlayRouteAlignmentDtwBridgeError.allocationFailure
        default:
            throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
        }
    }
}

@Suite struct RouteAlignmentDtwDifferentialTests {
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

    private static var cppGolden: UInt64? {
        #if os(macOS) && arch(arm64)
        0x9fc7_5d5e_35cb_3762
        #elseif os(Linux) && arch(x86_64)
        0x8a94_d3cb_d385_aa8c
        #else
        nil
        #endif
    }

    // Captured from the unchanged C++ port. This Swift-only test survives
    // removal of the live native differential and its marshalling.
    @Test(.enabled(if: RouteAlignmentDtwDifferentialTests.cppGolden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        let expected = try #require(Self.cppGolden)
        var digest = FNV1a64()
        for fixture in Self.bitCorpus() {
            try Self.observeSwift(fixture).append(to: &digest)
        }
        #expect(digest.value == expected)
    }

    @Test func cppAndSwiftMatchBitForBit() throws {
        var cppDigest = FNV1a64()
        var swiftDigest = FNV1a64()
        var comparedCategories = Set<UInt8>()
        let corpus = Self.bitCorpus()
        #expect(corpus.count == 1_291)
        for fixture in corpus {
            let cpp = try Observation {
                try RunPlayRouteAlignmentDtwCppBridge.solve(
                    primary: fixture.primary, comparison: fixture.comparison,
                    primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
                    comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
                    effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
                    policy: fixture.policy, isCancelled: { false }, checkUntouchedOutput: true
                )
            }
            let swift = try Self.observeSwift(fixture)
            #expect(swift == cpp, "DTW mismatch: \(fixture.name)")
            comparedCategories.insert(cpp.category)
            cpp.append(to: &cppDigest)
            swift.append(to: &swiftDigest)
        }
        #if os(macOS) && arch(arm64)
        let platform = "macos-arm64"
        #elseif os(Linux) && arch(x86_64)
        let platform = "linux-x86_64"
        #else
        let platform = "other"
        #endif
        print("DTW_NATIVE_FNV1A64 \(String(cppDigest.value, radix: 16)) \(platform) cases=\(corpus.count)")
        #expect(comparedCategories == [0, 1, 2, 3, 4])
        #expect(swiftDigest.value == cppDigest.value)
        if let expected = Self.cppGolden {
            #expect(cppDigest.value == expected)
        }
    }
}
