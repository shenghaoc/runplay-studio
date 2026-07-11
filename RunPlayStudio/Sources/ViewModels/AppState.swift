import Foundation
import RunPlayCore
import SwiftUI

import UniformTypeIdentifiers

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
    @Published private(set) var isLoadingLibrary = false

    // Comparison state
    @Published var comparisonWorkout: RunWorkout?
    @Published var isComparing: Bool = false
    @Published var comparisonSelectionMessage: String?
    @Published var selectedComparisonDistanceMeters: Double = 0

    let replayController = ReplayController()
    let comparisonService = WorkoutComparisonService()

    /// The store used for persistence. Nil only when `loadSampleWorkout` is false
    /// (used in tests that construct AppState without a store).
    private let store: WorkoutLibraryStoring?

    private struct SendableStore: @unchecked Sendable {
        let value: WorkoutLibraryStoring
    }

    /// Create AppState with an optional store injection.
    ///
    /// - Parameters:
    ///   - store: The persistence store to use. Pass `nil` to skip persistence (tests only).
    ///   - loadSampleWorkout: Whether to load demos if no persisted workouts exist.
    init(
        store: WorkoutLibraryStoring? = nil,
        loadSampleWorkout: Bool = true,
        loadStoreAsynchronously: Bool = false
    ) {
        self.store = store

        if loadSampleWorkout {
            if let store {
                if loadStoreAsynchronously {
                    isLoadingLibrary = true
                    loadFromStoreInBackground(store)
                } else {
                    applyLibraryLoadResult(WorkoutLibraryLoader.load(from: store))
                }
            } else {
                // No store provided: fall back to legacy demo-only behavior.
                loadSampleWorkouts()
            }
        }
    }

    /// Convenience init for production: creates a store rooted at the given directory.
    convenience init(libraryRoot: URL, loadSampleWorkout: Bool = true) {
        let store = FileWorkoutLibraryStore(rootURL: libraryRoot)
        self.init(
            store: store,
            loadSampleWorkout: loadSampleWorkout,
            loadStoreAsynchronously: true
        )
    }

    // MARK: - Startup

    /// Load and decode persisted workouts away from the main actor, then publish
    /// the resulting state on the main actor.
    private func loadFromStoreInBackground(_ store: WorkoutLibraryStoring) {
        let sendableStore = SendableStore(value: store)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                WorkoutLibraryLoader.load(from: sendableStore.value)
            }.value
            guard let self else { return }
            applyLibraryLoadResult(result)
            isLoadingLibrary = false
        }
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
    func loadWorkout(from url: URL) {
        do {
            let workout = try WorkoutImporterFactory.importWorkout(from: url)

            // Persist first. If persistence fails, don't add to in-memory state.
            if let store {
                do {
                    try persistImportedWorkout(workout, store: store)
                } catch {
                    errorMessage = "Import succeeded but could not be saved: \(error.localizedDescription)"
                    showingError = true
                    return
                }
            }

            workouts.append(workout)
            selectedWorkout = workout
            replayController.load(workout)
            // Use persisted segments from the analyzed workout.
            detectedSegments = workout.segments
            selectedSegment = nil
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func persistImportedWorkout(_ workout: RunWorkout, store: WorkoutLibraryStoring) throws {
        try store.saveWorkout(workout)

        do {
            var manifest: WorkoutLibraryManifest
            do {
                manifest = try store.loadManifest()
            } catch let error as WorkoutLibraryError {
                if case .manifestMissing = error {
                    manifest = WorkoutLibraryManifest()
                } else {
                    throw error
                }
            }
            manifest.workoutIDs.append(workout.id)
            manifest.selectedWorkoutID = workout.id
            try store.saveManifest(manifest)
        } catch {
            do {
                try store.deleteWorkout(id: workout.id)
            } catch let cleanupError {
                throw WorkoutLibraryError.writeFailed(
                    "Could not update the manifest (\(error.localizedDescription)); "
                    + "cleanup of the saved workout also failed (\(cleanupError.localizedDescription))"
                )
            }
            throw error
        }
    }

    /// Handle file import result.
    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            loadWorkout(from: url)
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

        if persistSelection, let store {
            persistSelectedWorkout(workout?.id, store: store)
        }
    }

    /// Persist the selected workout ID to the manifest.
    private func persistSelectedWorkout(_ id: UUID?, store: WorkoutLibraryStoring) {
        do {
            var manifest = try store.loadManifest()
            manifest.selectedWorkoutID = id
            try store.saveManifest(manifest)
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                return // Bundled demos have no persisted selection.
            }
            errorMessage = "Selection changed, but could not be saved: \(error.localizedDescription)"
            showingError = true
        } catch {
            errorMessage = "Selection changed, but could not be saved: \(error.localizedDescription)"
            showingError = true
        }
    }

    // MARK: - Deletion

    /// Delete a workout.
    func deleteWorkout(_ workout: RunWorkout) {
        let deletingSelectedWorkout = selectedWorkout?.id == workout.id
        let deletingComparisonWorkout = comparisonWorkout?.id == workout.id
        let remainingWorkouts = workouts.filter { $0.id != workout.id }

        // Persist the logical deletion before publishing it to the UI. If the
        // manifest cannot be updated, leave both disk and memory unchanged.
        if let store, store.workoutExists(id: workout.id) {
            do {
                let originalManifest = try store.loadManifest()
                var updatedManifest = originalManifest
                updatedManifest.workoutIDs.removeAll { $0 == workout.id }
                if deletingSelectedWorkout {
                    updatedManifest.selectedWorkoutID = remainingWorkouts.first?.id
                }
                try store.saveManifest(updatedManifest)

                do {
                    try store.deleteWorkout(id: workout.id)
                } catch {
                    do {
                        try store.saveManifest(originalManifest)
                    } catch let rollbackError {
                        errorMessage = "Workout was removed from the library, but its file and the manifest rollback both failed: \(error.localizedDescription); \(rollbackError.localizedDescription)"
                        showingError = true
                        workouts = remainingWorkouts
                        applyDeletionSelection(
                            deletingSelectedWorkout: deletingSelectedWorkout,
                            deletingComparisonWorkout: deletingComparisonWorkout
                        )
                        return
                    }
                    throw error
                }
            } catch {
                errorMessage = "Could not delete workout; no changes were made: \(error.localizedDescription)"
                showingError = true
                return
            }
        }

        workouts = remainingWorkouts

        applyDeletionSelection(
            deletingSelectedWorkout: deletingSelectedWorkout,
            deletingComparisonWorkout: deletingComparisonWorkout
        )
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
