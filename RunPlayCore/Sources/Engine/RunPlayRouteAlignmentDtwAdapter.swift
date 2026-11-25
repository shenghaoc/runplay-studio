internal import RunPlayEngine

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

/// Core diagnostic categories for the constrained-DTW path solve.
enum RunPlayRouteAlignmentDtwBridgeError: Error, Equatable {
    case invalidPolicy
    case invalidInputContract
    case allocationFailure
    case engineContractViolation
}

/// Maps Core-owned policy and samples to one synchronous engine solve.
/// Cancellation, output checks, and diagnostics remain Core-owned.
enum RunPlayRouteAlignmentDtwAdapter {
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
        let enginePrimary = try makeCostSamples(primary, stride: stride, isCancelled: isCancelled)
        let engineComparison = try makeCostSamples(comparison, stride: stride, isCancelled: isCancelled)
        let (sum, sumOverflow) = primary.count.addingReportingOverflow(comparison.count)
        let (pathBound, boundOverflow) = sum.addingReportingOverflow(1)
        guard !sumOverflow, !boundOverflow, pathBound > 0 else {
            throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        }
        if isCancelled() { throw CancellationError() }

        var enginePolicy = RouteAlignmentDtwPolicy()
        enginePolicy.bandWidthFraction = policy.bandWidthFraction
        enginePolicy.maximumUnmatchedPrefixSuffixMeters = policy.maximumUnmatchedPrefixSuffixMeters
        enginePolicy.maximumUnmatchedPrefixSuffixFraction = policy.maximumUnmatchedPrefixSuffixFraction
        enginePolicy.nonDiagonalStepPenalty = policy.nonDiagonalStepPenalty
        enginePolicy.maximumConsecutiveWarpSteps = UInt64(max(0, policy.maximumConsecutiveWarpSteps))
        enginePolicy.spatialDistanceCostScaleMeters = policy.spatialDistanceCostScaleMeters
        enginePolicy.maximumSpatialCost = policy.maximumSpatialCost
        enginePolicy.headingPenaltyWeight = policy.headingPenaltyWeight
        enginePolicy.progressPenaltyWeight = policy.progressPenaltyWeight
        enginePolicy.maximumBandCells = UInt64(max(0, policy.maximumBandCells))

        let solved: RouteAlignmentDtwPath
        NativeCallObserver.record(.routeAlignmentDtw)
        do {
            solved = try RouteAlignmentDtw.solve(
                primary: enginePrimary.span,
                comparison: engineComparison.span,
                primaryRouteDistanceMeters: primaryRouteDistanceMeters,
                comparisonRouteDistanceMeters: comparisonRouteDistanceMeters,
                effectiveSampleIntervalMeters: effectiveSampleIntervalMeters,
                policy: enginePolicy
            )
        } catch {
            // Cancellation wins over every kernel outcome, as with the C++ call.
            if isCancelled() { throw CancellationError() }
            switch error {
            case .resourceLimit: return .resourceLimit
            case .noPath: return .noPath
            case .invalidPolicy: throw RunPlayRouteAlignmentDtwBridgeError.invalidPolicy
            case .invalidInputContract: throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
            case .internalFailure: throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
            }
        }

        if isCancelled() { throw CancellationError() }
        guard !solved.cells.isEmpty, solved.cells.count <= pathBound else {
            throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
        }

        var path: [RunPlayRouteAlignmentDtwPathCell] = []
        path.reserveCapacity(solved.cells.count)
        for (index, cell) in solved.cells.enumerated() {
            if index % stride == 0, isCancelled() { throw CancellationError() }
            guard cell.primaryIndex >= 0, cell.primaryIndex < primary.count,
                  cell.comparisonIndex >= 0, cell.comparisonIndex < comparison.count
            else { throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation }

            let step: RunPlayRouteAlignmentDtwStepKind
            switch cell.step {
            case .diagonal: step = .diagonal
            case .primaryOnly: step = .primaryOnly
            case .comparisonOnly: step = .comparisonOnly
            }

            if let previous = path.last {
                let di = cell.primaryIndex - previous.primaryIndex
                let dj = cell.comparisonIndex - previous.comparisonIndex
                let consistent: Bool
                switch step {
                case .diagonal: consistent = di == 1 && dj == 1
                case .primaryOnly: consistent = di == 1 && dj == 0
                case .comparisonOnly: consistent = di == 0 && dj == 1
                }
                guard consistent else { throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation }
            }
            path.append(RunPlayRouteAlignmentDtwPathCell(
                primaryIndex: cell.primaryIndex, comparisonIndex: cell.comparisonIndex, step: step
            ))
        }
        return .success(
            path: path, bandRadius: solved.bandRadius, bandCellCount: solved.bandCellCount, bestEndCost: solved.bestEndCost
        )
    }

    private static func makeCostSamples(
        _ samples: [RouteAlignmentSample], stride: Int, isCancelled: @Sendable () -> Bool
    ) throws -> [RouteAlignmentDtwSample] {
        var result: [RouteAlignmentDtwSample] = []
        result.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            if index % stride == 0, isCancelled() { throw CancellationError() }
            result.append(RouteAlignmentDtwSample(
                xMeters: sample.xMeters, zMeters: sample.zMeters, normalizedProgress: sample.normalizedProgress,
                headingRadians: sample.headingRadians ?? 0, hasHeading: sample.headingRadians == nil ? 0 : 1
            ))
        }
        return result
    }
}
