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

    // Comparison state
    @Published var comparisonWorkout: RunWorkout?
    @Published var isComparing: Bool = false
    @Published var comparisonSelectionMessage: String?
    @Published var selectedComparisonDistanceMeters: Double = 0

    let replayController = ReplayController()
    let comparisonService = WorkoutComparisonService()

    /// Backward-compatible computed property for views that check loading state.
    var isLoadingLibrary: Bool {
        operationState == .loadingLibrary
    }

    /// The store actor for persistence. Nil only in tests without persistence.
    private let storeActor: WorkoutLibraryStoreActor?

    /// The import service for parsing workout files off the main actor.
    private let importService: WorkoutImportServicing?

    /// Handle for the current import task (cancelled on deinit or new import).
    private var importTask: Task<Void, Never>?

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
        importTask?.cancel()
        selectionTask?.cancel()
    }

    // MARK: - Startup

    /// Load the persisted library asynchronously.
    ///
    /// Call from `.task` on the root view. Sets `operationState` to
    /// `.loadingLibrary` while loading and `.idle` when complete.
    func start() async {
        guard let storeActor else {
            loadSampleWorkouts()
            return
        }

        operationState = .loadingLibrary

        let result = await storeActor.loadLibrary()
        applyLibraryLoadResult(result)
        operationState = .idle
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
            try await storeActor.addWorkout(workout, select: true)
            workouts.append(workout)
            selectedWorkout = workout
            replayController.load(workout)
            detectedSegments = workout.segments
            selectedSegment = nil
        } catch is CancellationError {
            // Cancelled — do not add to UI.
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    /// Handle file import result from SwiftUI's `.fileImporter`.
    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importWorkout(from: url) }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
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
    /// UI state updates immediately. If `persistSelection` is true, the
    /// manifest write is asynchronous with last-write-wins semantics.
    func selectWorkout(_ workout: RunWorkout?, persistSelection: Bool = true) {
        selectedWorkout = workout
        selectedSegment = nil
        if let workout, comparisonWorkout?.id == workout.id {
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
                    await MainActor.run {
                        self?.errorMessage = "Selection changed, but could not be saved: \(error.localizedDescription)"
                        self?.showingError = true
                    }
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
        let remainingWorkouts = workouts.filter { $0.id != workout.id }
        let newSelectedID = deletingSelectedWorkout ? remainingWorkouts.first?.id : nil

        if let storeActor {
            operationState = .deleting(workoutID: workout.id)
            defer { operationState = .idle }

            do {
                let result = try await storeActor.deleteWorkout(
                    id: workout.id,
                    newSelectedID: newSelectedID
                )

                switch result {
                case .deletedSelected:
                    workouts = remainingWorkouts
                    clearComparison()
                    selectedWorkout = remainingWorkouts.first
                    selectedSegment = nil
                    if let first = remainingWorkouts.first {
                        replayController.load(first)
                        detectedSegments = first.segments
                    } else {
                        detectedSegments = []
                    }

                case .deletedNonSelected:
                    workouts = remainingWorkouts
                    if deletingComparisonWorkout {
                        clearComparison()
                    }

                case .notInManifest:
                    // Bundled demo or non-persisted workout. Remove from memory only.
                    workouts = remainingWorkouts
                    applyDeletionSelection(
                        deletingSelectedWorkout: deletingSelectedWorkout,
                        deletingComparisonWorkout: deletingComparisonWorkout
                    )
                }
            } catch let storeError as WorkoutLibraryStoreError {
                // Manifest committed but file is orphaned. Remove from UI and warn.
                workouts = remainingWorkouts
                if deletingSelectedWorkout {
                    clearComparison()
                    selectedWorkout = remainingWorkouts.first
                    selectedSegment = nil
                    if let first = remainingWorkouts.first {
                        replayController.load(first)
                        detectedSegments = first.segments
                    } else {
                        detectedSegments = []
                    }
                } else if deletingComparisonWorkout {
                    clearComparison()
                }
                errorMessage = storeError.localizedDescription
                showingError = true
            } catch let deleteError {
                // Manifest transaction failed. No changes were made.
                errorMessage = "Could not delete workout; no changes were made: \(deleteError.localizedDescription)"
                showingError = true
            }
        } else {
            // No store: just update in-memory state (demo-only mode).
            workouts = remainingWorkouts
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
        if deletingSelectedWorkout {
            clearComparison()
            selectedWorkout = workouts.first
            selectedSegment = nil
            if let first = workouts.first {
                replayController.load(first)
                detectedSegments = first.segments
            } else {
                detectedSegments = []
            }
        } else if deletingComparisonWorkout {
            clearComparison()
        }
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
            isComparing = false
            comparisonSelectionMessage = "Select a primary run first."
            return
        }
        guard canCompare(workout) else {
            comparisonWorkout = nil
            isComparing = false
            comparisonSelectionMessage = "Choose a different run to compare."
            return
        }

        comparisonWorkout = workout
        isComparing = true
        clampComparisonDistance()
    }

    /// Clear comparison mode.
    func clearComparison() {
        comparisonWorkout = nil
        isComparing = false
        comparisonSelectionMessage = nil
        selectedComparisonDistanceMeters = 0
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
        return comparisonService.compare(primary: pair.primary, comparison: pair.comparison)
    }

    /// Get split comparisons, if available.
    var splitComparisons: [SplitComparison] {
        guard let pair = comparisonPair else { return [] }
        return comparisonService.compareSplits(primary: pair.primary, comparison: pair.comparison)
    }

    /// Get pace comparison metrics over distance.
    var comparisonMetrics: [ComparisonMetricPoint] {
        guard let pair = comparisonPair else { return [] }
        return comparisonService.compareMetricsOverDistance(primary: pair.primary, comparison: pair.comparison)
    }

    /// Common distance for both routes (clamped).
    var comparisonCommonDistanceMeters: Double {
        guard let pair = comparisonPair else { return 0 }
        return comparisonService.commonDistance(primary: pair.primary, comparison: pair.comparison)
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
            comparison: pair.comparison
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
}
