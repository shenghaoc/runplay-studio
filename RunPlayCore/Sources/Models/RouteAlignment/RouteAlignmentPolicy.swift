import Foundation

/// Central policy for route-aware alignment.
///
/// All thresholds live here so the algorithm and UI never scatter magic numbers.
/// Defaults are conservative product values, not scientific universal constants.
public struct RouteAlignmentPolicy: Hashable, Sendable {
    /// Preferred resampling interval along each continuous route segment.
    public var preferredSampleIntervalMeters: Double
    /// Hard cap on alignment samples per route after adaptive coarsening.
    public var maximumSamplesPerRoute: Int
    /// Minimum samples required on each route before DTW is attempted.
    public var minimumSamplesPerRoute: Int
    /// Minimum accepted matched aligned distance.
    public var minimumAlignedDistanceMeters: Double
    /// Normalized Sakoe–Chiba band width as a fraction of the longer sample count.
    public var bandWidthFraction: Double
    /// Absolute maximum unmatched prefix/suffix distance.
    public var maximumUnmatchedPrefixSuffixMeters: Double
    /// Fraction of route distance allowed as unmatched prefix/suffix.
    public var maximumUnmatchedPrefixSuffixFraction: Double
    /// Additive cost for a non-diagonal (warp) transition.
    public var nonDiagonalStepPenalty: Double
    /// Maximum consecutive horizontal or vertical warp steps.
    public var maximumConsecutiveWarpSteps: Int
    /// Spatial separation (metres) that maps to unit cost before bounding.
    public var spatialDistanceCostScaleMeters: Double
    /// Maximum contribution of the bounded spatial term.
    public var maximumSpatialCost: Double
    /// Weight applied to absolute heading difference in radians.
    public var headingPenaltyWeight: Double
    /// Weight applied to absolute normalized-progress difference.
    public var progressPenaltyWeight: Double
    /// Minimum coverage of each route required for availability.
    public var minimumCoverageFraction: Double
    /// Median spatial separation threshold for Excellent quality.
    public var excellentMedianSeparationMeters: Double
    /// Median spatial separation threshold for Good quality.
    public var goodMedianSeparationMeters: Double
    /// Median spatial separation threshold for Limited (acceptance ceiling).
    public var acceptableMedianSeparationMeters: Double
    /// 90th-percentile separation threshold for Excellent quality.
    public var excellentP90SeparationMeters: Double
    /// 90th-percentile separation threshold for Good quality.
    public var goodP90SeparationMeters: Double
    /// 90th-percentile separation threshold for acceptance.
    public var maximumAcceptedP90SeparationMeters: Double
    /// Minimum coverage for Excellent quality (per route).
    public var excellentCoverageFraction: Double
    /// Minimum coverage for Good quality (per route).
    public var goodCoverageFraction: Double
    /// Maximum allowed warp-step fraction of total steps for Excellent.
    public var excellentMaximumWarpFraction: Double
    /// Maximum allowed warp-step fraction of total steps for Good.
    public var goodMaximumWarpFraction: Double
    /// Maximum allowed warp-step fraction of total steps for acceptance.
    public var maximumAcceptedWarpFraction: Double
    /// Maximum supported projected extent from the shared origin (metres).
    public var maximumProjectedExtentMeters: Double
    /// Coarse samples used by the direction probe.
    public var directionProbeSampleCount: Int
    /// Reverse-to-forward cost ratio above which reverse is preferred.
    public var oppositeDirectionCostRatio: Double
    /// DTW cells between cooperative cancellation checks.
    public var cancellationStride: Int
    /// Hard cap on active band cells for one alignment attempt.
    public var maximumBandCells: Int
    /// Preferred chart sample interval along aligned progress.
    public var preferredChartSampleIntervalMeters: Double
    /// Maximum chart points retained after alignment.
    public var maximumChartSampleCount: Int
    /// Algorithm version included in cache keys and diagnostics.
    public var algorithmVersion: Int

