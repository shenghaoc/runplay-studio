import XCTest
@testable import RunPlayPlatform
import RunPlayCore

final class WatchFolderSupportTests: XCTestCase {

    // MARK: - Bookmark round-trip

    func testBookmarkRoundTripResolvesOriginalURL() throws {
        let store = SecurityScopedBookmarkStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bookmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bookmark = try store.createBookmark(for: directory)
        XCTAssertFalse(bookmark.isEmpty)

        let resolved = try store.resolve(bookmark)
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path,
                       directory.resolvingSymlinksInPath().path)
        // A freshly created bookmark should not be stale.
        XCTAssertFalse(resolved.wasStale)
    }

    func testResolveGarbageBookmarkDataThrows() throws {
        let store = SecurityScopedBookmarkStore()
        XCTAssertThrowsError(try store.resolve(Data([0x00, 0x01, 0x02, 0x03]))) { error in
            XCTAssertEqual(error as? SecurityScopedBookmarkStore.BookmarkError, .resolutionFailed)
        }
    }

    func testCreateBookmarkForMissingFolderThrows() {
        let store = SecurityScopedBookmarkStore()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bookmark-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try store.createBookmark(for: missing)) { error in
            XCTAssertEqual(error as? SecurityScopedBookmarkStore.BookmarkError, .creationFailed)
        }
    }

    func testScopedAccessStopsExactlyOnce() throws {
        let store = SecurityScopedBookmarkStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bookmark-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let access = store.beginAccess(to: directory)
        XCTAssertNotNil(access)
        // Double stop must be safe; deinit stops again without crashing.
        access?.stop()
    }

    // MARK: - Directory watcher

    func testDirectoryWatcherDeliversEventOnFileCreation() async throws {
        let watcher = DispatchSourceDirectoryWatcher()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectation = expectation(description: "watcher fired")
        let handle = watcher.start(directoryURL: directory) {
            expectation.fulfill()
        }
        XCTAssertNotNil(handle)
        defer { handle?.cancel() }

        // Create a file after the watch is live. The poll-remains-authoritative
        // design means a missed event is tolerable, but on a healthy local
        // filesystem the .write event fires promptly.
        try Data("<gpx/>".utf8).write(to: directory.appendingPathComponent("run.gpx"))

        await fulfillment(of: [expectation], timeout: 5)
    }
}
