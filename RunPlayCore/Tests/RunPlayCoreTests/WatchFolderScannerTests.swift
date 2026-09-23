import XCTest
@testable import RunPlayCore

final class WatchFolderScannerTests: XCTestCase {

    private let digest = TestContentDigest()

    private var scanner: WatchFolderScanner {
        WatchFolderScanner(digest: digest)
    }

    // MARK: - Temporary directory helpers

    private var temporaryDirectory: URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchFolderScanner-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func tearDownDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write(
        _ contents: String,
        name: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Write `contents` to `name` in pieces, pausing between them, so the
    /// file's size and modification date genuinely change over time.
    ///
    /// A single `Data.write` lands in one syscall and cannot reproduce the
    /// state a sync client or a device still copying a run leaves behind: a
    /// file that exists, is readable, and is still being written. This helper
    /// makes that state observable, and `onChunk` lets a test probe the scanner
    /// while the file is mid-write.
    @discardableResult
    private func writeSlowly(
        _ contents: String,
        name: String,
        in directory: URL,
        chunkCount: Int = 4,
        pause: TimeInterval = 0.02,
        onChunk: (URL) throws -> Void = { _ in }
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let data = Data(contents.utf8)
        let chunkSize = max(1, data.count / max(1, chunkCount))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            try handle.write(contentsOf: data[offset..<end])
            offset = end
            try onChunk(url)
            Thread.sleep(forTimeInterval: pause)
        }
        return url
    }

    // MARK: - Eligibility

    func testIsSupportedLowercasesExtension() {
        XCTAssertTrue(scanner.isSupported("GPX"))
        XCTAssertTrue(scanner.isSupported("tcx"))
        XCTAssertTrue(scanner.isSupported("fit"))
        XCTAssertTrue(scanner.isSupported("json"))
        XCTAssertFalse(scanner.isSupported("zip"))
        XCTAssertFalse(scanner.isSupported(""))
        XCTAssertFalse(scanner.isSupported("gpx.bak"))
    }

    // MARK: - Directory scan

    func testEligibleFilesListsSupportedRegularFilesSorted() throws {
        let directory = temporaryDirectory
        defer { tearDownDirectory(directory) }

        try write("<gpx/>", name: "b-run.gpx", in: directory)
        try write("{}", name: "a-run.json", in: directory)
        try write("<tcx/>", name: "c-run.TCX", in: directory)
        try write("noise", name: "ignored.txt", in: directory)
        try write("noise", name: ".hidden.gpx", in: directory)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("nested.gpx"),
            withIntermediateDirectories: false
        )

