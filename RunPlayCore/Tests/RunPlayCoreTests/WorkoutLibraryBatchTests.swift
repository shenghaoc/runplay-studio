import XCTest
@testable import RunPlayCore

final class WorkoutLibraryBatchTests: XCTestCase {
    private var tempDir: URL!
    private var store: FileWorkoutLibraryStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchTests-\(UUID().uuidString)")
        store = FileWorkoutLibraryStore(rootURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeWorkout(name: String = "W") -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<3 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i)),
                latitude: 37 + Double(i) * 0.0001,
                longitude: -122,
                distanceFromStartMeters: Double(i) * 10,
                elapsedSeconds: Double(i)
            ))
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: start),
            source: .gpx,
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 20, totalElapsedSeconds: 2)
        )
    }

    func testEmptyBatchCommitIsNoOp() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let token = try await actor.beginBatchImport()
        let ids = try await actor.commitBatchImport(token, selectedWorkoutID: nil)
        XCTAssertTrue(ids.isEmpty)
        XCTAssertThrowsError(try store.loadManifest())
    }

    func testBatchStagesThenOneManifestWrite() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let w1 = makeWorkout(name: "One")
        let w2 = makeWorkout(name: "Two")
        let token = try await actor.beginBatchImport()
        try await actor.stageWorkout(w1, in: token)
        try await actor.stageWorkout(w2, in: token)

        // Manifest still missing until commit.
        XCTAssertThrowsError(try store.loadManifest())
        XCTAssertFalse(store.workoutExists(id: w1.id))

        let committed = try await actor.commitBatchImport(token, selectedWorkoutID: w2.id)
        XCTAssertEqual(Set(committed), Set([w1.id, w2.id]))

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.workoutIDs, [w1.id, w2.id])
        XCTAssertEqual(manifest.selectedWorkoutID, w2.id)
        XCTAssertTrue(store.workoutExists(id: w1.id))
        XCTAssertTrue(store.workoutExists(id: w2.id))
    }

    func testRollbackRemovesStaging() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let w = makeWorkout()
        let token = try await actor.beginBatchImport()
        try await actor.stageWorkout(w, in: token)
        await actor.rollbackBatchImport(token)
        XCTAssertThrowsError(try store.loadManifest())
        XCTAssertFalse(store.workoutExists(id: w.id))
        // Staging dir cleaned
        let staging = tempDir.appendingPathComponent(".staging")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testDuplicateIDInBatchRejected() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let w = makeWorkout()
        let token = try await actor.beginBatchImport()
        try await actor.stageWorkout(w, in: token)
        do {
            try await actor.stageWorkout(w, in: token)
            XCTFail("expected duplicate")
        } catch let error as WorkoutLibraryStoreError {
            XCTAssertEqual(error, .duplicateWorkoutID(w.id))
        }
        await actor.rollbackBatchImport(token)
    }

    func testStaleStagingCleanupOnLoad() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        let w = makeWorkout()
        let token = try await actor.beginBatchImport()
        try await actor.stageWorkout(w, in: token)
        // Simulate crash: abandon batch without rollback (leave active batch?
        // recoverStaleState cleans .staging regardless)
        // Force cleanup via new actor load
        let actor2 = WorkoutLibraryStoreActor(store: store)
        _ = await actor2.loadLibrary()
        let staging = tempDir.appendingPathComponent(".staging")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testConcurrentBatchConflict() async throws {
        let actor = WorkoutLibraryStoreActor(store: store)
        _ = try await actor.beginBatchImport()
        do {
            _ = try await actor.beginBatchImport()
            XCTFail("expected conflict")
        } catch {
            // expected
        }
    }
}
