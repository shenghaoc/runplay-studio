import Foundation

/// Route metric aggregates shared by every recorded-lap query.
///
/// Prefix sums provide O(1) range averages. The segment tree provides O(log n)
/// maximum-heart-rate queries without rescanning route points for each lap.
struct RecordedLapMetricIndex: Sendable {
    private let pointCount: Int
    private let heartRateSums: [Double]
    private let heartRateCounts: [Int]
    private let cadenceSums: [Double]
    private let cadenceCounts: [Int]
    private let maximumHeartRateTree: [Double]
    private let maximumHeartRateLeafOffset: Int

    init(
        routePoints: [RoutePoint],
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws {
        pointCount = routePoints.count
        let checkStride = max(1, cancellationCheckStride)

        var leafOffset = 1
        while leafOffset < routePoints.count {
            leafOffset *= 2
        }
        maximumHeartRateLeafOffset = leafOffset

        var hrSums = Array(repeating: 0.0, count: routePoints.count + 1)
        var hrCounts = Array(repeating: 0, count: routePoints.count + 1)
        var cadenceSums = Array(repeating: 0.0, count: routePoints.count + 1)
        var cadenceCounts = Array(repeating: 0, count: routePoints.count + 1)
        var maximumTree = Array(repeating: -Double.infinity, count: leafOffset * 2)

        for index in routePoints.indices {
            if index % checkStride == 0, isCancelled() {
                throw CancellationError()
            }

            hrSums[index + 1] = hrSums[index]
            hrCounts[index + 1] = hrCounts[index]
            cadenceSums[index + 1] = cadenceSums[index]
            cadenceCounts[index + 1] = cadenceCounts[index]

            let point = routePoints[index]
            if let heartRate = point.heartRateBPM,
               MetricValidation.isValidHeartRate(heartRate) {
                hrSums[index + 1] += heartRate
                hrCounts[index + 1] += 1
                maximumTree[leafOffset + index] = heartRate
            }
            if let cadence = point.cadence,
               MetricValidation.isValidCadence(cadence) {
                cadenceSums[index + 1] += cadence
                cadenceCounts[index + 1] += 1
            }
        }

        if leafOffset > 1 {
            for node in stride(from: leafOffset - 1, through: 1, by: -1) {
                if node % checkStride == 0, isCancelled() {
                    throw CancellationError()
                }
                maximumTree[node] = max(maximumTree[node * 2], maximumTree[node * 2 + 1])
            }
        }

        heartRateSums = hrSums
        heartRateCounts = hrCounts
        self.cadenceSums = cadenceSums
        self.cadenceCounts = cadenceCounts
        maximumHeartRateTree = maximumTree
    }

    func heartRateStatistics(in sourceRange: Range<Int>) -> (average: Double?, maximum: Double?) {
        let range = clamped(sourceRange)
        guard !range.isEmpty else { return (nil, nil) }

        let count = heartRateCounts[range.upperBound] - heartRateCounts[range.lowerBound]
        guard count > 0 else { return (nil, nil) }
        let sum = heartRateSums[range.upperBound] - heartRateSums[range.lowerBound]
        let maximum = maximumHeartRate(in: range)
        return (sum / Double(count), maximum)
    }

    func averageCadence(in sourceRange: Range<Int>) -> Double? {
        let range = clamped(sourceRange)
        guard !range.isEmpty else { return nil }

        let count = cadenceCounts[range.upperBound] - cadenceCounts[range.lowerBound]
        guard count > 0 else { return nil }
        let sum = cadenceSums[range.upperBound] - cadenceSums[range.lowerBound]
        return sum / Double(count)
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        let lower = min(max(0, range.lowerBound), pointCount)
        let upper = min(max(lower, range.upperBound), pointCount)
        return lower..<upper
    }

    private func maximumHeartRate(in range: Range<Int>) -> Double? {
        var lower = range.lowerBound + maximumHeartRateLeafOffset
        var upper = range.upperBound + maximumHeartRateLeafOffset
        var maximum = -Double.infinity

        while lower < upper {
            if !lower.isMultiple(of: 2) {
                maximum = max(maximum, maximumHeartRateTree[lower])
                lower += 1
            }
            if !upper.isMultiple(of: 2) {
                upper -= 1
                maximum = max(maximum, maximumHeartRateTree[upper])
            }
            lower /= 2
            upper /= 2
        }

        return maximum.isFinite ? maximum : nil
    }
}
