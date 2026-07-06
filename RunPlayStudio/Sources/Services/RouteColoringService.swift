import Foundation
import RunPlayCore
import AppKit
import RunPlayCore

/// Route coloring mode for 3D visualization.
enum RouteColorMode: String, CaseIterable, Identifiable {
    case singleColor = "Single"
    case pace = "Pace"
    case elevation = "Elevation"
    case heartRate = "Heart Rate"

    var id: String { rawValue }
}

/// Computes colors for route segments based on metrics like pace.
struct RouteColoringService {

    /// Compute segment colors for the given route points and color mode.
    ///
    /// Returns an array of colors, one per segment (points.count - 1).
    /// Falls back to the default color if data is unavailable.
    func computeSegmentColors(
        points: [RouteScenePoint],
        mode: RouteColorMode,
        defaultColor: NSColor = .systemBlue
    ) -> [NSColor] {
        guard points.count >= 2 else { return [] }

        switch mode {
        case .singleColor:
            return Array(repeating: defaultColor, count: points.count - 1)
        case .pace:
            return computePaceColors(points: points, defaultColor: defaultColor)
        case .elevation:
            return computeElevationColors(points: points, defaultColor: defaultColor)
        case .heartRate:
            return computeHeartRateColors(points: points, defaultColor: defaultColor)
        }
    }

    /// Compute pace values for each segment, suitable for color mapping.
    ///
    /// Returns smoothed pace values in seconds per kilometer.
    /// Invalid values are replaced with the median.
    func computeSegmentPace(points: [RouteScenePoint]) -> [Double] {
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
    func computePaceScale(points: [RouteScenePoint]) -> PaceColorScale? {
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
}

/// Pace color scale for legend display.
struct PaceColorScale {
    let fastestPace: Double   // seconds per km
    let medianPace: Double
    let slowestPace: Double

    var fastestFormatted: String { formatPace(fastestPace) }
    var medianFormatted: String { formatPace(medianPace) }
    var slowestFormatted: String { formatPace(slowestPace) }

    private func formatPace(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }
}

// MARK: - Private Color Computation

extension RouteColoringService {

    private func computePaceColors(points: [RouteScenePoint], defaultColor: NSColor) -> [NSColor] {
        let paceValues = computeSegmentPace(points: points)
        guard !paceValues.isEmpty else {
            return Array(repeating: defaultColor, count: points.count - 1)
        }

        // Compute scale from 10th to 90th percentile
        let sorted = paceValues.filter { $0.isFinite }.sorted()
        guard sorted.count >= 2 else {
            return Array(repeating: defaultColor, count: points.count - 1)
        }

        let fastBound = sorted[max(0, sorted.count / 10)]
        let slowBound = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]

        return paceValues.map { pace in
            paceToColor(pace: pace, fastBound: fastBound, slowBound: slowBound)
        }
    }

    private func computeElevationColors(points: [RouteScenePoint], defaultColor: NSColor) -> [NSColor] {
        let elevations = points.map { $0.yMeters }
        guard let minElev = elevations.min(), let maxElev = elevations.max(), maxElev > minElev else {
            return Array(repeating: defaultColor, count: points.count - 1)
        }

        var colors: [NSColor] = []
        for i in 0..<(points.count - 1) {
            let avgElev = (elevations[i] + elevations[i + 1]) / 2
            let fraction = (avgElev - minElev) / (maxElev - minElev)
            colors.append(elevationToColor(fraction: fraction))
        }
        return colors
    }

    /// Map pace to color: fast = blue/cyan, slow = red/yellow
    private func paceToColor(pace: Double, fastBound: Double, slowBound: Double) -> NSColor {
        guard pace.isFinite && !pace.isNaN else {
            return NSColor.systemBlue
        }

        // Clamp to bounds
        let clamped = max(fastBound, min(slowBound, pace))

        // Normalize: 0 = fastest (blue), 1 = slowest (red)
        let range = slowBound - fastBound
        guard range > 0 else { return NSColor.systemBlue }
        let t = (clamped - fastBound) / range

        // Color gradient: blue -> cyan -> green -> yellow -> red
        // Using HSV: hue goes from 0.6 (blue) to 0.0 (red)
        let hue = 0.6 * (1.0 - t) // 0.6=blue, 0.0=red
        let saturation = 0.8
        let brightness = 0.9

        return NSColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: 1.0
        )
    }

