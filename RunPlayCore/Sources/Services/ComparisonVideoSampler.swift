import Foundation

/// Portable route-position identity used for gap-safe pixel mapping.
public struct ComparisonVideoRoutePosition: Hashable, Sendable {
    public let routePointID: UUID?
    public let routePointIndex: Int
    public let routeSegmentIndex: Int
    public let distanceMeters: Double

    public init(
        routePointID: UUID?,
        routePointIndex: Int,
        routeSegmentIndex: Int,
        distanceMeters: Double
    ) {
        self.routePointID = routePointID
        self.routePointIndex = max(0, routePointIndex)
        self.routeSegmentIndex = max(0, routeSegmentIndex)
        self.distanceMeters = distanceMeters.isFinite ? max(0, distanceMeters) : 0
    }
}

/// Lightweight dual-workout metrics for one planned comparison video frame.
public struct ComparisonVideoFrameSample: Hashable, Sendable {
    public let frameIndex: Int
    public let frameCount: Int
    public let progress: Double
    public let alignmentMode: ComparisonAlignmentMode

    public let domainPositionMeters: Double
    public let domainLengthMeters: Double
    public let alignmentBlockIndex: Int?
    public let alignmentBlockCount: Int?

    public let primaryDistanceMeters: Double
    public let comparisonDistanceMeters: Double

    public let primaryElapsedSeconds: Double?
    public let comparisonElapsedSeconds: Double?
    public let elapsedDeltaSeconds: Double?

    public let primaryActiveSeconds: Double?
    public let comparisonActiveSeconds: Double?
    public let activeDeltaSeconds: Double?

    public let primaryActivePaceSecondsPerKm: Double?
    public let comparisonActivePaceSecondsPerKm: Double?
    public let activePaceDeltaSecondsPerKm: Double?

    public let spatialSeparationMeters: Double?

    public let primaryRoutePosition: ComparisonVideoRoutePosition?
    public let comparisonRoutePosition: ComparisonVideoRoutePosition?

    public let alignmentQuality: RouteAlignmentQuality?
    public let alignmentStatusLabel: String?

    public init(
        frameIndex: Int,
        frameCount: Int,
        progress: Double,
        alignmentMode: ComparisonAlignmentMode,
        domainPositionMeters: Double,
        domainLengthMeters: Double,
        alignmentBlockIndex: Int?,
        alignmentBlockCount: Int?,
        primaryDistanceMeters: Double,
        comparisonDistanceMeters: Double,
        primaryElapsedSeconds: Double?,
        comparisonElapsedSeconds: Double?,
        elapsedDeltaSeconds: Double?,
        primaryActiveSeconds: Double?,
        comparisonActiveSeconds: Double?,
        activeDeltaSeconds: Double?,
        primaryActivePaceSecondsPerKm: Double?,
        comparisonActivePaceSecondsPerKm: Double?,
        activePaceDeltaSecondsPerKm: Double?,
        spatialSeparationMeters: Double?,
        primaryRoutePosition: ComparisonVideoRoutePosition?,
        comparisonRoutePosition: ComparisonVideoRoutePosition?,
        alignmentQuality: RouteAlignmentQuality?,
        alignmentStatusLabel: String?
    ) {
        self.frameIndex = frameIndex
        self.frameCount = frameCount
        self.progress = progress
        self.alignmentMode = alignmentMode
        self.domainPositionMeters = domainPositionMeters
        self.domainLengthMeters = domainLengthMeters
        self.alignmentBlockIndex = alignmentBlockIndex
        self.alignmentBlockCount = alignmentBlockCount
        self.primaryDistanceMeters = primaryDistanceMeters
        self.comparisonDistanceMeters = comparisonDistanceMeters
        self.primaryElapsedSeconds = primaryElapsedSeconds
        self.comparisonElapsedSeconds = comparisonElapsedSeconds
        self.elapsedDeltaSeconds = elapsedDeltaSeconds
        self.primaryActiveSeconds = primaryActiveSeconds
        self.comparisonActiveSeconds = comparisonActiveSeconds
        self.activeDeltaSeconds = activeDeltaSeconds
        self.primaryActivePaceSecondsPerKm = primaryActivePaceSecondsPerKm
        self.comparisonActivePaceSecondsPerKm = comparisonActivePaceSecondsPerKm
        self.activePaceDeltaSecondsPerKm = activePaceDeltaSecondsPerKm
        self.spatialSeparationMeters = spatialSeparationMeters
        self.primaryRoutePosition = primaryRoutePosition
        self.comparisonRoutePosition = comparisonRoutePosition
        self.alignmentQuality = alignmentQuality
        self.alignmentStatusLabel = alignmentStatusLabel
    }
}

