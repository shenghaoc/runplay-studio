import Foundation
import RunPlayCore
import RunPlayPlatform
import Observation

/// Cache key for native metric route map lines.
struct WorkoutRouteMapCacheKey: Hashable, Sendable {
    let workoutID: UUID
    let normalizationVersion: Int
    let analysisVersion: Int
    let pointCount: Int
    let firstPointID: UUID?
    let lastPointID: UUID?
    let mode: WorkoutRouteColorMode
    let policyVersion: Int
    let profileVersion: Int

    static let profileVersion = 1

    init(workout: RunWorkout, mode: WorkoutRouteColorMode, policy: RouteMetricColorPolicy) {
        self.workoutID = workout.id
        self.normalizationVersion = workout.normalizationVersion
        self.analysisVersion = workout.analysisVersion
        self.pointCount = workout.routePoints.count
        self.firstPointID = workout.routePoints.first?.id
        self.lastPointID = workout.routePoints.last?.id
        self.mode = mode
        self.policyVersion = policy.policyVersion
        self.profileVersion = Self.profileVersion
    }

    /// Workout revision without color mode — used to cache availability.
    var workoutRevision: WorkoutRouteMapWorkoutRevision {
        WorkoutRouteMapWorkoutRevision(
            workoutID: workoutID,
            normalizationVersion: normalizationVersion,
            analysisVersion: analysisVersion,
            pointCount: pointCount,
            firstPointID: firstPointID,
            lastPointID: lastPointID,
            policyVersion: policyVersion,
            profileVersion: profileVersion
        )
    }
}

/// Identifies a workout analysis revision for availability caching.
struct WorkoutRouteMapWorkoutRevision: Hashable, Sendable {
    let workoutID: UUID
    let normalizationVersion: Int
    let analysisVersion: Int
    let pointCount: Int
    let firstPointID: UUID?
    let lastPointID: UUID?
    let policyVersion: Int
    let profileVersion: Int
}

/// Snapshot of map lines + legend ready for presentation.
struct WorkoutRouteMapPresentation: Hashable, Sendable {
    let key: WorkoutRouteMapCacheKey
    let lines: [RouteMapLine]
    let profile: RouteMetricProfile?
    let availability: RouteMetricModeAvailability
    let effectiveMode: WorkoutRouteColorMode
    let fallbackReason: String?
    let lineDiagnostics: RouteMetricMapLineDiagnostics?
}

/// Builds and caches native metric route map content off the main actor.
@MainActor
@Observable
final class WorkoutRouteMapViewModel {
    /// Preferred mode from user settings (may be unavailable for a workout).
    var preferredMode: WorkoutRouteColorMode = .solid {
        didSet {
            if preferredMode != oldValue {
                scheduleRebuild()
            }
        }
    }

    private(set) var presentation: WorkoutRouteMapPresentation?
    private(set) var isBuilding = false
    private(set) var availability: RouteMetricModeAvailability = .init(
        pace: false,
        heartRate: false,
        correctedElevation: false
    )

    private var workout: RunWorkout?
    private var analysisContext: WorkoutAnalysisContext?
    private var buildTask: Task<Void, Never>?
    private var requestSerial = 0
    private var cache: [WorkoutRouteMapCacheKey: WorkoutRouteMapPresentation] = [:]
    /// Availability is independent of preferred mode — cache per workout revision
    /// so mode switches do not rebuild three metric profiles every time.
    private var availabilityCache: [WorkoutRouteMapWorkoutRevision: RouteMetricModeAvailability] = [:]
    private let policy = RouteMetricColorPolicy.runningDefault
    private let maxCacheEntries = 12

    private let profileBuilder: RouteMetricProfileBuilding
    private let lineBuilder: RouteMetricMapLineBuilding

    init(
        profileBuilder: RouteMetricProfileBuilding = DefaultRouteMetricProfileBuilder(),
        lineBuilder: RouteMetricMapLineBuilding = DefaultRouteMetricMapLineBuilder()
    ) {
        self.profileBuilder = profileBuilder
        self.lineBuilder = lineBuilder
    }

    /// Bind to the selected workout. Replay index changes must not call this.
    func update(
        workout: RunWorkout?,
        analysisContext: WorkoutAnalysisContext?
    ) {
        let previousID = self.workout?.id
        self.workout = workout
        self.analysisContext = analysisContext

        if workout?.id != previousID {
            // Never show one workout's route with another workout's markers.
            // Prior presentation is retained only for same-workout refreshes.
            presentation = nil
            availability = .init(pace: false, heartRate: false, correctedElevation: false)
            if workout == nil {
                availabilityCache.removeAll()
            }
        }
        scheduleRebuild()
    }

    func cancel() {
        buildTask?.cancel()
        buildTask = nil
        requestSerial &+= 1
        isBuilding = false
    }

    // MARK: - Build

