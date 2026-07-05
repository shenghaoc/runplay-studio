import Foundation
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

    // Comparison state
    @Published var comparisonWorkout: RunWorkout?
    @Published var isComparing: Bool = false

    let replayController = ReplayController()
    let sceneBuilder = RouteSceneBuilder()
    let cameraController = SceneCameraController()
    var projectionService = RouteProjectionService()
    let comparisonService = WorkoutComparisonService()

    init() {
        loadSampleWorkout()
    }

    /// Load the bundled sample workout.
    func loadSampleWorkout() {
        guard let url = Bundle.main.url(forResource: "sample_run", withExtension: "json") else {
            // Try loading from file system for development
            let devURL = URL(fileURLWithPath: "RunPlayStudio/Resources/sample_run.json")
            if FileManager.default.fileExists(atPath: devURL.path) {
                loadWorkout(from: devURL)
            }
            return
        }
        loadWorkout(from: url)
    }

    /// Import a workout from a file URL.
    func loadWorkout(from url: URL) {
        do {
            let workout = try WorkoutImporterFactory.importWorkout(from: url)
            workouts.append(workout)
            selectedWorkout = workout
            replayController.load(workout)
            detectedSegments = SegmentDetector.detectSegments(from: workout)
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

    /// Select a workout for viewing.
    func selectWorkout(_ workout: RunWorkout?) {
        selectedWorkout = workout
        selectedSegment = nil
        if let workout = workout {
            replayController.load(workout)
            detectedSegments = SegmentDetector.detectSegments(from: workout)
        } else {
            detectedSegments = []
        }
    }

    /// Delete a workout.
    func deleteWorkout(_ workout: RunWorkout) {
        workouts.removeAll { $0.id == workout.id }
        if selectedWorkout?.id == workout.id {
            selectedWorkout = workouts.first
            if let first = workouts.first {
                replayController.load(first)
            }
        }
        if comparisonWorkout?.id == workout.id {
            comparisonWorkout = nil
            isComparing = false
        }
    }

    // MARK: - Comparison

    /// Set the comparison workout and enter comparison mode.
    func setComparison(_ workout: RunWorkout?) {
        comparisonWorkout = workout
        isComparing = workout != nil
    }

    /// Clear comparison mode.
    func clearComparison() {
        comparisonWorkout = nil
        isComparing = false
    }

    /// Get the current comparison pair, if both workouts are selected.
    var comparisonPair: ComparisonPair? {
        guard let primary = selectedWorkout, let comparison = comparisonWorkout else {
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

    /// Other workouts available for comparison (excluding current selection).
    var availableForComparison: [RunWorkout] {
        guard let selected = selectedWorkout else { return workouts }
        return workouts.filter { $0.id != selected.id }
    }
}