/// Samples both workouts over a comparison domain without mutating live UI state.
public final class ComparisonVideoSampler: @unchecked Sendable {
    private let pair: ComparisonPair
    private let primaryContext: WorkoutAnalysisContext
    private let comparisonContext: WorkoutAnalysisContext
    private let comparisonService: WorkoutComparisonService
    private let alignmentMetricsService: RouteAlignmentMetricsService
    private let snapshot: RouteAlignmentSnapshot?
    private let alignmentMode: ComparisonAlignmentMode
    private let lock = NSLock()

    public init(
        pair: ComparisonPair,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        alignmentMode: ComparisonAlignmentMode,
        snapshot: RouteAlignmentSnapshot? = nil,
        comparisonService: WorkoutComparisonService = WorkoutComparisonService(),
        alignmentMetricsService: RouteAlignmentMetricsService = RouteAlignmentMetricsService()
    ) {
        self.pair = pair
        self.primaryContext = primaryContext
        self.comparisonContext = comparisonContext
        self.alignmentMode = alignmentMode
        self.snapshot = snapshot
        self.comparisonService = comparisonService
        self.alignmentMetricsService = alignmentMetricsService
    }

    public var domainLengthMeters: Double {
        switch alignmentMode {
        case .distance:
            return ComparisonVideoExportEligibility.commonDistanceMeters(
                primaryContext: primaryContext,
                comparisonContext: comparisonContext
            )
        case .routeAware:
            return snapshot?.totalAlignedDistanceMeters ?? 0
        }
    }

    public var domain: ComparisonVideoDomain {
        switch alignmentMode {
        case .distance: return .commonDistance
        case .routeAware: return .alignedProgress
        }
    }

    public var isReady: Bool {
        let length = domainLengthMeters
        guard length.isFinite, length > 0 else { return false }
        if alignmentMode == .routeAware {
            guard let snapshot, snapshot.availability.isAvailable, !snapshot.blocks.isEmpty else {
                return false
            }
        }
        return true
    }

    /// Sample both workouts at a planned frame index.
    public func sample(
        frameIndex: Int,
        plan: ComparisonVideoFramePlan
    ) -> ComparisonVideoFrameSample {
        lock.lock()
        defer { lock.unlock() }

        let progress = plan.progress(atFrameIndex: frameIndex)
        let domainPosition = plan.domainPosition(atFrameIndex: frameIndex)

        switch alignmentMode {
        case .distance:
            return sampleDistance(
                frameIndex: frameIndex,
                frameCount: plan.frameCount,
                progress: progress,
                domainPosition: domainPosition,
                domainLength: plan.domainLength
            )
        case .routeAware:
            return sampleRouteAware(
                frameIndex: frameIndex,
                frameCount: plan.frameCount,
                progress: progress,
                domainPosition: domainPosition,
                domainLength: plan.domainLength
            )
        }
    }

