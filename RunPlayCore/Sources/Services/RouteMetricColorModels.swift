import Foundation

#if canImport(Darwin)
private func routeMetricLocalized(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}
#else
/// Swift Foundation on Linux does not currently expose `String(localized:)`.
/// Keep Core buildable there while Darwin presentation uses the localized key.
private func routeMetricLocalized(_ key: String) -> String {
    key
}
#endif

// MARK: - Mode

/// Native route-color presentation mode for a single workout map.
///
/// Values are relative to the selected workout only. Heart-rate mode is not a
/// training-zone or max-HR model.
public enum WorkoutRouteColorMode: String, CaseIterable, Codable, Hashable, Sendable {
    case solid
    case pace
    case heartRate
    case correctedElevation

    public var displayName: String {
        switch self {
        case .solid: return routeMetricLocalized("Solid")
        case .pace: return routeMetricLocalized("Pace")
        case .heartRate: return routeMetricLocalized("Heart Rate")
        case .correctedElevation: return routeMetricLocalized("Elevation")
        }
    }

    /// Explicit relative-scale wording for legends and accessibility.
    public var relativeScaleCaption: String {
        switch self {
        case .solid: return ""
        case .pace: return routeMetricLocalized("Relative pace within this workout")
        case .heartRate: return routeMetricLocalized("Relative heart rate within this workout")
        case .correctedElevation: return routeMetricLocalized("Corrected elevation within this workout")
        }
    }

    /// Concise explanation used when this metric cannot produce a reliable scale.
    public var unavailableReason: String? {
        switch self {
        case .solid:
            return nil
        case .pace:
            return routeMetricLocalized("Pace coloring needs more valid active distance and time in this workout.")
        case .heartRate:
            return routeMetricLocalized("Heart-rate coloring needs meaningful HR coverage in this workout.")
        case .correctedElevation:
            return routeMetricLocalized("Elevation coloring needs meaningful corrected elevation in this workout.")
        }
    }
}

// MARK: - Bucket tokens (palette-independent)

/// Palette-independent color token for a metric interval or map line.
///
/// Core never emits RGB, hex, `Color`, or `NSColor` values.
public enum RouteMetricColorBucket: Hashable, Sendable {
    case noData
    /// Zero-based level index in `0 ..< bucketCount`.
    case level(Int)
}

// MARK: - Scale

/// Direction of a relative metric scale for legend and normalization.
public enum RouteMetricScaleDirection: String, Hashable, Sendable {
    /// Lower raw values map toward normalized 0 (e.g. faster pace seconds).
    case lowerIsBetter
    /// Higher raw values map toward normalized 1 (HR, elevation).
    case higherIsMore
}

/// Distance-weighted scale bounds and labels for one workout metric mode.
public struct RouteMetricScale: Hashable, Sendable {
    public let lowerBound: Double
    public let median: Double
    public let upperBound: Double
    public let lowerLabel: String
    public let medianLabel: String
    public let upperLabel: String
    public let direction: RouteMetricScaleDirection

    public init(
        lowerBound: Double,
        median: Double,
        upperBound: Double,
        lowerLabel: String,
        medianLabel: String,
        upperLabel: String,
        direction: RouteMetricScaleDirection
    ) {
        self.lowerBound = lowerBound
        self.median = median
        self.upperBound = upperBound
        self.lowerLabel = lowerLabel
        self.medianLabel = medianLabel
        self.upperLabel = upperLabel
        self.direction = direction
    }
}

// MARK: - Interval

/// One adjacent same-segment pair of normalized route points with an optional metric.
public struct RouteMetricInterval: Hashable, Sendable {
    public let startPointIndex: Int
    public let endPointIndex: Int
    public let routeSegmentIndex: Int
    public let startDistanceMeters: Double
    public let endDistanceMeters: Double
    public let metricValue: Double?
    public let normalizedValue: Double?
    public let bucket: RouteMetricColorBucket

    public var distanceMeters: Double {
        max(0, endDistanceMeters - startDistanceMeters)
    }

    public init(
        startPointIndex: Int,
        endPointIndex: Int,
        routeSegmentIndex: Int,
        startDistanceMeters: Double,
        endDistanceMeters: Double,
        metricValue: Double?,
        normalizedValue: Double?,
        bucket: RouteMetricColorBucket
    ) {
        self.startPointIndex = startPointIndex
        self.endPointIndex = endPointIndex
        self.routeSegmentIndex = routeSegmentIndex
        self.startDistanceMeters = startDistanceMeters
        self.endDistanceMeters = endDistanceMeters
        self.metricValue = metricValue
        self.normalizedValue = normalizedValue
        self.bucket = bucket
    }
}

