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

    private func makeStoreActor(store: WorkoutLibraryStoring? = nil) -> WorkoutLibraryStoreActor {
        WorkoutLibraryStoreActor(store: store ?? makeStore())
    }

    private func makeAppState(
        store: WorkoutLibraryStoring? = nil,
        loadSampleWorkout: Bool = true
    ) -> AppState {
        let storeActor = store.map { WorkoutLibraryStoreActor(store: $0) }
        let importService = WorkoutImportService()
        let state = AppState(storeActor: storeActor, importService: importService)
        if loadSampleWorkout {
            // For tests that need synchronous startup, call start() and wait.
            // But many tests set up state directly, so we handle that below.
        }
        return state
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

    private func writeImportFile(for workout: RunWorkout) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = tempDir.appendingPathComponent("import.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try encoder.encode(workout).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Startup With No Saved Workouts Loads Demos

    func testStartupWithNoSavedWorkoutsLoadsDemos() async {
        let store = makeStore()
        let appState = makeAppState(store: store)

        await appState.start()

        // With no manifest, it should load bundled demos.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
        XCTAssertNotNil(appState.selectedWorkout)
    }

    func testStartupWithEmptyManifestLoadsDemos() async throws {
        let store = makeStore()
        try store.saveManifest(WorkoutLibraryManifest(workoutIDs: []))

        let appState = makeAppState(store: store)
        await appState.start()

        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
    }

    func testDeletingTagKeepsActiveCollectionUnmodifiedAfterSavedFilterRepair() async throws {
        let store = makeStore()
        let workout = makeWorkout(name: "Tagged Run")
        let tag = WorkoutTag(name: "Race", color: .red)
        let collection = WorkoutSmartCollection(
            name: "Races",
            query: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(
                    tags: .selected(tagIDs: [tag.id], match: .any)
                )
            )
        )
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id,
            tags: [tag],
            tagAssignments: [WorkoutTagAssignment(workoutID: workout.id, tagIDs: [tag.id])],
            smartCollections: [collection]
        ))

        let appState = makeAppState(store: store)
        await appState.start()
        appState.showSmartCollection(id: collection.id)
        XCTAssertFalse(appState.workoutLibrary.isCollectionModified)

        let deleted = await appState.deleteTag(id: tag.id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(appState.workoutLibrary.isCollectionModified)
        XCTAssertEqual(appState.workoutLibrary.tagFilter, .anyTags)
    }

    // MARK: - Startup With Saved Workouts Does Not Insert Demos

    func testStartupWithSavedWorkoutsDoesNotInsertDemos() async throws {
        let store = makeStore()
        let workout = makeWorkout(name: "My Persisted Run")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let appState = makeAppState(store: store)
        await appState.start()

        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.workouts.first?.metadata.name, "My Persisted Run")
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
    }

    func testStartupRepairsStaleSelectedWorkoutID() async throws {
        let store = makeStore()
        let workout = makeWorkout(name: "Valid")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: UUID()
        ))

        let appState = makeAppState(store: store)
        await appState.start()

        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
        XCTAssertEqual(try store.loadManifest().selectedWorkoutID, workout.id)
    }

    // MARK: - Successful Import Persists

    func testSuccessfulImportPersists() async throws {
        let store = makeStore()
        let appState = makeAppState(store: store, loadSampleWorkout: false)
        let url = try writeImportFile(for: makeWorkout(name: "Imported Run"))

        await appState.importWorkout(from: url)

        let importedID = try XCTUnwrap(appState.selectedWorkout?.id)
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.selectedWorkout?.metadata.name, "Imported Run")
        XCTAssertTrue(store.workoutExists(id: importedID))
        XCTAssertEqual(try store.loadManifest().workoutIDs, [importedID])

        // Verify persistence across restarts.
        let freshAppState = makeAppState(store: store)
        await freshAppState.start()
        XCTAssertEqual(freshAppState.workouts.map(\.id), [importedID])
        XCTAssertEqual(freshAppState.selectedWorkout?.id, importedID)
    }

    // MARK: - Failed Persistence Does Not Leave False In-Memory Success

    func testFailedPersistenceDoesNotAddToMemory() async throws {
        let seed = makeWorkout(name: "Existing")
        let store = ManifestSaveFailingStore(workout: seed)
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let importService = WorkoutImportService()
        let appState = AppState(storeActor: storeActor, importService: importService)
        let url = try writeImportFile(for: makeWorkout(name: "Cannot Persist"))

        await appState.importWorkout(from: url)

        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertNil(appState.selectedWorkout)
        XCTAssertTrue(appState.showingError)
        XCTAssertTrue(appState.errorMessage?.contains("could not be saved") == true
            || appState.errorMessage?.contains("Write failed") == true)
    }

    // MARK: - Delete Updates Persistence And Selection

    func testDeleteUpdatesPersistenceAndSelection() async throws {
        let store = makeStore()
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")
        try store.saveWorkout(w1)
        try store.saveWorkout(w2)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [w1.id, w2.id],
            selectedWorkoutID: w1.id
        ))

        let appState = makeAppState(store: store)
        await appState.start()
        XCTAssertEqual(appState.workouts.count, 2)

        await appState.deleteWorkout(w1)

        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.selectedWorkout?.id, w2.id)

        // Verify persistence
        let freshAppState = makeAppState(store: store)
        await freshAppState.start()
        XCTAssertEqual(freshAppState.workouts.count, 1)
        XCTAssertEqual(freshAppState.workouts.first?.id, w2.id)
        XCTAssertEqual(freshAppState.selectedWorkout?.id, w2.id)
    }

    func testDeleteManifestFailureLeavesPublishedStateUnchanged() async {
        let workout = makeWorkout(name: "Cannot Delete")
        let store = ManifestSaveFailingStore(workout: workout)
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: nil)
        appState.workouts = [workout]
        appState.selectedWorkout = workout

        await appState.deleteWorkout(workout)

        XCTAssertEqual(appState.workouts.map(\.id), [workout.id])
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
        XCTAssertTrue(appState.showingError)
        XCTAssertTrue(appState.errorMessage?.contains("Could not delete workout") == true)
    }

    func testDeleteBundledDemoDoesNotRequirePersistedManifest() async {
        let store = makeStore()
        let appState = makeAppState(store: store)
        await appState.start()
        let demo = appState.workouts[0]
        let initialCount = appState.workouts.count

        await appState.deleteWorkout(demo)

        XCTAssertEqual(appState.workouts.count, initialCount - 1)
        XCTAssertFalse(appState.showingError)
    }

    func testDeleteFileFailureOrphansFileAndWarns() async throws {
        let workout = makeWorkout(name: "Orphaned")
        let store = WorkoutDeleteFailingStore(workout: workout)
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: nil)
        appState.workouts = [workout]
        appState.selectedWorkout = workout

        await appState.deleteWorkout(workout)

        // Manifest committed, file orphaned. Workout removed from UI with warning.
        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertTrue(appState.showingError)
    }

    // MARK: - Deleting Comparison Workout Clears Comparison State

    func testDeleteComparisonWorkoutClearsComparison() async throws {
        let store = makeStore()
        let primary = makeWorkout(name: "Primary")
        let comparison = makeWorkout(name: "Comparison")
        try store.saveWorkout(primary)
        try store.saveWorkout(comparison)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [primary.id, comparison.id],
            selectedWorkoutID: primary.id
        ))

        let appState = makeAppState(store: store)
        await appState.start()
        appState.setComparison(comparison)
        XCTAssertTrue(appState.isComparing)

        await appState.deleteWorkout(comparison)

        XCTAssertFalse(appState.isComparing)
        XCTAssertNil(appState.comparisonWorkout)
    }

    // MARK: - Restored Selection Loads ReplayController

    func testRestoredSelectionLoadsReplayController() async throws {
        let store = makeStore()
        let workout = makeWorkout(name: "Replay Test")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let appState = makeAppState(store: store)
        await appState.start()

        XCTAssertNotNil(appState.selectedWorkout)
        XCTAssertEqual(appState.replayController.state.totalDistance, workout.routePoints.last?.distanceFromStartMeters ?? 0, accuracy: 0.001)
    }

    // MARK: - Selection Persists Across App Restarts

    func testSelectionPersistsAcrossRestarts() async throws {
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
        let appState1 = makeAppState(store: store)
        await appState1.start()
        XCTAssertEqual(appState1.selectedWorkout?.id, w1.id)

        // User selects second workout
        appState1.selectWorkout(w2)
        XCTAssertEqual(appState1.selectedWorkout?.id, w2.id)

        // Give async selection persistence time to complete.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Second launch — should restore w2
        let appState2 = makeAppState(store: store)
        await appState2.start()
        XCTAssertEqual(appState2.selectedWorkout?.id, w2.id)
    }

    func testSelectionPersistenceFailureIsReported() async {
        let workout = makeWorkout(name: "Selection")
        let store = ManifestSaveFailingStore(workout: workout)
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: nil)
        appState.workouts = [workout]

        appState.selectWorkout(workout)

        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
        // Wait for async persistence to fail.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(appState.showingError)
        XCTAssertTrue(appState.errorMessage?.contains("could not be saved") == true)
    }

    func testClearingSelectionPersistsNilSelection() async throws {
        let store = makeStore()
        let workout = makeWorkout(name: "Selection")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))
        let appState = makeAppState(store: store)
        await appState.start()

        appState.selectWorkout(nil)

        XCTAssertNil(appState.selectedWorkout)
        // Wait for async persistence.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(try store.loadManifest().selectedWorkoutID)
    }

    // MARK: - Corrupt Manifest Falls Back To Demos

    func testCorruptManifestFallsBackToDemos() async throws {
        let store = makeStore()
        try store.ensureDirectoriesExist()
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try "{bad json".data(using: .utf8)!.write(to: manifestURL)

        let appState = makeAppState(store: store)
        await appState.start()

        // Should fall back to demos.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
        XCTAssertTrue(appState.showingError)
        XCTAssertTrue(appState.errorMessage?.contains("Failed to load library") == true)
    }

    // MARK: - Corrupt Workout File Skips It

    func testCorruptWorkoutFileSkippedWithWarning() async throws {
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

        let appState = makeAppState(store: store)
        await appState.start()

        // Valid workout should still load.
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.workouts.first?.metadata.name, "Valid")

        // Should have reported an error about the corrupt workout.
        XCTAssertTrue(appState.showingError)
        XCTAssertNotNil(appState.errorMessage)
        XCTAssertTrue(appState.errorMessage!.contains("corrupted") || appState.errorMessage!.contains("skipped"))
    }

    // MARK: - Missing All Workout Files Falls Back To Demos

    func testMissingAllWorkoutFilesFallsBackToDemos() async throws {
        let store = makeStore()
        let missingID = UUID()
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [missingID],
            selectedWorkoutID: missingID
        ))

        let appState = makeAppState(store: store)
        await appState.start()

        // Should fall back to demos since all workouts are missing.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
    }

    // MARK: - No Store (Legacy Test Behavior)

    func testNoStoreLoadsDemos() async {
        let appState = AppState(storeActor: nil, importService: nil)
        await appState.start()
        // With nil store, should load demos via loadSampleWorkouts.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
    }

    func testNoStoreNoStartIsEmpty() {
        let appState = AppState(storeActor: nil, importService: nil)
        // Without calling start(), state is empty.
        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertNil(appState.selectedWorkout)
    }
}

