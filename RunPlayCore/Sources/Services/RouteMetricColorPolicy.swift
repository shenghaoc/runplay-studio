import Foundation

/// Central policy for native route metric coloring.
///
/// All thresholds live here so Core, Platform, and UI do not scatter magic numbers.
public struct RouteMetricColorPolicy: Hashable, Sendable {
    /// Bump when semantic defaults change in a way that should invalidate caches.
    public static let currentVersion = 1

    public let policyVersion: Int

    // MARK: Pace

    /// Valid active pace range in seconds per kilometre (2:00–20:00 /km).
    public let validPaceRangeSecondsPerKm: ClosedRange<Double>
    /// Distance-domain smoothing half-window for pace (metres each side).
    public let paceSmoothingHalfWindowMeters: Double

    // MARK: Heart rate

    /// Uses shared `MetricValidation` range by default.
    public let validHeartRateRange: ClosedRange<Double>
    /// Distance-domain smoothing half-window for HR (metres each side).
    public let heartRateSmoothingHalfWindowMeters: Double
    /// Maximum elapsed gap (seconds) allowing a single-endpoint HR sample to
    /// stand for the interval. Longer gaps remain no-data.
    public let maximumHeartRateEndpointGapSeconds: Double
    /// Minimum route-distance fraction of valid HR for the mode to be available.
    public let minimumHeartRateCoverageFraction: Double

    // MARK: Elevation

    /// Minimum route-distance fraction of corrected elevation for availability.
    public let minimumElevationCoverageFraction: Double
    /// Minimum absolute elevation span (metres) for a meaningful scale.
    public let minimumElevationSpanMeters: Double

    // MARK: Scale & buckets

    public let lowerQuantile: Double
    public let upperQuantile: Double
    public let bucketCount: Int
    /// Minimum valid-distance fraction of the route for a metric mode to enable.
    public let minimumValidCoverageFraction: Double
    /// Minimum number of valid weighted intervals for a scale.
    public let minimumValidIntervalCount: Int

    // MARK: Line rendering (consumed by Platform)

    public let maximumStyledLineCount: Int
    public let preferredMinimumColorRunDistanceMeters: Double
    /// Merge isolated single-interval bucket flicker when neighbours match.
    public let enableBucketHysteresis: Bool

    // MARK: Work control

    public let cancellationStride: Int

    public init(
        policyVersion: Int = RouteMetricColorPolicy.currentVersion,
        validPaceRangeSecondsPerKm: ClosedRange<Double> = 120...1200,
        paceSmoothingHalfWindowMeters: Double = 40,
        validHeartRateRange: ClosedRange<Double> = MetricValidation.validHeartRateRange,
        heartRateSmoothingHalfWindowMeters: Double = 40,
        /// Allows sparse GPS (tens of seconds) while still rejecting multi-minute holes.
        maximumHeartRateEndpointGapSeconds: Double = 45,
        minimumHeartRateCoverageFraction: Double = 0.08,
        minimumElevationCoverageFraction: Double = 0.08,
        minimumElevationSpanMeters: Double = 1.0,
        lowerQuantile: Double = 0.10,
        upperQuantile: Double = 0.90,
        bucketCount: Int = 7,
        minimumValidCoverageFraction: Double = 0.05,
        minimumValidIntervalCount: Int = 1,
        maximumStyledLineCount: Int = 1_000,
        preferredMinimumColorRunDistanceMeters: Double = 8,
        enableBucketHysteresis: Bool = true,
        cancellationStride: Int = 512
    ) {
        self.policyVersion = policyVersion
        self.validPaceRangeSecondsPerKm = validPaceRangeSecondsPerKm
        self.paceSmoothingHalfWindowMeters = paceSmoothingHalfWindowMeters
        self.validHeartRateRange = validHeartRateRange
        self.heartRateSmoothingHalfWindowMeters = heartRateSmoothingHalfWindowMeters
        self.maximumHeartRateEndpointGapSeconds = maximumHeartRateEndpointGapSeconds
        self.minimumHeartRateCoverageFraction = minimumHeartRateCoverageFraction
        self.minimumElevationCoverageFraction = minimumElevationCoverageFraction
        self.minimumElevationSpanMeters = minimumElevationSpanMeters
        self.lowerQuantile = lowerQuantile
        self.upperQuantile = upperQuantile
        self.bucketCount = max(2, bucketCount)
        self.minimumValidCoverageFraction = minimumValidCoverageFraction
        self.minimumValidIntervalCount = max(1, minimumValidIntervalCount)
        self.maximumStyledLineCount = max(1, maximumStyledLineCount)
        self.preferredMinimumColorRunDistanceMeters = max(0, preferredMinimumColorRunDistanceMeters)
        self.enableBucketHysteresis = enableBucketHysteresis
        self.cancellationStride = max(1, cancellationStride)
    }

    public static let runningDefault = RouteMetricColorPolicy()
}
