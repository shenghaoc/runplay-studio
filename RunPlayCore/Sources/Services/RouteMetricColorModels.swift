import Foundation

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
        case .solid: return String(localized: "Solid")
        case .pace: return String(localized: "Pace")
        case .heartRate: return String(localized: "Heart Rate")
        case .correctedElevation: return String(localized: "Elevation")
        }
    }

    /// Explicit relative-scale wording for legends and accessibility.
    public var relativeScaleCaption: String {
        switch self {
        case .solid: return ""
        case .pace: return String(localized: "Relative pace within this workout")
        case .heartRate: return String(localized: "Relative heart rate within this workout")
        case .correctedElevation: return String(localized: "Corrected elevation within this workout")
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
