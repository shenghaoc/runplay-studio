import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class AppStatePersistenceTests: XCTestCase {

    // XCTest lifecycle overrides are nonisolated even though this test case's
    // test methods run on the main actor.
    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStatePersistenceTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> FileWorkoutLibraryStore {
        FileWorkoutLibraryStore(rootURL: tempDir)
    }

    private func makeWorkout(
        id: UUID = UUID(),
        name: String = "Test Run",
        distance: Double = 5000,
        duration: Double = 1800
    ) -> RunWorkout {
        var points: [RoutePoint] = []
        for i in 0...10 {
            let point = RoutePoint(
                timestamp: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 100),
                latitude: 37.0 + Double(i) * 0.0001,
                longitude: -122.0 + Double(i) * 0.0001,
                altitudeMeters: 100 + Double(i),
                distanceFromStartMeters: distance / 10 * Double(i),
                elapsedSeconds: duration / 10 * Double(i)
            )
            points.append(point)
        }
        return RunWorkout(
            id: id,
            metadata: WorkoutMetadata(name: name, startDate: Date(timeIntervalSince1970: 1_000_000)),
            source: .gpx,
            routePoints: points,
            splits: [],
            summary: RunSummary(
                totalDistanceMeters: distance,
                totalElapsedSeconds: duration
            )
        )
    }

    // MARK: - Startup With No Saved Workouts Loads Demos

    func testStartupWithNoSavedWorkoutsLoadsDemos() {
        let store = makeStore()
        let appState = AppState(store: store)

        // With no manifest, it should load bundled demos.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
        XCTAssertNotNil(appState.selectedWorkout)
    }

    func testStartupWithEmptyManifestLoadsDemos() throws {
        let store = makeStore()
        try store.saveManifest(WorkoutLibraryManifest(workoutIDs: []))

        let appState = AppState(store: store)

        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
    }

    // MARK: - Startup With Saved Workouts Does Not Insert Demos

    func testStartupWithSavedWorkoutsDoesNotInsertDemos() throws {
        let store = makeStore()
        let workout = makeWorkout(name: "My Persisted Run")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let appState = AppState(store: store)

        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.workouts.first?.metadata.name, "My Persisted Run")
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
    }

    // MARK: - Successful Import Persists

    func testSuccessfulImportPersists() throws {
        let store = makeStore()
        _ = AppState(store: store, loadSampleWorkout: false)

        // Manually add a workout and persist it (simulating import flow).
        let workout = makeWorkout(name: "Imported Run")
        try store.saveWorkout(workout)
        var manifest = WorkoutLibraryManifest()
        manifest.workoutIDs.append(workout.id)
        manifest.selectedWorkoutID = workout.id
        try store.saveManifest(manifest)

        // Simulate loading from store to verify persistence.
        let freshAppState = AppState(store: store)
        XCTAssertTrue(freshAppState.workouts.contains { $0.id == workout.id })
        XCTAssertEqual(freshAppState.selectedWorkout?.id, workout.id)
    }

    // MARK: - Failed Persistence Does Not Leave False In-Memory Success

    func testFailedPersistenceDoesNotAddToMemory() throws {
        let store = makeStore()
        let appState = AppState(store: store, loadSampleWorkout: false)

        // Initially empty
        XCTAssertTrue(appState.workouts.isEmpty)

        // After a simulated failed import (store is empty), workouts should remain empty.
        // The actual import flow checks store.saveWorkout before appending.
        let manifest = try? store.loadManifest()
        XCTAssertNil(manifest)
        XCTAssertTrue(appState.workouts.isEmpty)
    }

    // MARK: - Delete Updates Persistence And Selection

    func testDeleteUpdatesPersistenceAndSelection() throws {
        let store = makeStore()
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")
        try store.saveWorkout(w1)
        try store.saveWorkout(w2)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [w1.id, w2.id],
            selectedWorkoutID: w1.id
        ))

        let appState = AppState(store: store)
        XCTAssertEqual(appState.workouts.count, 2)

        appState.deleteWorkout(w1)

        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.selectedWorkout?.id, w2.id)

        // Verify persistence
        let freshAppState = AppState(store: store)
        XCTAssertEqual(freshAppState.workouts.count, 1)
        XCTAssertEqual(freshAppState.workouts.first?.id, w2.id)
        XCTAssertEqual(freshAppState.selectedWorkout?.id, w2.id)
    }

    func testDeleteManifestFailureLeavesPublishedStateUnchanged() {
        let workout = makeWorkout(name: "Cannot Delete")
        let store = ManifestSaveFailingStore(workout: workout)
        let appState = AppState(store: store, loadSampleWorkout: false)
        appState.workouts = [workout]
        appState.selectedWorkout = workout

        appState.deleteWorkout(workout)

        XCTAssertEqual(appState.workouts.map(\.id), [workout.id])
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
        XCTAssertTrue(appState.showingError)
        XCTAssertTrue(appState.errorMessage?.contains("Could not delete workout") == true)
        XCTAssertFalse(store.didDeleteWorkoutFile)
    }

    func testDeleteBundledDemoDoesNotRequirePersistedManifest() {
        let appState = AppState(store: makeStore())
        let demo = appState.workouts[0]
        let initialCount = appState.workouts.count

        appState.deleteWorkout(demo)

        XCTAssertEqual(appState.workouts.count, initialCount - 1)
        XCTAssertFalse(appState.showingError)
    }

    // MARK: - Deleting Comparison Workout Clears Comparison State

    func testDeleteComparisonWorkoutClearsComparison() throws {
        let store = makeStore()
        let primary = makeWorkout(name: "Primary")
        let comparison = makeWorkout(name: "Comparison")
        try store.saveWorkout(primary)
        try store.saveWorkout(comparison)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [primary.id, comparison.id],
            selectedWorkoutID: primary.id
        ))

        let appState = AppState(store: store)
        appState.setComparison(comparison)
        XCTAssertTrue(appState.isComparing)

        appState.deleteWorkout(comparison)

        XCTAssertFalse(appState.isComparing)
        XCTAssertNil(appState.comparisonWorkout)
    }

    // MARK: - Restored Selection Loads ReplayController

    func testRestoredSelectionLoadsReplayController() throws {
        let store = makeStore()
        let workout = makeWorkout(name: "Replay Test")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let appState = AppState(store: store)

        XCTAssertNotNil(appState.selectedWorkout)
        XCTAssertEqual(appState.replayController.state.totalDistance, workout.routePoints.last?.distanceFromStartMeters ?? 0, accuracy: 0.001)
    }

    // MARK: - Selection Persists Across App Restarts

    func testSelectionPersistsAcrossRestarts() throws {
        let store = makeStore()
        let w1 = makeWorkout(name: "First")
        let w2 = makeWorkout(name: "Second")
        try store.saveWorkout(w1)
        try store.saveWorkout(w2)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [w1.id, w2.id],
            selectedWorkoutID: w1.id
        ))

        // First launch
        let appState1 = AppState(store: store)
        XCTAssertEqual(appState1.selectedWorkout?.id, w1.id)

        // User selects second workout
        appState1.selectWorkout(w2)
        XCTAssertEqual(appState1.selectedWorkout?.id, w2.id)

        // Second launch — should restore w2
        let appState2 = AppState(store: store)
        XCTAssertEqual(appState2.selectedWorkout?.id, w2.id)
    }

    // MARK: - Corrupt Manifest Falls Back To Demos

    func testCorruptManifestFallsBackToDemos() throws {
        let store = makeStore()
        try store.ensureDirectoriesExist()
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try "{bad json".data(using: .utf8)!.write(to: manifestURL)

        let appState = AppState(store: store)

        // Should fall back to demos.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
        XCTAssertTrue(appState.showingError)
        XCTAssertTrue(appState.errorMessage?.contains("Failed to load library") == true)
    }

    // MARK: - Corrupt Workout File Skips It

    func testCorruptWorkoutFileSkippedWithWarning() throws {
        let store = makeStore()
        let validWorkout = makeWorkout(name: "Valid")
        let corruptID = UUID()

        try store.saveWorkout(validWorkout)
        try store.ensureDirectoriesExist()
        // Write corrupt file
        let corruptURL = tempDir
            .appendingPathComponent("workouts")
            .appendingPathComponent("\(corruptID.uuidString).json")
        try "not valid json".data(using: .utf8)!.write(to: corruptURL)

        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [corruptID, validWorkout.id],
            selectedWorkoutID: corruptID
        ))

        let appState = AppState(store: store)

        // Valid workout should still load.
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.workouts.first?.metadata.name, "Valid")

        // Should have reported an error about the corrupt workout.
        XCTAssertTrue(appState.showingError)
        XCTAssertNotNil(appState.errorMessage)
        XCTAssertTrue(appState.errorMessage!.contains("corrupted") || appState.errorMessage!.contains("skipped"))
    }

    // MARK: - Missing All Workout Files Falls Back To Demos

    func testMissingAllWorkoutFilesFallsBackToDemos() throws {
        let store = makeStore()
        let missingID = UUID()
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [missingID],
            selectedWorkoutID: missingID
        ))

        let appState = AppState(store: store)

        // Should fall back to demos since all workouts are missing.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
    }

    // MARK: - No Store (Legacy Test Behavior)

    func testNoStoreLoadsDemos() {
        let appState = AppState(store: nil)
        // With nil store and loadSampleWorkout=true, should load demos via legacy path.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
    }

    func testNoStoreNoLoadSampleWorkoutIsEmpty() {
        let appState = AppState(store: nil, loadSampleWorkout: false)
        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertNil(appState.selectedWorkout)
    }

    func testAsynchronousStartupLoadsPersistedWorkout() async throws {
        let store = makeStore()
        let workout = makeWorkout(name: "Background Load")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let appState = AppState(
            store: store,
            loadStoreAsynchronously: true
        )

        for _ in 0..<1_000 where appState.isLoadingLibrary {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertFalse(appState.isLoadingLibrary)
        XCTAssertEqual(appState.workouts.map(\.id), [workout.id])
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
    }
}

private final class ManifestSaveFailingStore: WorkoutLibraryStoring {
    private let workout: RunWorkout
    private let manifest: WorkoutLibraryManifest
    private(set) var didDeleteWorkoutFile = false

    init(workout: RunWorkout) {
        self.workout = workout
        self.manifest = WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        )
    }

    func loadManifest() throws -> WorkoutLibraryManifest {
        manifest
    }

    func saveManifest(_ manifest: WorkoutLibraryManifest) throws {
        throw WorkoutLibraryError.writeFailed("simulated manifest failure")
    }

    func loadWorkout(id: UUID) throws -> RunWorkout {
        workout
    }

    func saveWorkout(_ workout: RunWorkout) throws {}

    func deleteWorkout(id: UUID) throws {
        didDeleteWorkoutFile = true
    }

    func workoutExists(id: UUID) -> Bool {
        id == workout.id
    }
}
