import XCTest
@testable import RunPlayCore

final class WatchFolderStoreTests: XCTestCase {

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchFolderStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSnapshot() -> FileWatchFolderStore.WatchFolderStoreSnapshot {
        let folderID = UUID()
        let folder = WatchFolderConfiguration(
            id: folderID,
            displayName: "Garmin",
            bookmarkData: Data([0x01, 0x02, 0x03]),
            defaultTagName: "watch",
            isPaused: false
        )
        let state = WatchFolderState(
            folderID: folderID,
            ledger: [
                WatchFolderLedgerEntry(
                    contentSHA256: String(repeating: "a", count: 64),
                    fileName: "run.gpx",
                    outcome: .imported,
                    processedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ],
            pendingReview: [
                String(repeating: "b", count: 64): WatchFolderPendingReviewEntry(
                    filePath: "/tmp/run.fit",
                    fileName: "run.fit",
                    queuedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            ]
        )
        return FileWatchFolderStore.WatchFolderStoreSnapshot(
            folders: [folder],
            states: [state]
        )
    }

    func testMissingFileLoadsMissing() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchFolderStore-\(UUID().uuidString)")
        let store = FileWatchFolderStore(rootURL: directory)
        XCTAssertEqual(store.load(), .missing)
        XCTAssertEqual(store.loadOrEmpty(), FileWatchFolderStore.WatchFolderStoreSnapshot())
    }

    func testRoundTripPersistsFoldersAndState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWatchFolderStore(rootURL: directory)

        let snapshot = makeSnapshot()
        try store.save(snapshot)

        guard case .loaded(let loaded) = store.load() else {
            return XCTFail("Expected loaded outcome")
        }
        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.folders, snapshot.folders)
        XCTAssertEqual(loaded.states, snapshot.states)
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWatchFolderStore(rootURL: directory)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("watch-folders.json"))

        XCTAssertEqual(store.load(), .corrupt)
        XCTAssertEqual(store.loadOrEmpty(), FileWatchFolderStore.WatchFolderStoreSnapshot())
    }

    func testFutureVersionLoadsAsCorrupt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWatchFolderStore(rootURL: directory)

        // A snapshot from a newer build decodes but must not be trusted.
        let future = """
        {"version": 99, "folders": [], "states": []}
        """
        try Data(future.utf8).write(to: directory.appendingPathComponent("watch-folders.json"))
        XCTAssertEqual(store.load(), .corrupt)
    }

    func testSnapshotDefaults() {
        let snapshot = FileWatchFolderStore.WatchFolderStoreSnapshot()
        XCTAssertEqual(snapshot.version, FileWatchFolderStore.currentVersion)
        XCTAssertTrue(snapshot.folders.isEmpty)
        XCTAssertTrue(snapshot.states.isEmpty)
    }
}
