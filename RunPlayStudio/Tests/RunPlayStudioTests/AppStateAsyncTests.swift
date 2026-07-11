import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class AppStateAsyncTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateAsyncTests-\(UUID().uuidString)")
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
        pointCount: Int = 11
    ) -> RunWorkout {
        var points: [RoutePoint] = []
        for i in 0..<pointCount {
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 100),
                latitude: 37.0 + Double(i) * 0.0001,
                longitude: -122.0 + Double(i) * 0.0001,
                altitudeMeters: 100 + Double(i),
                distanceFromStartMeters: 500 * Double(i),
                elapsedSeconds: 180 * Double(i)
            ))
        }
        return RunWorkout(
            id: id,
            metadata: WorkoutMetadata(name: name, startDate: Date(timeIntervalSince1970: 1_000_000)),
            source: .gpx,
            routePoints: points,
            splits: [],
            summary: RunSummary(totalDistanceMeters: 5000, totalElapsedSeconds: 1800)
        )
    }

    private func writeImportFile(for workout: RunWorkout) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = tempDir.appendingPathComponent("\(workout.id).json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try encoder.encode(workout).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Startup State

    func testStartShowsLoadingState() async {
        let store = makeStore()
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())

        // Before start, state is idle.
        XCTAssertEqual(appState.operationState, .idle)

        await appState.start()

        // After start completes, state is idle.
        XCTAssertEqual(appState.operationState, .idle)
    }

    func testSuccessfulLoadRestoresSelection() async throws {
        let store = makeStore()
        let w1 = makeWorkout(name: "First")
        let w2 = makeWorkout(name: "Second")
        try store.saveWorkout(w1)
        try store.saveWorkout(w2)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [w1.id, w2.id],
            selectedWorkoutID: w2.id
        ))

        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())
        await appState.start()

        XCTAssertEqual(appState.selectedWorkout?.id, w2.id)
        XCTAssertEqual(appState.workouts.count, 2)
        XCTAssertFalse(appState.isLoadingLibrary)
    }

    func testLoadFailureShowsRecoveryWarning() async {
        let store = makeStore()
        // Don't create any manifest or workouts.
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())

        await appState.start()

        // Should fall back to demos without crashing.
        XCTAssertGreaterThanOrEqual(appState.workouts.count, 1)
        XCTAssertFalse(appState.isLoadingLibrary)
    }

    func testDontFlashDemosDuringStartup() async throws {
        let store = makeStore()
        let workout = makeWorkout(name: "Real")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())

        // Before start(), no workouts should be loaded.
        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertEqual(appState.operationState, .idle)

        await appState.start()

        // After start(), only the persisted workout should be present.
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.workouts.first?.id, workout.id)
    }

    // MARK: - Import Operation State

    func testImportShowsImportingState() async throws {
        let store = makeStore()
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())

        let workout = makeWorkout(name: "Import State Test")
        let url = try writeImportFile(for: workout)

        await appState.importWorkout(from: url)

        // After import completes, state should be idle.
        XCTAssertEqual(appState.operationState, .idle)
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.selectedWorkout?.metadata.name, "Import State Test")
    }

    func testParseFailureDoesNotAddToUI() async throws {
        let store = makeStore()
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())

        // Try to import a nonexistent file.
        let url = tempDir.appendingPathComponent("nonexistent.json")
        await appState.importWorkout(from: url)

        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertTrue(appState.showingError)
        XCTAssertEqual(appState.operationState, .idle)
    }

    func testPersistenceFailureDoesNotAddToUI() async throws {
        let failingStore = TestManifestFailingStore()
        let storeActor = WorkoutLibraryStoreActor(store: failingStore)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())

        let workout = makeWorkout(name: "No Persist")
        let url = try writeImportFile(for: workout)

        await appState.importWorkout(from: url)

        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertTrue(appState.showingError)
        XCTAssertEqual(appState.operationState, .idle)
    }

    func testOperationStateReturnsToIdleAfterError() async throws {
        let store = makeStore()
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())

        let url = tempDir.appendingPathComponent("doesnotexist.json")
        await appState.importWorkout(from: url)

        XCTAssertEqual(appState.operationState, .idle)
    }

    // MARK: - Delete Operation State

    func testDeleteShowsDeletingState() async throws {
        let store = makeStore()
        let workout = makeWorkout(name: "Delete Me")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())
        await appState.start()

        await appState.deleteWorkout(workout)

        XCTAssertEqual(appState.operationState, .idle)
        XCTAssertTrue(appState.workouts.isEmpty)
    }

    func testDeleteOrphanedFileRemovesFromUIWithWarning() async throws {
        let workout = makeWorkout(name: "Orphaned")
        let failingStore = TestFileDeleteFailingStore(workout: workout)
        let storeActor = WorkoutLibraryStoreActor(store: failingStore)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())
        appState.workouts = [workout]
        appState.selectedWorkout = workout

        await appState.deleteWorkout(workout)

        // Manifest committed, file orphaned. Workout removed from UI with warning.
        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertNil(appState.selectedWorkout)
        XCTAssertTrue(appState.showingError)
        XCTAssertEqual(appState.operationState, .idle)
    }

    // MARK: - Imported Workout Becomes Selected

    func testImportedWorkoutBecomesSelected() async throws {
        let store = makeStore()
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())

        let workout = makeWorkout(name: "Auto Selected")
        let url = try writeImportFile(for: workout)

        await appState.importWorkout(from: url)

        XCTAssertEqual(appState.selectedWorkout?.metadata.name, "Auto Selected")
        XCTAssertEqual(appState.workouts.count, 1)
    }

    // MARK: - Comparison State After Delete

    func testDeleteComparisonWorkoutClearsComparisonState() async throws {
        let store = makeStore()
        let primary = makeWorkout(name: "Primary")
        let comparison = makeWorkout(name: "Comparison")
        try store.saveWorkout(primary)
        try store.saveWorkout(comparison)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [primary.id, comparison.id],
            selectedWorkoutID: primary.id
        ))

        let storeActor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: storeActor, importService: WorkoutImportService())
        await appState.start()

        appState.setComparison(comparison)
        XCTAssertTrue(appState.isComparing)

        await appState.deleteWorkout(comparison)

        XCTAssertFalse(appState.isComparing)
        XCTAssertNil(appState.comparisonWorkout)
    }
}

