import Foundation

/// Pure-Swift phase timings for one production-equivalent analysis run.
///
/// Diagnostic only. Production `analyze` / `normalizeAndAnalyze` never collect
/// these values. Only test-visible profiled entry points populate a profile, and
/// only when tests request them. Contains no C++ types and no global state.
struct WorkoutAnalysisPhaseProfile: Sendable, Equatable {
    /// Route-quality geometry + elevation from `normalizeAndAnalyze` only.
    var routeQualityNanoseconds: UInt64 = 0
    /// Elevation profile construction when measured as a top-level phase.
    var elevationNanoseconds: UInt64 = 0
    /// Timeline construction when measured as a top-level phase.
    var timelineNanoseconds: UInt64 = 0
    /// Derived speed/pace mutation on route points.
    var derivedMetricsNanoseconds: UInt64 = 0
    /// Movement profile construction (skipped when already supplied in context).
    var movementProfileNanoseconds: UInt64 = 0
    /// Context rebind after derived metrics (rebuilds timeline with updated points).
    /// Production `analyzeCancellable` always performs this step.
    var contextRebindNanoseconds: UInt64 = 0
    /// Summary calculation.
    var summaryNanoseconds: UInt64 = 0
    /// Split calculation.
    var splitsNanoseconds: UInt64 = 0
    /// Recorded-lap reanalysis.
    var recordedLapsNanoseconds: UInt64 = 0
    /// Segment detection.
    var segmentsNanoseconds: UInt64 = 0
    /// Warning and diagnostic assembly after primary phases.
    var warningsNanoseconds: UInt64 = 0
    /// Full wall clock of the profiled entry point (Mode B total).
    var wallNanoseconds: UInt64 = 0

    /// Top-level phases that sum toward the wall clock (no nested double-count).
    var accountedNanoseconds: UInt64 {
        routeQualityNanoseconds
            &+ elevationNanoseconds
            &+ timelineNanoseconds
            &+ derivedMetricsNanoseconds
            &+ movementProfileNanoseconds
            &+ contextRebindNanoseconds
            &+ summaryNanoseconds
            &+ splitsNanoseconds
            &+ recordedLapsNanoseconds
            &+ segmentsNanoseconds
            &+ warningsNanoseconds
    }
}

/// Pure-Swift phase timings for alignment sample construction.
struct RouteAlignmentSamplePhaseProfile: Sendable, Equatable {
    var validPointFilterNanoseconds: UInt64 = 0
    var sharedOriginNanoseconds: UInt64 = 0
    var adaptiveIntervalNanoseconds: UInt64 = 0
    var primaryResampleNanoseconds: UInt64 = 0
    var comparisonResampleNanoseconds: UInt64 = 0
    var extentValidationNanoseconds: UInt64 = 0
    var wallNanoseconds: UInt64 = 0

    var accountedNanoseconds: UInt64 {
        validPointFilterNanoseconds
            &+ sharedOriginNanoseconds
            &+ adaptiveIntervalNanoseconds
            &+ primaryResampleNanoseconds
            &+ comparisonResampleNanoseconds
            &+ extentValidationNanoseconds
    }
}

/// Pure-Swift phase timings for a complete constrained-DTW alignment.
struct RouteAlignmentPhaseProfile: Sendable, Equatable {
    var sampleBuilderNanoseconds: UInt64 = 0
    var sampleBuilderDetail: RouteAlignmentSamplePhaseProfile = RouteAlignmentSamplePhaseProfile()
    var directionDetectionNanoseconds: UInt64 = 0
    var nativeDTWNanoseconds: UInt64 = 0
    var blockConstructionNanoseconds: UInt64 = 0
    var diagnosticsNanoseconds: UInt64 = 0
    var wallNanoseconds: UInt64 = 0

    /// Top-level phases only; sample-builder subphases are nested diagnostics.
    var accountedNanoseconds: UInt64 {
        sampleBuilderNanoseconds
            &+ directionDetectionNanoseconds
            &+ nativeDTWNanoseconds
            &+ blockConstructionNanoseconds
            &+ diagnosticsNanoseconds
    }
}

/// Pure-Swift phase timings for route metric profile construction.
struct RouteMetricPhaseProfile: Sendable, Equatable {
    var inputValidationNanoseconds: UInt64 = 0
    var metricExtractionNanoseconds: UInt64 = 0
    var smoothingNanoseconds: UInt64 = 0
    var scaleBucketNanoseconds: UInt64 = 0
    var wallNanoseconds: UInt64 = 0

    var accountedNanoseconds: UInt64 {
        inputValidationNanoseconds
            &+ metricExtractionNanoseconds
            &+ smoothingNanoseconds
            &+ scaleBucketNanoseconds
    }
}
