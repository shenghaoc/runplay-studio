import Foundation
import RunPlayCore
import SwiftUI

import UniformTypeIdentifiers

/// Observable state for library operations.
public enum LibraryOperationState: Equatable {
    case idle
    case loadingLibrary
    case importing(filename: String)
    case deleting(workoutID: UUID)
}

/// Top-level workspace mode. Mutually exclusive destinations.
enum AppWorkspaceMode: Hashable, Sendable {
    case workout
    case comparison
    case personalHeatmap
}

/// Main application state manager.
@MainActor
class AppState: ObservableObject {
    @Published var workouts: [RunWorkout] = []
    @Published var selectedWorkout: RunWorkout?
    @Published var showImporter = false
    @Published var errorMessage: String?
    @Published var showingError = false
    @Published var detectedSegments: [SegmentHighlight] = []
    @Published var selectedSegment: SegmentHighlight?
    @Published private(set) var operationState: LibraryOperationState = .idle

    /// Single source of truth for which workspace is visible.
    @Published private(set) var workspaceMode: AppWorkspaceMode = .workout

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

    let replayController = ReplayController()
    let comparisonService = WorkoutComparisonService()
    let personalHeatmap = PersonalHeatmapViewModel()

    private struct CachedAnalysisContext {
        let normalizationVersion: Int
        let pointCount: Int
        let firstPointID: UUID?
        let lastPointID: UUID?
        let context: WorkoutAnalysisContext
    }

    /// Main-actor-owned immutable contexts avoid rebuilding 100k-point
    /// elevation profiles from multiple SwiftUI computed properties.
    private var analysisContextCache: [UUID: CachedAnalysisContext] = [:]

    /// Backward-compatible computed property for views that check loading state.
    var isLoadingLibrary: Bool {
        operationState == .loadingLibrary
    }

    /// The store actor for persistence. Nil only in tests without persistence.
    private let storeActor: WorkoutLibraryStoreActor?

    /// The import service for parsing workout files off the main actor.
    private let importService: WorkoutImportServicing?

    /// Handle for the current selection persistence task.
    private var selectionTask: Task<Void, Never>?

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
        importService: WorkoutImportServicing? = nil
    ) {
        self.storeActor = storeActor
        self.importService = importService
    }

    /// Convenience init for production: creates real services rooted at the given directory.
    convenience init(libraryRoot: URL) {
        let store = FileWorkoutLibraryStore(rootURL: libraryRoot)
        let actor = WorkoutLibraryStoreActor(store: store)
        let importService = WorkoutImportService()
        self.init(storeActor: actor, importService: importService)
    }

    deinit {
        selectionTask?.cancel()
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
            return
        }

        operationState = .loadingLibrary
        defer { operationState = .idle }

        let result = await storeActor.loadLibrary()
        applyLibraryLoadResult(result)
    }

    private func applyLibraryLoadResult(_ result: WorkoutLibraryLoadResult) {
        switch result {
        case .demos(let loadErrorMessage):
            loadSampleWorkouts()
            if let loadErrorMessage {
                errorMessage = loadErrorMessage
                showingError = true
            }
        case .workouts(let loaded, let selectedWorkoutID, let warning):
            analysisContextCache.removeAll()
            workouts = loaded
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
    func loadSampleWorkouts() {
        let initialCount = workouts.count
        loadBundledWorkout(resource: "sample_run", extension: "json")
        loadBundledWorkout(resource: "comparison_park_run", extension: "json", subdirectory: "fixtures")

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

        let filename = url.lastPathComponent
        operationState = .importing(filename: filename)
        defer { operationState = .idle }

        do {
            let workout = try await importService.importWorkout(from: url)
            try Task.checkCancellation()
            try await storeActor.addWorkout(workout, select: true)
            try Task.checkCancellation()
            analysisContextCache.removeValue(forKey: workout.id)

            if let existingIndex = workouts.firstIndex(where: { $0.id == workout.id }) {
                workouts[existingIndex] = workout
            } else {
                workouts.append(workout)
            }
            // Selecting a workout exits heatmap by design.
            selectWorkout(workout, persistSelection: false)
        } catch is CancellationError {
            // Cancelled — do not add to UI.
        } catch let error as WorkoutImportError {
            errorMessage = importErrorMessage(for: error, filename: filename)
            showingError = true
        } catch {
            errorMessage = "Imported but could not save to your library. "
                + "Check available storage and app permissions. Details: \(error.localizedDescription)"
            showingError = true
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
                } catch is CancellationError {
                    // A newer selection superseded this one.
                } catch {
                    self?.errorMessage = "Selection changed, but could not be saved: \(error.localizedDescription)"
                    self?.showingError = true
                }
            }
        }
    }

    // MARK: - Deletion

    /// Delete a workout.
    ///
    /// The manifest transaction runs off the main actor. UI state updates
    /// only after the logical deletion commits.
    func deleteWorkout(_ workout: RunWorkout) async {
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
                analysisContextCache.removeValue(forKey: workout.id)
                applyDeletionSelection(
                    deletingSelectedWorkout: deletingSelectedWorkout,
                    deletingComparisonWorkout: deletingComparisonWorkout
                )
            } catch let storeError as WorkoutLibraryStoreError {
                // Manifest committed but file is orphaned. Remove from UI and warn.
                workouts.removeAll { $0.id == workout.id }
                analysisContextCache.removeValue(forKey: workout.id)
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
            analysisContextCache.removeValue(forKey: workout.id)
            applyDeletionSelection(
                deletingSelectedWorkout: deletingSelectedWorkout,
                deletingComparisonWorkout: deletingComparisonWorkout
            )
        }
    }

    private func applyDeletionSelection(
        deletingSelectedWorkout: Bool,
        deletingComparisonWorkout: Bool
    ) {
        let wasHeatmap = workspaceMode == .personalHeatmap
        if deletingSelectedWorkout {
            clearComparison()
            // Preserve heatmap workspace when deleting while viewing heatmap.
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
            } else {
                selectWorkout(workouts.first, persistSelection: false)
            }
        } else if deletingComparisonWorkout {
            clearComparison()
            if wasHeatmap {
                workspaceMode = .personalHeatmap
                personalHeatmap.refresh(workouts: workouts)
            }
        } else if wasHeatmap {
            personalHeatmap.refresh(workouts: workouts)
        }
    }

    // MARK: - Workspace navigation

    /// Open the Personal Heatmap workspace. Does not change selected workout.
    func showPersonalHeatmap() {
        personalHeatmap.cancel()
        // Leave comparison cleanly; heatmap and comparison are mutually exclusive.
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        workspaceMode = .personalHeatmap
        personalHeatmap.refresh(workouts: workouts)
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
    }

    private func enterComparisonWorkspace() {
        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
        }
        workspaceMode = .comparison
    }

    // MARK: - Comparison

    /// Set the comparison workout and enter comparison mode.
    func setComparison(_ workout: RunWorkout?) {
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
    }

    /// Clear comparison mode and return to the selected workout.
    func clearComparison() {
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
        if workspaceMode == .comparison {
            workspaceMode = .workout
        }
    }

    /// Enter comparison mode without a specific comparison workout,
    /// showing the empty state so users can import additional runs.
    func enterEmptyComparisonMode() {
        if workspaceMode == .personalHeatmap {
            personalHeatmap.cancel()
        }
        comparisonWorkout = nil
        comparisonSelectionMessage = nil
        workspaceMode = .comparison
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
