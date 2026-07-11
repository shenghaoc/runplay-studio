import Foundation


/// Pure computation for route segment metrics (pace, heart rate, elevation).
///
/// Platform-neutral — no AppKit/SwiftUI dependencies.
/// Color mapping stays in `RouteColoringService` (RunPlayPlatform).
public struct RouteColorMetrics: Sendable {

    public init() {}

    // MARK: - Pace

    /// Compute pace values for each segment, suitable for color mapping.
    ///
    /// Returns smoothed pace values in seconds per kilometer.
    /// Invalid values are replaced with the median.
    public func computeSegmentPace(points: [RouteScenePoint]) -> [Double] {
        guard points.count >= 2 else { return [] }

        var rawPace: [Double] = []

        for i in 0..<(points.count - 1) {
            let from = points[i]
            let to = points[i + 1]

            let distance = to.distanceFromStartMeters - from.distanceFromStartMeters
            let time = to.elapsedSeconds - from.elapsedSeconds

            if distance > 0 && time > 0 {
                // Pace in seconds per kilometer
                let pace = (time / distance) * 1000.0
                // Filter unreasonable values (faster than 2:00/km or slower than 20:00/km)
                if pace >= 120 && pace <= 1200 && pace.isFinite && !pace.isNaN {
                    rawPace.append(pace)
                } else {
                    rawPace.append(.nan) // Mark as invalid
                }
            } else {
                rawPace.append(.nan) // Zero distance or time
            }
        }

        // Smooth pace to reduce noise (moving average with window of 3-5)
        let smoothed = smoothValues(rawPace, windowSize: 5)

        // Replace remaining NaN with median
        let validPace = smoothed.filter { !$0.isNaN && $0.isFinite }
        let median = validPace.isEmpty ? 300.0 : medianOf(validPace) // Default 5:00/km

        return smoothed.map { $0.isNaN || !$0.isFinite ? median : $0 }
    }

    /// Compute the pace color scale (min, median, max) for legend display.
    public func computePaceScale(points: [RouteScenePoint]) -> PaceColorScale? {
        let paceValues = computeSegmentPace(points: points)
        guard !paceValues.isEmpty else { return nil }

        let sorted = paceValues.sorted()
        let count = sorted.count

        // Use 10th and 90th percentiles to avoid outliers
        let fastIdx = max(0, count / 10)
        let slowIdx = min(count - 1, count * 9 / 10)
        let medianIdx = count / 2

        return PaceColorScale(
            fastestPace: sorted[fastIdx],
            medianPace: sorted[medianIdx],
            slowestPace: sorted[slowIdx]
        )
    }

    // MARK: - Heart Rate

    /// Compute heart rate values for each segment.
    ///
    /// Returns smoothed HR values. Invalid values are replaced with the median.
    public func computeSegmentHeartRate(points: [RouteScenePoint]) -> [Double] {
        guard points.count >= 2 else { return [] }

        var rawHR: [Double] = []

        for i in 0..<(points.count - 1) {
            let from = points[i]
            let to = points[i + 1]

            // Average HR of the two points
            let hr1 = from.heartRateBPM
            let hr2 = to.heartRateBPM

            if let h1 = hr1, let h2 = hr2 {
                let avg = (h1 + h2) / 2
                // Filter unreasonable values
                if avg >= 40 && avg <= 230 && avg.isFinite && !avg.isNaN {
                    rawHR.append(avg)
                } else {
                    rawHR.append(.nan)
                }
            } else if let h = hr1 ?? hr2 {
                // One point has HR
                if h >= 40 && h <= 230 && h.isFinite && !h.isNaN {
                    rawHR.append(h)
                } else {
                    rawHR.append(.nan)
                }
            } else {
                rawHR.append(.nan) // No HR data
            }
        }

        // Smooth HR to reduce noise
        let smoothed = smoothValues(rawHR, windowSize: 5)

        // Replace remaining NaN with median (only if we have valid HR data)
        let validHR = smoothed.filter { !$0.isNaN && $0.isFinite }
        guard !validHR.isEmpty else {
            // No valid HR data at all - return NaN array (no coloring should happen)
            return smoothed
        }
        let median = medianOf(validHR)

        return smoothed.map { $0.isNaN || !$0.isFinite ? median : $0 }
    }

    /// Compute the heart rate color scale for legend display.
    public func computeHeartRateScale(points: [RouteScenePoint]) -> HeartRateColorScale? {
        let hrValues = computeSegmentHeartRate(points: points)
        guard !hrValues.isEmpty else { return nil }

        let validValues = hrValues.filter { $0.isFinite && $0 >= 40 && $0 <= 230 }
        guard validValues.count >= 2 else { return nil }

        let sorted = validValues.sorted()
        let count = sorted.count

        // Use 10th and 90th percentiles to avoid outliers
        let lowIdx = max(0, count / 10)
        let highIdx = min(count - 1, count * 9 / 10)
        let medianIdx = count / 2

        return HeartRateColorScale(
            lowHR: sorted[lowIdx],
            medianHR: sorted[medianIdx],
            highHR: sorted[highIdx]
        )
    }

    /// Check if points have usable heart rate data.
    public func hasHeartRateData(points: [RouteScenePoint]) -> Bool {
        let hrValues = points.compactMap { $0.heartRateBPM }
        let validCount = hrValues.filter { $0 >= 40 && $0 <= 230 && $0.isFinite }.count
        return validCount >= 2
    }

    // MARK: - Helpers

    /// Smooth an array of values using a moving average, skipping NaN.
    private func smoothValues(_ values: [Double], windowSize: Int) -> [Double] {
        guard values.count > 1 else { return values }
        let halfWindow = windowSize / 2
        var result: [Double] = []

        for i in 0..<values.count {
            let start = max(0, i - halfWindow)
            let end = min(values.count, i + halfWindow + 1)

            var sum: Double = 0
            var count: Int = 0
            for j in start..<end {
                if values[j].isFinite && !values[j].isNaN {
                    sum += values[j]
                    count += 1
                }
            }

            if count > 0 {
                result.append(sum / Double(count))
            } else {
                result.append(.nan)
            }
        }

        return result
    }

    /// Compute median of a non-empty array.
    public func medianOf(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            return sorted[count / 2]
        }
    }
}

// MARK: - Scale Types

/// Pace color scale for legend display (data only, no colors).
public struct PaceColorScale: Sendable {
    public let fastestPace: Double   // seconds per km
    public let medianPace: Double
    public let slowestPace: Double

    public var fastestFormatted: String { formatPace(fastestPace) }
    public var medianFormatted: String { formatPace(medianPace) }
    public var slowestFormatted: String { formatPace(slowestPace) }

    public init(fastestPace: Double, medianPace: Double, slowestPace: Double) {
        self.fastestPace = fastestPace
        self.medianPace = medianPace
        self.slowestPace = slowestPace
    }

    private func formatPace(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }
}

/// Heart rate color scale for legend display (data only, no colors).
public struct HeartRateColorScale: Sendable {
    public let lowHR: Double
    public let medianHR: Double
    public let highHR: Double

    public var lowFormatted: String { formatHR(lowHR) }
    public var medianFormatted: String { formatHR(medianHR) }
    public var highFormatted: String { formatHR(highHR) }

    public init(lowHR: Double, medianHR: Double, highHR: Double) {
        self.lowHR = lowHR
        self.medianHR = medianHR
        self.highHR = highHR
    }

    private func formatHR(_ bpm: Double) -> String {
        "\(Int(bpm)) bpm"
    }
}
