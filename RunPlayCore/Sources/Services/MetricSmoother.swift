import Foundation

/// Smooths noisy metrics like pace and heart rate.
public struct MetricSmoother {

    /// Apply simple moving average smoothing to an array of values.
    public static func movingAverage(_ values: [Double], windowSize: Int = 5) -> [Double] {
        guard values.count > 1 else { return values }
        let window = max(1, windowSize)
        var smoothed: [Double] = []

        for i in 0..<values.count {
            let start = max(0, i - window / 2)
            let end = min(values.count, i + window / 2 + 1)
            let slice = values[start..<end]
            let avg = slice.reduce(0, +) / Double(slice.count)
            smoothed.append(avg)
        }

        return smoothed
    }

    /// Smooth pace values from route points, handling nil values.
    /// Does not smooth across route segment boundaries.
    public static func smoothPace(from points: [RoutePoint], windowSize: Int = 5) -> [Double?] {
        let rawPace = points.map { $0.paceSecondsPerKilometer }

        // Separate valid values for smoothing
        var validIndices: [Int] = []
        var validValues: [Double] = []

        for (i, pace) in rawPace.enumerated() {
            if let p = pace, p > 0, p < 3600 { // Filter unreasonable values
                validIndices.append(i)
                validValues.append(p)
            }
        }

        // Smooth within segment boundaries only.
        let smoothed = movingAverageBySegment(
            validValues,
            indices: validIndices,
            points: points,
            windowSize: windowSize
        )

        // Rebuild array with smoothed values
        var result: [Double?] = Array(repeating: nil, count: points.count)
        for (idx, smoothedVal) in zip(validIndices, smoothed) {
            result[idx] = smoothedVal
        }

        return result
    }

    /// Smooth heart-rate values without compacting away route-point alignment.
    /// Does not smooth across route segment boundaries.
    public static func smoothHeartRate(from points: [RoutePoint], windowSize: Int = 5) -> [Double?] {
        let window = max(1, windowSize)
        let halfWindow = window / 2
        var result: [Double?] = Array(repeating: nil, count: points.count)

        for index in points.indices {
            guard let current = points[index].heartRateBPM,
                  MetricValidation.isValidHeartRate(current)
            else {
                continue
            }

            let segmentIndex = points[index].routeSegmentIndex

            let start = max(points.startIndex, index - halfWindow)
            let end = min(points.endIndex, index + halfWindow + 1)

            // ⚡ Bolt: Use an inline loop instead of .compactMap { ... }.reduce(0, +)
            // to avoid intermediate array allocations on every window slide (O(N)).
            var sum = 0.0
            var count = 0

            for j in start..<end {
                let point = points[j]
                // Don't smooth across segment boundaries.
                guard point.routeSegmentIndex == segmentIndex else { continue }
                guard let hr = point.heartRateBPM,
                      MetricValidation.isValidHeartRate(hr)
                else {
                    continue
                }
                sum += hr
                count += 1
            }

            guard count > 0 else { continue }
            result[index] = sum / Double(count)
        }

        return result
    }

    // MARK: - Segment-Aware Smoothing

    /// Moving average that only averages values within the same route segment.
    private static func movingAverageBySegment(
        _ values: [Double],
        indices: [Int],
        points: [RoutePoint],
        windowSize: Int
    ) -> [Double] {
        let window = max(1, windowSize)
        var smoothed: [Double] = []

        for (valueIdx, pointIdx) in indices.enumerated() {
            let segmentIndex = points[pointIdx].routeSegmentIndex
            let start = max(0, valueIdx - window / 2)
            let end = min(values.count, valueIdx + window / 2 + 1)

            // Only include values from the same segment.
            var sum = 0.0
            var count = 0
            for j in start..<end {
                if indices[j] < points.count, points[indices[j]].routeSegmentIndex == segmentIndex {
                    sum += values[j]
                    count += 1
                }
            }

            smoothed.append(count > 0 ? sum / Double(count) : values[valueIdx])
        }

        return smoothed
    }
}
