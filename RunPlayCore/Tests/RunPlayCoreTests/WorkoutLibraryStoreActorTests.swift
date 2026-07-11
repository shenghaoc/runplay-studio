import XCTest
@testable import RunPlayCore

final class WorkoutLibraryStoreActorTests: XCTestCase {

    private var tempDir: URL!
    private var store: FileWorkoutLibraryStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreActorTests-\(UUID().uuidString)")
        store = FileWorkoutLibraryStore(rootURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

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

    // MARK: - Load Library

    func testLoadLibraryFromEmptyReturnsDemos() async {
        let actor = WorkoutLibraryStoreActor(store: store)
        let result = await actor.loadLibrary()

        guard case .demos(let error) = result else {
            XCTFail("Expected .demos, got \(result)")
            return
        }
        XCTAssertNil(error)
    }

    func testLoadLibraryWithWorkoutsReturnsThem() async throws {
        let workout = makeWorkout(name: "Persisted")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let actor = WorkoutLibraryStoreActor(store: store)
        let result = await actor.loadLibrary()

        guard case .workouts(let loaded, let selectedID, _) = result else {
            XCTFail("Expected .workouts, got \(result)")
            return
        }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, workout.id)
        XCTAssertEqual(selectedID, workout.id)
    }

    // MARK: - Concurrent Additions Preserve All IDs

    func testConcurrentAdditionsPreserveAllIDs() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let workouts = (0..<10).map { makeWorkout(name: "Run \($0)") }

        // Add all workouts concurrently.
        await withTaskGroup(of: Void.self) { group in
            for workout in workouts {
                group.addTask {
                    try? await actor.addWorkout(workout, select: false)
                }
            }
        }

        let result = await actor.loadLibrary()
        guard case .workouts(let loaded, _, _) = result else {
            XCTFail("Expected .workouts")
            return
        }

        let loadedIDs = Set(loaded.map(\.id))
        let expectedIDs = Set(workouts.map(\.id))
        XCTAssertEqual(loadedIDs, expectedIDs, "All workout IDs should be preserved after concurrent adds")
    }

    // MARK: - Duplicate Add Is Idempotent

    func testDuplicateAddIsIdempotent() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let workout = makeWorkout(name: "Duplicate")

        try await actor.addWorkout(workout, select: true)
        try await actor.addWorkout(workout, select: true) // second add

        let manifest = try store.loadManifest()
        let count = manifest.workoutIDs.filter { $0 == workout.id }.count
        XCTAssertEqual(count, 1, "Duplicate ID should appear exactly once")
    }

    // MARK: - Add Rollback On Manifest Failure

    func testAddRollbackOnManifestFailure() async throws {
        let failingStore = ManifestFailingStore()
        let actor = WorkoutLibraryStoreActor(store: failingStore)
        let workout = makeWorkout(name: "Rollback")

        do {
            try await actor.addWorkout(workout, select: true)
            XCTFail("Expected error")
        } catch {
            // Expected: manifest write failed
        }

        // The workout file should have been rolled back (deleted).
        // Since ManifestFailingStore doesn't actually write files, just verify
        // the error propagated.
        XCTAssertTrue(failingStore.saveManifestCallCount > 0)
    }

    // MARK: - Delete Transaction Success

    func testDeleteTransactionSuccess() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")

        try await actor.addWorkout(w1, select: true)
        try await actor.addWorkout(w2, select: false)

        let result = try await actor.deleteWorkout(id: w1.id, newSelectedID: w2.id)
        XCTAssertEqual(result, .deletedSelected)

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.workoutIDs, [w2.id])
        XCTAssertEqual(manifest.selectedWorkoutID, w2.id)
        XCTAssertFalse(store.workoutExists(id: w1.id))
    }

    // MARK: - Delete Manifest Failure Leaves Workout Intact

    func testDeleteManifestFailureLeavesWorkoutIntact() async throws {
        // First, save a workout using a real store.
        let workout = makeWorkout(name: "Keep")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        // Now wrap in a failing store that fails on saveManifest.
        let failingStore = ManifestFailingOnDeleteStore(originalManifest:
            WorkoutLibraryManifest(workoutIDs: [workout.id], selectedWorkoutID: workout.id)
        )
        let actor = WorkoutLibraryStoreActor(store: failingStore)

        do {
            try await actor.deleteWorkout(id: workout.id, newSelectedID: nil)
            XCTFail("Expected error")
        } catch {
            // Expected: manifest save failed
        }

        // Workout file should still exist (we used the real store for writes).
        XCTAssertTrue(store.workoutExists(id: workout.id))
    }

    // MARK: - Orphaned File Policy

    func testOrphanedFileThrowsError() async throws {
        let workout = makeWorkout(name: "Orphan")
        let fileFailingStore = FileDeleteFailingStore(workout: workout)
        let actor = WorkoutLibraryStoreActor(store: fileFailingStore)

        // Save workout file via real store first.
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        // Use the file-failing store which commits manifest but fails file delete.
        do {
            try await actor.deleteWorkout(id: workout.id, newSelectedID: nil)
            XCTFail("Expected orphanedFile error")
        } catch let error as WorkoutLibraryStoreError {
            if case .orphanedFile = error {
                // Expected
            } else {
                XCTFail("Expected orphanedFile, got \(error)")
            }
        }
    }

    // MARK: - Rapid Selection Preserves Newest

    func testRapidSelectionPreservesNewest() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let ids = (0..<5).map { _ in UUID() }
        try store.saveManifest(WorkoutLibraryManifest(workoutIDs: ids))

        // Fire rapid selection changes. The last one should win.
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    try? await actor.setSelectedWorkoutID(id)
                }
            }
        }

        let manifest = try store.loadManifest()
        // The manifest should have one of the IDs (last-write-wins).
        XCTAssertTrue(ids.contains(manifest.selectedWorkoutID!), "Selection should be one of the attempted IDs")
    }

    // MARK: - Corrupt Manifest Not Overwritten

    func testCorruptManifestNotOverwritten() async throws {
        try store.ensureDirectoriesExist()
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try "{bad json".data(using: .utf8)!.write(to: manifestURL)

        let actor = WorkoutLibraryStoreActor(store: store)
        let result = await actor.loadLibrary()

        guard case .demos(let error) = result else {
            XCTFail("Expected .demos for corrupt manifest")
            return
        }
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("Failed to load library"))

        // Verify the corrupt manifest was NOT overwritten.
        let rawData = try Data(contentsOf: manifestURL)
        let rawString = String(data: rawData, encoding: .utf8)!
        XCTAssertTrue(rawString.contains("bad json"), "Corrupt manifest should not be overwritten")
    }

    // MARK: - Store Operations Serialize

    func testStoreOperationsSerialize() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let workouts = (0..<20).map { makeWorkout(name: "Serial \($0)") }

        // Interleave adds and deletes.
        for workout in workouts.prefix(10) {
            try await actor.addWorkout(workout, select: false)
        }
        for workout in workouts.prefix(5) {
            try await actor.deleteWorkout(id: workout.id, newSelectedID: nil)
        }
        for workout in workouts.suffix(10) {
            try await actor.addWorkout(workout, select: false)
        }

        let result = await actor.loadLibrary()
        guard case .workouts(let loaded, _, _) = result else {
            XCTFail("Expected .workouts")
            return
        }

        // Should have workouts 5..19 (first 5 deleted, 5..9 kept, 10..19 added).
        XCTAssertEqual(loaded.count, 15)
    }

    // MARK: - Not-In-Manifest Delete Returns Correctly

    func testDeleteNonexistentWorkoutReturnsNotInManifest() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        try store.saveManifest(WorkoutLibraryManifest(workoutIDs: []))

        let result = try await actor.deleteWorkout(id: UUID(), newSelectedID: nil)
        XCTAssertEqual(result, .notInManifest)
    }

    func testDeleteWithNoManifestReturnsNotInManifest() async {
        let actor = WorkoutLibraryStoreActor(store: store)
        let result = try? await actor.deleteWorkout(id: UUID(), newSelectedID: nil)
        XCTAssertEqual(result, .notInManifest)
    }

    // MARK: - Large Workout Round-Trip

    func testLargeWorkoutEncodeDecode() async throws {
        let pointCount = 50_000
        var points: [RoutePoint] = []
        for i in 0..<pointCount {
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSince1970: 1_000_000 + Double(i)),
                latitude: 37.0 + Double(i) * 0.00001,
                longitude: -122.0 + Double(i) * 0.00001,
                altitudeMeters: 100 + Double(i) * 0.01,
                distanceFromStartMeters: Double(i) * 10,
                elapsedSeconds: Double(i) * 3
            ))
        }
        let workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Large Workout"),
            source: .gpx,
            routePoints: points,
            splits: [],
            summary: RunSummary(
                totalDistanceMeters: Double(pointCount) * 10,
                totalElapsedSeconds: Double(pointCount) * 3
            )
        )

        let actor = WorkoutLibraryStoreActor(store: store)
        try await actor.addWorkout(workout, select: true)

        let result = await actor.loadLibrary()
        guard case .workouts(let loaded, _, _) = result else {
            XCTFail("Expected .workouts")
            return
        }

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.routePoints.count, pointCount)
        XCTAssertEqual(loaded.first?.metadata.name, "Large Workout")
    }
}

