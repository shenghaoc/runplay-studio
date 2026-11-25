/// The status failures DTW can report with borrowed input spans and owned output.
package enum RouteAlignmentDtwError: Error, Equatable {
    case invalidPolicy
    case invalidInputContract
    case resourceLimit
    case noPath
    case internalFailure
}

/// Projected route point consumed by the geometry-only cost function.
package struct RouteAlignmentDtwSample: Sendable {
    package var xMeters: Double
    package var zMeters: Double
    package var normalizedProgress: Double
    package var headingRadians: Double
    package var hasHeading: UInt8

    package init(
        xMeters: Double = 0, zMeters: Double = 0, normalizedProgress: Double = 0,
        headingRadians: Double = 0, hasHeading: UInt8 = 0
    ) {
        self.xMeters = xMeters
        self.zMeters = zMeters
        self.normalizedProgress = normalizedProgress
        self.headingRadians = headingRadians
        self.hasHeading = hasHeading
    }
}

package struct RouteAlignmentDtwPolicy: Sendable {
    package var bandWidthFraction: Double = 0
    package var maximumUnmatchedPrefixSuffixMeters: Double = 0
    package var maximumUnmatchedPrefixSuffixFraction: Double = 0
    package var nonDiagonalStepPenalty: Double = 0
    package var maximumConsecutiveWarpSteps: UInt64 = 0
    package var spatialDistanceCostScaleMeters: Double = 0
    package var maximumSpatialCost: Double = 0
    package var headingPenaltyWeight: Double = 0
    package var progressPenaltyWeight: Double = 0
    package var maximumBandCells: UInt64 = 0

    package init() {}

    fileprivate var isFinite: Bool {
        bandWidthFraction.isFinite
            && maximumUnmatchedPrefixSuffixMeters.isFinite
            && maximumUnmatchedPrefixSuffixFraction.isFinite
            && nonDiagonalStepPenalty.isFinite
            && spatialDistanceCostScaleMeters.isFinite
            && maximumSpatialCost.isFinite
            && headingPenaltyWeight.isFinite
            && progressPenaltyWeight.isFinite
    }
}

package enum RouteAlignmentDtwStep: UInt8, Sendable {
    case diagonal = 0
    case primaryOnly = 1
    case comparisonOnly = 2
}

package struct RouteAlignmentDtwCell: Equatable, Sendable {
    package let primaryIndex: Int
    package let comparisonIndex: Int
    package let step: RouteAlignmentDtwStep

    package init(primaryIndex: Int, comparisonIndex: Int, step: RouteAlignmentDtwStep) {
        self.primaryIndex = primaryIndex
        self.comparisonIndex = comparisonIndex
        self.step = step
    }
}

package struct RouteAlignmentDtwPath: Sendable {
    package let cells: [RouteAlignmentDtwCell]
    package let bandRadius: Int
    package let bandCellCount: Int
    package let bestEndCost: Double
}

