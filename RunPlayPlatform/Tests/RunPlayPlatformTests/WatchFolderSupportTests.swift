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

    // MARK: - Resolution without UI or mounting (#181)

    func testMovedFolderResolvesToItsNewLocation() throws {
        let store = SecurityScopedBookmarkStore()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkMove-\(UUID().uuidString)")
        let original = parent.appendingPathComponent("original")
        let moved = parent.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let bookmark = try store.createBookmark(for: original)
        try FileManager.default.moveItem(at: original, to: moved)

        let resolved = try store.resolve(bookmark)
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
    }

    /// A bookmark into a volume the user ejected must fail to resolve rather
    /// than mount the volume again.
    func testEjectedDiskImageIsNotMountedAgainByResolution() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkImage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appendingPathComponent("watch.dmg")
        let volumeName = "RPBM\(UUID().uuidString.prefix(8))"
        guard (try? Self.hdiutil(["create", "-size", "4m", "-fs", "HFS+", "-volname", volumeName, image.path])) != nil else {
            throw XCTSkip("hdiutil cannot create a disk image here")
        }
        let attached = try Self.hdiutil(["attach", "-nobrowse", image.path])
        let volume = URL(fileURLWithPath: "/Volumes/\(volumeName)")
        guard FileManager.default.fileExists(atPath: volume.path) else {
            _ = try? Self.hdiutil(["detach", "-force", volume.path])
            throw XCTSkip("the disk image did not mount at /Volumes: \(attached)")
        }
        let folder = volume.appendingPathComponent("Activities")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SecurityScopedBookmarkStore()
        let bookmark = try store.createBookmark(for: folder)
        _ = try Self.hdiutil(["detach", "-force", volume.path])
        defer { _ = try? Self.hdiutil(["detach", "-force", volume.path]) }

        XCTAssertThrowsError(try store.resolve(bookmark))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: volume.path),
            "resolving a bookmark must not mount an ejected volume"
        )
    }

    private static func hdiutil(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "hdiutil", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
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