    private func scheduleRebuild() {
        buildTask?.cancel()
        buildTask = nil
        // Invalidate a completed detached result that may already be queued to
        // publish on the main actor, including nil updates and cache hits.
        requestSerial &+= 1
        guard let workout, let analysisContext else {
            presentation = nil
            isBuilding = false
            return
        }

        let mode = preferredMode
        let key = WorkoutRouteMapCacheKey(workout: workout, mode: mode, policy: policy)
        if let cached = cache[key] {
            presentation = cached
            availability = cached.availability
            availabilityCache[key.workoutRevision] = cached.availability
            isBuilding = false
            return
        }

        let serial = requestSerial
        isBuilding = true

        let workoutSnapshot = workout
        let contextSnapshot = analysisContext
        let preferred = mode
        let policySnapshot = policy
        let profileBuilder = self.profileBuilder
        let lineBuilder = self.lineBuilder
        let cachedAvailability = availabilityCache[key.workoutRevision]

        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<WorkoutRouteMapPresentation, Error>
            do {
                let built = try Self.buildPresentation(
                    workout: workoutSnapshot,
                    context: contextSnapshot,
                    preferredMode: preferred,
                    policy: policySnapshot,
                    profileBuilder: profileBuilder,
                    lineBuilder: lineBuilder,
                    knownAvailability: cachedAvailability,
                    isCancelled: { Task.isCancelled }
                )
                result = .success(built)
            } catch is CancellationError {
                return
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                guard let self, serial == self.requestSerial else { return }
                switch result {
                case .success(let presentation):
                    self.cache[presentation.key] = presentation
                    self.availabilityCache[presentation.key.workoutRevision] = presentation.availability
                    self.trimCache()
                    self.presentation = presentation
                    self.availability = presentation.availability
                    self.isBuilding = false
                case .failure:
                    // Retain prior route; ensure solid fallback is available.
                    if self.presentation == nil {
                        let solidKey = WorkoutRouteMapCacheKey(
                            workout: workoutSnapshot,
                            mode: .solid,
                            policy: policySnapshot
                        )
                        let solidLines = RouteMapContent.segmentedRoutes(
                            idPrefix: "route",
                            points: workoutSnapshot.routePoints,
                            style: .primary
                        )
                        let solid = WorkoutRouteMapPresentation(
                            key: solidKey,
                            lines: solidLines,
                            profile: nil,
                            availability: .init(pace: false, heartRate: false, correctedElevation: false),
                            effectiveMode: .solid,
                            fallbackReason: String(localized: "Unable to build metric route colors."),
                            lineDiagnostics: nil
                        )
                        self.presentation = solid
                    }
                    self.isBuilding = false
                }
            }
        }
    }

    nonisolated private static func buildPresentation(
        workout: RunWorkout,
        context: WorkoutAnalysisContext,
        preferredMode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy,
        profileBuilder: RouteMetricProfileBuilding,
        lineBuilder: RouteMetricMapLineBuilding,
        knownAvailability: RouteMetricModeAvailability?,
        isCancelled: @Sendable () -> Bool
    ) throws -> WorkoutRouteMapPresentation {
        if isCancelled() { throw CancellationError() }

        // Reuse cached availability when only the preferred mode changed so we
        // do not rebuild pace + HR + elevation profiles on every menu selection.
        let availability: RouteMetricModeAvailability
        if let knownAvailability {
            availability = knownAvailability
        } else {
            availability = try profileBuilder.availability(
                routePoints: workout.routePoints,
                context: context,
                policy: policy,
                isCancelled: isCancelled
            )
        }

        var effective = preferredMode
        var fallbackReason: String?

        if !availability.isAvailable(effective) {
            switch effective {
            case .solid:
                break
            case .pace:
                fallbackReason = String(localized: "Pace coloring needs more valid active distance and time in this workout.")
            case .heartRate:
                fallbackReason = String(localized: "Heart-rate coloring needs meaningful HR coverage in this workout.")
            case .correctedElevation:
                fallbackReason = String(localized: "Elevation coloring needs meaningful corrected elevation in this workout.")
            }
            effective = .solid
        }

        let key = WorkoutRouteMapCacheKey(workout: workout, mode: preferredMode, policy: policy)
        // Cache key retains preferred mode so availability fallback still reuses
        // the solid lines when the user reselects the same unavailable mode.
        let profile = try profileBuilder.build(
            routePoints: workout.routePoints,
            context: context,
            mode: effective,
            policy: policy,
            isCancelled: isCancelled
        )

        let lineResult = try lineBuilder.build(
            routePoints: workout.routePoints,
            profile: profile,
            idPrefix: "route",
            policy: policy,
            isCancelled: isCancelled
        )

        return WorkoutRouteMapPresentation(
            key: key,
            lines: lineResult.lines,
            profile: effective == .solid ? nil : profile,
            availability: availability,
            effectiveMode: effective,
            fallbackReason: fallbackReason,
            lineDiagnostics: lineResult.diagnostics
        )
    }

    private func trimCache() {
        while cache.count > maxCacheEntries {
            if let first = cache.keys.first {
                cache.removeValue(forKey: first)
            } else {
                break
            }
        }
        // Keep availability cache aligned with remaining line cache revisions.
        let liveRevisions = Set(cache.keys.map(\.workoutRevision))
        availabilityCache = availabilityCache.filter { liveRevisions.contains($0.key) }
    }
}

// MARK: - Injectable builders

protocol RouteMetricProfileBuilding: Sendable {
    func build(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfile

    func availability(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricModeAvailability
}

struct DefaultRouteMetricProfileBuilder: RouteMetricProfileBuilding {
    private let builder = RouteMetricProfileBuilder()

    func build(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfile {
        try builder.build(
            routePoints: routePoints,
            context: context,
            mode: mode,
            policy: policy,
            isCancelled: isCancelled
        )
    }

    func availability(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricModeAvailability {
        try builder.availability(
            routePoints: routePoints,
            context: context,
            policy: policy,
            isCancelled: isCancelled
        )
    }
}

protocol RouteMetricMapLineBuilding: Sendable {
    func build(
        routePoints: [RoutePoint],
        profile: RouteMetricProfile,
        idPrefix: String,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricMapLineBuildResult
}

struct DefaultRouteMetricMapLineBuilder: RouteMetricMapLineBuilding {
    private let builder = RouteMetricMapLineBuilder()

    func build(
        routePoints: [RoutePoint],
        profile: RouteMetricProfile,
        idPrefix: String,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricMapLineBuildResult {
        try builder.build(
            routePoints: routePoints,
            profile: profile,
            idPrefix: idPrefix,
            policy: policy,
            isCancelled: isCancelled
        )
    }
}