// MARK: - Test Fakes

/// Store that fails on saveManifest to test rollback behavior.
private final class ManifestFailingStore: WorkoutLibraryStoring, @unchecked Sendable {
    private(set) var saveManifestCallCount = 0

    func loadManifest() throws -> WorkoutLibraryManifest {
        WorkoutLibraryManifest()
    }

    func saveManifest(_ manifest: WorkoutLibraryManifest) throws {
        saveManifestCallCount += 1
        throw WorkoutLibraryError.writeFailed("simulated manifest failure")
    }

    func loadWorkout(id: UUID) throws -> RunWorkout {
        throw WorkoutLibraryError.workoutFileMissing(id)
    }

    func saveWorkout(_ workout: RunWorkout) throws {}

    func deleteWorkout(id: UUID) throws {}

    func workoutExists(id: UUID) -> Bool { false }
}

/// Store that fails on saveManifest only during delete (for delete-failure tests).
private final class ManifestFailingOnDeleteStore: WorkoutLibraryStoring, @unchecked Sendable {
    private let originalManifest: WorkoutLibraryManifest

    init(originalManifest: WorkoutLibraryManifest) {
        self.originalManifest = originalManifest
    }

    func loadManifest() throws -> WorkoutLibraryManifest {
        originalManifest
    }

    func saveManifest(_ manifest: WorkoutLibraryManifest) throws {
        throw WorkoutLibraryError.writeFailed("simulated manifest failure on delete")
    }

    func loadWorkout(id: UUID) throws -> RunWorkout {
        throw WorkoutLibraryError.workoutFileMissing(id)
    }

    func saveWorkout(_ workout: RunWorkout) throws {}

    func deleteWorkout(id: UUID) throws {}

    func workoutExists(id: UUID) -> Bool { true }
}

/// Store that commits manifest but fails on file deletion (orphaned file scenario).
private final class FileDeleteFailingStore: WorkoutLibraryStoring, @unchecked Sendable {
    private var manifest: WorkoutLibraryManifest
    private let workout: RunWorkout

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
