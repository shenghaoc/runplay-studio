internal import CxxStdlib
import Foundation
import RunPlayEngine
internal import RunPlayEngineCpp
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

struct RouteQualityDifferentialTests {
    private typealias Parity = RouteQualityParity

    @Test func comparesNativeOutputs() {
        var digest = FNV1a64()
        forEachFixture { label, inputs, strategy, selection, confirmationCount in
            let cpp = Parity.cpp(inputs, strategy, selection: selection, confirmationCount: confirmationCount)
            let swift = Parity.swift(inputs, strategy, selection: selection, confirmationCount: confirmationCount)
            // Equality compares encoded floating-point bits, not Double equality.
            // Avoid dumping either complete buffer for a failed 1M-point fixture.
            let equal = swift == cpp
            #expect(equal, Comment(rawValue: label))
            #expect(cpp.outputUntouchedOnError, Comment(rawValue: label))
            Self.append(cpp, to: &digest)
        }
        print("ROUTE_QUALITY_CPP_GOLDEN=\(String(digest.value, radix: 16))")
    }

    private static let cppGolden: UInt64? = {
        #if os(macOS) && arch(arm64)
        0x6edd5a41ea952c20
        #elseif os(Linux) && arch(x86_64)
        // Captured from the C++ oracle in hosted Linux CI run 45327247726.
        0x6edd5a41ea952c20
        #else
        nil
        #endif
    }()