    public init(
        preferredSampleIntervalMeters: Double = 20,
        maximumSamplesPerRoute: Int = 2_000,
        minimumSamplesPerRoute: Int = 20,
        minimumAlignedDistanceMeters: Double = 500,
        bandWidthFraction: Double = 0.15,
        maximumUnmatchedPrefixSuffixMeters: Double = 500,
        maximumUnmatchedPrefixSuffixFraction: Double = 0.10,
        nonDiagonalStepPenalty: Double = 0.35,
        maximumConsecutiveWarpSteps: Int = 6,
        spatialDistanceCostScaleMeters: Double = 50,
        maximumSpatialCost: Double = 8,
        headingPenaltyWeight: Double = 0.45,
        progressPenaltyWeight: Double = 1.5,
        minimumCoverageFraction: Double = 0.70,
        excellentMedianSeparationMeters: Double = 20,
        goodMedianSeparationMeters: Double = 35,
        acceptableMedianSeparationMeters: Double = 75,
        excellentP90SeparationMeters: Double = 50,
        goodP90SeparationMeters: Double = 100,
        maximumAcceptedP90SeparationMeters: Double = 200,
        excellentCoverageFraction: Double = 0.90,
        goodCoverageFraction: Double = 0.80,
        excellentMaximumWarpFraction: Double = 0.20,
        goodMaximumWarpFraction: Double = 0.35,
        maximumAcceptedWarpFraction: Double = 0.55,
        maximumProjectedExtentMeters: Double = 150_000,
        directionProbeSampleCount: Int = 32,
        oppositeDirectionCostRatio: Double = 0.85,
        cancellationStride: Int = 2_048,
        maximumBandCells: Int = 4_000_000,
        preferredChartSampleIntervalMeters: Double = 50,
        maximumChartSampleCount: Int = 2_000,
        algorithmVersion: Int = 1
    ) {
        self.preferredSampleIntervalMeters = preferredSampleIntervalMeters
        self.maximumSamplesPerRoute = maximumSamplesPerRoute
        self.minimumSamplesPerRoute = minimumSamplesPerRoute
        self.minimumAlignedDistanceMeters = minimumAlignedDistanceMeters
        self.bandWidthFraction = bandWidthFraction
        self.maximumUnmatchedPrefixSuffixMeters = maximumUnmatchedPrefixSuffixMeters
        self.maximumUnmatchedPrefixSuffixFraction = maximumUnmatchedPrefixSuffixFraction
        self.nonDiagonalStepPenalty = nonDiagonalStepPenalty
        self.maximumConsecutiveWarpSteps = maximumConsecutiveWarpSteps
        self.spatialDistanceCostScaleMeters = spatialDistanceCostScaleMeters
        self.maximumSpatialCost = maximumSpatialCost
        self.headingPenaltyWeight = headingPenaltyWeight
        self.progressPenaltyWeight = progressPenaltyWeight
        self.minimumCoverageFraction = minimumCoverageFraction
        self.excellentMedianSeparationMeters = excellentMedianSeparationMeters
        self.goodMedianSeparationMeters = goodMedianSeparationMeters
        self.acceptableMedianSeparationMeters = acceptableMedianSeparationMeters
        self.excellentP90SeparationMeters = excellentP90SeparationMeters
        self.goodP90SeparationMeters = goodP90SeparationMeters
        self.maximumAcceptedP90SeparationMeters = maximumAcceptedP90SeparationMeters
        self.excellentCoverageFraction = excellentCoverageFraction
        self.goodCoverageFraction = goodCoverageFraction
        self.excellentMaximumWarpFraction = excellentMaximumWarpFraction
        self.goodMaximumWarpFraction = goodMaximumWarpFraction
        self.maximumAcceptedWarpFraction = maximumAcceptedWarpFraction
        self.maximumProjectedExtentMeters = maximumProjectedExtentMeters
        self.directionProbeSampleCount = directionProbeSampleCount
        self.oppositeDirectionCostRatio = oppositeDirectionCostRatio
        self.cancellationStride = cancellationStride
        self.maximumBandCells = maximumBandCells
        self.preferredChartSampleIntervalMeters = preferredChartSampleIntervalMeters
        self.maximumChartSampleCount = maximumChartSampleCount
        self.algorithmVersion = algorithmVersion
    }

    /// Product defaults used by comparison UI and tests.
    public static let `default` = RouteAlignmentPolicy()

    /// Maximum unmatched prefix/suffix for a route of the given length.
    public func maximumUnmatchedDistance(forRouteDistance routeDistanceMeters: Double) -> Double {
        let finite = routeDistanceMeters.isFinite ? max(0, routeDistanceMeters) : 0
        let fractional = finite * maximumUnmatchedPrefixSuffixFraction
        return min(maximumUnmatchedPrefixSuffixMeters, fractional)
    }
}
