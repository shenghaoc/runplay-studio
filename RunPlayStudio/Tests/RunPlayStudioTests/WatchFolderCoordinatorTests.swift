import XCTest
import RunPlayCore
import RunPlayPlatform
@testable import RunPlayStudio

/// Watch-folder coordinator state machine: add/remove/pause, ledgering,
/// dedupe, FIT review queueing, and non-modal failure surfacing.
///
/// These tests inject a stub digest and never wait on real poll timers;
/// `importExistingNow()` and direct scan-pass invocation drive the same
/// code paths the poll loop uses.
@MainActor
final class WatchFolderCoordinatorTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!
    nonisolated(unsafe) private var libraryRoot: URL!
    nonisolated(unsafe) private var watchedDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchFolderCoordinator-\(UUID().uuidString)")
        libraryRoot = tempDir.appendingPathComponent("library")
        watchedDir = tempDir.appendingPathComponent("watched")
        try? FileManager.default.createDirectory(at: watchedDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Deterministic digest so ledger hashes are predictable in assertions.
    private struct CountingDigest: ContentDigesting {
        func sha256Hex(of data: Data) -> String {
            "hash-\(data.count)-\(data.first.map(String.init(describing:)) ?? "empty")"
        }
    }

    private final class ImportRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        private var results: [WatchFolderExecutionResult]
        private var nextIndex = 0

        init(results: [WatchFolderExecutionResult]) {
            self.results = results
        }

        func record(url: URL) -> WatchFolderExecutionResult {
            lock.lock()
            urls.append(url)
            let result = nextIndex < results.count
                ? results[nextIndex]
                : .imported
            nextIndex += 1
            lock.unlock()
            return result
        }

        var recordedURLs: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    /// Collects announcement events so aggregation can be asserted.
    private final class AnnouncementCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AccessibilityAnnouncementEvent] = []

        func record(_ event: AccessibilityAnnouncementEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var collected: [AccessibilityAnnouncementEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private struct AnnouncementCollectorBox: @unchecked Sendable {
        let collector: AnnouncementCollector
    }

    private func makeCoordinator(
        importResults: [WatchFolderExecutionResult] = [],
        maxFileBytes: Int? = nil
    ) -> (coordinator: WatchFolderCoordinator, recorder: ImportRecorder, announcements: AnnouncementCollector) {
        let recorder = ImportRecorder(results: importResults)
        let collector = AnnouncementCollector()
        var policy = WatchFolderScanPolicy(
            pollInterval: 3600, // effectively never fires during a test
            settleInterval: 0
        )
        if let maxFileBytes {
            policy.maxFileBytes = maxFileBytes
        }
        let coordinator = WatchFolderCoordinator(
            store: FileWatchFolderStore(rootURL: libraryRoot),
            watcherFactory: { NoopDirectoryWatcher() },
            digest: CountingDigest(),
            policy: policy
        )
        let box = ImportRecorderBox(recorder: recorder)
        coordinator.importExecutor = { url, _ in
            box.recorder.record(url: url)
        }
        let announcementBox = AnnouncementCollectorBox(collector: collector)
        coordinator.announce = { event in
            announcementBox.collector.record(event)
        }
        return (coordinator, recorder, collector)
    }

    /// Box so the Sendable closure can reach the non-Sendable recorder
    /// through an unsafe reference, matching how AppState is captured.
    private struct ImportRecorderBox: @unchecked Sendable {
        let recorder: ImportRecorder
    }

    private struct NoopDirectoryWatcher: DirectoryWatching {
        func start(directoryURL: URL, onEvent: @escaping @Sendable () -> Void) -> DirectoryWatchHandle? {
            nil
        }
    }

    @discardableResult
    private func writeJSON(_ name: String = "run.json") throws -> URL {
        let url = watchedDir.appendingPathComponent(name)
        try Data("{\"marker\":\"\(name)\"}".utf8).write(to: url)
        return url
    }

    private func waitForCondition(
        timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Folder management

    func testAddFolderPersistsConfiguration() throws {
        let (coordinator, _, _) = makeCoordinator()
        XCTAssertTrue(coordinator.addFolder(url: watchedDir, defaultTagName: "watch"))

        // Persisted snapshot round-trips through the store.
        let snapshot = FileWatchFolderStore(rootURL: libraryRoot).loadOrEmpty()
        XCTAssertEqual(snapshot.folders.count, 1)
        XCTAssertEqual(snapshot.folders.first?.displayName, watchedDir.lastPathComponent)
        XCTAssertEqual(snapshot.folders.first?.defaultTagName, "watch")

        coordinator.removeFolder(id: snapshot.folders.first!.id)
        XCTAssertTrue(FileWatchFolderStore(rootURL: libraryRoot).loadOrEmpty().folders.isEmpty)
    }

    func testAddFolderFiresOneImmediateScanWithSettleBypass() async throws {
        // addFolder triggers requestEarlyScan(bypassSettle: true), so a file
        // that already exists in the folder is picked up without waiting for
        // two probes across the poll interval.
        let runURL = try writeJSON()
        let (coordinator, recorder, _) = makeCoordinator()

        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        // The early scan coalesces after 300ms.
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        XCTAssertEqual(
            recorder.recordedURLs.map { $0.resolvingSymlinksInPath() },
            [runURL.resolvingSymlinksInPath()]
        )
    }

    // MARK: - Ledgering and dedupe

    func testImportedFileIsLedgeredAndNotReimported() async throws {
        _ = try writeJSON()
        let (coordinator, recorder, _) = makeCoordinator()
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        XCTAssertEqual(recorder.recordedURLs.count, 1)

        // Second scan pass: the file is still there but its content hash is
        // ledgered; steady-state duplicates are silent.
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(recorder.recordedURLs.count, 1, "ledgered file must not reimport")
        XCTAssertEqual(coordinator.recentImports.count, 1)

        // Persisted ledger carries the hash.
        let snapshot = FileWatchFolderStore(rootURL: libraryRoot).loadOrEmpty()
        XCTAssertEqual(snapshot.states.first?.ledger.count, 1)
        XCTAssertEqual(snapshot.states.first?.ledger.first?.outcome, .imported)
    }

    func testRenamedDuplicateContentIsSkipped() async throws {
        _ = try writeJSON("run.json")
        let (coordinator, recorder, _) = makeCoordinator()
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        XCTAssertEqual(recorder.recordedURLs.count, 1)
        let originalURL = watchedDir.appendingPathComponent("run.json")

        // Same content, new name.
        try FileManager.default.moveItem(at: originalURL, to: watchedDir.appendingPathComponent("renamed.json"))
        coordinator.importExistingNow()
        await waitForCondition(timeout: 3.0) {
            coordinator.recentImports.contains { $0.status == .skippedDuplicate }
        }
        XCTAssertEqual(recorder.recordedURLs.count, 1, "renamed duplicate must not import")
        XCTAssertTrue(coordinator.recentImports.contains { $0.status == .skippedDuplicate })
    }

    func testFailedFileIsLedgeredSoItDoesNotRetryForever() async throws {
        _ = try writeJSON("bad.json")
        let (coordinator, recorder, _) = makeCoordinator(importResults: [.failed("bad file")])
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }

        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(recorder.recordedURLs.count, 1, "failed file must not retry")
        XCTAssertEqual(coordinator.recentImports.first?.status, .failed)
        XCTAssertFalse(coordinator.recentImports.first?.failureDetail.isEmpty ?? true)
    }

    // MARK: - FIT review queue

    func testAwaitingReviewQueuesBannerAndNotRequeued() async throws {
        let fitURL = watchedDir.appendingPathComponent("multi.fit")
        try Data(repeating: 0x40, count: 16).write(to: fitURL)
        let (coordinator, recorder, _) = makeCoordinator(importResults: [.awaitingReview])
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        XCTAssertEqual(coordinator.recentImports.first?.status, .awaitingReview)
        XCTAssertNotNil(coordinator.pendingReviewBanner)
        XCTAssertEqual(coordinator.pendingReviewBanner?.fileName, "multi.fit")

        // Resolve: ledgered as imported, banner cleared.
        coordinator.resolvePendingReview(fileURL: fitURL, outcome: .imported)
        XCTAssertNil(coordinator.pendingReviewBanner)
        let snapshot = FileWatchFolderStore(rootURL: libraryRoot).loadOrEmpty()
        XCTAssertEqual(snapshot.states.first?.pendingReview.isEmpty, true)
        XCTAssertEqual(snapshot.states.first?.ledger.first?.outcome, .imported)

        // Next pass: content ledgered, silent duplicate, no requeue.
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(recorder.recordedURLs.count, 1, "resolved review must not requeue")
    }

    // MARK: - Pause

    func testPauseBlocksScansAndImports() async throws {
        _ = try writeJSON()
        let (coordinator, recorder, _) = makeCoordinator()
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        XCTAssertEqual(recorder.recordedURLs.count, 1)

        // Pause: a new file must not import.
        let folderID = coordinator.folders.first!.id
        coordinator.setPaused(true, folderID: folderID)
        XCTAssertTrue(coordinator.isPaused)
        _ = try writeJSON("second.json")
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(recorder.recordedURLs.count, 1)
    }

    // MARK: - Resource limits

    func testOversizedFileIsReportedOnceAndNotReRead() async throws {
        // 200 bytes against a 10-byte limit: the scanner proves the oversize by
        // reading limit + 1 and throws the product resource-limit error.
        let bigURL = watchedDir.appendingPathComponent("huge.json")
        try Data(repeating: 0x61, count: 200).write(to: bigURL)
        let (coordinator, recorder, _) = makeCoordinator(maxFileBytes: 10)

        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !coordinator.recentImports.isEmpty }

        XCTAssertEqual(recorder.recordedURLs.count, 0, "oversized file must never reach the importer")
        XCTAssertEqual(coordinator.recentImports.count, 1)
        XCTAssertEqual(coordinator.recentImports.first?.status, .failed)
        XCTAssertEqual(coordinator.recentImports.first?.fileName, "huge.json")
        XCTAssertFalse(coordinator.recentImports.first?.failureDetail.isEmpty ?? true)

        // Further passes must not re-report it, and must not ledger it (there
        // is no hash to ledger), so the panel does not accumulate rows.
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(coordinator.recentImports.count, 1, "oversized file must be reported exactly once")
        XCTAssertEqual(recorder.recordedURLs.count, 0)
    }

    // MARK: - Folder availability

    func testFolderRemovedWhileWatchingIsReportedOnceAndRecovers() async throws {
        _ = try writeJSON()
        let (coordinator, recorder, _) = makeCoordinator()
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        let folderID = try XCTUnwrap(coordinator.folders.first?.id)
        XCTAssertTrue(coordinator.unavailableFolderIDs.isEmpty)

        // Eject equivalent: the watched directory disappears with the app
        // running. This must not read as "watched and empty".
        try FileManager.default.removeItem(at: watchedDir)
        coordinator.importExistingNow()
        await waitForCondition(timeout: 3.0) { coordinator.unavailableFolderIDs.contains(folderID) }

        XCTAssertEqual(coordinator.unavailableFolderIDs, [folderID])
        let failures = coordinator.recentImports.filter {
            $0.status == .failed && $0.folderID == folderID
        }
        XCTAssertEqual(failures.count, 1, "unavailability must be reported once")
        XCTAssertTrue(failures.first?.failureDetail.contains("not available") ?? false)

        // Further passes must not repeat the row.
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(
            coordinator.recentImports.filter { $0.status == .failed && $0.folderID == folderID }.count,
            1
        )

        // Remount equivalent: the directory returns and watching resumes
        // without re-adding the folder, picking up a new file.
        try FileManager.default.createDirectory(at: watchedDir, withIntermediateDirectories: true)
        _ = try writeJSON("after-remount.json")
        coordinator.importExistingNow()
        await waitForCondition(timeout: 3.0) { recorder.recordedURLs.count >= 2 }
        XCTAssertTrue(coordinator.unavailableFolderIDs.isEmpty, "recovery must clear the flag")
        XCTAssertEqual(recorder.recordedURLs.count, 2)
    }

    func testPausedFolderIsNeverReportedUnavailable() async throws {
        _ = try writeJSON()
        let (coordinator, recorder, _) = makeCoordinator()
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        let folderID = coordinator.folders.first!.id

        // Pause, then remove the directory: unavailability is expected while
        // paused, so it must not surface as a fault.
        coordinator.setPaused(true, folderID: folderID)
        try FileManager.default.removeItem(at: watchedDir)
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(coordinator.unavailableFolderIDs.isEmpty)
        XCTAssertTrue(coordinator.recentImports.allSatisfy { $0.status != .failed })

        // Resume with the directory restored: watching returns cleanly.
        try FileManager.default.createDirectory(at: watchedDir, withIntermediateDirectories: true)
        coordinator.setPaused(false, folderID: folderID)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(coordinator.unavailableFolderIDs.isEmpty)
    }

    // MARK: - Pending review lifecycle

    func testQueuedReviewBannerIsRestoredOnRelaunch() async throws {
        let fitURL = watchedDir.appendingPathComponent("multi.fit")
        try Data(repeating: 0x40, count: 16).write(to: fitURL)
        let (first, recorder, _) = makeCoordinator(importResults: [.awaitingReview])
        XCTAssertTrue(first.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        XCTAssertNotNil(first.pendingReviewBanner)

        // Simulate relaunch: a fresh coordinator over the same persisted store.
        // The queued review is persisted state, so its banner must return
        // without waiting for another FIT file to arrive.
        let (second, _, _) = makeCoordinator()
        second.start()
        XCTAssertNotNil(second.pendingReviewBanner, "queued review must survive relaunch")
        XCTAssertEqual(second.pendingReviewBanner?.fileName, "multi.fit")
        XCTAssertEqual(
            second.pendingReviewBanner?.fileURL.resolvingSymlinksInPath(),
            fitURL.resolvingSymlinksInPath()
        )
    }

    func testRemovingOneFolderResurfacesAnotherFoldersQueuedReview() async throws {
        let secondDir = tempDir.appendingPathComponent("watched-2")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let fitA = watchedDir.appendingPathComponent("a.fit")
        let fitB = secondDir.appendingPathComponent("b.fit")
        try Data(repeating: 0x40, count: 16).write(to: fitA)
        try Data(repeating: 0x40, count: 24).write(to: fitB)

        let (coordinator, recorder, _) = makeCoordinator(
            importResults: [.awaitingReview, .awaitingReview]
        )
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        XCTAssertTrue(coordinator.addFolder(url: secondDir))
        await waitForCondition(timeout: 3.0) { recorder.recordedURLs.count >= 2 }

        // Both files queued; exactly one banner is on screen.
        XCTAssertNotNil(coordinator.pendingReviewBanner)
        let visibleFolderID = try XCTUnwrap(coordinator.pendingReviewBanner?.folderID)
        XCTAssertEqual(coordinator.folders.count, 2)

        // Removing the folder that owns the visible banner must not strand the
        // other folder's queued review.
        coordinator.removeFolder(id: visibleFolderID)
        XCTAssertNotNil(
            coordinator.pendingReviewBanner,
            "the other folder's queued review must re-surface"
        )
        XCTAssertNotEqual(coordinator.pendingReviewBanner?.folderID, visibleFolderID)

        // Removing the last folder clears the banner entirely.
        let remaining = coordinator.folders.first?.id
        if let remaining {
            coordinator.removeFolder(id: remaining)
        }
        XCTAssertNil(coordinator.pendingReviewBanner)
        XCTAssertTrue(coordinator.folders.isEmpty)
    }

    func testQueuedReviewForVanishedFileIsNotSurfaced() async throws {
        let fitURL = watchedDir.appendingPathComponent("gone.fit")
        try Data(repeating: 0x40, count: 16).write(to: fitURL)
        let (coordinator, recorder, _) = makeCoordinator(importResults: [.awaitingReview])
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        XCTAssertNotNil(coordinator.pendingReviewBanner)

        // The user moved the file away before reviewing: relaunch must not
        // offer a review that cannot be opened.
        try FileManager.default.removeItem(at: fitURL)
        let (relaunched, _, _) = makeCoordinator()
        relaunched.start()
        XCTAssertNil(relaunched.pendingReviewBanner)
    }

    // MARK: - Announcement aggregation

    func testAnnouncesOncePerPassNotPerFile() async throws {
        // Three files land in one pass: a background watcher must make one
        // aggregate announcement, not three.
        _ = try writeJSON("a.json")
        _ = try writeJSON("b.json")
        _ = try writeJSON("c.json")
        let (coordinator, recorder, announcements) = makeCoordinator()
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { recorder.recordedURLs.count >= 3 }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(recorder.recordedURLs.count, 3)
        XCTAssertEqual(
            announcements.collected,
            [.watchFolderImportCompleted(count: 3)],
            "one aggregate announcement per pass, never one per file"
        )

        // Idle passes must stay silent: announcing "nothing happened" every
        // poll is exactly the spam the accessibility policy forbids.
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(announcements.collected.count, 1, "idle passes must not announce")
    }

    func testFailureOutranksSuccessInTheAnnouncement() async throws {
        // One good file and one bad file in the same pass: the failure must be
        // spoken, because an error masked by a sibling success is invisible to
        // a screen-reader user.
        _ = try writeJSON("good.json")
        _ = try writeJSON("bad.json")
        let (coordinator, recorder, announcements) = makeCoordinator(
            importResults: [.imported, .failed("bad file")]
        )
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { recorder.recordedURLs.count >= 2 }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            announcements.collected,
            [.watchFolderImportFailed(count: 1)]
        )
    }

    func testUnavailabilityIsAnnouncedOncePerEdge() async throws {
        _ = try writeJSON()
        let (coordinator, recorder, announcements) = makeCoordinator()
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }

        try FileManager.default.removeItem(at: watchedDir)
        coordinator.importExistingNow()
        await waitForCondition(timeout: 3.0) { !coordinator.unavailableFolderIDs.isEmpty }
        try await Task.sleep(for: .milliseconds(300))

        let unavailableEvents = announcements.collected.filter {
            if case .watchFolderUnavailable = $0 { return true }
            return false
        }
        XCTAssertEqual(unavailableEvents.count, 1)
        XCTAssertEqual(
            unavailableEvents.first,
            .watchFolderUnavailable(name: watchedDir.lastPathComponent)
        )

        // Repeated polls while still gone must not repeat the announcement.
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(
            announcements.collected.filter {
                if case .watchFolderUnavailable = $0 { return true }
                return false
            }.count,
            1,
            "unavailability is announced per transition, not per poll"
        )
    }

    func testQueuedReviewIsAnnouncedOnce() async throws {
        _ = try writeJSON("multi.fit")
        let (coordinator, recorder, announcements) = makeCoordinator(
            importResults: [.awaitingReview]
        )
        XCTAssertTrue(coordinator.addFolder(url: watchedDir))
        await waitForCondition(timeout: 3.0) { !recorder.recordedURLs.isEmpty }
        try await Task.sleep(for: .milliseconds(300))

        let reviewEvents = announcements.collected.filter {
            if case .watchFolderReviewReady = $0 { return true }
            return false
        }
        XCTAssertEqual(reviewEvents, [.watchFolderReviewReady(name: "multi.fit")])

        // The queued file is not ledgered, so every later pass sees it again;
        // it must not be re-announced on each poll.
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        coordinator.importExistingNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(
            announcements.collected.filter {
                if case .watchFolderReviewReady = $0 { return true }
                return false
            }.count,
            1,
            "a queued review is announced once, not per poll"
        )
    }
}