/// Literal port of RouteAlignmentDtw.cpp. All floating-point operations stay
/// in source order, including each term of the point cost and transition cost.
package enum RouteAlignmentDtw {
    private static let unreachable = Double.greatestFiniteMagnitude / 4
    private static let unset = UInt8.max

    private struct Row {
        let start: Int
        let end: Int
        let offset: Int

        @inline(__always)
        func index(_ column: Int) -> Int {
            column >= start && column <= end ? offset + (column - start) : -1
        }
    }

    private static func saturatingInt(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        // Double(Int.max) rounds up to 2^63; the conversion below must
        // exclude that value, while -2^63 is exactly representable.
        if value >= Double(Int.max) { return .max }
        if value <= Double(Int.min) { return .min }
        return Int(value)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs < 0 ? .min : .max) : sum
    }

    private static func saturatingSubtract(_ lhs: Int, _ rhs: Int) -> Int {
        let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? (rhs > 0 ? .min : .max) : difference
    }

    private static func unmatchedDistance(_ distance: Double, _ policy: RouteAlignmentDtwPolicy) -> Double {
        let finite = distance.isFinite ? max(0, distance) : 0
        let fractional = finite * policy.maximumUnmatchedPrefixSuffixFraction
        return cppMin(policy.maximumUnmatchedPrefixSuffixMeters, fractional)
    }

    // std::min returns its first argument when neither operand compares less
    // (including NaN). Swift's generic min does not promise NaN behaviour.
    @inline(__always)
    private static func cppMin(_ lhs: Double, _ rhs: Double) -> Double {
        rhs < lhs ? rhs : lhs
    }

    @inline(__always)
    private static func pointCost(
        _ primary: RouteAlignmentDtwSample,
        _ comparison: RouteAlignmentDtwSample,
        _ policy: RouteAlignmentDtwPolicy,
        spatialScale: Double
    ) -> Double {
        let dx = primary.xMeters - comparison.xMeters
        let dz = primary.zMeters - comparison.zMeters
        let dxSquared = dx * dx
        let dzSquared = dz * dz
        let sumOfSquares = dxSquared + dzSquared
        let separation = sumOfSquares.squareRoot()
        let scaledSeparation = separation / spatialScale
        let spatial = cppMin(policy.maximumSpatialCost, scaledSeparation)

        var headingTerm = 0.0
        if primary.hasHeading != 0 && comparison.hasHeading != 0 {
            let difference = primary.headingRadians - comparison.headingRadians
            var delta = abs(difference)
            if delta > Double.pi {
                let fullTurn = 2 * Double.pi
                delta = fullTurn - delta
            }
            let normalizedDelta = delta / Double.pi
            headingTerm = normalizedDelta * policy.headingPenaltyWeight
        }

        let progressDifference = primary.normalizedProgress - comparison.normalizedProgress
        let progressDelta = abs(progressDifference)
        let progressTerm = progressDelta * policy.progressPenaltyWeight
        let spatialAndHeading = spatial + headingTerm
        let total = spatialAndHeading + progressTerm
        return total.isFinite ? total : policy.maximumSpatialCost
    }

    private static func satisfiesContract(_ samples: borrowing Span<RouteAlignmentDtwSample>) -> Bool {
        for i in samples.indices {
            let sample = samples[i]
            guard sample.xMeters.isFinite, sample.zMeters.isFinite,
                  sample.normalizedProgress.isFinite,
                  sample.normalizedProgress >= 0, sample.normalizedProgress <= 1,
                  sample.hasHeading <= 1,
                  sample.hasHeading == 0 || sample.headingRadians.isFinite
            else { return false }
        }
        return true
    }

    package static func solve(
        primary: borrowing Span<RouteAlignmentDtwSample>,
        comparison: borrowing Span<RouteAlignmentDtwSample>,
        primaryRouteDistanceMeters: Double,
        comparisonRouteDistanceMeters: Double,
        effectiveSampleIntervalMeters: Double,
        policy: RouteAlignmentDtwPolicy
    ) throws(RouteAlignmentDtwError) -> RouteAlignmentDtwPath {
        let n = primary.count
        let m = comparison.count
        guard n > 0, m > 0 else { throw .invalidInputContract }
        guard policy.isFinite else { throw .invalidPolicy }

        let (count, countOverflow) = n.addingReportingOverflow(m)
        let (pathBound, pathBoundOverflow) = count.addingReportingOverflow(1)
        guard !countOverflow, !pathBoundOverflow,
              primaryRouteDistanceMeters.isFinite, primaryRouteDistanceMeters > 0,
              comparisonRouteDistanceMeters.isFinite, comparisonRouteDistanceMeters > 0,
              effectiveSampleIntervalMeters.isFinite, effectiveSampleIntervalMeters > 0,
              satisfiesContract(primary), satisfiesContract(comparison)
        else { throw .invalidInputContract }

        let primaryMaximum = unmatchedDistance(primaryRouteDistanceMeters, policy)
        let comparisonMaximum = unmatchedDistance(comparisonRouteDistanceMeters, policy)
        let maximumMeters = max(primaryMaximum, comparisonMaximum)
        let step = max(effectiveSampleIntervalMeters, 1)
        let quotient = maximumMeters / step
        let openSamples = max(1, saturatingInt(quotient.rounded(.down)))
        let longerCount = Double(max(n, m))
        let rawRadius = longerCount * policy.bandWidthFraction
        let fractionalRadius = saturatingInt(rawRadius.rounded(.up))
        let bandRadius = max(max(1, fractionalRadius), openSamples)

        // Budget gate one: the conservative rectangular estimate happens
        // before allocating even the packed row layout.
        let (doubledRadius, radiusOverflow) = bandRadius.multipliedReportingOverflow(by: 2)
        let (bandWidth, widthOverflow) = doubledRadius.addingReportingOverflow(1)
        let (estimated, estimateOverflow) = n.multipliedReportingOverflow(by: bandWidth)
        guard !radiusOverflow, !widthOverflow, !estimateOverflow,
              UInt64(estimated) <= policy.maximumBandCells
        else { throw .resourceLimit }

        var rows: [Row] = []
        rows.reserveCapacity(n)
        let primarySpan = max(n - 1, 1)
        let comparisonSpan = max(m - 1, 1)
        let suffixThreshold = saturatingSubtract(n, openSamples)
        var total = 0
        for i in 0..<n {
            let rowPosition = Double(i)
            let normalizedRow = rowPosition / Double(primarySpan)
            let projectedColumn = normalizedRow * Double(comparisonSpan)
            let center = saturatingInt(projectedColumn)
            let start = max(0, saturatingSubtract(center, bandRadius))
            let end = min(m - 1, saturatingAdd(center, bandRadius))
            let expandedStart = i < openSamples ? 0 : start
            let expandedEnd = i >= suffixThreshold ? m - 1 : end
            let actualStart = min(expandedStart, start)
            let actualEnd = max(expandedEnd, end)
            rows.append(Row(start: actualStart, end: actualEnd, offset: total))
            // Nonnegative column bounds are at most m - 1; their
            // difference plus one fits in Int, even for an empty row.
            let cells = max(0, (actualEnd - actualStart) + 1)
            let (next, overflow) = total.addingReportingOverflow(cells)
            guard !overflow else { throw .resourceLimit }
            total = next
        }
        // Gate two must use the actual packed count: open ends can make it
        // exceed the rectangular estimate.
        guard UInt64(total) <= policy.maximumBandCells else { throw .resourceLimit }

        var costs = [Double](repeating: unreachable, count: total)
        var steps = [UInt8](repeating: unset, count: total)
        var warpRuns = [UInt8](repeating: 0, count: total)
        let spatialScale = max(policy.spatialDistanceCostScaleMeters, 1)
        let quarterPenalty = policy.nonDiagonalStepPenalty * 0.25

        let first = rows[0]
        // Only the origin and the open prefix seed row zero. Later cells keep
        // the same unreachable sentinel (and unset step) as in C++.
        let firstPrimary = primary[0]
        costs[0] = pointCost(firstPrimary, comparison[0], policy, spatialScale: spatialScale)
        steps[0] = RouteAlignmentDtwStep.diagonal.rawValue
        let comparisonPrefix = min(first.end, openSamples)
        if comparisonPrefix > 0 {
            for j in 1...comparisonPrefix {
                let partial = costs[j - 1] + pointCost(firstPrimary, comparison[j], policy, spatialScale: spatialScale)
                costs[j] = partial + quarterPenalty
                steps[j] = RouteAlignmentDtwStep.comparisonOnly.rawValue
                warpRuns[j] = UInt8(clamping: Int(warpRuns[j - 1]) + 1)
            }
        }

        // Primary prefix seeds column zero before any regular transition.
        for i in 1..<n {
            let row = rows[i]
            guard row.start == 0, row.end >= 0, i <= openSamples else { continue }
            let previous = rows[i - 1].index(0)
            guard previous >= 0 else { continue }
            let partial = costs[previous] + pointCost(primary[i], comparison[0], policy, spatialScale: spatialScale)
            costs[row.offset] = partial + quarterPenalty
            steps[row.offset] = RouteAlignmentDtwStep.primaryOnly.rawValue
            warpRuns[row.offset] = UInt8(clamping: Int(warpRuns[previous]) + 1)
        }

        // The same ascending row/column visits, priority, and strict less-than
        // replacements as the C++ loop. Row offsets are loaded once per row.
        for i in 1..<n {
            let row = rows[i]
            let above = rows[i - 1]
            let start = max(1, row.start)
            guard start <= row.end else { continue }
            let primarySample = primary[i]
            for j in start...row.end {
                let cell = row.offset + (j - row.start)
                let stepCost = pointCost(primarySample, comparison[j], policy, spatialScale: spatialScale)
                var best = unreachable
                var bestStep = RouteAlignmentDtwStep.diagonal.rawValue
                var bestWarp: UInt8 = 0

                let diagonal = above.index(j - 1)
                if diagonal >= 0, costs[diagonal] < unreachable {
                    let candidate = costs[diagonal] + stepCost
                    if candidate < best {
                        best = candidate
                    }
                }

                let vertical = above.index(j)
                if vertical >= 0, costs[vertical] < unreachable {
                    let run = Int(warpRuns[vertical]) + 1
                    if UInt64(run) <= policy.maximumConsecutiveWarpSteps {
                        let partial = costs[vertical] + stepCost
                        let candidate = partial + policy.nonDiagonalStepPenalty
                        if candidate < best {
                            best = candidate
                            bestStep = RouteAlignmentDtwStep.primaryOnly.rawValue
                            bestWarp = UInt8(clamping: run)
                        }
                    }
                }

                if j > row.start, costs[cell - 1] < unreachable {
                    let run = Int(warpRuns[cell - 1]) + 1
                    if UInt64(run) <= policy.maximumConsecutiveWarpSteps {
                        let partial = costs[cell - 1] + stepCost
                        let candidate = partial + policy.nonDiagonalStepPenalty
                        if candidate < best {
                            best = candidate
                            bestStep = RouteAlignmentDtwStep.comparisonOnly.rawValue
                            bestWarp = UInt8(clamping: run)
                        }
                    }
                }

                costs[cell] = best
                steps[cell] = bestStep
                warpRuns[cell] = bestWarp
            }
        }

        var endPrimary = n - 1
        var endComparison = m - 1
        var endCost = unreachable
        let primaryFrom = max(0, saturatingSubtract(n - 1, openSamples))
        let comparisonFrom = max(0, saturatingSubtract(m - 1, openSamples))
        for i in primaryFrom..<n {
            let row = rows[i]
            let start = max(comparisonFrom, row.start)
            guard start <= row.end else { continue }
            // Skip columns the original packed-index check would reject,
            // preserving both the candidates and their tie order.
            for j in start...row.end {
                let candidate = costs[row.offset + (j - row.start)]
                if candidate < endCost {
                    endCost = candidate
                    endPrimary = i
                    endComparison = j
                }
            }
        }

        guard endCost < unreachable, rows[endPrimary].index(endComparison) >= 0 else { throw .noPath }
        let path = try reconstruct(
            rows: rows, steps: steps, primary: endPrimary, comparison: endComparison, pathBound: pathBound
        )
        return RouteAlignmentDtwPath(cells: path, bandRadius: bandRadius, bandCellCount: total, bestEndCost: endCost)
    }

    private static func reconstruct(
        rows: [Row], steps: [UInt8], primary: Int, comparison: Int, pathBound: Int
    ) throws(RouteAlignmentDtwError) -> [RouteAlignmentDtwCell] {
        var i = primary
        var j = comparison
        // The C++ guard is pathBound + 7. Each step strictly reduces i + j,
        // so a correct path reaches the origin (or an unset cell) before
        // pathBound; never initialize beyond that proven upper bound.
        var invalidStep = false
        // SAFETY: initialize the next unwritten element only, after checking
        // initializedCount < capacity. Return the exact valid prefix; the
        // buffer cannot escape the initializer.
        var result = unsafe [RouteAlignmentDtwCell](unsafeUninitializedCapacity: pathBound) {
            buffer, initializedCount in
            while initializedCount < pathBound {
                let index = rows[i].index(j)
                if index < 0 || steps[index] == unset { break }
                guard let step = RouteAlignmentDtwStep(rawValue: steps[index]) else {
                    invalidStep = true
                    break
                }
                unsafe buffer.initializeElement(
                    at: initializedCount,
                    to: RouteAlignmentDtwCell(primaryIndex: i, comparisonIndex: j, step: step)
                )
                initializedCount += 1
                if i == 0 && j == 0 { break }

                switch step {
                case .diagonal:
                    i = max(0, i - 1)
                    j = max(0, j - 1)
                case .primaryOnly:
                    if i == 0 { invalidStep = true } else { i -= 1 }
                case .comparisonOnly:
                    if j == 0 { invalidStep = true } else { j -= 1 }
                }
                if invalidStep { break }
                // The origin is always seeded with the diagonal step; the
                // next iteration emits exactly the cell C++ appends here.
            }
        }
        guard !invalidStep else { throw .internalFailure }
        guard !result.isEmpty else { throw .noPath }
        result.reverse()
        return result
    }
}
