import Combine
import Foundation
import RunPlayCore
import RunPlayPlatform
import SwiftUI

import UniformTypeIdentifiers

/// Observable state for library operations.
public enum LibraryOperationState: Equatable {
    case idle
    case loadingLibrary
    case importing(filename: String)
    case deleting(workoutID: UUID)
    case scanningArchive(filename: String)
    case importingArchive
    case scanningFITFile(filename: String)
    case importingFITSessions
}

/// Top-level workspace mode. Mutually exclusive destinations.
enum AppWorkspaceMode: Hashable, Sendable {
    case workout
    case comparison
    case personalHeatmap
    case trends
    case personalRecords
    case routeGroups
    case workoutLibrary
}

/// Menu-level command routed through the same workspace transition methods as
/// sidebar selection. Kept separate from the visible workspace state.
enum AppWorkspaceCommand {
    case showPersonalHeatmap
    case showTrends
    case showPersonalRecords
    case showRouteGroups
    case showAllRuns
}

/// A cumulative-distance range to emphasize on the workout map and charts.
struct HighlightedWorkoutRange: Equatable, Sendable {
    let workoutID: UUID
    let startDistanceMeters: Double
    let endDistanceMeters: Double
}

/// Main application state manager.
@MainActor
class AppState: ObservableObject {
    @Published var workouts: [RunWorkout] = []
    @Published var selectedWorkout: RunWorkout?
    @Published var showImporter = false
    @Published var showArchiveImporter = false
    @Published var archiveSession: ArchiveImportSession?
    @Published var fitSessionImportSession: FITSessionImportSession?
    @Published var errorMessage: String?
    @Published var showingError = false
    @Published var detectedSegments: [SegmentHighlight] = []
    @Published var selectedSegment: SegmentHighlight?

    /// A distance range highlighted on the workout map and charts, set by
    /// Personal Records navigation. Transient: cleared when another workout is
    /// selected; never persisted in the session.
    @Published var highlightedWorkoutRange: HighlightedWorkoutRange?

    /// Increments whenever the in-memory library's record windows change
    /// (load, import, delete, backfill update), so derived UI such as the
    /// workout Overview badges can recompute without walking the library on
    /// replay ticks.
    @Published private(set) var personalRecordsLibraryRevision = 0

    /// Local-only athlete profile for training-load computation. Loaded once
    /// at startup; edits go through `updateAthleteProfile`.
    @Published private(set) var athleteProfile = AthleteProfile()
    private let profileStore: FileAthleteProfileStore?

    /// Settings-scene progress for an explicit training-load recompute.
    /// Feature-local published state, never a library-wide token.
    @Published private(set) var trainingLoadRecomputeState: TrainingLoadRecomputeState = .idle

    func bumpPersonalRecordsLibraryRevision() {
        personalRecordsLibraryRevision += 1
    }

    /// Increments whenever route-group membership changes — once per pass
    /// (assignment, backfill, re-cluster) or manual mutation, never per
    /// workout inside a pass. See the library-level revision discipline in
    /// docs/architecture.md.
    @Published private(set) var routeGroupsLibraryRevision = 0

    func bumpRouteGroupsLibraryRevision() {
        routeGroupsLibraryRevision += 1
    }

    /// Route groups (library organisation; empty for demos).
    @Published var routeGroups: [WorkoutRouteGroup] = []

    /// Route-group assignment records, mirroring the manifest.
    @Published var routeGroupAssignments: [WorkoutRouteGroupAssignment] = []

    @Published var operationState: LibraryOperationState = .idle

    /// Local favourite markers for library workouts (not demos).
    @Published var favoriteWorkoutIDs: Set<UUID> = []

    /// User-defined tags (library organisation; empty for demos).
    @Published var tags: [WorkoutTag] = []

    /// Smart collections (saved dynamic All Runs queries).
    @Published var smartCollections: [WorkoutSmartCollection] = []

    /// Requests the All Runs view to present the collection manager. This is
    /// shared workspace state so a sidebar action survives the destination
    /// transition instead of relying on a notification that a new view may
    /// not yet be observing.
    @Published var showSmartCollectionsManager = false

    /// True when the in-memory library is backed by a persisted manifest.
    /// Bundled demos leave this false so favourite/metadata actions stay disabled.
    @Published var hasPersistedLibrary = false

    /// IDs known to exist in the persisted library manifest.
    /// Bundled demos are never added here, even if still shown in-session.
    @Published var libraryWorkoutIDs: Set<UUID> = []

    /// Transient metadata editor error (stays in the sheet; not a workspace overlay).
    @Published var metadataEditError: String?

    /// Transient tag/collection editor error (stays in the sheet).
    @Published var organizationEditError: String?

    /// Single source of truth for which workspace is visible.
    @Published private(set) var workspaceMode: AppWorkspaceMode = .workout

    /// Durable presentation values owned by the application rather than a
    /// recreated detail view.
    @Published var workoutDetailTabRaw = "Overview" {
        didSet { requestSessionSave() }
    }
    @Published var workoutMapDisplayModeRaw = "2D" {
        didSet { requestSessionSave() }
    }
    @Published var sidebarVisibilityRaw = "automatic" {
        didSet { requestSessionSave() }
    }

    /// Set by RunPlayStudioApp after both application-owned objects exist.
    /// AppSessionController's back-reference to AppState is weak, so this
    /// forward link does not create a retain cycle.
    var sessionController: AppSessionController?

    // Comparison state
    @Published var comparisonWorkout: RunWorkout?
    @Published var comparisonSelectionMessage: String?
    @Published var selectedComparisonDistanceMeters: Double = 0
    /// Owns alignment mode, Route-Aware DTW load state, cache, and mapping.
    let comparisonViewModel: ComparisonViewModel

    /// Compatibility view of comparison mode. Prefer `workspaceMode`.
    var isComparing: Bool {
        get { workspaceMode == .comparison }
        set {
            if newValue {
                enterComparisonWorkspace()
            } else if workspaceMode == .comparison {
                clearComparison()
            }
        }
    }

    /// Native sidebar selection derived from workspace mode and selected workout.
    var sidebarSelection: SidebarSelection? {
        switch workspaceMode {
        case .personalHeatmap:
            return .personalHeatmap
        case .trends:
            return .trends
        case .personalRecords:
            return .personalRecords
        case .routeGroups:
            return .routeGroups
        case .workoutLibrary:
            if case .smartCollection(let id, _) = workoutLibrary.queryContext {
                return .smartCollection(id)
            }
            return .allRuns
        case .workout, .comparison:
            if let id = selectedWorkout?.id {
                return .workout(id)
            }
            return nil
        }
    }