// MARK: - Test Fakes

private final class ManifestSaveFailingStore: WorkoutLibraryStoring, @unchecked Sendable {
    private let workout: RunWorkout
    private let manifest: WorkoutLibraryManifest
    private(set) var didDeleteWorkoutFile = false
    private(set) var savedWorkoutID: UUID?
    private(set) var deletedWorkoutIDs: [UUID] = []

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

    func saveWorkout(_ workout: RunWorkout) throws {
        savedWorkoutID = workout.id
    }

    func deleteWorkout(id: UUID) throws {
        didDeleteWorkoutFile = true
        deletedWorkoutIDs.append(id)
    }

    func workoutExists(id: UUID) -> Bool {
        id == workout.id
    }
}

private final class WorkoutDeleteFailingStore: WorkoutLibraryStoring, @unchecked Sendable {
    private let workout: RunWorkout
    private var manifest: WorkoutLibraryManifest

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
        self.manifest = manifest
    }

    func loadWorkout(id: UUID) throws -> RunWorkout {
        workout
    }

    func saveWorkout(_ workout: RunWorkout) throws {}

    func deleteWorkout(id: UUID) throws {
        throw WorkoutLibraryError.writeFailed("simulated file deletion failure")
    }

    func workoutExists(id: UUID) -> Bool {
        id == workout.id
    }
}