        let result = scanner.eligibleFiles(in: directory)
        XCTAssertEqual(result.files.map(\.url.lastPathComponent), ["a-run.json", "b-run.gpx", "c-run.TCX"])
        XCTAssertTrue(result.unreadable.isEmpty)
        for file in result.files {
            XCTAssertGreaterThan(file.byteSize, 0)
        }
    }

    func testEligibleFilesMissingDirectoryReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchFolderScanner-missing-\(UUID().uuidString)")
        let result = scanner.eligibleFiles(in: missing)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertTrue(result.unreadable.isEmpty)
    }

    // MARK: - Classification

    func testClassifySeparatesCandidatesDuplicatesAndPending() {
        let urlA = URL(fileURLWithPath: "/tmp/a.gpx")
        let urlB = URL(fileURLWithPath: "/tmp/b.gpx")
        let urlC = URL(fileURLWithPath: "/tmp/c.gpx")
        let hashA = digest.sha256Hex(of: Data("a".utf8))
        let hashB = digest.sha256Hex(of: Data("b".utf8))
        let files = [
            WatchFolderScanner.DiscoveredFile(url: urlA, byteSize: 1, contentModificationDate: Date()),
            WatchFolderScanner.DiscoveredFile(url: urlB, byteSize: 1, contentModificationDate: Date()),
            WatchFolderScanner.DiscoveredFile(url: urlC, byteSize: 1, contentModificationDate: Date())
        ]
        let state = WatchFolderState(
            folderID: UUID(),
            ledger: [
                WatchFolderLedgerEntry(
                    contentSHA256: hashA,
                    fileName: "a.gpx",
                    outcome: .imported,
                    processedAt: Date()
                )
            ],
            pendingReview: [
                hashB: WatchFolderPendingReviewEntry(
                    filePath: urlB.path,
                    fileName: "b.gpx",
                    queuedAt: Date()
                )
            ]
        )

        let result = scanner.classify(
            files: files,
            state: state,
            contentHashes: [urlA: hashA, urlB: hashB]
        )
        // urlC has no hash yet: the coordinator has not read it, so it is a
        // candidate.
        XCTAssertEqual(result.candidates.map(\.url), [urlC])
        XCTAssertEqual(result.duplicates.map(\.url), [urlA])
        XCTAssertEqual(result.pendingReview.map(\.url), [urlB])
    }

    func testClassifyDuplicateByRenameOnlyDedupes() {
        // Same content, different filename: still a duplicate because
        // identity is the content hash.
        let urlRenamed = URL(fileURLWithPath: "/tmp/renamed.gpx")
        let hash = digest.sha256Hex(of: Data("same".utf8))
        let files = [
            WatchFolderScanner.DiscoveredFile(url: urlRenamed, byteSize: 4, contentModificationDate: Date())
        ]
        let state = WatchFolderState(
            folderID: UUID(),
            ledger: [
                WatchFolderLedgerEntry(
                    contentSHA256: hash,
                    fileName: "original.gpx",
                    outcome: .imported,
                    processedAt: Date()
                )
            ]
        )
        let result = scanner.classify(
            files: files,
            state: state,
            contentHashes: [urlRenamed: hash]
        )
        XCTAssertEqual(result.duplicates.map(\.url), [urlRenamed])
        XCTAssertTrue(result.candidates.isEmpty)
    }

    // MARK: - Settle

    func testSettleRequiresTwoIdenticalProbesAfterInterval() {
        var tracker = WatchFolderScanner.SettleTracker(settleInterval: 2)
        let mtime = Date(timeIntervalSince1970: 1_000)

        // First probe: never settled.
        XCTAssertFalse(tracker.update(key: "run.gpx", byteSize: 100, contentModificationDate: mtime, now: Date(timeIntervalSince1970: 1_100)))
        // Same probes too soon: still not settled.
        XCTAssertFalse(tracker.update(key: "run.gpx", byteSize: 100, contentModificationDate: mtime, now: Date(timeIntervalSince1970: 1_101)))
        // Identical probes, interval elapsed: settled.
        XCTAssertTrue(tracker.update(key: "run.gpx", byteSize: 100, contentModificationDate: mtime, now: Date(timeIntervalSince1970: 1_103)))
    }

    func testSettleResetsWhenFileChanges() {
        var tracker = WatchFolderScanner.SettleTracker(settleInterval: 2)
        let mtime = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(tracker.update(key: "run.gpx", byteSize: 100, contentModificationDate: mtime, now: Date(timeIntervalSince1970: 1_100)))
        // The file grew: previous probe replaced, still not settled even
        // after the interval — the new probe's own window restarts.
        XCTAssertFalse(tracker.update(key: "run.gpx", byteSize: 150, contentModificationDate: mtime.addingTimeInterval(5), now: Date(timeIntervalSince1970: 1_104)))
        XCTAssertFalse(tracker.update(key: "run.gpx", byteSize: 150, contentModificationDate: mtime.addingTimeInterval(5), now: Date(timeIntervalSince1970: 1_105)))
        // Probe taken after the interval from the changed probe's timestamp:
        // settled.
        XCTAssertTrue(tracker.update(key: "run.gpx", byteSize: 150, contentModificationDate: mtime.addingTimeInterval(5), now: Date(timeIntervalSince1970: 1_107)))
    }

    func testSettlePruneDropsVanishedFiles() {
        var tracker = WatchFolderScanner.SettleTracker(settleInterval: 2)
        let mtime = Date(timeIntervalSince1970: 1_000)
        _ = tracker.update(key: "a.gpx", byteSize: 1, contentModificationDate: mtime, now: Date(timeIntervalSince1970: 1_100))
        _ = tracker.update(key: "b.gpx", byteSize: 1, contentModificationDate: mtime, now: Date(timeIntervalSince1970: 1_100))
        tracker.prune(keeping: ["a.gpx"])
        // b.gpx was pruned: probing it again is a first probe.
        XCTAssertFalse(tracker.update(key: "b.gpx", byteSize: 1, contentModificationDate: mtime, now: Date(timeIntervalSince1970: 1_500)))
        // a.gpx retained its previous probe and settles on the next match.
        XCTAssertTrue(tracker.update(key: "a.gpx", byteSize: 1, contentModificationDate: mtime, now: Date(timeIntervalSince1970: 1_500)))
    }

    /// The scripted form of the checklist's slow-write case: a file being
    /// written into a watched directory must not be treated as settled until
    /// its size and modification date have been stable for the settle
    /// interval, and must be once they have.
    func testSettleWithholdsSlowlyWrittenFileUntilStable() throws {
        let directory = temporaryDirectory
        defer { tearDownDirectory(directory) }

        let scanner = self.scanner
        let policy = WatchFolderScanPolicy(settleInterval: 0.05)
        var tracker = WatchFolderScanner.SettleTracker(settleInterval: policy.settleInterval)

        // What the scanner would settle for this directory right now, given
        // the probes recorded so far. An empty directory or a directory with
        // no settled file both yield no candidates; asserting on the file
        // itself is what distinguishes "still writing" from "gone".
        func settledURLs() -> [URL] {
            guard let file = scanner.eligibleFiles(in: directory).files.first else { return [] }
            return tracker.update(
                key: file.url.lastPathComponent,
                byteSize: file.byteSize,
                contentModificationDate: file.contentModificationDate,
                now: Date()
            ) ? [file.url] : []
        }

        // A run file arriving the way a sync client leaves it: several writes
        // separated by pauses, probed mid-write.
        let payload = "<gpx><trkpt lat=\"1\" lon=\"2\"/></gpx>"
        let url = try writeSlowly(
            payload,
            name: "slow-run.gpx",
            in: directory,
            chunkCount: 5,
            pause: 0.03
        ) { url in
            // Mid-write the size is still changing, so the file must never be
            // reported settled, however long the writes take in total.
            let file = scanner.eligibleFiles(in: directory).files.first { $0.url == url }
            guard let file else { return }
            let settled = tracker.update(
                key: file.url.lastPathComponent,
                byteSize: file.byteSize,
                contentModificationDate: file.contentModificationDate,
                now: Date()
            )
            XCTAssertFalse(settled, "a file still being written must not be settled")
        }

        // Still within the interval of the final write: not yet settled.
        XCTAssertTrue(settledURLs().isEmpty, "settle interval has not elapsed yet")

        // Once the size has been stable for the interval, it settles.
        Thread.sleep(forTimeInterval: policy.settleInterval + 0.02)
        XCTAssertEqual(
            settledURLs().map(\.lastPathComponent),
            [url.lastPathComponent],
            "a stable file must settle"
        )

        // And the settled content hashes to what was written, so the ledger
        // records the completed file rather than a partial one.
        XCTAssertEqual(
            try scanner.contentHash(for: url),
            digest.sha256Hex(of: Data(payload.utf8))
        )
        // Sanity: the file exists and is non-empty as the scanner sees it.
        XCTAssertEqual(scanner.eligibleFiles(in: directory).files.first?.byteSize, Data(payload.utf8).count)
    }

    // MARK: - Content hashing

    func testContentHashReadsAndHashesFile() throws {
        let directory = temporaryDirectory
        defer { tearDownDirectory(directory) }
        let url = try write("<gpx>data</gpx>", name: "run.gpx", in: directory)

        let hash = try scanner.contentHash(for: url)
        XCTAssertEqual(hash, digest.sha256Hex(of: Data("<gpx>data</gpx>".utf8)))
    }

    func testContentHashMissingFileReturnsNil() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).gpx")
        XCTAssertNil(try scanner.contentHash(for: missing))
    }

    func testContentHashThrowsResourceLimitForOversizedFile() throws {
        let directory = temporaryDirectory
        defer { tearDownDirectory(directory) }
        let url = directory.appendingPathComponent("huge.gpx")
        try Data(repeating: 0x20, count: 65).write(to: url)

        let tight = WatchFolderScanner(
            digest: digest,
            policy: WatchFolderScanPolicy(maxFileBytes: 64)
        )
        XCTAssertThrowsError(try tight.contentHash(for: url)) { error in
            XCTAssertTrue(error is WorkoutResourceLimitError)
        }
    }

    func testResourceLimitMessageReportsTheEnforcedLimit() throws {
        // A narrowed policy must not claim the product-wide limit it never
        // applied: the message names the bound actually enforced.
        let directory = temporaryDirectory
        defer { tearDownDirectory(directory) }
        let url = directory.appendingPathComponent("huge.gpx")
        try Data(repeating: 0x20, count: 65).write(to: url)

        let tight = WatchFolderScanner(
            digest: digest,
            policy: WatchFolderScanPolicy(maxFileBytes: 10)
        )
        XCTAssertThrowsError(try tight.contentHash(for: url)) { error in
            guard case .sourceFileTooLarge(let limitBytes)? = error as? WorkoutResourceLimitError else {
                return XCTFail("expected a source-file-too-large error, got \(error)")
            }
            XCTAssertEqual(limitBytes, 10)
        }
    }

    // MARK: - Directory listability

    func testIsDirectoryListableDistinguishesGoneFromEmpty() throws {
        // Zero eligible files alone cannot separate "watched folder is empty"
        // from "watched folder is gone"; this predicate makes the ejected or
        // deleted case observable.
        let empty = temporaryDirectory
        defer { tearDownDirectory(empty) }
        XCTAssertTrue(scanner.isDirectoryListable(empty))
        XCTAssertTrue(scanner.eligibleFiles(in: empty).files.isEmpty)

        let withFile = temporaryDirectory
        defer { tearDownDirectory(withFile) }
        try write("<gpx/>", name: "run.gpx", in: withFile)
        XCTAssertTrue(scanner.isDirectoryListable(withFile))
        XCTAssertEqual(scanner.eligibleFiles(in: withFile).files.count, 1)

        // Delete the watched directory: now unlistable, still zero files.
        try FileManager.default.removeItem(at: withFile)
        XCTAssertFalse(scanner.isDirectoryListable(withFile))
        XCTAssertTrue(scanner.eligibleFiles(in: withFile).files.isEmpty)
    }

    func testIsDirectoryListableRejectsMissingAndNonDirectory() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchFolderScanner-missing-\(UUID().uuidString)")
        XCTAssertFalse(scanner.isDirectoryListable(missing))

        let directory = temporaryDirectory
        defer { tearDownDirectory(directory) }
        let file = try write("<gpx/>", name: "run.gpx", in: directory)
        // A regular file is not a watchable directory, even though it exists.
        XCTAssertFalse(scanner.isDirectoryListable(file))
    }
}
