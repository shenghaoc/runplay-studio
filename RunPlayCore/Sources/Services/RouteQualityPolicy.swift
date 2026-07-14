import Foundation

/// Central policy for deterministic, local route-quality processing.
///
/// The defaults deliberately favour retaining legitimate running data. A point
/// is never rejected only because one adjacent speed is high.
public struct RouteQualityPolicy: Hashable, Sendable {
    /// 43.2 km/h. Used as evidence for GPS discontinuities, not as a sole test.
    public var maximumPlausibleRunningSpeedMetersPerSecond: Double
    /// 54 km/h. Source speeds above this are discarded so geometry can derive a replacement.
    public var maximumSourceSpeedMetersPerSecond: Double
    /// A zero source speed is treated as stale when normalized movement exceeds this value.
    public var sourceZeroSpeedMovementThresholdMetersPerSecond: Double
    /// Positive source speed above this value is stale while normalized distance is stationary.
    public var maximumStationarySourceSpeedMetersPerSecond: Double
    /// Larger disagreement with normalized distance invalidates a source speed.
    public var maximumSourceSpeedGeometryDisagreementRatio: Double
    /// Accuracy worse than this supports rejection when neighbouring accuracy is better.
    public var maximumUsefulHorizontalAccuracyMeters: Double
    /// Minimum excess path length needed before an interior point can be a teleport.
    public var coordinateSpikeMinimumExcessDistanceMeters: Double
    /// Required ratio between the two-leg path through a candidate and the direct bridge.
    public var coordinateSpikeMinimumDistortionRatio: Double
    /// Poor accuracy can lower the excess-distance requirement, but never proves rejection.
    public var poorAccuracyEvidenceMultiplier: Double
    /// Minimum disconnected jump considered for an inferred recording boundary.
    public var implicitGapMinimumDistanceMeters: Double
    /// A long time gap supports a geographic discontinuity only when the jump is also large.
    public var implicitGapMinimumTimeIntervalSeconds: Double
    /// Long-gap evidence must exceed the resumed sampling cadence by this ratio.
    public var implicitGapMinimumTimeDiscontinuityRatio: Double
    /// Number of mutually coherent points required after a suspected relocation.
    public var relocatedClusterConfirmationPointCount: Int
    /// Maximum geographic step used only when relocated-cluster timing is unusable.
    public var relocatedClusterMaximumStepMeters: Double
    /// Absolute tolerance used to infer whether a legacy distance series was device supplied.
    public var legacyDistanceInferenceAbsoluteToleranceMeters: Double
    /// Geometry-relative tolerance used for the same legacy inference.
    public var legacyDistanceInferenceRelativeTolerance: Double
    /// Broad physical Earth range, preserving below-sea-level activity.
    public var plausibleAltitudeRangeMeters: ClosedRange<Double>
    /// Minimum isolated vertical deviation considered an altitude spike.
    public var altitudeSpikeMinimumDeviationMeters: Double
    /// Larger deviation required to reject a short multi-sample excursion.
    public var altitudeShortExcursionMinimumDeviationMeters: Double
    /// Maximum consecutive samples eligible for short-excursion rejection.
    public var altitudeShortExcursionMaximumSampleCount: Int
    /// Neighbouring altitude samples must agree this closely before rejecting the middle sample.
    public var altitudeSpikeMaximumNeighborDifferenceMeters: Double
    /// Isolated and short-excursion rejection is limited to a short horizontal neighbourhood.
    public var altitudeSpikeMaximumHorizontalSpanMeters: Double
    /// Radius of the centred distance-domain elevation smoother (30 m full window).
    public var elevationSmoothingRadiusMeters: Double
    /// Shorter runs retain sanitized source values but do not claim gain/loss analysis.
    public var minimumReliableAltitudeSampleCount: Int
    /// Trend reversal required before gain/loss changes direction.
    public var elevationGainLossDeadbandMeters: Double
    /// Fraction of total distance used for notable climb/descent windows.
    public var elevationHighlightWindowRouteFraction: Double
    /// Minimum notable climb/descent window distance.
    public var elevationHighlightMinimumWindowMeters: Double
    /// Maximum notable climb/descent window distance.
    public var elevationHighlightMaximumWindowMeters: Double
    /// Minimum distance step between notable elevation window evaluations.
    public var elevationHighlightMinimumStepMeters: Double
    /// Preferred number of evaluation steps per notable elevation window.
    public var elevationHighlightStepsPerWindow: Int
    /// Long loops check cooperative cancellation at this stride.
    public var cancellationCheckStride: Int

