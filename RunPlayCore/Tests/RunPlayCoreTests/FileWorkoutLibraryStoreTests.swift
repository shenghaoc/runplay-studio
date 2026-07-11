import XCTest
@testable import RunPlayCore

final class FileWorkoutLibraryStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: FileWorkoutLibraryStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkoutLibraryTests-\(UUID().uuidString)")
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

    // MARK: - Empty Library

    func testLoadManifestFromEmptyLibraryThrows() {
        XCTAssertThrowsError(try store.loadManifest()) { error in
            guard case WorkoutLibraryError.manifestMissing = error else {
                XCTFail("Expected manifestMissing, got \(error)")
                return
            }
        }
    }

    // MARK: - Save and Reload One Workout

    func testSaveAndReloadOneWorkout() throws {
        let workout = makeWorkout()
        let manifest = WorkoutLibraryManifest(workoutIDs: [workout.id])

        try store.saveWorkout(workout)
        try store.saveManifest(manifest)

        let loadedManifest = try store.loadManifest()
        XCTAssertEqual(loadedManifest.workoutIDs, [workout.id])

        let loadedWorkout = try store.loadWorkout(id: workout.id)
        XCTAssertEqual(loadedWorkout.id, workout.id)
        XCTAssertEqual(loadedWorkout.metadata.name, "Test Run")
        XCTAssertEqual(loadedWorkout.summary.totalDistanceMeters, 5000)
        XCTAssertEqual(loadedWorkout.summary.totalElapsedSeconds, 1800)
        XCTAssertEqual(loadedWorkout.routePoints.count, 11)
    }

    // MARK: - Save and Reload Multiple Workouts

    func testSaveAndReloadMultipleWorkouts() throws {
        let w1 = makeWorkout(name: "Morning Run", distance: 5000)
        let w2 = makeWorkout(name: "Evening Run", distance: 10000)
        let manifest = WorkoutLibraryManifest(workoutIDs: [w1.id, w2.id])

        try store.saveWorkout(w1)
        try store.saveWorkout(w2)
        try store.saveManifest(manifest)

        let loaded = try store.loadManifest()
        XCTAssertEqual(loaded.workoutIDs.count, 2)
        XCTAssertEqual(loaded.workoutIDs, [w1.id, w2.id])

        let loaded1 = try store.loadWorkout(id: w1.id)
        let loaded2 = try store.loadWorkout(id: w2.id)
        XCTAssertEqual(loaded1.metadata.name, "Morning Run")
        XCTAssertEqual(loaded2.metadata.name, "Evening Run")
    }

    // MARK: - Order Preservation

    func testOrderPreservedAcrossReload() throws {
        let ids = (0..<5).map { _ in UUID() }
        let manifest = WorkoutLibraryManifest(workoutIDs: ids)
        try store.saveManifest(manifest)

        let loaded = try store.loadManifest()
        XCTAssertEqual(loaded.workoutIDs, ids)
    }

    // MARK: - Selected Workout Restoration

    func testSelectedWorkoutRestored() throws {
        let id = UUID()
        let manifest = WorkoutLibraryManifest(workoutIDs: [id], selectedWorkoutID: id)
        try store.saveManifest(manifest)

        let loaded = try store.loadManifest()
        XCTAssertEqual(loaded.selectedWorkoutID, id)
    }

    func testNilSelectedWorkoutPreserved() throws {
        let manifest = WorkoutLibraryManifest(workoutIDs: [UUID()])
        try store.saveManifest(manifest)

        let loaded = try store.loadManifest()
        XCTAssertNil(loaded.selectedWorkoutID)
    }

    // MARK: - Update Existing Workout

    func testUpdateExistingWorkout() throws {
        let id = UUID()
        var workout = makeWorkout(id: id, name: "Original")
        try store.saveWorkout(workout)

        workout.metadata.name = "Updated"
        try store.saveWorkout(workout)

        let loaded = try store.loadWorkout(id: id)
        XCTAssertEqual(loaded.metadata.name, "Updated")
    }

    // MARK: - Delete Workout

    func testDeleteWorkout() throws {
        let workout = makeWorkout()
        try store.saveWorkout(workout)
        XCTAssertTrue(store.workoutExists(id: workout.id))

        try store.deleteWorkout(id: workout.id)
        XCTAssertFalse(store.workoutExists(id: workout.id))

        XCTAssertThrowsError(try store.loadWorkout(id: workout.id)) { error in
            guard case WorkoutLibraryError.workoutFileMissing = error else {
                XCTFail("Expected workoutFileMissing, got \(error)")
                return
            }
        }
    }

    func testDeleteNonexistentWorkoutDoesNotThrow() throws {
        // Deleting an already-missing workout is a no-op.
        try store.deleteWorkout(id: UUID())
    }

    // MARK: - Deletion Persists After Reload

    func testDeletionPersistsAfterReload() throws {
        let id = UUID()
        try store.saveWorkout(makeWorkout(id: id))
        try store.saveManifest(WorkoutLibraryManifest(workoutIDs: [id]))

        try store.deleteWorkout(id: id)
        var manifest = try store.loadManifest()
        manifest.workoutIDs.removeAll { $0 == id }
        try store.saveManifest(manifest)

        // Create a fresh store to simulate app restart
        let freshStore = FileWorkoutLibraryStore(rootURL: tempDir)
        let reloaded = try freshStore.loadManifest()
        XCTAssertFalse(reloaded.workoutIDs.contains(id))
        XCTAssertFalse(freshStore.workoutExists(id: id))
    }

    // MARK: - Missing Workout File Referenced by Manifest

    func testMissingWorkoutFileReferencedByManifest() throws {
        let missingID = UUID()
        let manifest = WorkoutLibraryManifest(workoutIDs: [missingID])
        try store.saveManifest(manifest)

        // Manifest loads fine
        let loaded = try store.loadManifest()
        XCTAssertEqual(loaded.workoutIDs, [missingID])

        // But the workout file doesn't exist
        XCTAssertThrowsError(try store.loadWorkout(id: missingID)) { error in
            guard case WorkoutLibraryError.workoutFileMissing = error else {
                XCTFail("Expected workoutFileMissing, got \(error)")
                return
            }
        }
    }

    // MARK: - Corrupt Workout File Among Valid Files

    func testCorruptWorkoutFileAmongValid() throws {
        let validID = UUID()
        let corruptID = UUID()

        try store.saveWorkout(makeWorkout(id: validID, name: "Valid"))

        // Write corrupt data directly
        let corruptURL = tempDir
            .appendingPathComponent("workouts")
            .appendingPathComponent("\(corruptID.uuidString).json")
        try FileManager.default.createDirectory(
            at: corruptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not valid json".data(using: .utf8)!.write(to: corruptURL)

        // Valid workout loads fine
        let valid = try store.loadWorkout(id: validID)
        XCTAssertEqual(valid.metadata.name, "Valid")

        // Corrupt workout throws
        XCTAssertThrowsError(try store.loadWorkout(id: corruptID)) { error in
            guard case WorkoutLibraryError.workoutCorrupted = error else {
                XCTFail("Expected workoutCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - Corrupt Manifest

    func testCorruptManifestThrows() throws {
        try store.ensureDirectoriesExist()
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try "{bad json".data(using: .utf8)!.write(to: manifestURL)

        XCTAssertThrowsError(try store.loadManifest()) { error in
            guard case WorkoutLibraryError.manifestCorrupted = error else {
                XCTFail("Expected manifestCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - Schema Version Rejection

    func testUnsupportedSchemaVersionThrows() throws {
        let manifest = WorkoutLibraryManifest(version: 999, workoutIDs: [])
        try store.saveManifest(manifest)

        XCTAssertThrowsError(try store.loadManifest()) { error in
            guard case WorkoutLibraryError.unsupportedSchemaVersion(let v) = error else {
                XCTFail("Expected unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, 999)
        }
    }

    func testOlderSchemaVersionThrowsWithoutMigration() throws {
        let manifest = WorkoutLibraryManifest(version: 0, workoutIDs: [])
        try store.saveManifest(manifest)

        XCTAssertThrowsError(try store.loadManifest()) { error in
            guard case WorkoutLibraryError.unsupportedSchemaVersion(let version) = error else {
                XCTFail("Expected unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(version, 0)
        }
    }

    // MARK: - Failed Write Does Not Destroy Prior Valid Data

    func testFailedWorkoutWritePreservesPriorValidData() throws {
        let workout = makeWorkout(name: "Original")
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(workoutIDs: [workout.id]))

        let workoutsDirectory = tempDir.appendingPathComponent("workouts")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: workoutsDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: workoutsDirectory.path
            )
        }

        var updated = workout
        updated.metadata.name = "Updated"
        XCTAssertThrowsError(try store.saveWorkout(updated))

        let loaded = try store.loadWorkout(id: workout.id)
        XCTAssertEqual(loaded.metadata.name, "Original")
    }

    // MARK: - Date Round-Trip

    func testDateRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let workout = makeWorkout()
        var w = workout
        w.metadata.startDate = date
        w.metadata.endDate = date.addingTimeInterval(3600)

        try store.saveWorkout(w)
        let loaded = try store.loadWorkout(id: w.id)

        XCTAssertEqual(loaded.metadata.startDate!.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(loaded.metadata.endDate!.timeIntervalSince1970, date.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - UUID Round-Trip

    func testUUIDRoundTrip() throws {
        let id = UUID()
        let workout = makeWorkout(id: id)
        try store.saveWorkout(workout)

        let loaded = try store.loadWorkout(id: id)
        XCTAssertEqual(loaded.id, id)
    }

    // MARK: - Route Points Round-Trip

    func testRoutePointsRoundTrip() throws {
        let point = RoutePoint(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            latitude: 37.7749,
            longitude: -122.4194,
            altitudeMeters: 10.5,
            distanceFromStartMeters: 100,
            elapsedSeconds: 60,
            speedMetersPerSecond: 3.2,
            paceSecondsPerKilometer: 312.5,
            heartRateBPM: 155,
            cadence: 180
        )
        let workout = RunWorkout(
            id: UUID(),
            metadata: WorkoutMetadata(),
            source: .gpx,
            routePoints: [point],
            splits: [],
            summary: RunSummary()
        )

        try store.saveWorkout(workout)
        let loaded = try store.loadWorkout(id: workout.id)

        let lp = loaded.routePoints.first!
        XCTAssertEqual(lp.latitude, 37.7749)
        XCTAssertEqual(lp.longitude, -122.4194)
        XCTAssertEqual(lp.altitudeMeters, 10.5)
        XCTAssertEqual(lp.heartRateBPM, 155)
        XCTAssertEqual(lp.cadence, 180)
    }

    // MARK: - Summary Round-Trip

    func testSummaryRoundTrip() throws {
        var workout = makeWorkout()
        workout.summary = RunSummary(
            totalDistanceMeters: 10000,
            totalElapsedSeconds: 3600,
            averagePaceSecondsPerKilometer: 360,
            averageSpeedMetersPerSecond: 2.78,
            elevationGainMeters: 150,
            elevationLossMeters: 120,
            averageHeartRateBPM: 160,
            maxHeartRateBPM: 185
        )

        try store.saveWorkout(workout)
        let loaded = try store.loadWorkout(id: workout.id)

        XCTAssertEqual(loaded.summary.totalDistanceMeters, 10000)
        XCTAssertEqual(loaded.summary.totalElapsedSeconds, 3600)
        XCTAssertEqual(loaded.summary.averagePaceSecondsPerKilometer, 360)
        XCTAssertEqual(loaded.summary.elevationGainMeters, 150)
        XCTAssertEqual(loaded.summary.averageHeartRateBPM, 160)
        XCTAssertEqual(loaded.summary.maxHeartRateBPM, 185)
    }

    // MARK: - Splits Round-Trip

    func testSplitsRoundTrip() throws {
        let split = RunSplit(
            splitIndex: 0,
            distanceMeters: 1000,
            elapsedSeconds: 300,
            paceSecondsPerKilometer: 300,
            averageHeartRateBPM: 155,
            elevationGainMeters: 10,
            startDistanceMeters: 0,
            endDistanceMeters: 1000
        )
        var workout = makeWorkout()
        workout.splits = [split]

        try store.saveWorkout(workout)
        let loaded = try store.loadWorkout(id: workout.id)

        XCTAssertEqual(loaded.splits.count, 1)
        XCTAssertEqual(loaded.splits[0].splitIndex, 0)
        XCTAssertEqual(loaded.splits[0].paceSecondsPerKilometer, 300)
        XCTAssertEqual(loaded.splits[0].averageHeartRateBPM, 155)
    }

    // MARK: - Segments Round-Trip

    func testSegmentsRoundTrip() throws {
        let segment = SegmentHighlight(
            type: .fastest1km,
            title: "Fastest Kilometer",
            subtitle: "4:30 /km",
            startDistanceMeters: 1000,
            endDistanceMeters: 2000,
            startElapsedSeconds: 300,
            endElapsedSeconds: 570,
            durationSeconds: 270,
            distanceMeters: 1000,
            paceSecondsPerKilometer: 270,
            sourcePointRange: 10..<20
        )
        var workout = makeWorkout()
        workout.segments = [segment]

        try store.saveWorkout(workout)
        let loaded = try store.loadWorkout(id: workout.id)

        XCTAssertEqual(loaded.segments.count, 1)
        XCTAssertEqual(loaded.segments[0].type, .fastest1km)
        XCTAssertEqual(loaded.segments[0].title, "Fastest Kilometer")
        XCTAssertEqual(loaded.segments[0].paceSecondsPerKilometer, 270)
    }

    // MARK: - WorkoutExists

    func testWorkoutExistsReturnsFalseForMissing() {
        XCTAssertFalse(store.workoutExists(id: UUID()))
    }

    func testWorkoutExistsReturnsTrueForSaved() throws {
        let workout = makeWorkout()
        try store.saveWorkout(workout)
        XCTAssertTrue(store.workoutExists(id: workout.id))
    }

    // MARK: - Manifest Equatable

    func testManifestEquality() {
        let id = UUID()
        let m1 = WorkoutLibraryManifest(workoutIDs: [id], selectedWorkoutID: id)
        let m2 = WorkoutLibraryManifest(workoutIDs: [id], selectedWorkoutID: id)
        XCTAssertEqual(m1, m2)
    }

    func testManifestInequalityDifferentOrder() {
        let id1 = UUID()
        let id2 = UUID()
        let m1 = WorkoutLibraryManifest(workoutIDs: [id1, id2])
        let m2 = WorkoutLibraryManifest(workoutIDs: [id2, id1])
        XCTAssertNotEqual(m1, m2)
    }

    // MARK: - WorkoutError Equatable

    func testWorkoutLibraryErrorEquatable() {
        let id = UUID()
        XCTAssertEqual(
            WorkoutLibraryError.workoutFileMissing(id),
            WorkoutLibraryError.workoutFileMissing(id)
        )
        XCTAssertNotEqual(
            WorkoutLibraryError.workoutFileMissing(UUID()),
            WorkoutLibraryError.workoutFileMissing(UUID())
        )
    }
}
