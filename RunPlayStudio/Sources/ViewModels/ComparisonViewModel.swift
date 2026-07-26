import Foundation
import RunPlayCore

/// Cache key for in-memory route alignment results.
struct RouteAlignmentCacheKey: Hashable, Sendable {
    let primaryID: UUID
    let comparisonID: UUID
    let primaryNormalizationVersion: Int
    let comparisonNormalizationVersion: Int
    let primaryAnalysisVersion: Int
    let comparisonAnalysisVersion: Int
    let primaryPointCount: Int
    let comparisonPointCount: Int
    let primaryFirstPointID: UUID?
    let primaryLastPointID: UUID?
    let comparisonFirstPointID: UUID?
    let comparisonLastPointID: UUID?
    let primaryDistanceMeters: Double
    let comparisonDistanceMeters: Double
    let policyVersion: Int

    init(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryDistanceMeters: Double,
        comparisonDistanceMeters: Double,
        policyVersion: Int
    ) {
        self.primaryID = primary.id
        self.comparisonID = comparison.id
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
    }
}

/// Owns comparison alignment mode, Route-Aware load state, cache, and mapping.
///
/// Heavy DTW work runs off the main actor via an immutable Sendable request.
/// Slider interaction never recomputes DTW.
@MainActor
final class ComparisonViewModel: ObservableObject {
    @Published private(set) var alignmentMode: ComparisonAlignmentMode = .distance
    @Published private(set) var routeAlignmentLoadState: RouteAlignmentLoadState = .idle
    @Published private(set) var routeAlignmentSnapshot: RouteAlignmentSnapshot?
    @Published private(set) var alignedChartPoints: [AlignedComparisonMetricPoint] = []
    @Published var selectedAlignedProgressMeters: Double = 0
    @Published private(set) var lastAnnouncement: String?

    private let aligner: any RouteComparisonAligning
    private let metricsService: RouteAlignmentMetricsService
    private let policy: RouteAlignmentPolicy
    private let announcementPolicy: AccessibilityAnnouncementPolicy

    private var cache: [RouteAlignmentCacheKey: RouteAlignmentSnapshot] = [:]
    private var alignmentTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var activePairIDs: (primary: UUID, comparison: UUID)?

    init(
        aligner: any RouteComparisonAligning = ConstrainedDynamicTimeWarpingAligner(),
        metricsService: RouteAlignmentMetricsService = RouteAlignmentMetricsService(),
        policy: RouteAlignmentPolicy = .default,
        announcementPolicy: AccessibilityAnnouncementPolicy = AccessibilityAnnouncementPolicy()
    ) {
        self.aligner = aligner
        self.metricsService = metricsService
        self.policy = policy
        self.announcementPolicy = announcementPolicy
    }

    var totalAlignedDistanceMeters: Double {
        routeAlignmentSnapshot?.totalAlignedDistanceMeters ?? 0
    }

    var clampedAlignedProgressMeters: Double {
        max(0, min(selectedAlignedProgressMeters, totalAlignedDistanceMeters))
    }

    var isRouteAwareReady: Bool {
        alignmentMode == .routeAware && routeAlignmentLoadState == .ready
    }

    func setAlignmentMode(
        _ mode: ComparisonAlignmentMode,
        pair: ComparisonPair?,
        primaryContext: WorkoutAnalysisContext?,
        comparisonContext: WorkoutAnalysisContext?
    ) {
        guard mode != alignmentMode else { return }
        alignmentMode = mode
        switch mode {
        case .distance:
            cancelAlignmentWork()
            if case .loading = routeAlignmentLoadState {
                routeAlignmentLoadState = routeAlignmentSnapshot?.availability.isAvailable == true
                    ? .ready
                    : .idle
            }
            announcementPolicy.handle(.usingDistanceAlignment)
            lastAnnouncement = AccessibilityAnnouncementEvent.usingDistanceAlignment.message
        case .routeAware:
            announcementPolicy.handle(.usingRouteAwareAlignment)
            lastAnnouncement = AccessibilityAnnouncementEvent.usingRouteAwareAlignment.message
            if let pair, let primaryContext, let comparisonContext {
                ensureRouteAlignment(
                    pair: pair,
                    primaryContext: primaryContext,
                    comparisonContext: comparisonContext
                )
            }
        }
    }

    /// Restore mode from session without announcing.
    func restoreAlignmentMode(_ mode: ComparisonAlignmentMode) {
        alignmentMode = mode
    }

    func clear() {
        cancelAlignmentWork()
        alignmentMode = .distance
        routeAlignmentLoadState = .idle
        routeAlignmentSnapshot = nil
        alignedChartPoints = []
        selectedAlignedProgressMeters = 0
        activePairIDs = nil
        // Keep cache for the session lifetime; clear only on pair churn pressure.
        if cache.count > 8 {
            cache.removeAll(keepingCapacity: false)
        }
    }

