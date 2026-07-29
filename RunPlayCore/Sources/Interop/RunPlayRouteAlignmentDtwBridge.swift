import Foundation

// Keep imported C++ declarations confined to the internal Interop layer.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Transition that produced one matched path cell.
///
/// Raw values match the engine's `RouteAlignmentDtwStepKind` and the historical
/// Swift `StepKind` so diagnostics counting stays unchanged.
enum RunPlayRouteAlignmentDtwStepKind: UInt8, Equatable, Sendable {
    case diagonal = 0
    case primaryOnly = 1
    case comparisonOnly = 2
}

/// One matched sample pair on the reconstructed path, in forward order.
struct RunPlayRouteAlignmentDtwPathCell: Equatable, Sendable {
    let primaryIndex: Int
    let comparisonIndex: Int
    let step: RunPlayRouteAlignmentDtwStepKind
}

/// Pure-Swift projection of one complete constrained-DTW path solve.
enum RunPlayRouteAlignmentDtwResult: Equatable, Sendable {
    case success(
        path: [RunPlayRouteAlignmentDtwPathCell],
        bandRadius: Int,
        bandCellCount: Int,
        bestEndCost: Double
    )

    case resourceLimit
    case noPath
}

/// Errors raised by the constrained-DTW path bridge.
enum RunPlayRouteAlignmentDtwBridgeError: Error, Equatable {
    case invalidPolicy
    case invalidInputContract
    case allocationFailure
    case engineContractViolation
}

/// Production bridge for the bounded band-packed constrained-DTW path solve.
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
enum RunPlayRouteAlignmentDtwBridge {
    static func solve(
        primary: [RouteAlignmentSample],
        comparison: [RouteAlignmentSample],
        primaryRouteDistanceMeters: Double,
        comparisonRouteDistanceMeters: Double,
        effectiveSampleIntervalMeters: Double,
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayRouteAlignmentDtwResult {
        guard !primary.isEmpty, !comparison.isEmpty else {
            throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        }

        let stride = max(1, policy.cancellationStride)

        let nativePrimary = try makeCostSamples(primary, stride: stride, isCancelled: isCancelled)
        let nativeComparison = try makeCostSamples(comparison, stride: stride, isCancelled: isCancelled)

        // A valid DTW path never exceeds n + m + 1 cells, so production never
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

        var outputBuffer = ContiguousArray<runplay.RouteAlignmentDtwPathCell>(
            repeating: runplay.RouteAlignmentDtwPathCell(),
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
