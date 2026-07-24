import XCTest
@testable import RunPlayCore

final class WorkoutLibraryManifestTests: XCTestCase {

    func testVersion1JSONDecodesWithEmptyFavorites() throws {
        let id = UUID()
        let selected = UUID()
        let json = """
        {
          "version": 1,
          "workoutIDs": ["\(id.uuidString)"],
          "selectedWorkoutID": "\(selected.uuidString)"
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkoutLibraryManifest.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.workoutIDs, [id])
        XCTAssertEqual(decoded.selectedWorkoutID, selected)
        XCTAssertTrue(decoded.favoriteWorkoutIDs.isEmpty)
    }

    func testVersion2RoundTripPreservesFavorites() throws {
        let a = UUID()
        let b = UUID()
        let original = WorkoutLibraryManifest(
            version: 2,
            workoutIDs: [a, b],
            selectedWorkoutID: b,
            favoriteWorkoutIDs: [a]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkoutLibraryManifest.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSanitizeRemovesMissingFavorites() {
        let a = UUID()
        let b = UUID()
        var manifest = WorkoutLibraryManifest(
            workoutIDs: [a],
            favoriteWorkoutIDs: [a, b]
        )
        manifest.sanitizeFavorites()
        XCTAssertEqual(manifest.favoriteWorkoutIDs, [a])
    }

    func testMigratePromotesSchemaVersion() {
        var manifest = WorkoutLibraryManifest(version: 1, workoutIDs: [])
        manifest.migrateToCurrentVersionIfNeeded()
        XCTAssertEqual(manifest.version, WorkoutLibraryManifest.currentVersion)
    }

    func testFileStoreLoadsVersion1AndUpgradesOnSave() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifestV1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = FileWorkoutLibraryStore(rootURL: temp)
        try store.ensureDirectoriesExist()

        let id = UUID()
        // Write a raw v1 manifest without favoriteWorkoutIDs.
        let raw = """
        {"version":1,"workoutIDs":["\(id.uuidString)"],"selectedWorkoutID":"\(id.uuidString)"}
        """
        let manifestURL = temp.appendingPathComponent("manifest.json")
        try Data(raw.utf8).write(to: manifestURL)

        let loaded = try store.loadManifest()
        XCTAssertEqual(loaded.workoutIDs, [id])
        XCTAssertEqual(loaded.selectedWorkoutID, id)
        XCTAssertTrue(loaded.favoriteWorkoutIDs.isEmpty)
        XCTAssertEqual(loaded.version, WorkoutLibraryManifest.currentVersion)

        try store.saveManifest(loaded)
        let reloaded = try store.loadManifest()
        XCTAssertEqual(reloaded.version, WorkoutLibraryManifest.currentVersion)
        XCTAssertEqual(reloaded.workoutIDs, [id])
        XCTAssertEqual(reloaded.selectedWorkoutID, id)
    }

    func testUnsupportedFutureVersionStillRejected() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifestFuture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = FileWorkoutLibraryStore(rootURL: temp)
        try store.saveManifest(WorkoutLibraryManifest(version: 999, workoutIDs: []))
        XCTAssertThrowsError(try store.loadManifest()) { error in
            guard case WorkoutLibraryError.unsupportedSchemaVersion(let v) = error else {
                XCTFail("Expected unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, 999)
        }
    }

    func testVersionZeroStillRejected() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifestV0-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = FileWorkoutLibraryStore(rootURL: temp)
        try store.saveManifest(WorkoutLibraryManifest(version: 0, workoutIDs: []))
        XCTAssertThrowsError(try store.loadManifest()) { error in
            guard case WorkoutLibraryError.unsupportedSchemaVersion(let v) = error else {
                XCTFail("Expected unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, 0)
        }
    }
}