    @Test(.enabled(if: cppGolden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        let expected = try #require(Self.cppGolden)
        var digest = FNV1a64()
        forEachFixture { _, inputs, strategy, selection, confirmationCount in
            let swift = Parity.swift(inputs, strategy, selection: selection, confirmationCount: confirmationCount)
            Self.append(swift, to: &digest)
        }
        #expect(digest.value == expected)
    }

    private static func append(_ result: Parity.Summary, to digest: inout FNV1a64) {
        digest.append(byte: result.status)
        digest.append(word: result.input)
        digest.append(word: result.retained)
        digest.append(word: result.discarded)
        digest.append(word: result.gaps)
        digest.append(word: result.segments)
        digest.append(byte: result.source)
        digest.append(word: result.totalBits)
        digest.append(word: UInt64(result.rows.count))
        for row in result.rows {
            digest.append(word: row.source)
            digest.append(word: row.segment)
            digest.append(word: row.distanceBits)
            digest.append(byte: row.distanceSource)
            digest.append(byte: row.retained)
            digest.append(byte: row.rejected)
            digest.append(byte: row.inferred)
        }
    }

    private func forEachFixture(
        _ visit: (String, [Parity.Input], Parity.Strategy, [UInt8]?, UInt64) -> Void
    ) {
        func compare(
            _ label: String, _ inputs: [Parity.Input], _ strategy: Parity.Strategy = .coordinates,
            selection: [UInt8]? = nil, confirmationCount: UInt64 = 3
        ) {
            visit(label, inputs, strategy, selection, confirmationCount)
        }
        compare("empty", [])
        compare("empty first", [], .suppliedForSelection, selection: [2], confirmationCount: 0)
        compare("one", [.init()])
        compare("first accuracy unchecked", [.init(accuracy: .nan)])
        compare("invalid policy before input", [.init(latitude: .nan)], confirmationCount: 1)
        compare("invalid latitude", [.init(latitude: .nan)])
        compare("invalid longitude", [.init(longitude: .infinity)])
        compare("invalid timestamp", [.init(timestamp: -.infinity)])
        compare("invalid elapsed", [.init(elapsed: .nan)])
        compare("selection missing", [.init()], .suppliedForSelection)
        compare("byte out of domain", [.init()], .suppliedForSelection, selection: [2])
        compare("selection present, nonselected policy", [.init()], selection: [])
        compare("inconsistent within-segment selection", [.init(), .init(source: 1)], .suppliedForSelection, selection: [1, 0])
        compare("first and last accuracy", [.init(), .init(source: 1, accuracy: -.infinity)])
        compare("segment gap", [.init(), .init(source: 1, segment: 2)])
        compare("subnormal and negative zero", [
            .init(latitude: -.leastNonzeroMagnitude, distance: -0.0),
            .init(source: 1, timestamp: 1, latitude: .leastNonzeroMagnitude, distance: 0.0, elapsed: 1),
        ], .allSupplied)
        compare("antimeridian, poles, Mercator limit", [
            .init(latitude: 85.0511287798066, longitude: 179.999999),
            .init(source: 1, timestamp: 300, latitude: 90, longitude: -179.999999, elapsed: 300),
            .init(source: 2, timestamp: 600, latitude: -90, longitude: 180, elapsed: 600),
        ])
        compare("inferred boundary and rejected point", route([0, 10, 5_000, 20, 30, 3_000, 3_010, 3_020, 3_030]))
        compare("adjacent flags", route([0, 0, 5_000, 0, 5_000, 0, 0]))
        compare("confirmation max wraps without accepting incomplete windows", route([0, 1, 3_000, 3_010]), confirmationCount: .max)

        var random = SplitMix64(seed: 0x4ee3_19ac_c6b9_b509)
        for length in [1, 2, 3, 8, 31, 64, 127, 512] {
            let rows = (0..<length).map { index -> Parity.Input in
                let latitude = Double(index) / 111_132 + Double(random.next() % 500) / 10_000_000
                let longitude = Double(random.next() % 100) / 100_000_000
                let metres = index % 37 == 7 ? -1.0 : Double(index)
                let t = Double(index)
                return .init(
                    source: random.next(), timestamp: t, latitude: latitude, longitude: longitude,
                    distance: metres, elapsed: t, segment: Int64(index / 11),
                    accuracy: index % 15 == 0 ? 120 : nil
                )
            }
            for strategy in Parity.Strategy.allCases {
                let selection = strategy == .suppliedForSelection ? rows.map { UInt8($0.segment % 2) } : nil
                compare("seeded: \(length), \(strategy)", rows, strategy, selection: selection)
            }
        }

        // Real allocated Spans, not C++'s single-pointer oversized count fixture.
        let product = 1_000_000
        compare("product limit", Array(repeating: .init(), count: product), .allSupplied)
        compare("one above kernel ceiling", Array(repeating: .init(), count: 1_250_001))
    }

    private func route(_ metres: [Double]) -> [Parity.Input] {
        metres.enumerated().map {
            .init(
                source: UInt64($0.offset), timestamp: Double($0.offset), latitude: $0.element / 111_132,
                distance: Double($0.offset), elapsed: Double($0.offset), accuracy: 8
            )
        }
    }
}

// Raw forms used only by the temporary C++/Swift differential tests.
private enum RouteQualityParity {
    struct Input {
        var source: UInt64 = 0
        var timestamp = 0.0
        var latitude = 0.0
        var longitude = 0.0
        var distance = 0.0
        var elapsed = 0.0
        var segment: Int64 = 0
        var accuracy: Double?
    }

    enum Strategy: UInt8, CaseIterable {
        case coordinates, allSupplied, suppliedPerSegment, suppliedForSelection
    }

    struct Row: Equatable {
        let source: UInt64
        let segment: Int64
        let distanceBits: UInt64
        let distanceSource: UInt8
        let retained: UInt8
        let rejected: UInt8
        let inferred: UInt8
    }

    struct Summary: Equatable {
        let status: UInt8
        var input: UInt64 = 0
        var retained: UInt64 = 0
        var discarded: UInt64 = 0
        var gaps: UInt64 = 0
        var segments: UInt64 = 0
        var source: UInt8 = 0
        var totalBits: UInt64 = 0
        var rows: [Row] = []
        var outputUntouchedOnError = true
    }

    static func cpp(
        _ inputs: [Input], _ strategy: Strategy, selection: [UInt8]? = nil,
        confirmationCount: UInt64 = 3
    ) -> Summary {
        CppRouteQualityOracle.rawCppForVerification(
            inputs, strategy: strategy, selection: selection, confirmationCount: confirmationCount
        )
    }

