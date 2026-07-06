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

        let smoothed = movingAverage(validValues, windowSize: windowSize)

        // Rebuild array with smoothed values
        var result: [Double?] = Array(repeating: nil, count: points.count)
        for (idx, smoothedVal) in zip(validIndices, smoothed) {
            result[idx] = smoothedVal
        }

        return result
    }
}
