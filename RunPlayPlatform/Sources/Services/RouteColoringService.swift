import Foundation
import RunPlayCore
import AppKit


/// Route coloring mode for 3D visualization.
public enum RouteColorMode: String, CaseIterable, Identifiable {
    case singleColor = "Single"
    case pace = "Pace"
    case elevation = "Elevation"
    case heartRate = "Heart Rate"

    public var id: String { rawValue }
}

/// Computes colors for route segments based on metrics like pace.
///
/// Delegates pure computation to `RouteColorMetrics` (RunPlayCore).
/// Color mapping uses AppKit's `NSColor`.
public struct RouteColoringService {

    private let metrics = RouteColorMetrics()

    public init() {}

    /// Compute segment colors for the given route points and color mode.
    ///
    /// Returns an array of colors, one per segment (points.count - 1).
    /// Falls back to the default color if data is unavailable.
    public func computeSegmentColors(
        points: [RouteScenePoint],
        mode: RouteColorMode,
        elevationProfile: ElevationProfile? = nil,
        defaultColor: NSColor = .systemBlue
    ) -> [NSColor] {
        guard points.count >= 2 else { return [] }

        switch mode {
        case .singleColor:
            return Array(repeating: defaultColor, count: points.count - 1)
        case .pace:
            return computePaceColors(points: points, defaultColor: defaultColor)
        case .elevation:
            if let elevationProfile {
                return computeElevationColors(
                    points: points,
                    elevationProfile: elevationProfile,
                    defaultColor: defaultColor
                )
            }
            return computeElevationColors(points: points, defaultColor: defaultColor)
        case .heartRate:
            return computeHeartRateColors(points: points, defaultColor: defaultColor)
        }
    }

    // MARK: - Delegate to Core

    /// Compute pace values for each segment (delegates to RouteColorMetrics).
    public func computeSegmentPace(points: [RouteScenePoint]) -> [Double] {
        metrics.computeSegmentPace(points: points)
    }

    /// Compute the pace color scale (delegates to RouteColorMetrics).
    public func computePaceScale(points: [RouteScenePoint]) -> PaceColorScale? {
        metrics.computePaceScale(points: points)
    }

    /// Compute heart rate values for each segment (delegates to RouteColorMetrics).
    public func computeSegmentHeartRate(points: [RouteScenePoint]) -> [Double] {
        metrics.computeSegmentHeartRate(points: points)
    }

    /// Compute the heart rate color scale (delegates to RouteColorMetrics).
    public func computeHeartRateScale(points: [RouteScenePoint]) -> HeartRateColorScale? {
        metrics.computeHeartRateScale(points: points)
    }

    /// Check if points have usable heart rate data (delegates to RouteColorMetrics).
    public func hasHeartRateData(points: [RouteScenePoint]) -> Bool {
        metrics.hasHeartRateData(points: points)
    }
}

// MARK: - Private Color Computation

extension RouteColoringService {

    private func computePaceColors(points: [RouteScenePoint], defaultColor: NSColor) -> [NSColor] {
        let paceValues = metrics.computeSegmentPace(points: points)
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

    /// Compute elevation colors from corrected profile samples rather than
    /// projected Y coordinates. `RouteScenePoint.sourceIndex` preserves the
    /// association after invalid coordinates are filtered by projection.
    ///
    /// If the profile is not meaningful, is stale, or lacks either endpoint
    /// of a segment, that segment uses `defaultColor`; no synthetic elevation
    /// range is inferred from projected geometry.
    private func computeElevationColors(
        points: [RouteScenePoint],
        elevationProfile: ElevationProfile,
        defaultColor: NSColor
    ) -> [NSColor] {
        guard elevationProfile.hasMeaningfulElevation else {
            return Array(repeating: defaultColor, count: points.count - 1)
        }

        let elevations = points.map { point in
            correctedAltitude(for: point, elevationProfile: elevationProfile)
        }
        let finiteElevations = elevations.compactMap { $0 }
        guard let minElevation = finiteElevations.min(),
              let maxElevation = finiteElevations.max(),
              maxElevation > minElevation
        else {
            return Array(repeating: defaultColor, count: points.count - 1)
        }

        return points.indices.dropLast().map { index in
            guard points[index].routeSegmentIndex == points[index + 1].routeSegmentIndex,
                  let fromElevation = elevations[index],
                  let toElevation = elevations[index + 1]
            else {
                return defaultColor
            }
            let averageElevation = (fromElevation + toElevation) / 2
            let fraction = (averageElevation - minElevation) / (maxElevation - minElevation)
            return elevationToColor(fraction: fraction)
        }
    }

    private func correctedAltitude(
        for point: RouteScenePoint,
        elevationProfile: ElevationProfile
    ) -> Double? {
        let index = point.sourceIndex
        guard elevationProfile.samples.indices.contains(index) else { return nil }

        let sample = elevationProfile.samples[index]
        guard sample.routePointID == point.id,
              sample.distanceFromStartMeters == point.distanceFromStartMeters,
              sample.routeSegmentIndex == point.routeSegmentIndex,
              let altitude = sample.correctedAltitudeMeters,
              altitude.isFinite
        else {
            return nil
        }
        return altitude
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
        guard fraction.isFinite else { return .systemGreen }
        let t = max(0, min(1, fraction))
        // Green (0.33) to brown/orange (0.08)
        let hue = 0.33 - 0.25 * t
        return NSColor(hue: hue, saturation: 0.7, brightness: 0.8, alpha: 1.0)
    }

    // MARK: - Heart Rate Colors

    private func computeHeartRateColors(points: [RouteScenePoint], defaultColor: NSColor) -> [NSColor] {
        let hrValues = metrics.computeSegmentHeartRate(points: points)
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
