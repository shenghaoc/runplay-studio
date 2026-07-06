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
    @Published var comparisonSelectionMessage: String?
    @Published var selectedComparisonDistanceMeters: Double = 0

    let replayController = ReplayController()
    let sceneBuilder = RouteSceneBuilder()
    let cameraController = SceneCameraController()
    var projectionService = RouteProjectionService()
    let comparisonService = WorkoutComparisonService()
    var comparisonProjectionService = ComparisonRouteProjectionService()
    let comparisonSceneBuilder = ComparisonSceneBuilder()
    let comparisonCameraController = SceneCameraController()

    init(loadSampleWorkout: Bool = true) {
        if loadSampleWorkout {
            self.loadSampleWorkouts()
        }
    }

    /// Load bundled demo workouts.
    func loadSampleWorkouts() {
        let initialCount = workouts.count
        loadBundledWorkout(resource: "sample_run", extension: "json")
        loadBundledWorkout(resource: "comparison_park_run", extension: "json", subdirectory: "fixtures")

        if workouts.count > initialCount {
            selectWorkout(workouts[initialCount])
        }
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

    private func loadBundledWorkout(resource: String, extension fileExtension: String, subdirectory: String? = nil) {
        if let url = Bundle.main.url(forResource: resource, withExtension: fileExtension, subdirectory: subdirectory) {
            loadWorkout(from: url)
            return
        }

        let relativePath = [subdirectory, "\(resource).\(fileExtension)"]
            .compactMap { $0 }
            .joined(separator: "/")
        let devURL = URL(fileURLWithPath: "RunPlayStudio/Resources/\(relativePath)")
        if FileManager.default.fileExists(atPath: devURL.path) {
            loadWorkout(from: devURL)
        }
    }

    /// Select a workout for viewing.
    func selectWorkout(_ workout: RunWorkout?) {
        selectedWorkout = workout
        selectedSegment = nil
        if let workout, comparisonWorkout?.id == workout.id {
            clearComparison()
        }
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
                detectedSegments = SegmentDetector.detectSegments(from: first)
            } else {
                detectedSegments = []
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
        // Clamp to common distance
        let clamped = max(0, min(selectedComparisonDistanceMeters, comparisonCommonDistanceMeters))
        return comparisonService.metricsAtDistance(
            clamped,
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
