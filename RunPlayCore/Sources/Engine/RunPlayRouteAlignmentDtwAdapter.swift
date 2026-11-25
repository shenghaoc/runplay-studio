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
    private static func engineDtwPolicy(_ policy: RouteAlignmentPolicy) -> RouteAlignmentDtwPolicy {
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
        return enginePolicy
    }

    /// The Core outcome of a kernel error: a resource limit and no path are
    /// results; every other error is thrown.
    private static func outcome(for error: RouteAlignmentDtwError) throws -> RunPlayRouteAlignmentDtwResult {
        switch error {
        case .resourceLimit: return .resourceLimit
        case .noPath: return .noPath
        case .invalidPolicy: throw RunPlayRouteAlignmentDtwBridgeError.invalidPolicy
        case .invalidInputContract: throw RunPlayRouteAlignmentDtwBridgeError.invalidInputContract
        case .internalFailure: throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
        }
    }

    /// The engine path as Core cells. Every index is in range and every step
    /// moves by exactly what its kind says.
    private static func translatedPath(
        _ cells: [RouteAlignmentDtwCell], primaryCount: Int, comparisonCount: Int,
        stride: Int, isCancelled: @Sendable () -> Bool
    ) throws -> [RunPlayRouteAlignmentDtwPathCell] {
        var path: [RunPlayRouteAlignmentDtwPathCell] = []
        path.reserveCapacity(cells.count)
        for (index, cell) in cells.enumerated() {
            if index % stride == 0, isCancelled() { throw CancellationError() }
            guard cell.primaryIndex >= 0, cell.primaryIndex < primaryCount,
                  cell.comparisonIndex >= 0, cell.comparisonIndex < comparisonCount
            else { throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation }

            let step = stepKind(cell.step)

            if let previous = path.last {
                let di = cell.primaryIndex - previous.primaryIndex
                let dj = cell.comparisonIndex - previous.comparisonIndex
                guard isConsistent(step, di: di, dj: dj) else {
                    throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
                }
            }
            path.append(RunPlayRouteAlignmentDtwPathCell(
                primaryIndex: cell.primaryIndex, comparisonIndex: cell.comparisonIndex, step: step
            ))
        }
        return path
    }

    private static func stepKind(_ step: RouteAlignmentDtwStep) -> RunPlayRouteAlignmentDtwStepKind {
        switch step {
        case .diagonal: .diagonal
        case .primaryOnly: .primaryOnly
        case .comparisonOnly: .comparisonOnly
        }
    }

    /// Whether a step moves one primary sample, one comparison sample, or
    /// one of each, as its kind says.
    private static func isConsistent(_ step: RunPlayRouteAlignmentDtwStepKind, di: Int, dj: Int) -> Bool {
        switch step {
        case .diagonal: di == 1 && dj == 1
        case .primaryOnly: di == 1 && dj == 0
        case .comparisonOnly: di == 0 && dj == 1
        }
    }

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

        let enginePolicy = engineDtwPolicy(policy)

        let solved: RouteAlignmentDtwPath
        EngineCallObserver.record(.routeAlignmentDtw)
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
            // Cancellation wins over every kernel outcome, as it did with the former C++ call.
            if isCancelled() { throw CancellationError() }
            return try outcome(for: error)
        }

        if isCancelled() { throw CancellationError() }
        guard !solved.cells.isEmpty, solved.cells.count <= pathBound else {
            throw RunPlayRouteAlignmentDtwBridgeError.engineContractViolation
        }

        let path = try translatedPath(
            solved.cells, primaryCount: primary.count, comparisonCount: comparison.count,
            stride: stride, isCancelled: isCancelled
        )
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
