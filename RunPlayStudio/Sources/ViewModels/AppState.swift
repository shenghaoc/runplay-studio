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
    case workoutLibrary
}

/// Menu-level command routed through the same workspace transition methods as
/// sidebar selection. Kept separate from the visible workspace state.
enum AppWorkspaceCommand {
    case showPersonalHeatmap
    case showAllRuns
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

    /// The import service for parsing workout files off the main actor.
    private let importService: WorkoutImportServicing?

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
        accessibilityAnnouncer: any AccessibilityAnnouncing = AccessibilityAnnouncer.shared
    ) {
        let announcementPolicy = AccessibilityAnnouncementPolicy(
            announcer: accessibilityAnnouncer
        )
        self.storeActor = storeActor
        self.importService = importService
        self.archiveService = archiveService
        self.fitSessionService = fitSessionService
        self.announcementPolicy = announcementPolicy
        self.personalHeatmap = PersonalHeatmapViewModel(
            announcementPolicy: announcementPolicy
        )
        self.workoutLibrary = WorkoutLibraryViewModel(
            announcementPolicy: announcementPolicy
        )
    }

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
            fitSessionService: fitSessionService
        )
    }

    deinit {
        selectionTask?.cancel()
        archiveTask?.cancel()
        fitImportTask?.cancel()
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
                distanceMeters: clampedComparisonDistanceMeters
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
                minimumWorkoutCount: personalHeatmap.minimumWorkoutCount
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
                workspaceMode = .comparison
                clampComparisonDistance()
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
        defer { operationState = .idle }

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
            libraryWorkoutIDs = Set(loaded.map(\.id))
            hasPersistedLibrary = true
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
            let workout = try await importService.importWorkout(from: url)
            try Task.checkCancellation()
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
            workoutLibrary.replaceLibrary(
                workouts: workouts,
                favoriteIDs: favoriteWorkoutIDs,
                organization: currentOrganizationSnapshot()
            )
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

    private func importErrorMessage(for error: WorkoutImportError, filename: String) -> String {
        switch error {
        case .unsupportedFormat(let ext):
            return "'\(filename)' uses the .\(ext) format, which isn't supported. Import a GPX, TCX, FIT, or JSON file instead."
        case .parsingError(let detail):
            return "'\(filename)' couldn't be parsed. \(detail)"
        case .missingData(let detail):
            return "'\(filename)' is missing required data. \(detail)"
        case .invalidFormat(let detail):
            return "'\(filename)' has an invalid format. \(detail)"
        case .fileNotFound:
            return "Couldn't find the selected file. Try importing again."
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
        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
            workspaceMode = .workout
        } else if workspaceMode == .workoutLibrary {
            workspaceMode = .workout
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
        requestSessionSave()
    }

    private func applyDeletionSelection(
        deletingSelectedWorkout: Bool,
        deletingComparisonWorkout: Bool
    ) {
        let wasHeatmap = workspaceMode == .personalHeatmap
        let wasLibrary = workspaceMode == .workoutLibrary
        if deletingSelectedWorkout {
            clearComparison()
            // Preserve heatmap / All Runs workspace when deleting while visible.
            if wasHeatmap {
                selectedWorkout = workouts.first
                selectedSegment = nil
                if let selectedWorkout {
                    replayController.load(selectedWorkout)
                    detectedSegments = selectedWorkout.segments
                } else {
                    detectedSegments = []
                }
                workspaceMode = .personalHeatmap
                personalHeatmap.refresh(workouts: workouts)
            } else if wasLibrary {
                selectedWorkout = workouts.first
                selectedSegment = nil
                if let selectedWorkout {
                    replayController.load(selectedWorkout)
                    detectedSegments = selectedWorkout.segments
                } else {
                    detectedSegments = []
                }
                workspaceMode = .workoutLibrary
            } else {
                selectWorkout(workouts.first, persistSelection: false)
            }
        } else if deletingComparisonWorkout {
            clearComparison()
            if wasHeatmap {
                workspaceMode = .personalHeatmap
                personalHeatmap.refresh(workouts: workouts)
            } else if wasLibrary {
                workspaceMode = .workoutLibrary
            }
        } else if wasHeatmap {
            personalHeatmap.refresh(workouts: workouts)
        }
    }

    // MARK: - Workspace navigation

    /// Handle a window-wide command that may arrive without a focused scene.
    func handleWorkspaceCommand(_ command: AppWorkspaceCommand) {
        switch command {
        case .showPersonalHeatmap:
            showPersonalHeatmap()
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
        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
        }
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
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
        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
        }
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
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

    private func currentOrganizationSnapshot() -> WorkoutLibraryOrganizationSnapshot {
        // Prefer live All Runs entry assignments so in-session tag edits stay
        // coherent across replaceLibrary without reloading the manifest.
        let assignments = workoutLibrary.entries.compactMap { entry -> WorkoutTagAssignment? in
            guard !entry.tagIDs.isEmpty else { return nil }
            return WorkoutTagAssignment(workoutID: entry.id, tagIDs: entry.tagIDs)
        }
        return WorkoutLibraryOrganizationSnapshot(
            tags: tags,
            tagAssignments: assignments,
            smartCollections: smartCollections
        )
    }

    /// Open a workout from All Runs (enters `.workout`).
    func openWorkoutFromLibrary(_ workout: RunWorkout) {
        selectWorkout(workout)
    }

    /// Open the Personal Heatmap workspace. Does not change selected workout.
    func showPersonalHeatmap() {
        personalHeatmap.cancel()
        // Leave comparison / All Runs cleanly; workspaces are mutually exclusive.
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        workspaceMode = .personalHeatmap
        personalHeatmap.refresh(workouts: workouts)
        requestSessionSave()
    }

    /// Return to the selected workout workspace (if any).
    func showWorkoutWorkspace() {
        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
        }
        if workspaceMode == .comparison {
            comparisonWorkout = nil
            comparisonSelectionMessage = nil
            selectedComparisonDistanceMeters = 0
        }
        workspaceMode = .workout
        requestSessionSave()
    }

    private func enterComparisonWorkspace() {
        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
        }
        workspaceMode = .comparison
        requestSessionSave()
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

        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
        }
        comparisonWorkout = workout
        workspaceMode = .comparison
        clampComparisonDistance()
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
        if workspaceMode == .comparison {
            workspaceMode = .workout
        }
        requestSessionSave()
        if wasComparing {
            announcementPolicy.handle(.comparisonExited)
        }
    }

    /// Enter comparison mode without a specific comparison workout,
    /// showing the empty state so users can import additional runs.
    func enterEmptyComparisonMode() {
        let wasComparing = workspaceMode == .comparison
        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
        }
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

    /// Other workouts available for comparison (excluding current selection).
    var availableForComparison: [RunWorkout] {
        guard let selected = selectedWorkout else { return workouts }
        return workouts.filter { $0.id != selected.id }
    }

    func analysisContext(for workout: RunWorkout) -> WorkoutAnalysisContext {
        if let cached = analysisContextCache[workout.id],
           cached.normalizationVersion == workout.normalizationVersion,
           cached.pointCount == workout.routePoints.count,
           cached.firstPointID == workout.routePoints.first?.id,
           cached.lastPointID == workout.routePoints.last?.id {
            return cached.context
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
}