    private func sampleDistance(
        frameIndex: Int,
        frameCount: Int,
        progress: Double,
        domainPosition: Double,
        domainLength: Double
    ) -> ComparisonVideoFrameSample {
        let metrics = comparisonService.metricsAtDistance(
            domainPosition,
            primary: pair.primary,
            comparison: pair.comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        let primaryDistance = metrics.selectedDistanceMeters
        let comparisonDistance = metrics.selectedDistanceMeters
        return ComparisonVideoFrameSample(
            frameIndex: frameIndex,
            frameCount: frameCount,
            progress: progress,
            alignmentMode: .distance,
            domainPositionMeters: domainPosition,
            domainLengthMeters: domainLength,
            alignmentBlockIndex: nil,
            alignmentBlockCount: nil,
            primaryDistanceMeters: primaryDistance,
            comparisonDistanceMeters: comparisonDistance,
            primaryElapsedSeconds: metrics.primaryElapsedSeconds,
            comparisonElapsedSeconds: metrics.comparisonElapsedSeconds,
            elapsedDeltaSeconds: metrics.elapsedTimeDeltaSeconds,
            primaryActiveSeconds: metrics.primaryActiveSeconds,
            comparisonActiveSeconds: metrics.comparisonActiveSeconds,
            activeDeltaSeconds: metrics.activeTimeDeltaSeconds,
            primaryActivePaceSecondsPerKm: metrics.primaryPaceSecondsPerKm,
            comparisonActivePaceSecondsPerKm: metrics.comparisonPaceSecondsPerKm,
            activePaceDeltaSecondsPerKm: metrics.paceDeltaSecondsPerKm,
            spatialSeparationMeters: nil,
            primaryRoutePosition: routePosition(
                for: pair.primary,
                at: primaryDistance
            ),
            comparisonRoutePosition: routePosition(
                for: pair.comparison,
                at: comparisonDistance
            ),
            alignmentQuality: nil,
            alignmentStatusLabel: nil
        )
    }

    private func sampleRouteAware(
        frameIndex: Int,
        frameCount: Int,
        progress: Double,
        domainPosition: Double,
        domainLength: Double
    ) -> ComparisonVideoFrameSample {
        guard let snapshot, snapshot.availability.isAvailable else {
            return emptyRouteAwareSample(
                frameIndex: frameIndex,
                frameCount: frameCount,
                progress: progress,
                domainPosition: domainPosition,
                domainLength: domainLength
            )
        }

        let metrics = alignmentMetricsService.metrics(
            atAlignedProgress: domainPosition,
            snapshot: snapshot,
            primary: pair.primary,
            comparison: pair.comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        let quality: RouteAlignmentQuality?
        if case .available(let q) = snapshot.availability {
            quality = q
        } else {
            quality = nil
        }

        return ComparisonVideoFrameSample(
            frameIndex: frameIndex,
            frameCount: frameCount,
            progress: progress,
            alignmentMode: .routeAware,
            domainPositionMeters: metrics.alignedProgressMeters > 0
                ? metrics.alignedProgressMeters
                : domainPosition,
            domainLengthMeters: domainLength,
            alignmentBlockIndex: metrics.blockIndex,
            alignmentBlockCount: snapshot.blocks.count,
            primaryDistanceMeters: metrics.primaryDistanceMeters,
            comparisonDistanceMeters: metrics.comparisonDistanceMeters,
            primaryElapsedSeconds: metrics.primaryElapsedSeconds,
            comparisonElapsedSeconds: metrics.comparisonElapsedSeconds,
            elapsedDeltaSeconds: metrics.elapsedDeltaSeconds,
            primaryActiveSeconds: metrics.primaryActiveSeconds,
            comparisonActiveSeconds: metrics.comparisonActiveSeconds,
            activeDeltaSeconds: metrics.activeDeltaSeconds,
            primaryActivePaceSecondsPerKm: metrics.primaryActivePaceSecondsPerKm,
            comparisonActivePaceSecondsPerKm: metrics.comparisonActivePaceSecondsPerKm,
            activePaceDeltaSecondsPerKm: metrics.activePaceDeltaSecondsPerKm,
            spatialSeparationMeters: metrics.spatialSeparationMeters,
            primaryRoutePosition: routePosition(
                for: pair.primary,
                at: metrics.primaryDistanceMeters
            ),
            comparisonRoutePosition: routePosition(
                for: pair.comparison,
                at: metrics.comparisonDistanceMeters
            ),
            alignmentQuality: quality,
            alignmentStatusLabel: snapshot.diagnostics.compactStatusLabel
        )
    }

    private func emptyRouteAwareSample(
        frameIndex: Int,
        frameCount: Int,
        progress: Double,
        domainPosition: Double,
        domainLength: Double
    ) -> ComparisonVideoFrameSample {
        ComparisonVideoFrameSample(
            frameIndex: frameIndex,
            frameCount: frameCount,
            progress: progress,
            alignmentMode: .routeAware,
            domainPositionMeters: domainPosition,
            domainLengthMeters: domainLength,
            alignmentBlockIndex: nil,
            alignmentBlockCount: nil,
            primaryDistanceMeters: 0,
            comparisonDistanceMeters: 0,
            primaryElapsedSeconds: nil,
            comparisonElapsedSeconds: nil,
            elapsedDeltaSeconds: nil,
            primaryActiveSeconds: nil,
            comparisonActiveSeconds: nil,
            activeDeltaSeconds: nil,
            primaryActivePaceSecondsPerKm: nil,
            comparisonActivePaceSecondsPerKm: nil,
            activePaceDeltaSecondsPerKm: nil,
            spatialSeparationMeters: nil,
            primaryRoutePosition: nil,
            comparisonRoutePosition: nil,
            alignmentQuality: nil,
            alignmentStatusLabel: nil
        )
    }

    private func routePosition(
        for workout: RunWorkout,
        at distanceMeters: Double
    ) -> ComparisonVideoRoutePosition? {
        guard let point = RoutePointInterpolator.point(at: distanceMeters, in: workout.routePoints) else {
            return nil
        }
        // Prefer the last point at this distance for stable index identity.
        let index = workout.routePoints.lastIndex(where: { $0.id == point.id })
            ?? workout.routePoints.firstIndex(where: {
                abs($0.distanceFromStartMeters - point.distanceFromStartMeters) < 1e-9
                    && $0.routeSegmentIndex == point.routeSegmentIndex
            })
            ?? 0
        return ComparisonVideoRoutePosition(
            routePointID: point.id,
            routePointIndex: index,
            routeSegmentIndex: point.routeSegmentIndex,
            distanceMeters: point.distanceFromStartMeters
        )
    }
}