    /// Map elevation fraction to color: low = green, high = brown
    private func elevationToColor(fraction: Double) -> NSColor {
        let t = max(0, min(1, fraction))
        // Green (0.33) to brown/orange (0.08)
        let hue = 0.33 - 0.25 * t
        return NSColor(hue: hue, saturation: 0.7, brightness: 0.8, alpha: 1.0)
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
    private func medianOf(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        } else {
            return sorted[count / 2]
        }
    }

    // MARK: - Heart Rate

    /// Compute heart rate values for each segment.
    ///
    /// Returns smoothed HR values. Invalid values are replaced with the median.
    func computeSegmentHeartRate(points: [RouteScenePoint]) -> [Double] {
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

        // Replace remaining NaN with median
        let validHR = smoothed.filter { !$0.isNaN && $0.isFinite }
        let median = validHR.isEmpty ? 140.0 : medianOf(validHR) // Default 140 bpm

        return smoothed.map { $0.isNaN || !$0.isFinite ? median : $0 }
    }

    /// Compute the heart rate color scale for legend display.
    func computeHeartRateScale(points: [RouteScenePoint]) -> HeartRateColorScale? {
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
    func hasHeartRateData(points: [RouteScenePoint]) -> Bool {
        let hrValues = points.compactMap { $0.heartRateBPM }
        let validCount = hrValues.filter { $0 >= 40 && $0 <= 230 && $0.isFinite }.count
        return validCount >= 2
    }

    private func computeHeartRateColors(points: [RouteScenePoint], defaultColor: NSColor) -> [NSColor] {
        let hrValues = computeSegmentHeartRate(points: points)
        guard !hrValues.isEmpty else {
            return Array(repeating: defaultColor, count: points.count - 1)
        }

        // Compute scale from 10th to 90th percentile
        let sorted = hrValues.filter { $0.isFinite && $0 >= 40 && $0 <= 230 }.sorted()
        guard sorted.count >= 2 else {
            return Array(repeating: defaultColor, count: points.count - 1)
        }

        let lowBound = sorted[max(0, sorted.count / 10)]
        let highBound = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]

        return hrValues.map { hr in
            heartRateToColor(hr: hr, lowBound: lowBound, highBound: highBound)
        }
    }

    /// Map heart rate to color: low HR = blue/green, moderate = yellow/orange, high = red/purple
    private func heartRateToColor(hr: Double, lowBound: Double, highBound: Double) -> NSColor {
        guard hr.isFinite && !hr.isNaN else {
            return NSColor.systemGreen
        }

        // Clamp to bounds
        let clamped = max(lowBound, min(highBound, hr))

        // Normalize: 0 = low HR (blue/green), 1 = high HR (red/purple)
        let range = highBound - lowBound
        guard range > 0 else { return NSColor.systemGreen }
        let t = (clamped - lowBound) / range

        // Color gradient: blue -> cyan -> green -> yellow -> orange -> red
        // Using HSV: hue goes from 0.55 (blue-green) to 0.0 (red)
        let hue = 0.55 * (1.0 - t)
        let saturation = 0.8
        let brightness = 0.9

        return NSColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: 1.0
        )
    }
}

/// Heart rate color scale for legend display.
struct HeartRateColorScale {
    let lowHR: Double
    let medianHR: Double
    let highHR: Double

    var lowFormatted: String { formatHR(lowHR) }
    var medianFormatted: String { formatHR(medianHR) }
    var highFormatted: String { formatHR(highHR) }

    private func formatHR(_ bpm: Double) -> String {
        "\(Int(bpm)) bpm"
    }
}