    static func swift(
        _ inputs: [Input], _ strategy: Strategy, selection: [UInt8]? = nil,
        confirmationCount: UInt64 = 3
    ) -> Summary {
        let distancePolicy: EngineRouteDistancePolicy = switch strategy {
        case .coordinates: .coordinates
        case .allSupplied: .allSupplied
        case .suppliedPerSegment: .suppliedPerSegment
        case .suppliedForSelection: .suppliedForSelection
        }
        let samples = inputs.map {
            EngineRouteInputSample(
                sourceIndex: $0.source, timestampSecondsSinceReferenceDate: $0.timestamp,
                latitude: $0.latitude, longitude: $0.longitude, distanceFromStartMeters: $0.distance,
                elapsedSeconds: $0.elapsed, horizontalAccuracy: $0.accuracy, routeSegmentIndex: $0.segment
            )
        }
        let policy = EngineRouteQualityPolicy(
            maximumRunningSpeed: 12, usefulAccuracy: 100,
            minimumSpikeExcess: 200, minimumSpikeDistortion: 3, poorAccuracyMultiplier: 0.5,
            minimumGapDistance: 200, minimumGapInterval: 120, minimumGapRatio: 3,
            confirmationCount: confirmationCount, maximumClusterStep: 200
        )

        do throws(RouteQualityError) {
            let summary: EngineRouteQualityResult
            if let selection {
                summary = try EngineRouteQuality.process(
                    samples.span, policy: policy, distancePolicy: distancePolicy, selection: selection.span
                )
            } else {
                summary = try EngineRouteQuality.process(
                    samples.span, policy: policy, distancePolicy: distancePolicy, selection: nil
                )
            }
            return Summary(
                status: 0, input: UInt64(summary.samples.count), retained: UInt64(summary.retainedCount),
                discarded: UInt64(summary.discardedCount), gaps: UInt64(summary.inferredGapCount),
                segments: UInt64(summary.segmentCount), source: summary.distanceSource.rawValue,
                totalBits: summary.totalDistance.bitPattern,
                rows: summary.samples.map {
                    Row(
                        source: $0.sourceIndex, segment: $0.normalizedSegmentIndex,
                        distanceBits: $0.normalizedDistance.bitPattern, distanceSource: $0.distanceSource.rawValue,
                        retained: $0.retained ? 1 : 0, rejected: $0.rejected ? 1 : 0, inferred: $0.inferredBoundary ? 1 : 0
                    )
                }
            )
        } catch {
            // Typed throws cannot return or mutate a caller-owned output on failure.
            let status: UInt8 = switch error {
            case .invalidSelectionBuffer: 4
            case .invalidPolicy: 5
            case .invalidInputContract: 6
            case .resourceLimit: 7
            }
            return Summary(status: status)
        }
    }
}

enum CppRouteQualityOracle {
    static func withNativeSamples<Result>(
        _ points: [RoutePoint],
        _ body: (
            UnsafeBufferPointer<runplay.RouteInputSample>
        ) throws -> Result
    ) rethrows -> Result {
        var samples = ContiguousArray<runplay.RouteInputSample>()
        samples.reserveCapacity(points.count)
        for (sourceIndex, point) in points.enumerated() {
            samples.append(makeSample(sourceIndex: sourceIndex, point: point))
        }
        return try samples.withUnsafeBufferPointer(body)
    }

    /// Builds one complete native sample buffer while cooperatively checking
    /// cancellation at the configured stride during conversion.
    static func withNativeSamples<Result>(
        _ points: [RoutePoint],
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool,
        _ body: (
            UnsafeBufferPointer<runplay.RouteInputSample>
        ) throws -> Result
    ) throws -> Result {
        let stride = max(1, cancellationCheckStride)
        var samples = ContiguousArray<runplay.RouteInputSample>()
        samples.reserveCapacity(points.count)

        for (sourceIndex, point) in points.enumerated() {
            if sourceIndex.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }
            samples.append(makeSample(sourceIndex: sourceIndex, point: point))
        }

        return try samples.withUnsafeBufferPointer(body)
    }

