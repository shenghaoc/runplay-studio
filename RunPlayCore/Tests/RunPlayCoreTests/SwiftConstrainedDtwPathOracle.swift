import Foundation
@testable import RunPlayCore

/// Transition that produced one oracle path cell.
enum SwiftConstrainedDtwStepKind: UInt8, Equatable, Sendable {
    case diagonal = 0
    case primaryOnly = 1
    case comparisonOnly = 2
}

/// One matched sample pair on the oracle's reconstructed path, in forward order.
struct SwiftConstrainedDtwPathCell: Equatable, Sendable {
    let primaryIndex: Int
    let comparisonIndex: Int
    let step: SwiftConstrainedDtwStepKind
}

/// Outcome of one oracle path solve.
enum SwiftConstrainedDtwPathResult: Equatable, Sendable {
    case success(
        path: [SwiftConstrainedDtwPathCell],
        bandRadius: Int,
        bandCellCount: Int,
        bestEndCost: Double
    )

    case resourceLimit
    case noPath
}

/// Independent Swift reference for the constrained-DTW path solve.
///
/// This is the pre-migration `ConstrainedDynamicTimeWarpingAligner` dynamic
/// programming, band packing, endpoint selection, and path reconstruction,
/// transcribed verbatim into the test target and made self-contained.
///
/// It deliberately calls nothing shared with the migrated implementation: not
/// `RunPlayRouteAlignmentDtwBridge`, not the production aligner, and not
/// `RouteAlignmentPolicy.maximumUnmatchedDistance`. Every formula it needs is
/// reproduced locally so parity failures cannot be masked by a common helper.
///
/// Cancellation and the `cellsVisited` stride counter are omitted because they
/// never influenced the produced path.
enum SwiftConstrainedDtwPathOracle {
    static func solve(
        primary: [RouteAlignmentSample],
        comparison: [RouteAlignmentSample],
        primaryRouteDistanceMeters: Double,
        comparisonRouteDistanceMeters: Double,
        effectiveSampleIntervalMeters: Double,
        policy: RouteAlignmentPolicy
    ) -> SwiftConstrainedDtwPathResult {
        let n = primary.count
        let m = comparison.count
        guard n > 0, m > 0 else { return .noPath }

        let bandRadius = max(
            1,
            Int(ceil(Double(max(n, m)) * policy.bandWidthFraction)),
            maxPrefixSuffixSamples(
                primaryDistance: primaryRouteDistanceMeters,
                comparisonDistance: comparisonRouteDistanceMeters,
                interval: effectiveSampleIntervalMeters,
                policy: policy
            )
        )

        // Estimated cells inside the band.
        let estimatedCells = n * (2 * bandRadius + 1)
        if estimatedCells > policy.maximumBandCells {
            return .resourceLimit
        }

        let infinity = Double.greatestFiniteMagnitude / 4

        // Band-packed storage: for each i, columns [jStart...jEnd].
        var rowStarts = [Int](repeating: 0, count: n)
        var rowEnds = [Int](repeating: -1, count: n)
        var offsets = [Int](repeating: 0, count: n)
        var totalCells = 0
        for i in 0..<n {
            let center = Int((Double(i) / Double(max(n - 1, 1))) * Double(max(m - 1, 1)))
            let jStart = max(0, center - bandRadius)
            let jEnd = min(m - 1, center + bandRadius)
            // Also expand near ends for open begin/end.
            let open = maxPrefixSuffixSamples(
                primaryDistance: primaryRouteDistanceMeters,
                comparisonDistance: comparisonRouteDistanceMeters,
                interval: effectiveSampleIntervalMeters,
                policy: policy
            )
            let expandedStart = i < open ? 0 : jStart
            let expandedEnd = i >= n - open ? m - 1 : jEnd
            let start = min(expandedStart, jStart)
            let end = max(expandedEnd, jEnd)
            rowStarts[i] = start
            rowEnds[i] = end
            offsets[i] = totalCells
            totalCells += max(0, end - start + 1)
        }
        if totalCells > policy.maximumBandCells {
            return .resourceLimit
        }

        var costs = [Double](repeating: infinity, count: totalCells)
        var steps = [UInt8](repeating: 255, count: totalCells)
        var warpRuns = [UInt8](repeating: 0, count: totalCells)

        func index(_ i: Int, _ j: Int) -> Int? {
            guard i >= 0, i < n, j >= rowStarts[i], j <= rowEnds[i] else { return nil }
            return offsets[i] + (j - rowStarts[i])
        }

        func pointCostAt(i: Int, j: Int) -> Double {
            pointCost(primary: primary[i], comparison: comparison[j], policy: policy)
        }

        // Seed (0, j) open beginning for comparison prefix.
        let openPrimary = maxPrefixSuffixSamples(
            primaryDistance: primaryRouteDistanceMeters,
            comparisonDistance: comparisonRouteDistanceMeters,
            interval: effectiveSampleIntervalMeters,
            policy: policy
        )
        for j in rowStarts[0]...rowEnds[0] {
            guard let idx = index(0, j) else { continue }
            if j == 0 {
                costs[idx] = pointCostAt(i: 0, j: 0)
                steps[idx] = SwiftConstrainedDtwStepKind.diagonal.rawValue
                warpRuns[idx] = 0
            } else if j <= openPrimary {
                // Allow free-ish prefix on comparison.
                let prev = index(0, j - 1).map { costs[$0] } ?? infinity
                costs[idx] = prev + pointCostAt(i: 0, j: j) + policy.nonDiagonalStepPenalty * 0.25
                steps[idx] = SwiftConstrainedDtwStepKind.comparisonOnly.rawValue
                warpRuns[idx] = UInt8(min(255, Int(warpRuns[index(0, j - 1) ?? idx]) + 1))
            }
        }
        // Seed (i, 0) open beginning for primary prefix.
        for i in 1..<n where rowStarts[i] == 0 {
            guard let idx = index(i, 0), let prevIdx = index(i - 1, 0) else { continue }
            if i <= openPrimary {
                costs[idx] = costs[prevIdx] + pointCostAt(i: i, j: 0) + policy.nonDiagonalStepPenalty * 0.25
                steps[idx] = SwiftConstrainedDtwStepKind.primaryOnly.rawValue
                warpRuns[idx] = UInt8(min(255, Int(warpRuns[prevIdx]) + 1))
            }
        }

        for i in 1..<n {
            let jLo = rowStarts[i]
            let jHi = rowEnds[i]
            guard jLo <= jHi else { continue }
            for j in jLo...jHi {
                if j == 0 { continue }
                guard let idx = index(i, j) else { continue }
                let pc = pointCostAt(i: i, j: j)
                var best = infinity
                var bestStep = SwiftConstrainedDtwStepKind.diagonal
                var bestWarp: UInt8 = 0

                // Diagonal
                if let dIdx = index(i - 1, j - 1), costs[dIdx] < infinity {
                    let candidate = costs[dIdx] + pc
                    if candidate < best {
                        best = candidate
                        bestStep = .diagonal
                        bestWarp = 0
                    }
                }
                // Primary only (vertical in matrix if i is rows)
                if let pIdx = index(i - 1, j), costs[pIdx] < infinity {
                    let run = Int(warpRuns[pIdx]) + 1
                    if run <= policy.maximumConsecutiveWarpSteps {
                        let candidate = costs[pIdx] + pc + policy.nonDiagonalStepPenalty
                        if candidate < best {
                            best = candidate
                            bestStep = .primaryOnly
                            bestWarp = UInt8(min(255, run))
                        }
                    }
                }
                // Comparison only
                if let cIdx = index(i, j - 1), costs[cIdx] < infinity {
                    let run = Int(warpRuns[cIdx]) + 1
                    if run <= policy.maximumConsecutiveWarpSteps {
                        let candidate = costs[cIdx] + pc + policy.nonDiagonalStepPenalty
                        if candidate < best {
                            best = candidate
                            bestStep = .comparisonOnly
                            bestWarp = UInt8(min(255, run))
                        }
                    }
                }
                costs[idx] = best
                steps[idx] = bestStep.rawValue
                warpRuns[idx] = bestWarp
            }
        }

        // Choose best endpoint allowing open suffix.
        var bestEndI = n - 1
        var bestEndJ = m - 1
        var bestEndCost = infinity
        let openSuffix = openPrimary
        for i in max(0, n - 1 - openSuffix)..<n {
            for j in max(0, m - 1 - openSuffix)..<m {
                guard let idx = index(i, j), costs[idx] < bestEndCost else { continue }
                bestEndCost = costs[idx]
                bestEndI = i
                bestEndJ = j
            }
        }
        guard bestEndCost < infinity, index(bestEndI, bestEndJ) != nil else {
            return .noPath
        }

        // Reconstruct path.
        var path: [SwiftConstrainedDtwPathCell] = []
        path.reserveCapacity(n + m)
        var ci = bestEndI
        var cj = bestEndJ
        var guardCounter = 0
        while true {
            guardCounter += 1
            if guardCounter > n + m + 8 { break }
            guard let idx = index(ci, cj), steps[idx] != 255 else { break }
            let step = SwiftConstrainedDtwStepKind(rawValue: steps[idx]) ?? .diagonal
            path.append(SwiftConstrainedDtwPathCell(primaryIndex: ci, comparisonIndex: cj, step: step))
            if ci == 0 && cj == 0 { break }
            switch step {
            case .diagonal:
                ci = max(0, ci - 1)
                cj = max(0, cj - 1)
            case .primaryOnly:
                if ci == 0 { break }
                ci -= 1
            case .comparisonOnly:
                if cj == 0 { break }
                cj -= 1
            }
            if ci == 0 && cj == 0 {
                path.append(SwiftConstrainedDtwPathCell(primaryIndex: 0, comparisonIndex: 0, step: .diagonal))
                break
            }
        }
        path.reverse()

        guard !path.isEmpty else { return .noPath }

        return .success(
            path: path,
            bandRadius: bandRadius,
            bandCellCount: totalCells,
            bestEndCost: bestEndCost
        )
    }