// MARK: - Diagnostics

/// Bounded diagnostics for profile construction (not user-facing copy).
public struct RouteMetricDiagnostics: Hashable, Sendable {
    public let intervalCount: Int
    public let validIntervalCount: Int
    public let noDataIntervalCount: Int
    public let validCoverageFraction: Double
    public let bucketCount: Int
    public let policyVersion: Int
    public let wasCancelled: Bool

    public init(
        intervalCount: Int,
        validIntervalCount: Int,
        noDataIntervalCount: Int,
        validCoverageFraction: Double,
        bucketCount: Int,
        policyVersion: Int,
        wasCancelled: Bool = false
    ) {
        self.intervalCount = intervalCount
        self.validIntervalCount = validIntervalCount
        self.noDataIntervalCount = noDataIntervalCount
        self.validCoverageFraction = validCoverageFraction
        self.bucketCount = bucketCount
        self.policyVersion = policyVersion
        self.wasCancelled = wasCancelled
    }
}

// MARK: - Profile

/// Canonical metric profile for native map coloring and legacy palette adapters.
public struct RouteMetricProfile: Hashable, Sendable {
    public let mode: WorkoutRouteColorMode
    public let intervals: [RouteMetricInterval]
    public let scale: RouteMetricScale?
    public let validCoverageDistanceMeters: Double
    public let totalRouteDistanceMeters: Double
    public let diagnostics: RouteMetricDiagnostics

    public var validCoverageFraction: Double {
        guard totalRouteDistanceMeters > 0 else { return 0 }
        return min(1, max(0, validCoverageDistanceMeters / totalRouteDistanceMeters))
    }

    public var hasMeaningfulScale: Bool { scale != nil }

    public init(
        mode: WorkoutRouteColorMode,
        intervals: [RouteMetricInterval],
        scale: RouteMetricScale?,
        validCoverageDistanceMeters: Double,
        totalRouteDistanceMeters: Double,
        diagnostics: RouteMetricDiagnostics
    ) {
        self.mode = mode
        self.intervals = intervals
        self.scale = scale
        self.validCoverageDistanceMeters = validCoverageDistanceMeters
        self.totalRouteDistanceMeters = totalRouteDistanceMeters
        self.diagnostics = diagnostics
    }
}

// MARK: - Availability

/// Mode availability for a workout without building a full colored line set.
public struct RouteMetricModeAvailability: Hashable, Sendable {
    public let solid: Bool
    public let pace: Bool
    public let heartRate: Bool
    public let correctedElevation: Bool
    public let heartRateCoverageFraction: Double
    public let elevationCoverageFraction: Double
    public let paceCoverageFraction: Double

    public init(
        solid: Bool = true,
        pace: Bool,
        heartRate: Bool,
        correctedElevation: Bool,
        heartRateCoverageFraction: Double = 0,
        elevationCoverageFraction: Double = 0,
        paceCoverageFraction: Double = 0
    ) {
        self.solid = solid
        self.pace = pace
        self.heartRate = heartRate
        self.correctedElevation = correctedElevation
        self.heartRateCoverageFraction = heartRateCoverageFraction
        self.elevationCoverageFraction = elevationCoverageFraction
        self.paceCoverageFraction = paceCoverageFraction
    }

    public func isAvailable(_ mode: WorkoutRouteColorMode) -> Bool {
        switch mode {
        case .solid: return solid
        case .pace: return pace
        case .heartRate: return heartRate
        case .correctedElevation: return correctedElevation
        }
    }
}

/// Availability plus the metric profiles computed by the same probe.
///
/// Keeping the profiles lets presentation code reuse the selected metric instead
/// of immediately rebuilding work the availability pass already completed.
public struct RouteMetricProfileProbe: Hashable, Sendable {
    public let availability: RouteMetricModeAvailability
    public let paceProfile: RouteMetricProfile
    public let heartRateProfile: RouteMetricProfile
    public let correctedElevationProfile: RouteMetricProfile

    public init(
        availability: RouteMetricModeAvailability,
        paceProfile: RouteMetricProfile,
        heartRateProfile: RouteMetricProfile,
        correctedElevationProfile: RouteMetricProfile
    ) {
        self.availability = availability
        self.paceProfile = paceProfile
        self.heartRateProfile = heartRateProfile
        self.correctedElevationProfile = correctedElevationProfile
    }

    public func profile(for mode: WorkoutRouteColorMode) -> RouteMetricProfile? {
        switch mode {
        case .solid: return nil
        case .pace: return paceProfile
        case .heartRate: return heartRateProfile
        case .correctedElevation: return correctedElevationProfile
        }
    }
}