    private static func makeSample(
        sourceIndex: Int,
        point: RoutePoint
    ) -> runplay.RouteInputSample {
        guard let routeSegmentIndex = Int64(exactly: point.routeSegmentIndex) else {
            preconditionFailure("RoutePoint.routeSegmentIndex must fit in Int64")
        }
        return runplay.RouteInputSample(
            UInt64(sourceIndex),
            point.timestamp.timeIntervalSinceReferenceDate,
            point.latitude,
            point.longitude,
            nativeOptional(point.altitudeMeters),
            nativeOptional(point.demAltitudeMeters),
            point.distanceFromStartMeters,
            point.elapsedSeconds,
            nativeOptional(point.speedMetersPerSecond),
            nativeOptional(point.paceSecondsPerKilometer),
            nativeOptional(point.heartRateBPM),
            nativeOptional(point.cadence),
            nativeOptional(point.powerWatts),
            nativeOptional(point.groundContactTimeMilliseconds),
            nativeOptional(point.verticalOscillationMillimeters),
            nativeOptional(point.verticalRatioPercent),
            nativeOptional(point.stanceTimeBalancePercent),
            nativeOptional(point.stepLengthMeters),
            nativeOptional(point.horizontalAccuracy),
            routeSegmentIndex
        )
    }

    static func nativeOptional(
        _ value: Double?
    ) -> runplay.RouteOptionalDouble {
        guard let value else {
            return runplay.RouteOptionalDouble()
        }
        return runplay.RouteOptionalDouble(value)
    }


