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

    let replayController = ReplayController()
    let sceneBuilder = RouteSceneBuilder()
    let cameraController = SceneCameraController()
    var projectionService = RouteProjectionService()

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
    }
}