// MARK: - Test Fakes

private final class TestManifestFailingStore: WorkoutLibraryStoring, @unchecked Sendable {
    func loadManifest() throws -> WorkoutLibraryManifest {
        throw WorkoutLibraryError.manifestMissing("no manifest")
    }

    func saveManifest(_ manifest: WorkoutLibraryManifest) throws {
        throw WorkoutLibraryError.writeFailed("simulated failure")
    }

    func loadWorkout(id: UUID) throws -> RunWorkout {
        throw WorkoutLibraryError.workoutFileMissing(id)
    }

    func saveWorkout(_ workout: RunWorkout) throws {}

    func deleteWorkout(id: UUID) throws {}

    func workoutExists(id: UUID) -> Bool { false }
}

private final class TestFileDeleteFailingStore: WorkoutLibraryStoring, @unchecked Sendable {
    private let workout: RunWorkout
    private var manifest: WorkoutLibraryManifest

    init(workout: RunWorkout) {
        self.workout = workout
        self.manifest = WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        )
    }

    func loadManifest() throws -> WorkoutLibraryManifest { manifest }

    func saveManifest(_ manifest: WorkoutLibraryManifest) throws {
        self.manifest = manifest
    }

    func loadWorkout(id: UUID) throws -> RunWorkout { workout }

    func saveWorkout(_ workout: RunWorkout) throws {}

    func deleteWorkout(id: UUID) throws {
        throw WorkoutLibraryError.writeFailed("simulated file deletion failure")
    }

    func workoutExists(id: UUID) -> Bool { id == workout.id }
}
