import Foundation
import AppKit
import RunPlayCore

/// Explicit sequential palette stops for native route metric coloring.
///
/// Platform owns NSColor tokens for SceneKit adapters. SwiftUI maps the same
/// hex stops in Studio. Heatmap intensity colors are intentionally separate.
public enum RouteMetricPalette: Sendable {
    public static let policyBucketCount = RouteMetricColorPolicy.runningDefault.bucketCount

    /// Neutral no-data style — visible but unobtrusive on light/dark basemaps.
    public static let noDataHex: UInt = 0x8E8E93
    public static let noDataOpacity: Double = 0.72

    // Pace: cyan/blue (fast) → violet → orange (slow). Avoids red/green opposition.
    public static let paceHexStops: [UInt] = [
        0x00C7BE, // teal-cyan — fastest
        0x0A84FF, // blue
        0x5E5CE6, // indigo
        0xBF5AF2, // violet — mid
        0xFF9F0A, // orange
        0xFF6B00, // deep orange
        0xFF453A, // warm red-orange — slowest
    ]

    // Heart rate: blue (low) → violet → magenta/red (high relative effort).
    public static let heartRateHexStops: [UInt] = [
        0x64D2FF, // light blue — lower
        0x0A84FF, // blue
        0x5E5CE6, // indigo
        0xBF5AF2, // violet — mid
        0xFF375F, // pink-red
        0xFF2D55, // magenta-red
        0xFF453A, // alert red — higher
    ]

    // Elevation: teal/blue (low) → violet → warm brown/orange (high).
    public static let elevationHexStops: [UInt] = [
        0x30B0C7, // teal — lower
        0x40C8E0, // light teal
        0x5E5CE6, // indigo
        0xBF5AF2, // violet — mid
        0xAC8E68, // warm tan
        0xC9956B, // sand
        0xD4780A, // warm brown-orange — higher
    ]

    public static func hexStops(for mode: WorkoutRouteColorMode) -> [UInt] {
        switch mode {
        case .solid:
            return [0x0A84FF]
        case .pace:
            return paceHexStops
        case .heartRate:
            return heartRateHexStops
        case .correctedElevation:
            return elevationHexStops
        }
    }

    public static func nsColor(
        mode: WorkoutRouteColorMode,
        bucket: RouteMetricColorBucket
    ) -> NSColor {
        switch bucket {
        case .noData:
            return nsColor(hex: noDataHex, alpha: noDataOpacity)
        case .level(let index):
            let stops = hexStops(for: mode)
            guard !stops.isEmpty else {
                return nsColor(hex: 0x0A84FF, alpha: 1)
            }
            let clamped = min(max(0, index), stops.count - 1)
            return nsColor(hex: stops[clamped], alpha: 1)
        }
    }

    public static func nsColor(hex: UInt, alpha: Double = 1) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: CGFloat(min(1, max(0, alpha))))
    }
}