    func pairDidChange(
        pair: ComparisonPair?,
        primaryContext: WorkoutAnalysisContext?,
        comparisonContext: WorkoutAnalysisContext?
    ) {
        cancelAlignmentWork()
        routeAlignmentSnapshot = nil
        alignedChartPoints = []
        selectedAlignedProgressMeters = 0
        routeAlignmentLoadState = .idle
        activePairIDs = pair.map { ($0.primary.id, $0.comparison.id) }

        guard let pair, let primaryContext, let comparisonContext else { return }
        if alignmentMode == .routeAware {
            ensureRouteAlignment(
                pair: pair,
                primaryContext: primaryContext,
                comparisonContext: comparisonContext
            )
        }
    }

    func ensureRouteAlignment(
        pair: ComparisonPair,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext
    ) {
        let key = RouteAlignmentCacheKey(
            primary: pair.primary,
            comparison: pair.comparison,
            primaryDistanceMeters: primaryContext.timeline.totalDistanceMeters,
            comparisonDistanceMeters: comparisonContext.timeline.totalDistanceMeters,
            policyVersion: policy.algorithmVersion
        )
        activePairIDs = (pair.primary.id, pair.comparison.id)

        if let cached = cache[key] {
            publish(snapshot: cached, pair: pair, generation: requestGeneration)
            return
        }

        cancelAlignmentWork()
        requestGeneration += 1
        let generation = requestGeneration
        routeAlignmentLoadState = .loading

        let primary = pair.primary
        let comparison = pair.comparison
        let aligner = self.aligner
        let policy = self.policy
        // Capture immutable analysis contexts (Sendable) for off-main work.
        let primaryCtx = primaryContext
        let comparisonCtx = comparisonContext

        alignmentTask = Task { [weak self] in
            let isCancelled: @Sendable () -> Bool = { Task.isCancelled }
            let snapshot: RouteAlignmentSnapshot
            do {
                snapshot = try await Task.detached(priority: .userInitiated) {
                    try aligner.align(
                        primary: primary,
                        comparison: comparison,
                        primaryContext: primaryCtx,
                        comparisonContext: comparisonCtx,
                        policy: policy,
                        isCancelled: isCancelled
                    )
                }.value
            } catch {
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    if Task.isCancelled { return }
                    self.routeAlignmentLoadState = .failed("Route alignment could not be completed.")
                    self.announcementPolicy.handle(.routeAlignmentUnavailable)
                    self.lastAnnouncement = AccessibilityAnnouncementEvent.routeAlignmentUnavailable.message
                }
                return
            }

            await MainActor.run {
                guard let self else { return }
                // Stale-result suppression.
                guard self.requestGeneration == generation else { return }
                guard self.activePairIDs?.primary == primary.id,
                      self.activePairIDs?.comparison == comparison.id else { return }
                if case .unavailable(.cancelled) = snapshot.availability {
                    // Cancelled for this generation — do not publish as failure.
                    return
                }
                self.cache[key] = snapshot
                self.publish(snapshot: snapshot, pair: pair, generation: generation)
            }
        }
    }

    func clampAlignedProgress() {
        let total = totalAlignedDistanceMeters
        if selectedAlignedProgressMeters > total {
            selectedAlignedProgressMeters = total
        }
        if selectedAlignedProgressMeters < 0 || !selectedAlignedProgressMeters.isFinite {
            selectedAlignedProgressMeters = 0
        }
    }

    func alignedMetrics(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext
    ) -> ComparisonAlignedMetrics {
        guard let snapshot = routeAlignmentSnapshot, snapshot.availability.isAvailable else {
            return .empty
        }
        return metricsService.metrics(
            atAlignedProgress: clampedAlignedProgressMeters,
            snapshot: snapshot,
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
    }

    func useDistanceAlignment() {
        setAlignmentMode(.distance, pair: nil, primaryContext: nil, comparisonContext: nil)
    }

    // MARK: - Private

    private func publish(
        snapshot: RouteAlignmentSnapshot,
        pair: ComparisonPair,
        generation: Int
    ) {
        guard requestGeneration == generation else { return }
        routeAlignmentSnapshot = snapshot
        switch snapshot.availability {
        case .available:
            routeAlignmentLoadState = .ready
            alignedChartPoints = metricsService.chartPoints(
                snapshot: snapshot,
                primary: pair.primary,
                comparison: pair.comparison,
                policy: policy
            )
            clampAlignedProgress()
            announcementPolicy.handle(.routeAlignmentReady)
            lastAnnouncement = AccessibilityAnnouncementEvent.routeAlignmentReady.message
        case .unavailable(let reason):
            if reason == .cancelled { return }
            routeAlignmentLoadState = .unavailable(reason)
            alignedChartPoints = []
            announcementPolicy.handle(.routeAlignmentUnavailable)
            lastAnnouncement = AccessibilityAnnouncementEvent.routeAlignmentUnavailable.message
        }
    }

    private func cancelAlignmentWork() {
        alignmentTask?.cancel()
        alignmentTask = nil
        requestGeneration += 1
    }
}