    /// Apply a sidebar selection change (keyboard, click, or VoiceOver).
    func applySidebarSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .allRuns:
            showWorkoutLibrary(restoreManualQuery: true)
        case .personalHeatmap:
            showPersonalHeatmap()
        case .trends:
            showTrends()
        case .personalRecords:
            showPersonalRecords()
        case .routeGroups:
            showRouteGroups()
        case .smartCollection(let id):
            showSmartCollection(id: id)
        case .workout(let id):
            if let workout = workouts.first(where: { $0.id == id }) {
                selectWorkout(workout)
            }
        case .none:
            break
        }
    }

    let replayController = ReplayController()
    let comparisonService = WorkoutComparisonService()
    let personalHeatmap: PersonalHeatmapViewModel
    let trends: TrendsViewModel
    let personalRecords: PersonalRecordsViewModel
    let routeGroupsViewModel = RouteGroupsViewModel()
    let workoutLibrary: WorkoutLibraryViewModel

    struct CachedAnalysisContext {
        let normalizationVersion: Int
        let pointCount: Int
        let firstPointID: UUID?
        let lastPointID: UUID?
        let context: WorkoutAnalysisContext
    }

    /// Main-actor-owned immutable contexts avoid rebuilding 100k-point
    /// elevation profiles from multiple SwiftUI computed properties.
    var analysisContextCache: [UUID: CachedAnalysisContext] = [:]

    /// Backward-compatible computed property for views that check loading state.
    var isLoadingLibrary: Bool {
        operationState == .loadingLibrary
    }

    /// True when an application-owned modal presentation is on screen.
    ///
    /// Background replay, delete, and import commands stay inert while this is
    /// true. `ContentView` combines it with its own view-local presentations.
    var isModalPresentationActive: Bool {
        archiveSession != nil
            || fitSessionImportSession != nil
            || showImporter
            || showArchiveImporter
            || showSmartCollectionsManager
            || showingError
    }

    /// The store actor for persistence. Nil only in tests without persistence.
    let storeActor: WorkoutLibraryStoreActor?

    /// Watch-folder coordinator. Nil only in tests without watch folders;
    /// the app injects one rooted at the same library directory and calls
    /// `startWatchFolders()` after the library loads.
    private(set) var watchFolderCoordinator: WatchFolderCoordinator?

    /// The import service for parsing workout files off the main actor.
    /// Internal (not private) so `AppState+WatchFolderImport` reuses the
    /// identical import path.
    let importService: WorkoutImportServicing?

    /// Platform archive service (ZIP scan/import). Nil in tests without platform.
    let archiveService: StravaArchiveService?

    /// Core multi-session FIT scan/import service. Nil disables the review
    /// sheet entirely; every FIT file then follows the direct import path.
    let fitSessionService: FITSessionImportService?

    /// Retained, injectable policy shared by app-owned transition models.
    let announcementPolicy: AccessibilityAnnouncementPolicy

    /// Handle for the current selection persistence task.
    private var selectionTask: Task<Void, Never>?

    /// Handle for the active archive scan/import task.
    var archiveTask: Task<Void, Never>?

    /// Handle for the active multi-session FIT import task.
    var fitImportTask: Task<Void, Never>?

    /// Create AppState with injectable services.
    ///
    /// This initializer does **not** launch background tasks. Call `start()` to
    /// load the persisted library asynchronously.
    ///
    /// - Parameters:
    ///   - storeActor: The persistence actor. Pass `nil` to skip persistence (tests only).
    ///   - importService: The import service. Pass `nil` to skip import (tests only).
    init(
        storeActor: WorkoutLibraryStoreActor? = nil,
        importService: WorkoutImportServicing? = nil,
        archiveService: StravaArchiveService? = nil,
        fitSessionService: FITSessionImportService? = nil,
        profileStore: FileAthleteProfileStore? = nil,
        accessibilityAnnouncer: any AccessibilityAnnouncing = AccessibilityAnnouncer.shared
    ) {
        let announcementPolicy = AccessibilityAnnouncementPolicy(
            announcer: accessibilityAnnouncer
        )
        self.storeActor = storeActor
        self.profileStore = profileStore
        if let profileStore {
            athleteProfile = profileStore.loadOrDefault()
        }
        self.importService = importService
        self.archiveService = archiveService
        self.fitSessionService = fitSessionService
        self.announcementPolicy = announcementPolicy
        self.personalHeatmap = PersonalHeatmapViewModel(
            announcementPolicy: announcementPolicy
        )
        self.trends = TrendsViewModel(
            announcementPolicy: announcementPolicy
        )
        self.personalRecords = PersonalRecordsViewModel(
            announcementPolicy: announcementPolicy
        )
        self.workoutLibrary = WorkoutLibraryViewModel(
            announcementPolicy: announcementPolicy
        )
        let comparisonViewModel = ComparisonViewModel(
            announcementPolicy: announcementPolicy
        )
        self.comparisonViewModel = comparisonViewModel
        // Forward alignment load-state changes so SwiftUI views observing AppState refresh.
        comparisonViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &comparisonViewModelCancellables)
    }

    private var comparisonViewModelCancellables: Set<AnyCancellable> = []

    /// Convenience init for production: creates real services rooted at the given directory.
    convenience init(libraryRoot: URL) {
        let store = FileWorkoutLibraryStore(rootURL: libraryRoot)
        let actor = WorkoutLibraryStoreActor(store: store)
        let importService = WorkoutImportService()
        let archiveService = StravaArchiveService()
        let fitSessionService = FITSessionImportService(digest: CryptoKitContentDigest())
        self.init(
            storeActor: actor,
            importService: importService,
            archiveService: archiveService,
            fitSessionService: fitSessionService,
            profileStore: FileAthleteProfileStore(rootURL: libraryRoot)
        )
        attachWatchFolderCoordinator(
            store: FileWatchFolderStore(rootURL: libraryRoot),
            digest: CryptoKitContentDigest()
        )
    }

    /// Create and wire the watch-folder coordinator. Split from init so the
    /// coordinator can call back into this AppState through closures.
    func attachWatchFolderCoordinator(
        store: FileWatchFolderStore,
        digest: any ContentDigesting,
        policy: WatchFolderScanPolicy = .default
    ) {
        guard watchFolderCoordinator == nil else { return }
        let coordinator = WatchFolderCoordinator(
            store: store,
            digest: digest,
            policy: policy
        )
        coordinator.importExecutor = { [weak self] url, configuration in
            guard let self else { return .failed("AppState unavailable.") }
            return await self.performWatchFolderImport(
                from: url,
                configuration: configuration
            )
        }
        coordinator.reviewPresenter = { [weak self] url in
            guard let self else { return }
            Task { await self.presentWatchFolderFITReview(for: url) }
        }
        coordinator.canImportNow = { [weak self] in
            guard let self else { return false }
            return self.operationState == .idle
                && self.archiveSession == nil
                && self.fitSessionImportSession == nil
        }
        // Watch-folder results are non-modal, so speech is the only signal for
        // a background import completing, failing, or a folder disappearing.
        // The coordinator aggregates per pass; it never announces per file.
        coordinator.announce = { [weak self] event in
            self?.announcementPolicy.handle(event)
        }
        watchFolderCoordinator = coordinator
    }

    /// Begin watching after the library has loaded (called from `start()`),
    /// so watch-folder imports land on a fully loaded library.
    func startWatchFolders() {
        watchFolderCoordinator?.start()
    }

    deinit {
        selectionTask?.cancel()
        archiveTask?.cancel()
        fitImportTask?.cancel()
        personalRecordsBackfillTask?.cancel()
        trainingLoadBackfillTask?.cancel()
        routeGroupAssignmentTask?.cancel()
        routeGroupReclusterTask?.cancel()
        routeGroupBackfillTask?.cancel()
    }

    // MARK: - Application session

    func requestSessionSave(replay: Bool = false) {
        sessionController?.requestSave(replay: replay)
    }

    /// Build a logical snapshot from current application/workspace state.
    /// Library membership and selected-workout authority remain in the
    /// manifest; replay stores only a validated ID and scalar position.
    func makeSessionSnapshot() -> AppSessionSnapshot {
        let destination: AppSessionDestination
        switch workspaceMode {
        case .workout:
            destination = .workout
        case .comparison:
            destination = .comparison
        case .personalHeatmap:
            destination = .personalHeatmap
        case .trends:
            destination = .trends
        case .personalRecords:
            destination = .personalRecords
        case .routeGroups:
            destination = .routeGroups
        case .workoutLibrary:
            if case .smartCollection(let id, _) = workoutLibrary.queryContext {
                destination = .smartCollection(id)
            } else {
                destination = .allRuns
            }
        }

        let activeCollection: (UUID, Bool, WorkoutLibrarySavedQuery?)? = {
            guard case .smartCollection(let id, let modified) = workoutLibrary.queryContext else {
                return nil
            }
            return (
                id,
                modified,
                modified ? AppSessionPolicy.boundedQuery(workoutLibrary.currentSavedQuery()) : nil
            )
        }()
        let comparison: AppSessionComparisonState? = {
            guard workspaceMode == .comparison,
                  let peer = comparisonWorkout,
                  let primary = selectedWorkout,
                  primary.id != peer.id else {
                return nil
            }
            return AppSessionComparisonState(
                peerWorkoutID: peer.id,
                distanceMeters: clampedComparisonDistanceMeters,
                alignmentModeRaw: comparisonViewModel.alignmentMode.rawValue,
                alignedProgressMeters: comparisonViewModel.persistableAlignedProgressMeters
            )
        }()
        let replay: AppSessionReplayState? = selectedWorkout.map {
            AppSessionReplayState(
                workoutID: $0.id,
                elapsedSeconds: replayController.state.currentTime,
                playbackSpeed: replayController.state.playbackSpeed
            )
        }

        return AppSessionSnapshot(
            destination: destination,
            sidebarVisibilityRaw: sidebarVisibilityRaw,
            workout: AppSessionWorkoutState(
                tabRaw: workoutDetailTabRaw,
                mapDisplayModeRaw: workoutMapDisplayModeRaw
            ),
            library: AppSessionLibraryState(
                manualQuery: AppSessionPolicy.boundedQuery(workoutLibrary.sessionManualQuery()),
                activeSmartCollectionID: activeCollection?.0,
                activeSmartCollectionModified: activeCollection?.1 ?? false,
                modifiedWorkingQuery: activeCollection?.2
            ),
            heatmap: AppSessionHeatmapState(
                datePresetRaw: personalHeatmap.datePreset.rawValue,
                customStartDate: personalHeatmap.customStartDate,
                customEndDate: personalHeatmap.customEndDate,
                resolutionRaw: personalHeatmap.resolution.rawValue,
                minimumWorkoutCount: personalHeatmap.minimumWorkoutCount,
                routeGroupID: {
                    if case .group(let id) = personalHeatmap.routeFilter { return id }
                    return nil
                }()
            ),
            trends: AppSessionTrendsState(
                periodRaw: trends.period.rawValue,
                rangeRaw: trends.range.rawValue,
                scopeKindRaw: trends.scope.sessionKindRawValue,
                scopeSmartCollectionID: {
                    if case .smartCollection(let id) = trends.scope { return id }
                    return nil
                }()
            ),
            personalRecords: AppSessionPersonalRecordsState(
                scopeKindRaw: personalRecords.scope.sessionKindRawValue,
                scopeSmartCollectionID: {
                    if case .smartCollection(let id) = personalRecords.scope { return id }
                    return nil
                }()
            ),
            comparison: comparison,
            replay: replay
        )
    }

    /// Lightweight facts used to validate persisted references before apply.
    func sessionValidationContext() -> AppSessionValidationContext {
        AppSessionValidationContext(
            workoutIDs: Set(workouts.map(\.id)),
            selectedWorkoutID: selectedWorkout?.id,
            smartCollectionIDs: Set(smartCollections.map(\.id)),
            tagIDs: Set(tags.map(\.id)),
            routeGroupIDs: Set(routeGroups.map(\.id)),
            replayDuration: replayController.state.totalDuration.isFinite
                ? replayController.state.totalDuration
                : selectedWorkout?.summary.totalElapsedSeconds,
            workoutDistanceMetersByID: Dictionary(
                uniqueKeysWithValues: workouts.map {
                    ($0.id, max(0, $0.summary.totalDistanceMeters))
                }
            )
        )
    }

    /// Apply validated session context after the manifest-selected workout is
    /// already published. This never changes selectedWorkout from disk.
    func applySessionSnapshot(_ snapshot: AppSessionSnapshot) {
        workoutDetailTabRaw = snapshot.workout.tabRaw
        workoutMapDisplayModeRaw = snapshot.workout.mapDisplayModeRaw
        sidebarVisibilityRaw = snapshot.sidebarVisibilityRaw
        personalHeatmap.restoreSessionState(snapshot.heatmap)
        trends.restoreSessionState(snapshot.trends)
        personalRecords.restoreSessionState(snapshot.personalRecords)

        workoutLibrary.replaceLibrary(
            workouts: workouts,
            favoriteIDs: favoriteWorkoutIDs,
            organization: currentOrganizationSnapshot()
        )

        switch snapshot.destination {
        case .workout:
            clearComparison()
            workoutLibrary.restoreSessionState(
                manualQuery: snapshot.library.manualQuery,
                activeSmartCollectionID: nil,
                activeSmartCollectionModified: false,
                modifiedWorkingQuery: nil
            )
            workspaceMode = .workout
        case .allRuns:
            clearComparison()
            workoutLibrary.restoreSessionState(
                manualQuery: snapshot.library.manualQuery,
                activeSmartCollectionID: nil,
                activeSmartCollectionModified: false,
                modifiedWorkingQuery: nil
            )
            workspaceMode = .workoutLibrary
        case .smartCollection(let id):
            clearComparison()
            workoutLibrary.restoreSessionState(
                manualQuery: snapshot.library.manualQuery,
                activeSmartCollectionID: id,
                activeSmartCollectionModified: snapshot.library.activeSmartCollectionModified,
                modifiedWorkingQuery: snapshot.library.modifiedWorkingQuery
            )
            workspaceMode = .workoutLibrary
        case .personalHeatmap:
            clearComparison()
            workoutLibrary.restoreSessionState(
                manualQuery: snapshot.library.manualQuery,
                activeSmartCollectionID: nil,
                activeSmartCollectionModified: false,
                modifiedWorkingQuery: nil
            )
            workspaceMode = .personalHeatmap
            personalHeatmap.refresh(workouts: workouts)
        case .trends:
            clearComparison()
            workoutLibrary.restoreSessionState(
                manualQuery: snapshot.library.manualQuery,
                activeSmartCollectionID: nil,
                activeSmartCollectionModified: false,
                modifiedWorkingQuery: nil
            )
            workspaceMode = .trends
            refreshTrends()
            // Restoring into Trends is an open, not a navigation, so it never
            // passes through `showTrends()`. Without this, a pass interrupted
            // by a quit never resumes for someone who relaunches straight
            // back into Trends: the chart silently models only the workouts
            // that happened to finish. Session restore runs after the
            // library-first startup sequence, so the `hasPersistedLibrary`
            // guard inside is already satisfiable here.
            startTrainingLoadBackfillIfNeeded()
        case .personalRecords:
            clearComparison()
            workoutLibrary.restoreSessionState(
                manualQuery: snapshot.library.manualQuery,
                activeSmartCollectionID: nil,
                activeSmartCollectionModified: false,
                modifiedWorkingQuery: nil
            )
            workspaceMode = .personalRecords
            refreshPersonalRecords()
            startPersonalRecordsBackfillIfNeeded()
        case .routeGroups:
            clearComparison()
            workoutLibrary.restoreSessionState(
                manualQuery: snapshot.library.manualQuery,
                activeSmartCollectionID: nil,
                activeSmartCollectionModified: false,
                modifiedWorkingQuery: nil
            )
            workspaceMode = .routeGroups
            refreshRouteGroups()
            startRouteGroupBackfillIfNeeded()
        case .comparison:
            workoutLibrary.restoreSessionState(
                manualQuery: snapshot.library.manualQuery,
                activeSmartCollectionID: nil,
                activeSmartCollectionModified: false,
                modifiedWorkingQuery: nil
            )
            if let peerID = snapshot.comparison?.peerWorkoutID,
               let peer = workouts.first(where: { $0.id == peerID }),
               canCompare(peer) {
                comparisonWorkout = peer
                comparisonSelectionMessage = nil
                selectedComparisonDistanceMeters = snapshot.comparison?.distanceMeters ?? 0
                let restoredMode = ComparisonAlignmentMode(
                    rawValue: snapshot.comparison?.alignmentModeRaw ?? ComparisonAlignmentMode.distance.rawValue
                ) ?? .distance
                comparisonViewModel.restoreAlignmentMode(restoredMode)
                let restoredAlignedProgress = snapshot.comparison?.alignedProgressMeters ?? 0
                workspaceMode = .comparison
                clampComparisonDistance()
                // Recompute Route-Aware from current workout data; do not trust
                // persisted alignment anchors.
                if restoredMode == .routeAware, let pair = comparisonPair {
                    comparisonViewModel.ensureRouteAlignment(
                        pair: pair,
                        primaryContext: analysisContext(for: pair.primary),
                        comparisonContext: analysisContext(for: pair.comparison)
                    )
                }
                // `ensureRouteAlignment` may publish a cached result
                // synchronously. Restore the scalar selection afterwards, then
                // clamp now for a cache hit or when the async result publishes.
                comparisonViewModel.selectedAlignedProgressMeters = restoredAlignedProgress
                if comparisonViewModel.routeAlignmentLoadState == .ready {
                    comparisonViewModel.clampAlignedProgress()
                }
            } else {
                clearComparison()
                workspaceMode = .workout
            }
        }

        if let selectedWorkout,
           let replay = snapshot.replay,
           replay.workoutID == selectedWorkout.id {
            replayController.restore(
                workout: selectedWorkout,
                elapsedSeconds: replay.elapsedSeconds,
                playbackSpeed: replay.playbackSpeed
            )
        } else if let selectedWorkout {
            replayController.load(selectedWorkout)
            replayController.pause()
        }
    }

    // MARK: - Startup

    /// Load the persisted library asynchronously.
    ///
    /// Call from `.task` on the root view. Sets `operationState` to
    /// `.loadingLibrary` while loading and `.idle` when complete.
    /// Always resets to `.idle` even if the task is cancelled.
    func start() async {
        guard let storeActor else {
            loadSampleWorkouts()
            announcementPolicy.handle(.libraryLoaded(count: workouts.count))
            return
        }

        operationState = .loadingLibrary
        defer {
            operationState = .idle
            startWatchFolders()
        }

        let result = await storeActor.loadLibrary()
        applyLibraryLoadResult(result)
        announcementPolicy.handle(.libraryLoaded(count: workouts.count))
    }

    private func applyLibraryLoadResult(_ result: WorkoutLibraryLoadResult) {
        switch result {
        case .demos(let loadErrorMessage, let organization, let manifestPresent):
            analysisContextCache.removeAll()
            workouts = []
            favoriteWorkoutIDs = []
            tags = organization.tags
            smartCollections = organization.smartCollections
            routeGroups = organization.routeGroups
            routeGroupAssignments = organization.routeGroupAssignments
            libraryWorkoutIDs = []
            // Empty persisted libraries still own organisation (and future imports).
            hasPersistedLibrary = manifestPresent
            loadSampleWorkouts(resetOrganization: false)
            if let loadErrorMessage {
                errorMessage = loadErrorMessage
                showingError = true
            }
        case .workouts(let loaded, let selectedWorkoutID, let favoriteIDs, let organization, let warning):
            analysisContextCache.removeAll()
            workouts = loaded
            favoriteWorkoutIDs = favoriteIDs
            tags = organization.tags
            smartCollections = organization.smartCollections
            routeGroups = organization.routeGroups
            routeGroupAssignments = organization.routeGroupAssignments
            personalHeatmap.applyOrganization(organization)
            libraryWorkoutIDs = Set(loaded.map(\.id))
            hasPersistedLibrary = true
            bumpPersonalRecordsLibraryRevision()
            workoutLibrary.replaceLibrary(
                workouts: loaded,
                favoriteIDs: favoriteIDs,
                organization: organization
            )
            let selected = selectedWorkoutID.flatMap { id in
                loaded.first(where: { $0.id == id })
            } ?? loaded.first
            selectWorkout(selected, persistSelection: false)
            if let warning {
                errorMessage = warning
                showingError = true
            }
        }
    }

    /// Load bundled demo workouts.
    ///
    /// - Parameter resetOrganization: When true (default), clear tags/collections and
    ///   mark the library as non-persisted. Empty-library loads keep organisation.
    func loadSampleWorkouts(resetOrganization: Bool = true) {
        let initialCount = workouts.count
        loadBundledWorkout(resource: "sample_run", extension: "json")
        loadBundledWorkout(resource: "comparison_park_run", extension: "json", subdirectory: "fixtures")

        favoriteWorkoutIDs = []
        libraryWorkoutIDs = []
        if resetOrganization {
            tags = []
            smartCollections = []
            hasPersistedLibrary = false
            workoutLibrary.replaceLibrary(workouts: workouts, favoriteIDs: [], organization: .empty)
        } else {
            // Demos are browsable only; keep persisted tags/collections for management.
            workoutLibrary.replaceLibrary(
                workouts: workouts,
                favoriteIDs: [],
                organization: WorkoutLibraryOrganizationSnapshot(
                    tags: tags,
                    tagAssignments: [],
                    smartCollections: smartCollections
                )
            )
        }

        if workouts.count > initialCount {
            selectWorkout(workouts[initialCount], persistSelection: false)
        } else if errorMessage == nil {
            errorMessage = "Bundled demo workouts are unavailable. You can still import a GPX, TCX, FIT, or JSON file."
            showingError = true
        }
    }

    // MARK: - Import

    /// Import a workout from a file URL.
    ///
    /// Parsing and persistence run off the main actor. The UI shows
    /// `.importing(filename:)` while in progress.
    func importWorkout(from url: URL) async {
        guard let importService, let storeActor else { return }
        guard operationState == .idle,
              archiveSession == nil,
              fitSessionImportSession == nil
        else {
            return
        }

        // Only FIT containers are scanned for multiple sessions. GPX, TCX, and
        // JSON always take the direct path.
        if url.pathExtension.lowercased() == "fit",
           await presentFITSessionReviewIfNeeded(from: url) {
            return
        }

        let filename = url.lastPathComponent
        operationState = .importing(filename: filename)
        defer { operationState = .idle }

        do {
            var workout = try await importService.importWorkout(from: url)
            try Task.checkCancellation()
            // Importers analyze with the default profile; re-stamp the load
            // with the current one so fresh imports are never stale. One
            // native call, skipped entirely when the profile is default.
            workout.trainingLoad = try recomputeTrainingLoad(
                for: workout,
                profile: athleteProfile
            )
            try await storeActor.addWorkout(workout, select: true)
            try Task.checkCancellation()
            analysisContextCache.removeValue(forKey: workout.id)

            // First successful import after demos: drop non-persisted demos so
            // favourites/metadata cannot target IDs missing from the manifest.
            if !hasPersistedLibrary || libraryWorkoutIDs.isEmpty {
                analysisContextCache.removeAll()
                workouts = [workout]
                libraryWorkoutIDs = [workout.id]
            } else if let existingIndex = workouts.firstIndex(where: { $0.id == workout.id }) {
                workouts[existingIndex] = workout
                libraryWorkoutIDs.insert(workout.id)
            } else {
                workouts.append(workout)
                libraryWorkoutIDs.insert(workout.id)
            }
            hasPersistedLibrary = true
            bumpPersonalRecordsLibraryRevision()
            workoutLibrary.replaceLibrary(
                workouts: workouts,
                favoriteIDs: favoriteWorkoutIDs,
                organization: currentOrganizationSnapshot()
            )
            // Route-group assignment runs asynchronously after the commit:
            // the import is durable, the run appears on its route when the
            // pass finishes, and an interrupted pass leaves the nil marker.
            startRouteGroupAssignment(for: [workout.id])
            // Selecting a workout exits heatmap / All Runs by design (current product policy).
            selectWorkout(workout, persistSelection: false)
            requestSessionSave()
            announcementPolicy.handle(.importCompleted(name: filename))
        } catch is CancellationError {
            // Cancelled — do not add to UI.
            announcementPolicy.handle(.importCancelled)
        } catch let error as WorkoutImportError {
            errorMessage = importErrorMessage(for: error, filename: filename)
            showingError = true
            announcementPolicy.handle(
                .importFailed(message: errorMessage ?? error.localizedDescription)
            )
        } catch {
            errorMessage = "Imported but could not save to your library. "
                + "Check available storage and app permissions. Details: \(error.localizedDescription)"
            showingError = true
            announcementPolicy.handle(
                .importFailed(message: errorMessage ?? error.localizedDescription)
            )
        }
    }

    func importErrorMessage(for error: WorkoutImportError, filename: String) -> String {
        if let shared = Self.parseLevelImportErrorMessage(for: error, filename: filename) {
            return shared
        }
        switch error {
        case .unsupportedFormat(let ext):
            return "'\(filename)' uses the .\(ext) format, which isn't supported. Import a GPX, TCX, FIT, or JSON file instead."
        case .fileNotFound:
            return "Couldn't find the selected file. Try importing again."
        case .parsingError, .missingData, .invalidFormat:
            // Unreachable: handled by the shared helper above.
            return "'\(filename)' could not be imported."
        }
    }

    /// Wording for the parse-level failures, shared by every import entry point
    /// so it cannot drift between them.
    ///
    /// These three are identical no matter how the file was selected: the user
    /// cannot act differently on a malformed file reached through a picker
    /// versus one that arrived in a watched folder. Returns nil for
    /// `.unsupportedFormat` and `.fileNotFound`, whose wording genuinely
    /// depends on the entry point and is therefore owned by each caller.
    static func parseLevelImportErrorMessage(
        for error: WorkoutImportError,
        filename: String
    ) -> String? {
        switch error {
        case .parsingError(let detail):
            return "'\(filename)' couldn't be parsed. \(detail)"
        case .missingData(let detail):
            return "'\(filename)' is missing required data. \(detail)"
        case .invalidFormat(let detail):
            return "'\(filename)' has an invalid format. \(detail)"
        case .unsupportedFormat, .fileNotFound:
            return nil
        }
    }

    private func loadBundledWorkout(resource: String, extension fileExtension: String, subdirectory: String? = nil) {
        let resourceSubdirectory = ["Resources", subdirectory]
            .compactMap { $0 }
            .joined(separator: "/")
        if let url = Bundle.module.url(
            forResource: resource,
            withExtension: fileExtension,
            subdirectory: resourceSubdirectory
        ) {
            loadWorkoutFromBundled(url: url)
        }
    }

    /// Load a bundled workout WITHOUT persisting it (bundled demos are not user library entries).
    private func loadWorkoutFromBundled(url: URL) {
        do {
            let workout = try WorkoutImporterFactory.importWorkout(from: url)
            workouts.append(workout)
            // Use persisted segments from the analyzed workout.
            detectedSegments = workout.segments
        } catch {
            // Silently skip bundled workouts that fail to load.
        }
    }

    // MARK: - Selection

    /// Select a workout for viewing.
    ///
    /// Selecting a workout exits heatmap and, when the selected workout is the
    /// comparison peer, clears comparison. Selection persistence is unchanged.
    ///
    /// UI state updates immediately. If `persistSelection` is true, the
    /// manifest write is asynchronous with last-write-wins semantics.
    func selectWorkout(_ workout: RunWorkout?, persistSelection: Bool = true) {
        selectedWorkout = workout
        selectedSegment = nil
        if workout?.id != highlightedWorkoutRange?.workoutID {
            highlightedWorkoutRange = nil
        }
        switch workspaceMode {
        case .personalHeatmap, .trends, .personalRecords, .routeGroups, .workoutLibrary:
            cancelActiveWorkspaceWork()
            workspaceMode = .workout
        case .workout, .comparison:
            break
        }
        if let workout, comparisonWorkout?.id == workout.id {
            clearComparison()
        } else if workspaceMode == .comparison, workout == nil {
            clearComparison()
        }
        if let workout = workout {
            replayController.load(workout)
            // Use persisted segments instead of recomputing.
            detectedSegments = workout.segments
        } else {
            detectedSegments = []
        }

        if persistSelection, let storeActor {
            let id = workout?.id
            selectionTask?.cancel()
            selectionTask = Task { [weak self] in
                do {
                    try await storeActor.setSelectedWorkoutID(id)
                    self?.requestSessionSave()
                } catch is CancellationError {
                    // A newer selection superseded this one.
                } catch {
                    self?.errorMessage = "Selection changed, but could not be saved: \(error.localizedDescription)"
                    self?.showingError = true
                }
            }
        } else if persistSelection {
            requestSessionSave()
        }
    }

    // MARK: - Deletion

    /// Delete a workout.
    ///
    /// The manifest transaction runs off the main actor. UI state updates
    /// only after the logical deletion commits.
    func deleteWorkout(_ workout: RunWorkout) async {
        guard operationState == .idle else { return }
        let deletingSelectedWorkout = selectedWorkout?.id == workout.id
        let deletingComparisonWorkout = comparisonWorkout?.id == workout.id
        let newSelectedID = deletingSelectedWorkout
            ? workouts.first(where: { $0.id != workout.id })?.id
            : nil

        // Cancel pending selection persistence to prevent a stale write
        // from saving the deleted workout as selected after removal.
        selectionTask?.cancel()

        if let storeActor {
            operationState = .deleting(workoutID: workout.id)
            defer { operationState = .idle }

            do {
                // Persist the deletion. The actor handles manifest transaction.
                // We ignore the result and always use the UI-level selection
                // snapshot, because the UI state is authoritative for display.
                try await storeActor.deleteWorkout(
                    id: workout.id,
                    newSelectedID: newSelectedID
                )

                // Always use the UI-level selection snapshot. The actor's
                // manifest may disagree if selection persistence was pending
                // or failed, but the UI state is authoritative for display.
                workouts.removeAll { $0.id == workout.id }
                favoriteWorkoutIDs.remove(workout.id)
                libraryWorkoutIDs.remove(workout.id)
                analysisContextCache.removeValue(forKey: workout.id)
                workoutLibrary.removeWorkout(id: workout.id)
                applyDeletionSelection(
                    deletingSelectedWorkout: deletingSelectedWorkout,
                    deletingComparisonWorkout: deletingComparisonWorkout
                )
            } catch let storeError as WorkoutLibraryStoreError {
                // Manifest committed but file is orphaned. Remove from UI and warn.
                workouts.removeAll { $0.id == workout.id }
                favoriteWorkoutIDs.remove(workout.id)
                libraryWorkoutIDs.remove(workout.id)
                analysisContextCache.removeValue(forKey: workout.id)
                workoutLibrary.removeWorkout(id: workout.id)
                applyDeletionSelection(
                    deletingSelectedWorkout: deletingSelectedWorkout,
                    deletingComparisonWorkout: deletingComparisonWorkout
                )
                errorMessage = storeError.localizedDescription
                showingError = true
            } catch let deleteError {
                // Manifest transaction failed. No changes were made.
                errorMessage = "Could not delete workout; no changes were made: \(deleteError.localizedDescription)"
                showingError = true
            }
        } else {
            // No store: just update in-memory state (demo-only mode).
            workouts.removeAll { $0.id == workout.id }
            favoriteWorkoutIDs.remove(workout.id)
            libraryWorkoutIDs.remove(workout.id)
            analysisContextCache.removeValue(forKey: workout.id)
            workoutLibrary.removeWorkout(id: workout.id)
            applyDeletionSelection(
                deletingSelectedWorkout: deletingSelectedWorkout,
                deletingComparisonWorkout: deletingComparisonWorkout
            )
        }
        bumpPersonalRecordsLibraryRevision()
        // The actor repaired route-group membership transactionally; mirror
        // the persisted organization so Routes and the route filter agree.
        Task { @MainActor in
            await self.refreshRouteGroupOrganization()
        }
        requestSessionSave()
    }

    private func applyDeletionSelection(
        deletingSelectedWorkout: Bool,
        deletingComparisonWorkout: Bool
    ) {
        // A library-level workspace stays visible across a deletion; the
        // workout workspace instead follows the selection.
        let libraryWorkspace: AppWorkspaceMode?
        switch workspaceMode {
        case .personalHeatmap, .trends, .personalRecords, .routeGroups, .workoutLibrary:
            libraryWorkspace = workspaceMode
        case .workout, .comparison:
            libraryWorkspace = nil
        }
        if deletingSelectedWorkout {
            clearComparison()
            if let libraryWorkspace {
                selectedWorkout = workouts.first
                selectedSegment = nil
                if let selectedWorkout {
                    replayController.load(selectedWorkout)
                    detectedSegments = selectedWorkout.segments
                } else {
                    detectedSegments = []
                }
                workspaceMode = libraryWorkspace
                refreshLibraryWorkspace()
            } else {
                selectWorkout(workouts.first, persistSelection: false)
            }
        } else if deletingComparisonWorkout {
            clearComparison()
            if let libraryWorkspace {
                workspaceMode = libraryWorkspace
                refreshLibraryWorkspace()
            }
        } else if libraryWorkspace != nil {
            refreshLibraryWorkspace()
        }
    }

    /// Re-derive the visible library-level workspace after the library changed.
    private func refreshLibraryWorkspace() {
        switch workspaceMode {
        case .personalHeatmap:
            personalHeatmap.refresh(workouts: workouts)
        case .trends:
            refreshTrends()
        case .personalRecords:
            refreshPersonalRecords()
        case .routeGroups:
            refreshRouteGroups()
        case .workout, .comparison, .workoutLibrary:
            break
        }
    }

    // MARK: - Workspace navigation

    /// Handle a window-wide command that may arrive without a focused scene.
    func handleWorkspaceCommand(_ command: AppWorkspaceCommand) {
        switch command {
        case .showPersonalHeatmap:
            showPersonalHeatmap()
        case .showTrends:
            showTrends()
        case .showPersonalRecords:
            showPersonalRecords()
        case .showRouteGroups:
            showRouteGroups()
        case .showAllRuns:
            showWorkoutLibrary(restoreManualQuery: true)
        }
    }

    /// Open the All Runs library workspace. Does not clear selected workout.
    ///
    /// When `restoreManualQuery` is true and a smart collection is active, the
    /// session manual query is restored once. Re-selecting All Runs while already
    /// in the manual context must not re-apply a stale snapshot over live edits.
    func showWorkoutLibrary(restoreManualQuery: Bool = false) {
        cancelActiveWorkspaceWork()
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        comparisonViewModel.clear()
        workspaceMode = .workoutLibrary
        if restoreManualQuery, case .smartCollection = workoutLibrary.queryContext {
            workoutLibrary.returnToManualQuery(clearSnapshot: true)
        }
        // Ensure the library index tracks the current in-memory library.
        workoutLibrary.replaceLibrary(
            workouts: workouts,
            favoriteIDs: favoriteWorkoutIDs,
            organization: currentOrganizationSnapshot()
        )
        requestSessionSave()
    }

    /// Open All Runs under a smart collection.
    func showSmartCollection(id: UUID) {
        cancelActiveWorkspaceWork()
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        comparisonViewModel.clear()
        workspaceMode = .workoutLibrary
        workoutLibrary.replaceLibrary(
            workouts: workouts,
            favoriteIDs: favoriteWorkoutIDs,
            organization: currentOrganizationSnapshot()
        )
        workoutLibrary.openSmartCollection(id: id)
        requestSessionSave()
    }

    /// Open All Runs with the favourites-only filter applied.
    func showAllFavoritesInLibrary() {
        showWorkoutLibrary(restoreManualQuery: true)
        workoutLibrary.showAllFavorites()
        requestSessionSave()
    }

    func currentOrganizationSnapshot() -> WorkoutLibraryOrganizationSnapshot {
        // Prefer live All Runs entry assignments so in-session tag edits stay
        // coherent across replaceLibrary without reloading the manifest.
        let assignments = workoutLibrary.entries.compactMap { entry -> WorkoutTagAssignment? in
            guard !entry.tagIDs.isEmpty else { return nil }
            return WorkoutTagAssignment(workoutID: entry.id, tagIDs: entry.tagIDs)
        }
        return WorkoutLibraryOrganizationSnapshot(
            tags: tags,
            tagAssignments: assignments,
            smartCollections: smartCollections,
            routeGroups: routeGroups,
            routeGroupAssignments: routeGroupAssignments
        )
    }

    /// Open a workout from All Runs (enters `.workout`).
    func openWorkoutFromLibrary(_ workout: RunWorkout) {
        selectWorkout(workout)
    }

    /// Cancel the background work owned by the workspace being left.
    ///
    /// Every workspace transition routes through here rather than testing for
    /// each workspace at each call site: only the current workspace can have
    /// work in flight, so one switch covers them all and the next workspace
    /// added needs one case, not a guard at every transition.
    private func cancelActiveWorkspaceWork() {
        switch workspaceMode {
        case .personalHeatmap:
            personalHeatmap.cancel()
        case .trends:
            trends.cancel()
        case .personalRecords:
            personalRecords.cancel()
        case .routeGroups:
            routeGroupReclusterTask?.cancel()
        case .workout, .comparison, .workoutLibrary:
            break
        }
    }

    /// Open the Personal Heatmap workspace. Does not change selected workout.
    func showPersonalHeatmap() {
        cancelActiveWorkspaceWork()
        // Leave comparison / All Runs cleanly; workspaces are mutually exclusive.
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        comparisonViewModel.clear()
        workspaceMode = .personalHeatmap
        personalHeatmap.refresh(workouts: workouts)
        requestSessionSave()
    }

    /// Open the Trends workspace. Does not change selected workout.
    ///
    /// When All Runs currently shows a smart collection and Trends is still on
    /// the entire-library default, the scope preselects that collection so
    /// trends respect the active filter.
    func showTrends() {
        cancelActiveWorkspaceWork()
        if !trends.hasBeenOpened,
           case .entireLibrary = trends.scope,
           case .smartCollection(let id, _) = workoutLibrary.queryContext {
            trends.scope = .smartCollection(id)
        }
        trends.markOpened()
        // Leave comparison / All Runs cleanly; workspaces are mutually exclusive.
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        comparisonViewModel.clear()
        workspaceMode = .trends
        refreshTrends()
        startTrainingLoadBackfillIfNeeded()
        requestSessionSave()
    }

    /// Gather current library/query state and re-aggregate Trends.
    func refreshTrends() {
        trends.refresh(inputs: TrendsRefreshInputs(
            workouts: workouts,
            entries: workoutLibrary.entries,
            documents: workoutLibrary.searchDocuments,
            smartCollections: smartCollections,
            currentQuery: workoutLibrary.currentRuntimeQuery()
        ))
    }

    // MARK: - Routes workspace

    /// Open the Routes workspace. Does not change selected workout.
    func showRouteGroups() {
        cancelActiveWorkspaceWork()
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        comparisonViewModel.clear()
        workspaceMode = .routeGroups
        refreshRouteGroups()
        startRouteGroupBackfillIfNeeded()
        requestSessionSave()
    }

    /// Re-derive route-group rows from the current library and organization.
    func refreshRouteGroups() {
        routeGroupsViewModel.refresh(
            workouts: workouts,
            organization: currentOrganizationSnapshot()
        )
    }

    /// Handle for the active post-import assignment pass.
    private var routeGroupAssignmentTask: Task<Void, Never>?

    /// Handle for the active full re-cluster pass.
    private var routeGroupReclusterTask: Task<Void, Never>?

    /// Handle for the one-off assignment backfill.
    private var routeGroupBackfillTask: Task<Void, Never>?

    /// Asynchronously assign recently imported workouts to route groups.
    ///
    /// Runs after the import commit; an interrupted pass leaves those
    /// workouts without assignment records (the nil marker), and the next
    /// pass retries them. The library-wide route-groups revision bumps once,
    /// when the pass finishes.
    func startRouteGroupAssignment(for workoutIDs: [UUID]) {
        guard routeGroupAssignmentTask == nil,
              let storeActor,
              hasPersistedLibrary,
              !workoutIDs.isEmpty else {
            return
        }
        routeGroupsViewModel.assignmentStarted()
        let progress = makeRouteGroupProgressHandler()
        routeGroupAssignmentTask = Task { [weak self] in
            let result = try? await storeActor.assignRouteGroups(
                for: workoutIDs,
                progress: progress
            )
            self?.finishRouteGroupAssignmentPass(result)
        }
    }

    /// Start the one-off backfill for workouts whose assignment record is
    /// missing (schema v4 libraries) or produced by an older algorithm
    /// version. Auto-starts the first time Routes opens with pending work.
    func startRouteGroupBackfillIfNeeded() {
        guard routeGroupBackfillTask == nil,
              routeGroupAssignmentTask == nil,
              let storeActor,
              hasPersistedLibrary,
              routeGroupsViewModel.pendingAssignmentCount > 0 else {
            return
        }
        routeGroupsViewModel.assignmentStarted()
        let progress = makeRouteGroupProgressHandler()
        routeGroupBackfillTask = Task { [weak self] in
            let result = try? await storeActor.backfillRouteGroupAssignments(progress: progress)
            self?.routeGroupBackfillTask = nil
            self?.finishRouteGroupAssignmentPass(result)
        }
    }

    private func makeRouteGroupProgressHandler() -> @Sendable (RouteGroupingPassProgress) -> Void {
        { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                self.routeGroupsViewModel.assignmentProgress(
                    currentWorkoutName: update.currentWorkoutName
                )
            }
        }
    }

    private func finishRouteGroupAssignmentPass(
        _ result: WorkoutLibraryStoreActor.RouteGroupAssignmentPassResult?
    ) {
        routeGroupAssignmentTask = nil
        routeGroupsViewModel.assignmentFinished()
        if let result {
            applyRouteGroupPassResult(
                groups: result.groups,
                assignments: result.assignments
            )
        }
        if !isRouteGroupPassRunning {
            bumpRouteGroupsLibraryRevision()
            refreshRouteGroups()
        }
    }

    /// Run a full re-cluster with progress and cancellation. A cancelled or
    /// failed pass leaves the previous groups untouched on disk and in
    /// memory; the visible list is only replaced on success.
    func reclusterRouteGroups() {
        guard routeGroupReclusterTask == nil,
              let storeActor,
              hasPersistedLibrary,
              !workouts.isEmpty else {
            return
        }
        routeGroupsViewModel.reclusterStarted(totalCount: workouts.count)
        let progress: @Sendable (RouteGroupingPassProgress) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                self.routeGroupsViewModel.reclusterProgress(
                    completedCount: update.completedCount,
                    totalCount: update.totalCount,
                    currentWorkoutName: update.currentWorkoutName
                )
            }
        }
        routeGroupReclusterTask = Task { [weak self] in
            do {
                let result = try await storeActor.reclusterRouteGroups(progress: progress)
                self?.applyRouteGroupPassResult(
                    groups: result.groups,
                    assignments: result.assignments
                )
                self?.routeGroupsViewModel.reclusterFinished(summary: String(
                    format: String(localized: "route_group.recluster.summary", defaultValue: "%d runs on %d routes"),
                    result.workoutCount,
                    result.groups.count
                ))
                self?.bumpRouteGroupsLibraryRevision()
                self?.refreshRouteGroups()
            } catch is CancellationError {
                self?.routeGroupsViewModel.reclusterFinished(summary: nil)
            } catch {
                self?.routeGroupsViewModel.reclusterFinished(summary: nil)
                self?.errorMessage = "Could not re-cluster routes; the previous routes are unchanged: \(error.localizedDescription)"
                self?.showingError = true
            }
            self?.routeGroupReclusterTask = nil
        }
    }

    /// Whether a route-group pass is currently running.
    var isRouteGroupPassRunning: Bool {
        routeGroupAssignmentTask != nil
            || routeGroupBackfillTask != nil
            || routeGroupReclusterTask != nil
    }

    /// Cancel the active full re-cluster. The previous groups stay intact.
    func cancelRouteGroupRecluster() {
        routeGroupReclusterTask?.cancel()
    }

    /// Apply a pass result to in-memory organization state and rebuild the
    /// All Runs entries that carry route membership.
    func applyRouteGroupPassResult(
        groups: [WorkoutRouteGroup],
        assignments: [WorkoutRouteGroupAssignment]
    ) {
        routeGroups = groups
        routeGroupAssignments = assignments
        let organization = currentOrganizationSnapshot()
        workoutLibrary.replaceLibrary(
            workouts: workouts,
            favoriteIDs: favoriteWorkoutIDs,
            organization: organization
        )
        // The heatmap route picker reads the heatmap view model's own copy
        // of the organization; without this hand-off a group created by the
        // post-import pass (or a re-cluster) reached the All Runs filter but
        // not the picker until the next relaunch or manual route control.
        personalHeatmap.applyOrganization(organization)
    }

    /// Reload route-group organization from the persisted manifest after the
    /// actor mutated it (deletion, manual controls).
    func refreshRouteGroupOrganization() async {
        guard let storeActor else { return }
        guard let organization = await storeActor.organizationSnapshot() else { return }
        routeGroups = organization.routeGroups
        routeGroupAssignments = organization.routeGroupAssignments
        workoutLibrary.applyOrganizationSnapshot(
            currentOrganizationSnapshot(),
            schedule: true
        )
        personalHeatmap.applyOrganization(currentOrganizationSnapshot())
        bumpRouteGroupsLibraryRevision()
        refreshRouteGroups()
    }

    // MARK: - Route group manual controls

    func renameRouteGroup(id: UUID, name: String?) async {
        guard let storeActor else { return }
        do {
            try await storeActor.renameRouteGroup(id: id, name: name)
            await refreshRouteGroupOrganization()
        } catch {
            organizationEditError = error.localizedDescription
        }
    }

    func mergeRouteGroups(sourceID: UUID, into targetID: UUID) async {
        guard let storeActor else { return }
        do {
            try await storeActor.mergeRouteGroups(sourceID: sourceID, into: targetID)
            await refreshRouteGroupOrganization()
        } catch {
            organizationEditError = error.localizedDescription
        }
    }

    func removeWorkoutFromRouteGroup(workoutID: UUID) async {
        guard let storeActor else { return }
        do {
            try await storeActor.removeWorkoutFromRouteGroup(workoutID: workoutID)
            await refreshRouteGroupOrganization()
        } catch {
            organizationEditError = error.localizedDescription
        }
    }

    func pinRouteGroupRepresentative(groupID: UUID, workoutID: UUID) async {
        guard let storeActor else { return }
        do {
            try await storeActor.pinRouteGroupRepresentative(groupID: groupID, workoutID: workoutID)
            await refreshRouteGroupOrganization()
        } catch {
            organizationEditError = error.localizedDescription
        }
    }

    // MARK: - Personal Records workspace

    /// Open the Personal Records workspace. Does not change selected workout.
    ///
    /// When All Runs currently shows a smart collection and Records is still
    /// on the entire-library default, the scope preselects that collection so
    /// records respect the active filter (same first-open rule as Trends).
    func showPersonalRecords() {
        cancelActiveWorkspaceWork()
        if !personalRecordsHasBeenOpened,
           case .entireLibrary = personalRecords.scope,
           case .smartCollection(let id, _) = workoutLibrary.queryContext {
            personalRecords.scope = .smartCollection(id)
        }
        personalRecordsHasBeenOpened = true
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        comparisonViewModel.clear()
        workspaceMode = .personalRecords
        refreshPersonalRecords()
        startPersonalRecordsBackfillIfNeeded()
        requestSessionSave()
    }

    /// Whether Records has been opened with a user-selected scope this
    /// process. See `TrendsViewModel.hasBeenOpened` for the preselect rule.
    private var personalRecordsHasBeenOpened = false

    /// Gather current library/query state and re-aggregate Personal Records.
    func refreshPersonalRecords() {
        personalRecords.refresh(inputs: PersonalRecordsRefreshInputs(
            workouts: workouts,
            entries: workoutLibrary.entries,
            documents: workoutLibrary.searchDocuments,
            smartCollections: smartCollections,
            currentQuery: workoutLibrary.currentRuntimeQuery()
        ))
    }

    /// Open the workout behind one record effort, seek the replay position to
    /// the window start, and highlight the window range on the map and charts.
    /// Whole-run records (longest run, biggest ascent) open the workout
    /// without a range highlight.
    func openPersonalRecord(_ effort: PersonalRecordEffort) {
        guard let workout = workouts.first(where: { $0.id == effort.workoutID }) else {
            return
        }
        highlightedWorkoutRange = effort.window.map {
            HighlightedWorkoutRange(
                workoutID: effort.workoutID,
                startDistanceMeters: $0.startDistanceMeters,
                endDistanceMeters: $0.endDistanceMeters
            )
        }
        selectWorkout(workout)
        workoutDetailTabRaw = "Overview"
        if let window = effort.window {
            replayController.seekToDistance(window.startDistanceMeters)
        }
    }

    /// Handle for the active one-off records backfill.
    private var personalRecordsBackfillTask: Task<Void, Never>?

    /// Start the one-off library backfill for snapshots that predate record
    /// computation. Auto-starts the first time the Records workspace opens
    /// with pending work; never runs during library load. Each computed
    /// snapshot is applied in memory as it arrives so no work is lost, and
    /// the table re-aggregates once when the pass ends; cancellation keeps
    /// every completed snapshot and the pass resumes on the next open.
    func startPersonalRecordsBackfillIfNeeded() {
        guard personalRecordsBackfillTask == nil,
              let storeActor,
              hasPersistedLibrary,
              workouts.contains(where: { $0.personalRecords == nil }) else {
            return
        }
        // The pass walks the whole manifest, skipping snapshots that already
        // carry records, and reports progress against that total. Seeding the
        // banner with the pending count instead would make the first real
        // update jump to a different denominator.
        personalRecords.backfillStarted(totalCount: workouts.count)
        let applyUpdate: @Sendable (
            WorkoutLibraryStoreActor.PersonalRecordsBackfillUpdate
        ) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                self.applyPersonalRecordsBackfillUpdate(update)
            }
        }
        personalRecordsBackfillTask = Task { [weak self] in
            let result = await storeActor.backfillPersonalRecords(progress: applyUpdate)
            self?.finishPersonalRecordsBackfill(result)
        }
    }

    private func applyPersonalRecordsBackfillUpdate(
        _ update: WorkoutLibraryStoreActor.PersonalRecordsBackfillUpdate
    ) {
        guard workspaceMode == .personalRecords || personalRecordsBackfillTask != nil else {
            return
        }
        personalRecords.backfillProgress(
            completedCount: update.completedCount,
            totalCount: update.totalCount,
            currentWorkoutName: update.currentWorkoutName
        )
        guard let computed = update.computedWorkout,
              let index = workouts.firstIndex(where: { $0.id == computed.id }) else {
            return
        }
        workouts[index] = computed
        // No library rebuild here: library entries and search documents are
        // derived from metadata and summaries, never from record windows, so
        // a per-workout replaceLibrary would rebuild every entry and re-run
        // the All Runs query once per backfilled run for no visible change.
        //
        // The records-library revision deliberately does not bump here
        // either: a backfill updates workouts one at a time, and each bump
        // would make the visible workout detail re-aggregate the whole
        // library. The single bump in finishPersonalRecordsBackfill covers
        // the pass.
    }

    private func finishPersonalRecordsBackfill(
        _ result: WorkoutLibraryStoreActor.PersonalRecordsBackfillResult
    ) {
        personalRecordsBackfillTask = nil
        let failureMessage = Self.personalRecordsBackfillFailureMessage(result)
        personalRecords.backfillFinished(failureMessage: failureMessage)
        bumpPersonalRecordsLibraryRevision()
        refreshPersonalRecords()
        requestSessionSave()
    }

    /// The inline banner text for a finished pass, or `nil` when every
    /// workout was analyzed and saved. Analysis failures are retried the next
    /// time Records opens; a save failure leaves the in-memory snapshot
    /// complete, so only a later launch re-reads the incomplete file.
    static func personalRecordsBackfillFailureMessage(
        _ result: WorkoutLibraryStoreActor.PersonalRecordsBackfillResult
    ) -> String? {
        var clauses: [String] = []
        if result.failedCount > 0 {
            clauses.append(
                result.failedCount == 1
                    ? "1 run could not be analyzed; it will be retried the next time you open Records"
                    : "\(result.failedCount) runs could not be analyzed; they will be retried the next time you open Records"
            )
        }
        if result.saveFailureCount > 0 {
            clauses.append(
                result.saveFailureCount == 1
                    ? "1 run was analyzed but could not be saved; it will be recomputed on the next launch"
                    : "\(result.saveFailureCount) runs were analyzed but could not be saved; they will be recomputed on the next launch"
            )
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: ". ") + "."
    }

    /// Cancel the active records backfill (Records-view Cancel button).
    /// Completed snapshots stay saved; the pass resumes on the next open.
    func cancelPersonalRecordsBackfill() {
        personalRecordsBackfillTask?.cancel()
    }

    /// Navigate from a Trends period to All Runs filtered to that period.
    ///
    /// The filter uses the period bounds in the system zone; a run recorded
    /// abroad near a period boundary can therefore contribute to a bar whose
    /// filter excludes it (and vice versa) — an accepted display edge for
    /// mixed-zone libraries. Manual search/tag filters are preserved; an
    /// active smart collection becomes Modified through the normal path.
    func showWorkoutsInTrendsPeriod(_ key: WorkoutTrendsPeriodKey) {
        cancelActiveWorkspaceWork()
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        comparisonViewModel.clear()
        workspaceMode = .workoutLibrary
        workoutLibrary.replaceLibrary(
            workouts: workouts,
            favoriteIDs: favoriteWorkoutIDs,
            organization: currentOrganizationSnapshot()
        )
        let bounds = WorkoutTrendsAggregator.periodBounds(for: key, timeZone: .current)
        workoutLibrary.applyTrendsPeriodFilter(start: bounds.start, end: bounds.end)
        requestSessionSave()
    }

    /// Return to the selected workout workspace (if any).
    func showWorkoutWorkspace() {
        cancelActiveWorkspaceWork()
        if workspaceMode == .comparison {
            comparisonWorkout = nil
            comparisonSelectionMessage = nil
            selectedComparisonDistanceMeters = 0
            comparisonViewModel.clear()
        }
        workspaceMode = .workout
        requestSessionSave()
    }

    private func enterComparisonWorkspace() {
        cancelActiveWorkspaceWork()
        workspaceMode = .comparison
        requestSessionSave()
    }

    // MARK: - Training load

    /// Handle for the active one-off training-load backfill.
    private var trainingLoadBackfillTask: Task<Void, Never>?

    /// Start the one-off library backfill for snapshots that predate
    /// training-load computation. Auto-starts the first time Trends opens
    /// with pending work; never runs during library load. Profile-change
    /// recomputes go through the same store-actor pass but are
    /// user-triggered, so a custom profile never forces a full disk walk on
    /// every open. Each computed snapshot is applied in memory as it
    /// arrives; Trends recomputes once when the pass ends. Cancellation
    /// keeps every completed snapshot and the pass resumes on the next open.
    func startTrainingLoadBackfillIfNeeded() {
        guard trainingLoadBackfillTask == nil,
              let storeActor,
              hasPersistedLibrary,
              workouts.contains(where: { $0.trainingLoad == nil }) else {
            return
        }
        trends.trainingLoadBackfillStarted(totalCount: workouts.count)
        let applyUpdate: @Sendable (
            WorkoutLibraryStoreActor.TrainingLoadBackfillUpdate
        ) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                self.applyTrainingLoadBackfillUpdate(update)
            }
        }
        let profile = athleteProfile
        trainingLoadBackfillTask = Task { [weak self] in
            let result = await storeActor.backfillTrainingLoad(
                profile: profile,
                progress: applyUpdate
            )
            self?.finishTrainingLoadBackfill(result)
        }
    }

    private func applyTrainingLoadBackfillUpdate(
        _ update: WorkoutLibraryStoreActor.TrainingLoadBackfillUpdate
    ) {
        guard workspaceMode == .trends || trainingLoadBackfillTask != nil else {
            return
        }
        trends.trainingLoadBackfillProgress(
            completedCount: update.completedCount,
            totalCount: update.totalCount,
            currentWorkoutName: update.currentWorkoutName
        )
        guard let computed = update.computedWorkout,
              let index = workouts.firstIndex(where: { $0.id == computed.id }) else {
            return
        }
        workouts[index] = computed
        // No library rebuild and no revision bump per workout: entries and
        // search documents derive from metadata and summaries, never from
        // training loads. The single refresh after the pass covers Trends,
        // whose cache key carries each snapshot's training-load digest.
    }

    private func finishTrainingLoadBackfill(
        _ result: WorkoutLibraryStoreActor.TrainingLoadBackfillResult
    ) {
        trainingLoadBackfillTask = nil
        trends.trainingLoadBackfillFinished(
            failureMessage: Self.trainingLoadBackfillFailureMessage(result)
        )
        refreshTrends()
        requestSessionSave()
    }

    private static func trainingLoadBackfillFailureMessage(
        _ result: WorkoutLibraryStoreActor.TrainingLoadBackfillResult
    ) -> String? {
        if result.failedCount > 0 && result.saveFailureCount > 0 {
            return "Training load could not be computed for \(result.failedCount) run(s) and could not be saved for \(result.saveFailureCount) run(s). They will be retried next time Trends opens."
        }
        if result.failedCount > 0 {
            return "Training load could not be computed for \(result.failedCount) run(s). They will be retried next time Trends opens."
        }
        if result.saveFailureCount > 0 {
            return "Training load could not be saved for \(result.saveFailureCount) run(s). They will be retried next time Trends opens."
        }
        return nil
    }

    /// Whether a training-load pass (backfill or recompute) is running.
    var trainingLoadBackfillTaskActive: Bool {
        trainingLoadBackfillTask != nil
    }

    /// Workouts whose stored load is missing or was computed under a
    /// different profile — exactly what an explicit recompute would fix.
    var staleTrainingLoadCount: Int {
        workouts.count { $0.trainingLoad?.isCurrent(for: athleteProfile) != true }
    }

    /// Explicit, user-triggered recompute over the whole library under the
    /// current profile. The same resumable store-actor pass as the backfill;
    /// progress reports to the Settings scene instead of the Trends banner.
    func recomputeTrainingLoads() {
        guard trainingLoadBackfillTask == nil,
              let storeActor,
              hasPersistedLibrary else {
            return
        }
        trainingLoadRecomputeState = .running(
            completedCount: 0,
            totalCount: workouts.count,
            currentWorkoutName: ""
        )
        let applyUpdate: @Sendable (
            WorkoutLibraryStoreActor.TrainingLoadBackfillUpdate
        ) -> Void = { [weak self] update in
            guard let self else { return }
            Task { @MainActor in
                self.applyTrainingLoadRecomputeUpdate(update)
            }
        }
        let profile = athleteProfile
        trainingLoadBackfillTask = Task { [weak self] in
            let result = await storeActor.backfillTrainingLoad(
                profile: profile,
                progress: applyUpdate
            )
            self?.finishTrainingLoadRecompute(result)
        }
    }

    /// Cancel the active pass; completed snapshots stay saved and the pass
    /// resumes on the next trigger.
    func cancelTrainingLoadPass() {
        trainingLoadBackfillTask?.cancel()
    }

    private func applyTrainingLoadRecomputeUpdate(
        _ update: WorkoutLibraryStoreActor.TrainingLoadBackfillUpdate
    ) {
        applyTrainingLoadBackfillUpdate(update)
        trainingLoadRecomputeState = .running(
            completedCount: update.completedCount,
            totalCount: update.totalCount,
            currentWorkoutName: update.currentWorkoutName
        )
    }

    private func finishTrainingLoadRecompute(
        _ result: WorkoutLibraryStoreActor.TrainingLoadBackfillResult
    ) {
        trainingLoadRecomputeState = Self.trainingLoadBackfillFailureMessage(result)
            .map { .failed($0) } ?? .idle
        // Shared completion (resets the task, refreshes Trends once).
        finishTrainingLoadBackfill(result)
    }

    /// Persist a profile edit. Loads computed under a different profile are
    /// stale by the snapshot's own rule; recompute is explicit so a profile
    /// edit never kicks off silent background work.
    func updateAthleteProfile(_ profile: AthleteProfile) {
        athleteProfile = profile
        if let profileStore {
            do {
                try profileStore.save(profile)
            } catch {
                errorMessage = "Athlete profile could not be saved: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    /// Recompute one workout's load under `profile` (import re-stamp).
    func recomputeTrainingLoad(
        for workout: RunWorkout,
        profile: AthleteProfile
    ) throws -> TrainingLoadSnapshot? {
        guard profile != AthleteProfile() else { return workout.trainingLoad }
        return try TrainingLoadCalculator.compute(
            for: workout,
            profile: profile,
            referenceYear: Calendar.current.component(.year, from: Date())
        )
    }

    // MARK: - Favourites & metadata

    /// Whether favourite actions apply (imported library workouts only).
    func canFavorite(_ workout: RunWorkout) -> Bool {
        canEditLibraryMetadata(workout)
    }

    /// Whether name/notes editing applies (persisted library IDs only, never demos).
    func canEditLibraryMetadata(_ workout: RunWorkout) -> Bool {
        storeActor != nil
            && hasPersistedLibrary
            && libraryWorkoutIDs.contains(workout.id)
    }

    /// Toggle favourite for a library workout. No-op / error for demos.
    @discardableResult
    func setFavorite(_ isFavorite: Bool, workoutID: UUID) async -> Bool {
        guard let storeActor, hasPersistedLibrary, libraryWorkoutIDs.contains(workoutID) else {
            errorMessage = "Favourites apply to imported library workouts, not bundled demos."
            showingError = true
            return false
        }
        guard let workout = workouts.first(where: { $0.id == workoutID }) else {
            return false
        }
        guard canFavorite(workout) else {
            errorMessage = "Favourites apply to imported library workouts, not bundled demos."
            showingError = true
            return false
        }
        do {
            try await storeActor.setFavorite(isFavorite, workoutID: workoutID)
            if isFavorite {
                favoriteWorkoutIDs.insert(workoutID)
            } else {
                favoriteWorkoutIDs.remove(workoutID)
            }
            workoutLibrary.applyFavoriteChange(workoutID: workoutID, isFavorite: isFavorite)
            requestSessionSave()
            return true
        } catch {
            errorMessage = "Could not update favourite: \(error.localizedDescription)"
            showingError = true
            return false
        }
    }

    /// Whether tags can be assigned (persisted library workouts only, never demos).
    func canTag(_ workout: RunWorkout) -> Bool {
        canEditLibraryMetadata(workout)
    }

    /// Whether organisation management (tags/collections) is available.
    var canManageOrganization: Bool {
        storeActor != nil && hasPersistedLibrary
    }

    // MARK: - Tags & smart collections

    @discardableResult
    func createTag(name: String, color: WorkoutTagColor) async -> WorkoutTag? {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else {
            organizationEditError = "Tags require a saved local library."
            return nil
        }
        do {
            let tag = try await storeActor.createTag(name: name, color: color)
            tags.append(tag)
            workoutLibrary.applyTagDefinitions(tags)
            requestSessionSave()
            announcementPolicy.handle(.tagUpdateCompleted)
            return tag
        } catch {
            organizationEditError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func updateTag(id: UUID, name: String, color: WorkoutTagColor) async -> WorkoutTag? {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else {
            organizationEditError = "Tags require a saved local library."
            return nil
        }
        do {
            let tag = try await storeActor.updateTag(id: id, name: name, color: color)
            if let index = tags.firstIndex(where: { $0.id == id }) {
                tags[index] = tag
            }
            workoutLibrary.applyTagDefinitions(tags)
            requestSessionSave()
            announcementPolicy.handle(.tagUpdateCompleted)
            return tag
        } catch {
            organizationEditError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func deleteTag(id: UUID) async -> Bool {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else {
            organizationEditError = "Tags require a saved local library."
            return false
        }
        do {
            try await storeActor.deleteTag(id: id)
            tags.removeAll { $0.id == id }
            // Strip from local entry assignments and collection filters.
            var assignmentChanges: [UUID: Set<UUID>] = [:]
            for entry in workoutLibrary.entries where entry.tagIDs.contains(id) {
                var next = entry.tagIDs
                next.remove(id)
                assignmentChanges[entry.id] = next
            }
            if !assignmentChanges.isEmpty {
                workoutLibrary.applyBulkWorkoutTagChange(changes: assignmentChanges)
            }
            workoutLibrary.applyTagDefinitions(tags)
            // Repair in-memory collection filters.
            for index in smartCollections.indices {
                smartCollections[index].query.filter.tags = stripTag(
                    id,
                    from: smartCollections[index].query.filter.tags
                )
            }
            workoutLibrary.applySmartCollectionChange(smartCollections)
            // Repair active tag filter.
            let repairedActiveFilter = stripTag(id, from: workoutLibrary.tagFilter)
            if repairedActiveFilter != workoutLibrary.tagFilter {
                workoutLibrary.tagFilter = repairedActiveFilter
            }
            requestSessionSave()
            announcementPolicy.handle(.tagUpdateCompleted)
            return true
        } catch {
            organizationEditError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func reorderTags(_ orderedIDs: [UUID]) async -> Bool {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else { return false }
        do {
            try await storeActor.reorderTags(orderedIDs)
            let byID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
            tags = orderedIDs.compactMap { byID[$0] }
            workoutLibrary.applyTagDefinitions(tags)
            requestSessionSave()
            announcementPolicy.handle(.tagUpdateCompleted)
            return true
        } catch {
            organizationEditError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setTags(_ tagIDs: Set<UUID>, forWorkoutID workoutID: UUID) async -> Bool {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary, libraryWorkoutIDs.contains(workoutID) else {
            organizationEditError = "Tags apply to imported library workouts, not bundled demos."
            return false
        }
        do {
            try await storeActor.setTags(tagIDs, forWorkoutID: workoutID)
            workoutLibrary.applyWorkoutTagChange(workoutID: workoutID, tagIDs: tagIDs)
            requestSessionSave()
            announcementPolicy.handle(.tagUpdateCompleted)
            return true
        } catch {
            organizationEditError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateTags(
        workoutIDs: Set<UUID>,
        addTagIDs: Set<UUID>,
        removeTagIDs: Set<UUID>
    ) async -> Bool {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else {
            organizationEditError = "Tags require a saved local library."
            return false
        }
        let valid = workoutIDs.intersection(libraryWorkoutIDs)
        guard !valid.isEmpty else {
            organizationEditError = "Select imported library workouts to edit tags."
            return false
        }
        do {
            try await storeActor.updateTags(
                workoutIDs: valid,
                addTagIDs: addTagIDs,
                removeTagIDs: removeTagIDs
            )
            var changes: [UUID: Set<UUID>] = [:]
            for id in valid {
                var next = workoutLibrary.entry(for: id)?.tagIDs ?? []
                next.formUnion(addTagIDs)
                next.subtract(removeTagIDs)
                changes[id] = next
            }
            workoutLibrary.applyBulkWorkoutTagChange(changes: changes)
            requestSessionSave()
            announcementPolicy.handle(.tagUpdateCompleted)
            return true
        } catch {
            organizationEditError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func createSmartCollection(name: String, query: WorkoutLibrarySavedQuery) async -> WorkoutSmartCollection? {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else {
            organizationEditError = "Smart collections require a saved local library."
            return nil
        }
        do {
            let collection = try await storeActor.createSmartCollection(name: name, query: query)
            smartCollections.append(collection)
            workoutLibrary.didCreateSmartCollection(collection)
            requestSessionSave()
            announcementPolicy.handle(.smartCollectionUpdated)
            return collection
        } catch {
            organizationEditError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func updateSmartCollection(
        id: UUID,
        name: String,
        query: WorkoutLibrarySavedQuery
    ) async -> WorkoutSmartCollection? {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else {
            organizationEditError = "Smart collections require a saved local library."
            return nil
        }
        do {
            let collection = try await storeActor.updateSmartCollection(
                id: id,
                name: name,
                query: query
            )
            if let index = smartCollections.firstIndex(where: { $0.id == id }) {
                smartCollections[index] = collection
            }
            // Update definitions only. Do not clear Modified — rename/external
            // query saves must not discard an unsaved working All Runs query.
            // Explicit Update Collection uses markActiveCollectionUpdated after success.
            workoutLibrary.applySmartCollectionChange(smartCollections)
            requestSessionSave()
            announcementPolicy.handle(.smartCollectionUpdated)
            return collection
        } catch {
            organizationEditError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func deleteSmartCollection(id: UUID) async -> Bool {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else {
            organizationEditError = "Smart collections require a saved local library."
            return false
        }
        do {
            try await storeActor.deleteSmartCollection(id: id)
            smartCollections.removeAll { $0.id == id }
            workoutLibrary.didDeleteSmartCollection(id: id)
            requestSessionSave()
            announcementPolicy.handle(.smartCollectionUpdated)
            return true
        } catch {
            organizationEditError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func reorderSmartCollections(_ orderedIDs: [UUID]) async -> Bool {
        organizationEditError = nil
        guard let storeActor, hasPersistedLibrary else { return false }
        do {
            try await storeActor.reorderSmartCollections(orderedIDs)
            let byID = Dictionary(uniqueKeysWithValues: smartCollections.map { ($0.id, $0) })
            smartCollections = orderedIDs.compactMap { byID[$0] }
            workoutLibrary.applySmartCollectionChange(smartCollections)
            requestSessionSave()
            announcementPolicy.handle(.smartCollectionUpdated)
            return true
        } catch {
            organizationEditError = error.localizedDescription
            return false
        }
    }

    /// Persist the active modified collection query.
    @discardableResult
    func updateActiveSmartCollectionFromCurrentQuery() async -> Bool {
        guard case .smartCollection(let id, true) = workoutLibrary.queryContext,
              let existing = smartCollections.first(where: { $0.id == id }) else {
            return false
        }
        let updated = await updateSmartCollection(
            id: id,
            name: existing.name,
            query: workoutLibrary.currentSavedQuery()
        )
        guard let updated else { return false }
        // Only explicit Update Collection clears Modified after a successful save.
        workoutLibrary.markActiveCollectionUpdated(updated)
        requestSessionSave()
        return true
    }

    private func stripTag(_ id: UUID, from filter: WorkoutLibraryTagFilter) -> WorkoutLibraryTagFilter {
        switch filter {
        case .anyTags, .untaggedOnly:
            return filter
        case .selected(let tagIDs, let match):
            var remaining = tagIDs
            remaining.remove(id)
            if remaining.isEmpty { return .anyTags }
            return .selected(tagIDs: remaining, match: match)
        }
    }

    /// Persist name/notes for a library workout. UI updates only after success.
    @discardableResult
    func updateWorkoutMetadata(
        workoutID: UUID,
        name: String?,
        notes: String?
    ) async -> Bool {
        metadataEditError = nil
        guard let storeActor, hasPersistedLibrary, libraryWorkoutIDs.contains(workoutID) else {
            metadataEditError = "Details can only be edited for imported library workouts."
            return false
        }
        guard workouts.contains(where: { $0.id == workoutID }) else {
            metadataEditError = "Workout is not in the library."
            return false
        }
        do {
            let updated = try await storeActor.updateWorkoutMetadata(
                workoutID: workoutID,
                name: name,
                notes: notes
            )
            if let index = workouts.firstIndex(where: { $0.id == workoutID }) {
                workouts[index] = updated
            }
            if selectedWorkout?.id == workoutID {
                selectedWorkout = updated
            }
            if comparisonWorkout?.id == workoutID {
                comparisonWorkout = updated
            }
            analysisContextCache.removeValue(forKey: workoutID)
            workoutLibrary.applyWorkoutUpdate(updated)
            requestSessionSave()
            return true
        } catch {
            metadataEditError = error.localizedDescription
            return false
        }
    }

    // MARK: - Comparison

    /// Set the comparison workout and enter comparison mode.
    func setComparison(_ workout: RunWorkout?) {
        let wasComparing = workspaceMode == .comparison
        comparisonSelectionMessage = nil
        guard let workout else {
            clearComparison()
            return
        }
        guard selectedWorkout != nil else {
            comparisonWorkout = nil
            workspaceMode = .workout
            comparisonSelectionMessage = "Select a primary run first."
            return
        }
        guard canCompare(workout) else {
            comparisonWorkout = nil
            workspaceMode = .workout
            comparisonSelectionMessage = "Choose a different run to compare."
            return
        }
        // SwiftUI pickers may write their already-selected value while
        // reconciling a restored view. Treat that as a no-op so a valid
        // restored Route-Aware position is not cleared and recomputed.
        if workspaceMode == .comparison, comparisonWorkout?.id == workout.id {
            return
        }

        cancelActiveWorkspaceWork()
        comparisonWorkout = workout
        workspaceMode = .comparison
        clampComparisonDistance()
        if let pair = comparisonPair {
            comparisonViewModel.pairDidChange(
                pair: pair,
                primaryContext: analysisContext(for: pair.primary),
                comparisonContext: analysisContext(for: pair.comparison)
            )
        }
        requestSessionSave()
        if !wasComparing {
            announcementPolicy.handle(.comparisonEntered)
        }
    }

    /// Clear comparison mode and return to the selected workout.
    func clearComparison() {
        let wasComparing = workspaceMode == .comparison
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        comparisonViewModel.clear()
        if workspaceMode == .comparison {
            workspaceMode = .workout
        }
        requestSessionSave()
        if wasComparing {
            announcementPolicy.handle(.comparisonExited)
        }
    }

    /// Switch comparison alignment mode (Distance vs Route-Aware).
    func setComparisonAlignmentMode(_ mode: ComparisonAlignmentMode) {
        let pair = comparisonPair
        comparisonViewModel.setAlignmentMode(
            mode,
            pair: pair,
            primaryContext: pair.map { analysisContext(for: $0.primary) },
            comparisonContext: pair.map { analysisContext(for: $0.comparison) }
        )
        requestSessionSave()
    }

    /// Enter comparison mode without a specific comparison workout,
    /// showing the empty state so users can import additional runs.
    func enterEmptyComparisonMode() {
        let wasComparing = workspaceMode == .comparison
        cancelActiveWorkspaceWork()
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        workspaceMode = .comparison
        requestSessionSave()
        if !wasComparing {
            announcementPolicy.handle(.comparisonEntered)
        }
    }

    /// Whether the supplied workout can be compared with the current primary selection.
    func canCompare(_ workout: RunWorkout) -> Bool {
        guard let selectedWorkout else { return false }
        return selectedWorkout.id != workout.id
    }

    /// Get the current comparison pair, if both workouts are selected.
    var comparisonPair: ComparisonPair? {
        guard let primary = selectedWorkout, let comparison = comparisonWorkout, primary.id != comparison.id else {
            return nil
        }
        return ComparisonPair(primary: primary, comparison: comparison)
    }

    /// Get the comparison summary, if available.
    var comparisonSummary: WorkoutComparisonSummary? {
        guard let pair = comparisonPair else { return nil }
        return comparisonService.compare(
            primary: pair.primary,
            comparison: pair.comparison,
            primaryContext: analysisContext(for: pair.primary),
            comparisonContext: analysisContext(for: pair.comparison)
        )
    }

    /// Get calculated split comparisons, if available.
    var splitComparisons: [SplitComparison] {
        guard let pair = comparisonPair else { return [] }
        return comparisonService.compareSplits(primary: pair.primary, comparison: pair.comparison)
    }

    /// Ordinal recorded-lap comparisons when either workout has source laps.
    var recordedLapComparisons: [RecordedLapComparison] {
        guard let pair = comparisonPair else { return [] }
        return comparisonService.compareRecordedLaps(
            primary: pair.primary,
            comparison: pair.comparison
        )
    }

    /// Get pace comparison metrics over distance.
    var comparisonMetrics: [ComparisonMetricPoint] {
        guard let pair = comparisonPair else { return [] }
        return comparisonService.compareMetricsOverDistance(
            primary: pair.primary,
            comparison: pair.comparison,
            primaryContext: analysisContext(for: pair.primary),
            comparisonContext: analysisContext(for: pair.comparison)
        )
    }

    /// Common distance for both routes (clamped).
    var comparisonCommonDistanceMeters: Double {
        guard let pair = comparisonPair else { return 0 }
        return min(
            analysisContext(for: pair.primary).timeline.totalDistanceMeters,
            analysisContext(for: pair.comparison).timeline.totalDistanceMeters
        )
    }

    /// Selected comparison distance constrained to the current route pair.
    var clampedComparisonDistanceMeters: Double {
        max(0, min(selectedComparisonDistanceMeters, comparisonCommonDistanceMeters))
    }

    /// Metrics at the selected comparison distance.
    var comparisonDistanceMetrics: ComparisonDistanceMetrics {
        guard let pair = comparisonPair else {
            return ComparisonDistanceMetrics(
                selectedDistanceMeters: 0,
                primaryElapsedSeconds: nil, comparisonElapsedSeconds: nil,
                timeDeltaSeconds: nil,
                primaryPaceSecondsPerKm: nil, comparisonPaceSecondsPerKm: nil,
                paceDeltaSecondsPerKm: nil,
                primaryScenePoint: nil, comparisonScenePoint: nil
            )
        }
        return comparisonService.metricsAtDistance(
            clampedComparisonDistanceMeters,
            primary: pair.primary,
            comparison: pair.comparison,
            primaryContext: analysisContext(for: pair.primary),
            comparisonContext: analysisContext(for: pair.comparison)
        )
    }

    /// Route-Aware matched-section metrics at the selected aligned progress.
    var comparisonAlignedMetrics: ComparisonAlignedMetrics {
        guard let pair = comparisonPair else { return .empty }
        return comparisonViewModel.alignedMetrics(
            primary: pair.primary,
            comparison: pair.comparison,
            primaryContext: analysisContext(for: pair.primary),
            comparisonContext: analysisContext(for: pair.comparison)
        )
    }

    /// Clamp the selected comparison distance to the common route distance.
    func clampComparisonDistance() {
        let common = comparisonCommonDistanceMeters
        if selectedComparisonDistanceMeters > common {
            selectedComparisonDistanceMeters = common
        }
        if selectedComparisonDistanceMeters < 0 {
            selectedComparisonDistanceMeters = 0
        }
        requestSessionSave()
    }

    /// Comparison warnings filtered for the active alignment mode.
    var comparisonDisplayWarnings: [ComparisonWarning] {
        guard let warnings = comparisonSummary?.warnings else { return [] }
        if comparisonViewModel.isRouteAwareReady {
            return warnings.filter { $0 != .differentRouteShape }
        }
        return warnings
    }

    /// Other workouts available for comparison (excluding current selection).
    var availableForComparison: [RunWorkout] {
        guard let selected = selectedWorkout else { return workouts }
        return workouts.filter { $0.id != selected.id }
    }

    func analysisContext(for workout: RunWorkout) -> WorkoutAnalysisContext {
        if let cached = cachedAnalysisContext(for: workout) {
            return cached
        }
        let context = WorkoutAnalysisContext(workout: workout)
        analysisContextCache[workout.id] = CachedAnalysisContext(
            normalizationVersion: workout.normalizationVersion,
            pointCount: workout.routePoints.count,
            firstPointID: workout.routePoints.first?.id,
            lastPointID: workout.routePoints.last?.id,
            context: context
        )
        return context
    }

    /// Return an already-derived context without performing route-sized work.
    /// Callers that can derive off-main use this to reuse a valid cache entry
    /// while avoiding a synchronous cache miss on the main actor.
    func cachedAnalysisContext(for workout: RunWorkout) -> WorkoutAnalysisContext? {
        if let cached = analysisContextCache[workout.id],
           cached.normalizationVersion == workout.normalizationVersion,
           cached.pointCount == workout.routePoints.count,
           cached.firstPointID == workout.routePoints.first?.id,
           cached.lastPointID == workout.routePoints.last?.id {
            return cached.context
        }
        return nil
    }
}