    public init(
        maximumPlausibleRunningSpeedMetersPerSecond: Double = 12,
        maximumSourceSpeedMetersPerSecond: Double = 15,
        sourceZeroSpeedMovementThresholdMetersPerSecond: Double = 1,
        maximumStationarySourceSpeedMetersPerSecond: Double = 1,
        maximumSourceSpeedGeometryDisagreementRatio: Double = 4,
        maximumUsefulHorizontalAccuracyMeters: Double = 100,
        coordinateSpikeMinimumExcessDistanceMeters: Double = 200,
        coordinateSpikeMinimumDistortionRatio: Double = 3,
        poorAccuracyEvidenceMultiplier: Double = 0.5,
        implicitGapMinimumDistanceMeters: Double = 200,
        implicitGapMinimumTimeIntervalSeconds: Double = 120,
        implicitGapMinimumTimeDiscontinuityRatio: Double = 3,
        relocatedClusterConfirmationPointCount: Int = 3,
        relocatedClusterMaximumStepMeters: Double = 200,
        legacyDistanceInferenceAbsoluteToleranceMeters: Double = 20,
        legacyDistanceInferenceRelativeTolerance: Double = 0.05,
        plausibleAltitudeRangeMeters: ClosedRange<Double> = -500...9_000,
        altitudeSpikeMinimumDeviationMeters: Double = 35,
        altitudeShortExcursionMinimumDeviationMeters: Double = 100,
        altitudeShortExcursionMaximumSampleCount: Int = 2,
        altitudeSpikeMaximumNeighborDifferenceMeters: Double = 12,
        altitudeSpikeMaximumHorizontalSpanMeters: Double = 150,
        elevationSmoothingRadiusMeters: Double = 15,
        minimumReliableAltitudeSampleCount: Int = 2,
        elevationGainLossDeadbandMeters: Double = 3,
        elevationHighlightWindowRouteFraction: Double = 0.2,
        elevationHighlightMinimumWindowMeters: Double = 100,
        elevationHighlightMaximumWindowMeters: Double = 1_000,
        elevationHighlightMinimumStepMeters: Double = 25,
        elevationHighlightStepsPerWindow: Int = 10,
        cancellationCheckStride: Int = 2_048
    ) {
        self.maximumPlausibleRunningSpeedMetersPerSecond = max(0, maximumPlausibleRunningSpeedMetersPerSecond)
        self.maximumSourceSpeedMetersPerSecond = max(0, maximumSourceSpeedMetersPerSecond)
        self.sourceZeroSpeedMovementThresholdMetersPerSecond = max(
            0,
            sourceZeroSpeedMovementThresholdMetersPerSecond
        )
        self.maximumStationarySourceSpeedMetersPerSecond = max(
            0,
            maximumStationarySourceSpeedMetersPerSecond
        )
        self.maximumSourceSpeedGeometryDisagreementRatio = max(1, maximumSourceSpeedGeometryDisagreementRatio)
        self.maximumUsefulHorizontalAccuracyMeters = max(0, maximumUsefulHorizontalAccuracyMeters)
        self.coordinateSpikeMinimumExcessDistanceMeters = max(0, coordinateSpikeMinimumExcessDistanceMeters)
        self.coordinateSpikeMinimumDistortionRatio = max(1, coordinateSpikeMinimumDistortionRatio)
        self.poorAccuracyEvidenceMultiplier = min(1, max(0, poorAccuracyEvidenceMultiplier))
        self.implicitGapMinimumDistanceMeters = max(0, implicitGapMinimumDistanceMeters)
        self.implicitGapMinimumTimeIntervalSeconds = max(0, implicitGapMinimumTimeIntervalSeconds)
        self.implicitGapMinimumTimeDiscontinuityRatio = max(
            1,
            implicitGapMinimumTimeDiscontinuityRatio
        )
        self.relocatedClusterConfirmationPointCount = max(2, relocatedClusterConfirmationPointCount)
        self.relocatedClusterMaximumStepMeters = max(0, relocatedClusterMaximumStepMeters)
        self.legacyDistanceInferenceAbsoluteToleranceMeters = max(
            0,
            legacyDistanceInferenceAbsoluteToleranceMeters
        )
        self.legacyDistanceInferenceRelativeTolerance = max(
            0,
            legacyDistanceInferenceRelativeTolerance
        )
        self.plausibleAltitudeRangeMeters = plausibleAltitudeRangeMeters
        self.altitudeSpikeMinimumDeviationMeters = max(0, altitudeSpikeMinimumDeviationMeters)
        self.altitudeShortExcursionMinimumDeviationMeters = max(
            self.altitudeSpikeMinimumDeviationMeters,
            altitudeShortExcursionMinimumDeviationMeters
        )
        self.altitudeShortExcursionMaximumSampleCount = max(
            1,
            altitudeShortExcursionMaximumSampleCount
        )
        self.altitudeSpikeMaximumNeighborDifferenceMeters = max(0, altitudeSpikeMaximumNeighborDifferenceMeters)
        self.altitudeSpikeMaximumHorizontalSpanMeters = max(0, altitudeSpikeMaximumHorizontalSpanMeters)
        self.elevationSmoothingRadiusMeters = max(0, elevationSmoothingRadiusMeters)
        self.minimumReliableAltitudeSampleCount = max(2, minimumReliableAltitudeSampleCount)
        self.elevationGainLossDeadbandMeters = max(0, elevationGainLossDeadbandMeters)
        self.elevationHighlightWindowRouteFraction = max(0, elevationHighlightWindowRouteFraction)
        self.elevationHighlightMinimumWindowMeters = max(0, elevationHighlightMinimumWindowMeters)
        self.elevationHighlightMaximumWindowMeters = max(
            self.elevationHighlightMinimumWindowMeters,
            elevationHighlightMaximumWindowMeters
        )
        self.elevationHighlightMinimumStepMeters = max(1, elevationHighlightMinimumStepMeters)
        self.elevationHighlightStepsPerWindow = max(1, elevationHighlightStepsPerWindow)
        self.cancellationCheckStride = max(1, cancellationCheckStride)
    }

    public static let runningDefault = RouteQualityPolicy()
}
