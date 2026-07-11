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

    private enum LibraryLoadResult {
        case demos(errorMessage: String?)
        case workouts([RunWorkout], selectedWorkoutID: UUID?, warning: String?)
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
                    applyLibraryLoadResult(Self.readLibrary(from: store))
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
                Self.readLibrary(from: sendableStore.value)
            }.value
            guard let self else { return }
            applyLibraryLoadResult(result)
            isLoadingLibrary = false
        }
    }

    /// Read the persisted library without touching observable UI state.
    nonisolated private static func readLibrary(from store: WorkoutLibraryStoring) -> LibraryLoadResult {
        do {
            let manifest = try store.loadManifest()
            guard !manifest.workoutIDs.isEmpty else {
                return .demos(errorMessage: nil)
            }

            var loaded: [RunWorkout] = []
            var validIDs: [UUID] = []
            var corruptWarnings: [String] = []
            var missingIDs: [UUID] = []

            for id in manifest.workoutIDs {
                do {
                    let workout = try store.loadWorkout(id: id)
                    loaded.append(workout)
                    validIDs.append(id)
                } catch let error as WorkoutLibraryError {
                    switch error {
                    case .workoutFileMissing:
                        missingIDs.append(id)
                        corruptWarnings.append("Workout \(id.uuidString.prefix(8))… file missing — skipped")
                    case .workoutCorrupted:
                        corruptWarnings.append("Workout \(id.uuidString.prefix(8))… corrupted — skipped")
                    default:
                        corruptWarnings.append("Workout \(id.uuidString.prefix(8))… error: \(error.localizedDescription)")
                    }
                } catch {
                    corruptWarnings.append("Workout \(id.uuidString.prefix(8))… unexpected error: \(error.localizedDescription)")
                }
            }

            guard !loaded.isEmpty else {
                let warning = corruptWarnings.isEmpty
                    ? nil
                    : "Library recovery:\n" + corruptWarnings.joined(separator: "\n")
                return .demos(errorMessage: warning)
            }

            // Repair manifest if workouts were skipped.
            if validIDs.count != manifest.workoutIDs.count {
                var repaired = manifest
                repaired.workoutIDs = validIDs
                if let sel = repaired.selectedWorkoutID, !validIDs.contains(sel) {
                    repaired.selectedWorkoutID = validIDs.first
                }
                do {
                    try store.saveManifest(repaired)
                } catch {
                    corruptWarnings.append("Could not repair library manifest: \(error.localizedDescription)")
                }
            }

            let warning = corruptWarnings.isEmpty
                ? nil
                : "Some workouts could not be loaded:\n" + corruptWarnings.joined(separator: "\n")
            return .workouts(loaded, selectedWorkoutID: manifest.selectedWorkoutID, warning: warning)
        } catch let error as WorkoutLibraryError {
            switch error {
            case .manifestMissing:
                return .demos(errorMessage: nil)
            default:
                return .demos(errorMessage: "Failed to load library: \(error.localizedDescription)")
            }
        } catch {
            return .demos(errorMessage: "Unexpected error loading library: \(error.localizedDescription)")
        }
    }

    private func applyLibraryLoadResult(_ result: LibraryLoadResult) {
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
                    try store.saveWorkout(workout)
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
        // Primary: Bundle.main (works when launched from Xcode or built .app)
        if let url = Bundle.main.url(forResource: resource, withExtension: fileExtension, subdirectory: subdirectory) {
            loadWorkoutFromBundled(url: url)
            return
        }

        // Development fallback: relative path from repo root.
        // Only matches when the current working directory is the repository root.
        let relativePath = [subdirectory, "\(resource).\(fileExtension)"]
            .compactMap { $0 }
            .joined(separator: "/")
        let devURL = URL(filePath: "RunPlayStudio/Resources/\(relativePath)")
        if FileManager.default.fileExists(atPath: devURL.path) {
            loadWorkoutFromBundled(url: devURL)
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

        if persistSelection, let store, let workout {
            persistSelectedWorkout(workout.id, store: store)
        }
    }

    /// Persist the selected workout ID to the manifest.
    private func persistSelectedWorkout(_ id: UUID, store: WorkoutLibraryStoring) {
        guard var manifest = try? store.loadManifest() else { return }
        manifest.selectedWorkoutID = id
        try? store.saveManifest(manifest)
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
                var manifest = try store.loadManifest()
                manifest.workoutIDs.removeAll { $0 == workout.id }
                if deletingSelectedWorkout {
                    manifest.selectedWorkoutID = remainingWorkouts.first?.id
                }
                try store.saveManifest(manifest)
            } catch {
                errorMessage = "Could not delete workout: \(error.localizedDescription)"
                showingError = true
                return
            }

            do {
                try store.deleteWorkout(id: workout.id)
            } catch {
                // The manifest no longer references this workout, so complete
                // the logical deletion while reporting the orphaned file.
                errorMessage = "Workout removed from the library, but its stored file could not be deleted: \(error.localizedDescription)"
                showingError = true
            }
        }

        workouts = remainingWorkouts

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