    static func processCppForVerification(
        _ orderedPoints: [RoutePoint],
        policy: RouteQualityPolicy,
        distancePolicy: RouteDistancePolicy,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayRouteQualityGeometryResult {
        if orderedPoints.isEmpty {
            return RunPlayRouteQualityGeometryResult(
                routePoints: [],
                discardedCoordinatePointCount: 0,
                inferredRouteGapCount: 0,
                distanceSource: .coordinateDerived,
                distanceProvenance: RouteDistanceProvenance()
            )
        }

        return try processNative(
            orderedPoints,
            policy: policy,
            distancePolicy: distancePolicy,
            cancellationCheckStride: max(1, cancellationCheckStride),
            isCancelled: isCancelled
        )
    }

    /// Nested so every temporary C++ value is destroyed before the pure-Swift
    /// result returns to production code.
    private static func processNative(
        _ orderedPoints: [RoutePoint],
        policy: RouteQualityPolicy,
        distancePolicy: RouteDistancePolicy,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayRouteQualityGeometryResult {
        let geometryPolicy = nativeGeometryPolicy(from: policy)
        let nativeDistancePolicy = nativeDistancePolicy(from: distancePolicy)
        let selection = selectionBuffer(
            for: orderedPoints,
            distancePolicy: distancePolicy
        )

        var output = ContiguousArray<runplay.RouteQualityOutputSample>(
            repeating: runplay.RouteQualityOutputSample(),
            count: orderedPoints.count
        )

        let summary = try withNativeSamples(
            orderedPoints,
            cancellationCheckStride: cancellationCheckStride,
            isCancelled: isCancelled
        ) { input in
            try checkCancellation(isCancelled: isCancelled)
            NativeCallObserver.record(.routeQuality)
            let result: runplay.RouteQualityPipelineSummary =
                selection.withUnsafeBufferPointer { selectionBuffer in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        let selectionPointer: UnsafePointer<UInt8>? =
                            selection.isEmpty ? nil : selectionBuffer.baseAddress
                        return runplay.process_route_quality_geometry(
                            input.baseAddress,
                            input.count,
                            geometryPolicy,
                            nativeDistancePolicy,
                            selectionPointer,
                            selection.isEmpty ? 0 : selectionBuffer.count,
                            outputBuffer.baseAddress,
                            outputBuffer.count
                        )
                    }
                }
            try checkCancellation(isCancelled: isCancelled)
            return result
        }

        switch summary.status {
        case .success:
            break
        case .resource_limit:
            throw RunPlayRouteQualityBridgeError.resourceLimit
        case .invalid_input_contract:
            throw RunPlayRouteQualityBridgeError.invalidInputContract
        case .invalid_policy:
            throw RunPlayRouteQualityBridgeError.invalidPolicy
        case .invalid_input_buffer,
             .invalid_output_buffer,
             .insufficient_output_capacity,
             .invalid_selection_buffer:
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        default:
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        }

        guard summary.input_sample_count == UInt64(orderedPoints.count) else {
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        }

        return try projectResult(
            orderedPoints: orderedPoints,
            output: output,
            summary: summary,
            cancellationCheckStride: cancellationCheckStride,
            isCancelled: isCancelled
        )
    }

    private static func projectResult(
        orderedPoints: [RoutePoint],
        output: ContiguousArray<runplay.RouteQualityOutputSample>,
        summary: runplay.RouteQualityPipelineSummary,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayRouteQualityGeometryResult {
        guard output.count == orderedPoints.count else {
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        }

        var retained: [RoutePoint] = []
        retained.reserveCapacity(Int(summary.retained_sample_count))
        var retainedCount = 0
        var previousNormalizedSegment: Int64?
        var segmentSources: [RouteDistanceSource] = []

        for index in orderedPoints.indices {
            if index.isMultiple(of: cancellationCheckStride), isCancelled() {
                throw CancellationError()
            }

            let sample = output[index]
            guard sample.source_index == UInt64(index) else {
                throw RunPlayRouteQualityBridgeError.engineContractViolation
            }
            guard sample.retained == 0 || sample.retained == 1,
                  sample.rejected_coordinate_outlier == 0
                    || sample.rejected_coordinate_outlier == 1,
                  sample.inferred_boundary == 0 || sample.inferred_boundary == 1
            else {
                throw RunPlayRouteQualityBridgeError.engineContractViolation
            }

            if sample.retained == 0 {
                continue
            }
            retainedCount += 1

            let normalizedSegment = sample.normalized_segment_index
            if previousNormalizedSegment == nil {
                guard normalizedSegment == 0 else {
                    throw RunPlayRouteQualityBridgeError.engineContractViolation
                }
            } else if let previous = previousNormalizedSegment {
                guard normalizedSegment == previous
                    || normalizedSegment == previous + 1
                else {
                    throw RunPlayRouteQualityBridgeError.engineContractViolation
                }
            }
            if previousNormalizedSegment != normalizedSegment {
                segmentSources.append(swiftDistanceSource(sample.distance_source))
                previousNormalizedSegment = normalizedSegment
            } else if let last = segmentSources.last {
                let current = swiftDistanceSource(sample.distance_source)
                guard last == current else {
                    throw RunPlayRouteQualityBridgeError.engineContractViolation
                }
            }

            var point = orderedPoints[index]
            guard let segmentIndex = Int(exactly: normalizedSegment) else {
                throw RunPlayRouteQualityBridgeError.engineContractViolation
            }
            point.routeSegmentIndex = segmentIndex
            point.distanceFromStartMeters =
                sample.normalized_distance_from_start_meters
            retained.append(point)
        }

        guard retainedCount == Int(summary.retained_sample_count),
              retained.count == retainedCount,
              segmentSources.count == Int(summary.normalized_segment_count)
        else {
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        }

        let overall = swiftOverallDistanceSource(summary.distance_source)
        return RunPlayRouteQualityGeometryResult(
            routePoints: retained,
            discardedCoordinatePointCount: Int(summary.discarded_coordinate_point_count),
            inferredRouteGapCount: Int(summary.inferred_route_gap_count),
            distanceSource: overall,
            distanceProvenance: RouteDistanceProvenance(segmentSources: segmentSources)
        )
    }

    private static func nativeGeometryPolicy(
        from policy: RouteQualityPolicy
    ) -> runplay.RouteQualityGeometryPolicy {
        runplay.RouteQualityGeometryPolicy(
            maximum_plausible_running_speed_meters_per_second:
                policy.maximumPlausibleRunningSpeedMetersPerSecond,
            maximum_useful_horizontal_accuracy_meters:
                policy.maximumUsefulHorizontalAccuracyMeters,
            coordinate_spike_minimum_excess_distance_meters:
                policy.coordinateSpikeMinimumExcessDistanceMeters,
            coordinate_spike_minimum_distortion_ratio:
                policy.coordinateSpikeMinimumDistortionRatio,
            poor_accuracy_evidence_multiplier:
                policy.poorAccuracyEvidenceMultiplier,
            implicit_gap_minimum_distance_meters:
                policy.implicitGapMinimumDistanceMeters,
            implicit_gap_minimum_time_interval_seconds:
                policy.implicitGapMinimumTimeIntervalSeconds,
            implicit_gap_minimum_time_discontinuity_ratio:
                policy.implicitGapMinimumTimeDiscontinuityRatio,
            relocated_cluster_confirmation_point_count:
                UInt64(policy.relocatedClusterConfirmationPointCount),
            relocated_cluster_maximum_step_meters:
                policy.relocatedClusterMaximumStepMeters
        )
    }

    private static func nativeDistancePolicy(
        from policy: RouteDistancePolicy
    ) -> runplay.RouteQualityDistancePolicy {
        switch policy {
        case .computeFromCoordinates:
            return .compute_from_coordinates
        case .useSuppliedDistancesWhenValid:
            return .use_supplied_when_all_valid
        case .useSuppliedDistancesPerSegment:
            return .use_supplied_per_segment
        case .useSuppliedDistancesForSegments:
            return .use_supplied_for_selected_source_segments
        }
    }

    private static func selectionBuffer(
        for points: [RoutePoint],
        distancePolicy: RouteDistancePolicy
    ) -> ContiguousArray<UInt8> {
        guard case .useSuppliedDistancesForSegments(let selected) = distancePolicy else {
            return []
        }
        var buffer = ContiguousArray<UInt8>()
        buffer.reserveCapacity(points.count)
        for point in points {
            buffer.append(selected.contains(point.routeSegmentIndex) ? 1 : 0)
        }
        return buffer
    }

    private static func swiftDistanceSource(
        _ source: runplay.RouteSegmentDistanceSource
    ) -> RouteDistanceSource {
        switch source {
        case .coordinate_derived:
            return .coordinateDerived
        case .device_supplied:
            return .deviceSupplied
        default:
            return .coordinateDerived
        }
    }

    private static func swiftOverallDistanceSource(
        _ source: runplay.RouteQualityDistanceSource
    ) -> RouteDistanceSource {
        switch source {
        case .coordinate_derived:
            return .coordinateDerived
        case .device_supplied:
            return .deviceSupplied
        case .mixed:
            return .mixed
        default:
            return .coordinateDerived
        }
    }

    private static func checkCancellation(
        isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }

    /// Diagnostic-only: invoke the native kernel after input conversion is
    /// already complete. Used by release benchmarks; not a production path.
    static func invokeNativeKernelForBenchmark(
        _ orderedPoints: [RoutePoint],
        policy: RouteQualityPolicy,
        distancePolicy: RouteDistancePolicy
    ) throws {
        if orderedPoints.isEmpty { return }
        let geometryPolicy = nativeGeometryPolicy(from: policy)
        let nativeDistancePolicy = nativeDistancePolicy(from: distancePolicy)
        let selection = selectionBuffer(
            for: orderedPoints,
            distancePolicy: distancePolicy
        )
        var output = ContiguousArray<runplay.RouteQualityOutputSample>(
            repeating: runplay.RouteQualityOutputSample(),
            count: orderedPoints.count
        )
        NativeCallObserver.record(.routeQuality)
        let summary = withNativeSamples(orderedPoints) { input in
            selection.withUnsafeBufferPointer { selectionBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    let selectionPointer: UnsafePointer<UInt8>? =
                        selection.isEmpty ? nil : selectionBuffer.baseAddress
                    return runplay.process_route_quality_geometry(
                        input.baseAddress,
                        input.count,
                        geometryPolicy,
                        nativeDistancePolicy,
                        selectionPointer,
                        selection.isEmpty ? 0 : selectionBuffer.count,
                        outputBuffer.baseAddress,
                        outputBuffer.count
                    )
                }
            }
        }
        switch summary.status {
        case .success:
            return
        case .resource_limit:
            throw RunPlayRouteQualityBridgeError.resourceLimit
        case .invalid_input_contract:
            throw RunPlayRouteQualityBridgeError.invalidInputContract
        case .invalid_policy:
            throw RunPlayRouteQualityBridgeError.invalidPolicy
        default:
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        }
    }
}

extension CppRouteQualityOracle {
    fileprivate static func rawCppForVerification(
        _ rows: [RouteQualityParity.Input],
        strategy: RouteQualityParity.Strategy,
        selection: [UInt8]?,
        confirmationCount: UInt64
    ) -> RouteQualityParity.Summary {
        let nativeRows = rows.map {
            runplay.RouteInputSample(
                $0.source, $0.timestamp, $0.latitude, $0.longitude,
                runplay.RouteOptionalDouble(), runplay.RouteOptionalDouble(),
                $0.distance, $0.elapsed,
                runplay.RouteOptionalDouble(), runplay.RouteOptionalDouble(), runplay.RouteOptionalDouble(),
                runplay.RouteOptionalDouble(), runplay.RouteOptionalDouble(), runplay.RouteOptionalDouble(),
                runplay.RouteOptionalDouble(), runplay.RouteOptionalDouble(), runplay.RouteOptionalDouble(),
                runplay.RouteOptionalDouble(), nativeOptional($0.accuracy), $0.segment
            )
        }
        let policy = runplay.RouteQualityGeometryPolicy(
            maximum_plausible_running_speed_meters_per_second: 12,
            maximum_useful_horizontal_accuracy_meters: 100,
            coordinate_spike_minimum_excess_distance_meters: 200,
            coordinate_spike_minimum_distortion_ratio: 3,
            poor_accuracy_evidence_multiplier: 0.5,
            implicit_gap_minimum_distance_meters: 200,
            implicit_gap_minimum_time_interval_seconds: 120,
            implicit_gap_minimum_time_discontinuity_ratio: 3,
            relocated_cluster_confirmation_point_count: confirmationCount,
            relocated_cluster_maximum_step_meters: 200
        )
        let nativeStrategy: runplay.RouteQualityDistancePolicy = switch strategy {
        case .coordinates: .compute_from_coordinates
        case .allSupplied: .use_supplied_when_all_valid
        case .suppliedPerSegment: .use_supplied_per_segment
        case .suppliedForSelection: .use_supplied_for_selected_source_segments
        }
        let storage = selection.map { $0.isEmpty ? [0] : $0 } ?? []
        var sentinel = runplay.RouteQualityOutputSample()
        sentinel.source_index = 0xDEADBEEF
        sentinel.normalized_segment_index = -99
        sentinel.normalized_distance_from_start_meters = -123
        sentinel.distance_source = .device_supplied
        sentinel.retained = 7
        sentinel.rejected_coordinate_outlier = 7
        sentinel.inferred_boundary = 7
        var output = Array(repeating: sentinel, count: rows.count)
        let summary = nativeRows.withUnsafeBufferPointer { samples in
            storage.withUnsafeBufferPointer { selected in
                output.withUnsafeMutableBufferPointer { target in
                    runplay.process_route_quality_geometry(
                        samples.baseAddress, samples.count, policy, nativeStrategy,
                        selection == nil ? nil : selected.baseAddress, selection?.count ?? 0,
                        target.baseAddress, target.count
                    )
                }
            }
        }
        let status = summary.status.rawValue
        var untouched = true
        if status != 0 {
            untouched = output.allSatisfy {
                $0.source_index == 0xDEADBEEF && $0.normalized_segment_index == -99
                    && $0.normalized_distance_from_start_meters.bitPattern == (-123.0).bitPattern
                    && $0.distance_source == .device_supplied && $0.retained == 7
                    && $0.rejected_coordinate_outlier == 7 && $0.inferred_boundary == 7
            }
        }
        return .init(
            status: status, input: summary.input_sample_count, retained: summary.retained_sample_count,
            discarded: summary.discarded_coordinate_point_count, gaps: summary.inferred_route_gap_count,
            segments: summary.normalized_segment_count, source: summary.distance_source.rawValue,
            totalBits: summary.total_distance_meters.bitPattern,
            rows: status != 0 ? [] : output.map {
                .init(
                    source: $0.source_index, segment: $0.normalized_segment_index,
                    distanceBits: $0.normalized_distance_from_start_meters.bitPattern,
                    distanceSource: $0.distance_source.rawValue, retained: $0.retained,
                    rejected: $0.rejected_coordinate_outlier, inferred: $0.inferred_boundary
                )
            },
            outputUntouchedOnError: untouched
        )
    }
}
