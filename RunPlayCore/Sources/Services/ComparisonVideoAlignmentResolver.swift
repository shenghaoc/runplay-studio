import Foundation

/// Immutable seed that proves a snapshot belongs to a specific ordered pair.
///
/// Uses the same revision facts as `RouteAlignmentCacheKey` so UUID-only reuse
/// cannot apply a snapshot from a different normalization or analysis revision.
public struct ComparisonVideoAlignmentSeed: Sendable {
    public let primaryWorkoutID: UUID
    public let comparisonWorkoutID: UUID
    public let primaryNormalizationVersion: Int
    public let comparisonNormalizationVersion: Int
    public let primaryAnalysisVersion: Int
    public let comparisonAnalysisVersion: Int
    public let primaryPointCount: Int
    public let comparisonPointCount: Int
    public let primaryFirstPointID: UUID?
    public let primaryLastPointID: UUID?
    public let comparisonFirstPointID: UUID?
    public let comparisonLastPointID: UUID?
    public let primaryDistanceMeters: Double
    public let comparisonDistanceMeters: Double
    public let policyVersion: Int
    public let snapshot: RouteAlignmentSnapshot

    public init(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryDistanceMeters: Double,
        comparisonDistanceMeters: Double,
        policyVersion: Int,
        snapshot: RouteAlignmentSnapshot
    ) {
        self.primaryWorkoutID = primary.id
        self.comparisonWorkoutID = comparison.id
        self.primaryNormalizationVersion = primary.normalizationVersion
        self.comparisonNormalizationVersion = comparison.normalizationVersion
        self.primaryAnalysisVersion = primary.analysisVersion
        self.comparisonAnalysisVersion = comparison.analysisVersion
        self.primaryPointCount = primary.routePoints.count
        self.comparisonPointCount = comparison.routePoints.count
        self.primaryFirstPointID = primary.routePoints.first?.id
        self.primaryLastPointID = primary.routePoints.last?.id
        self.comparisonFirstPointID = comparison.routePoints.first?.id
        self.comparisonLastPointID = comparison.routePoints.last?.id
        self.primaryDistanceMeters = primaryDistanceMeters
        self.comparisonDistanceMeters = comparisonDistanceMeters
        self.policyVersion = policyVersion
        self.snapshot = snapshot
    }

    public init(
        pair: ComparisonPair,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        policy: RouteAlignmentPolicy = .default,
        snapshot: RouteAlignmentSnapshot
    ) {
        self.init(
            primary: pair.primary,
            comparison: pair.comparison,
            primaryDistanceMeters: primaryContext.timeline.totalDistanceMeters,
            comparisonDistanceMeters: comparisonContext.timeline.totalDistanceMeters,
            policyVersion: policy.algorithmVersion,
            snapshot: snapshot
        )
    }

    /// Whether this seed matches the ordered pair, revisions, and policy.
    public func matches(
        pair: ComparisonPair,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        policy: RouteAlignmentPolicy = .default
    ) -> Bool {
        guard primaryWorkoutID == pair.primary.id,
              comparisonWorkoutID == pair.comparison.id,
              primaryNormalizationVersion == pair.primary.normalizationVersion,
              comparisonNormalizationVersion == pair.comparison.normalizationVersion,
              primaryAnalysisVersion == pair.primary.analysisVersion,
              comparisonAnalysisVersion == pair.comparison.analysisVersion,
              primaryPointCount == pair.primary.routePoints.count,
              comparisonPointCount == pair.comparison.routePoints.count,
              primaryFirstPointID == pair.primary.routePoints.first?.id,
              primaryLastPointID == pair.primary.routePoints.last?.id,
              comparisonFirstPointID == pair.comparison.routePoints.first?.id,
              comparisonLastPointID == pair.comparison.routePoints.last?.id,
              policyVersion == policy.algorithmVersion,
              snapshot.policyVersion == policy.algorithmVersion
        else {
            return false
        }

        let primaryDistance = primaryContext.timeline.totalDistanceMeters
        let comparisonDistance = comparisonContext.timeline.totalDistanceMeters
        // Distances can float slightly after reanalysis; require near-equality.
        return abs(primaryDistanceMeters - primaryDistance) < 1e-3
            && abs(comparisonDistanceMeters - comparisonDistance) < 1e-3
    }
}

/// Result of comparison-video alignment resolution.
public enum ComparisonVideoAlignmentResolution: Sendable {
    case distanceOnly
    case routeAware(RouteAlignmentSnapshot)
    case unavailable(RouteAlignmentUnavailableReason)

    public var snapshot: RouteAlignmentSnapshot? {
        if case .routeAware(let snapshot) = self { return snapshot }
        return nil
    }

    public var unavailableReason: RouteAlignmentUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Resolves Route-Aware alignment for comparison video without publishing into
/// live `ComparisonViewModel` state.
public struct ComparisonVideoAlignmentResolver: Sendable {
    private let aligner: any RouteComparisonAligning
    private let policy: RouteAlignmentPolicy

    public init(
        aligner: any RouteComparisonAligning = ConstrainedDynamicTimeWarpingAligner(),
        policy: RouteAlignmentPolicy = .default
    ) {
        self.aligner = aligner
        self.policy = policy
    }

    /// Resolve alignment for the requested mode.
    ///
    /// - Distance mode always returns `.distanceOnly` without DTW.
    /// - Route-Aware reuses a validated seed when present; otherwise runs DTW once.
    public func resolve(
        pair: ComparisonPair,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        desiredMode: ComparisonAlignmentMode,
        seed: ComparisonVideoAlignmentSeed?,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ComparisonVideoAlignmentResolution {
        if isCancelled() { throw ComparisonVideoExportError.cancelled }

        switch desiredMode {
        case .distance:
            return .distanceOnly
        case .routeAware:
            break
        }

        if let seed,
           seed.matches(
               pair: pair,
               primaryContext: primaryContext,
               comparisonContext: comparisonContext,
               policy: policy
           ) {
            return classification(for: seed.snapshot)
        }

        if isCancelled() { throw ComparisonVideoExportError.cancelled }

        do {
            let snapshot = try aligner.align(
                primary: pair.primary,
                comparison: pair.comparison,
                primaryContext: primaryContext,
                comparisonContext: comparisonContext,
                policy: policy,
                isCancelled: isCancelled
            )
            if isCancelled() { throw ComparisonVideoExportError.cancelled }
            return classification(for: snapshot)
        } catch is CancellationError {
            throw ComparisonVideoExportError.cancelled
        } catch is RouteAlignmentCancellation {
            throw ComparisonVideoExportError.cancelled
        } catch let error as ComparisonVideoExportError {
            throw error
        } catch {
            return .unavailable(.algorithmFailure)
        }
    }

    private func classification(
        for snapshot: RouteAlignmentSnapshot
    ) -> ComparisonVideoAlignmentResolution {
        if snapshot.policyVersion != policy.algorithmVersion {
            return .unavailable(.algorithmFailure)
        }
        switch snapshot.availability {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available:
            let aligned = snapshot.totalAlignedDistanceMeters
            if aligned.isFinite, aligned > 0, !snapshot.blocks.isEmpty {
                return .routeAware(snapshot)
            }
            return .unavailable(.insufficientMatchedDistance)
        }
    }
}