    // MARK: - Local copies of the migrated formulas

    /// Local copy of `RouteAlignmentPolicy.maximumUnmatchedDistance(forRouteDistance:)`.
    private static func maximumUnmatchedDistance(
        forRouteDistance routeDistanceMeters: Double,
        policy: RouteAlignmentPolicy
    ) -> Double {
        let finite = routeDistanceMeters.isFinite ? max(0, routeDistanceMeters) : 0
        let fractional = finite * policy.maximumUnmatchedPrefixSuffixFraction
        return min(policy.maximumUnmatchedPrefixSuffixMeters, fractional)
    }

    /// Local copy of the pre-migration `maxPrefixSuffixSamples`.
    private static func maxPrefixSuffixSamples(
        primaryDistance: Double,
        comparisonDistance: Double,
        interval: Double,
        policy: RouteAlignmentPolicy
    ) -> Int {
        let maxMeters = max(
            maximumUnmatchedDistance(forRouteDistance: primaryDistance, policy: policy),
            maximumUnmatchedDistance(forRouteDistance: comparisonDistance, policy: policy)
        )
        let step = max(interval, 1)
        // Floor so the sample window cannot exceed the metre-based policy once
        // multiplied back by the effective interval (ceil would overshoot).
        return max(1, Int(floor(maxMeters / step)))
    }

    /// Local copy of the pre-migration `pointCost`.
    static func pointCost(
        primary: RouteAlignmentSample,
        comparison: RouteAlignmentSample,
        policy: RouteAlignmentPolicy
    ) -> Double {
        let dx = primary.xMeters - comparison.xMeters
        let dz = primary.zMeters - comparison.zMeters
        let separation = (dx * dx + dz * dz).squareRoot()
        let scale = max(policy.spatialDistanceCostScaleMeters, 1)
        // Bounded spatial cost dominates.
        let spatial = min(policy.maximumSpatialCost, separation / scale)

        var headingTerm = 0.0
        if let h1 = primary.headingRadians, let h2 = comparison.headingRadians {
            var delta = abs(h1 - h2)
            if delta > .pi { delta = 2 * .pi - delta }
            // 0...π → 0...1
            headingTerm = (delta / .pi) * policy.headingPenaltyWeight
        }

        let progressDelta = abs(primary.normalizedProgress - comparison.normalizedProgress)
        let progressTerm = progressDelta * policy.progressPenaltyWeight

        let total = spatial + headingTerm + progressTerm
        return total.isFinite ? total : policy.maximumSpatialCost
    }
}
