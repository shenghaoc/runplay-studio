import Foundation

// Keep imported C++ declarations confined to the internal Interop layer.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Errors raised by the combined route-quality geometry bulk boundary.
enum RunPlayRouteQualityBridgeError: Error, Equatable {
    case resourceLimit
    case invalidInputContract
    case invalidPolicy
    case engineContractViolation
}

/// Pure-Swift projection of one complete C++ route-quality geometry result.
struct RunPlayRouteQualityGeometryResult: Sendable {
    let routePoints: [RoutePoint]
    let discardedCoordinatePointCount: Int
    let inferredRouteGapCount: Int
    let distanceSource: RouteDistanceSource
    let distanceProvenance: RouteDistanceProvenance
}

/// Production adapter for combined route-quality stages 2–4.
///
/// Builds one shared native input buffer, an optional selection buffer, and one
/// Swift-owned output buffer, then invokes `process_route_quality_geometry`
/// exactly once. C++ retains no pointer and performs no callback. The public
/// step-distance boundary is not used on this production path.
enum RunPlayRouteQualityBridge {
    static func process(
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

        let summary = try RunPlayRouteInputBuffer.withNativeSamples(
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
        let summary = RunPlayRouteInputBuffer.withNativeSamples(orderedPoints) { input in
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
