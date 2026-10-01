import Combine
import XCTest
import RunPlayCore
import RunPlayPlatform
@testable import RunPlayStudio

/// The Strava archive sheet's import lifecycle, driven through `AppState`
/// against a small synthetic archive.
///
/// Scanning and importing are `RunPlayPlatform`'s to prove. Proven here is what
/// the sheet does with the outcome: above all, that a cancelled import ends on a
/// report that says nothing was saved instead of closing without a word.
@MainActor
final class AppStateArchiveImportTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateArchiveImportTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeAppState(announcer: any AccessibilityAnnouncing) -> AppState {
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("library"))
        return AppState(
            storeActor: WorkoutLibraryStoreActor(store: store),
            importService: WorkoutImportService(),
            archiveService: StravaArchiveService(),
            accessibilityAnnouncer: announcer
        )
    }

    /// A GPX run whose content differs from its siblings', so none is skipped as
    /// a duplicate of another.
    private static func gpx(name: String, latitude: Double) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RunPlayTest">
          <trk><name>\(name)</name><trkseg>
            <trkpt lat="\(latitude)" lon="-122.42"><ele>10</ele><time>2024-01-01T08:00:00Z</time></trkpt>
            <trkpt lat="\(latitude + 0.001)" lon="-122.42"><ele>12</ele><time>2024-01-01T08:00:30Z</time></trkpt>
            <trkpt lat="\(latitude + 0.002)" lon="-122.419"><ele>11</ele><time>2024-01-01T08:01:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """.utf8)
    }

    /// Open the review sheet over a synthetic archive of three running
    /// activities, the way a finished scan would.
    private func presentArchiveReview(on appState: AppState) throws -> ArchiveImportSession {
        let activities = (1...3).map { index in
            (path: "activities/\(index).gpx", data: Self.gpx(name: "Run \(index)", latitude: 37.0 + Double(index) * 0.01))
        }
        let zip = tempDir.appendingPathComponent("export.zip")
        try StoredZip.build(activities).write(to: zip)

        let candidates = activities.enumerated().map { offset, activity in
            WorkoutArchiveCandidate(
                id: "activity-\(offset + 1)",
                archiveRelativePath: activity.path,
                providerActivityID: "\(offset + 1)",
                activityName: "Run \(offset + 1)",
                activityType: "Run",
                format: .gpx,
                status: .ready,
                isSelectedByDefault: true,
                archiveOrder: offset
            )
        }
        let session = ArchiveImportSession(
            archiveURL: zip,
            scanResult: WorkoutArchiveScanResult(
                candidates: candidates,
                diagnostics: WorkoutArchiveScanDiagnostics(archiveName: "export.zip"),
                isRecognizedStravaExport: true
            ),
            securityScoped: false
        )
        appState.archiveSession = session
        return session
    }

    /// Wait for the sheet to reach a terminal phase, or to be dismissed.
    private func waitForTerminalPhase(_ appState: AppState) async {
        for _ in 0..<400 {
            guard let session = appState.archiveSession else { return }
            if session.phase == .report { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Strava archive import did not reach a terminal phase")
    }

    /// Assert the library holds nothing, in memory and on disk. A library that
    /// was never written has no manifest, which is exactly the state an import
    /// that rolled back leaves behind.
    private func assertLibraryUntouched(
        _ appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertTrue(appState.workouts.isEmpty, "a cancelled import must add nothing", file: file, line: line)
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("library"))
        XCTAssertThrowsError(try store.loadManifest(), "a cancelled import must write no manifest", file: file, line: line) { error in
            guard case WorkoutLibraryError.manifestMissing = error else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }
        let hasActiveBatch = await appState.storeActor?.hasActiveBatch
        XCTAssertEqual(hasActiveBatch, false, "a cancelled import must release the batch", file: file, line: line)
    }

    // MARK: - Lifecycle

    func testCancellingAfterStagingKeepsTheSheetOnACancelledReport() async throws {
        let announcer = RecordingAccessibilityAnnouncer()
        let appState = makeAppState(announcer: announcer)
        let session = try presentArchiveReview(on: appState)

        // Cancel from inside the progress stream once an activity is staged.
        // That fixes the cancel at a point of the pass, after staging and before
        // the commit, instead of racing it.
        let cancelOnceStaged = session.$progress.sink { progress in
            if progress.stagedCount >= 1 { appState.cancelArchiveImport() }
        }
        defer { cancelOnceStaged.cancel() }

        appState.confirmArchiveImport()
        await waitForTerminalPhase(appState)

        // The sheet stays open on a report until the user dismisses it.
        let open = try XCTUnwrap(appState.archiveSession, "a cancelled import must not close the sheet")
        XCTAssertEqual(open.phase, .report)
        let report = try XCTUnwrap(open.report)
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertTrue(
            report.items.contains { $0.status == .ready },
            "an activity had been staged when the cancel landed"
        )
        XCTAssertEqual(BatchImportReportPresentation.archiveTitle(for: report), "Import Cancelled")
        XCTAssertEqual(
            BatchImportReportPresentation.archiveNotice(for: report),
            BatchImportReportPresentation.cancelledNotice
        )

        await assertLibraryUntouched(appState)
        XCTAssertEqual(appState.operationState, .idle)
        XCTAssertTrue(appState.isModalPresentationActive, "the report is the open sheet")
        XCTAssertEqual(announcer.messages, ["Import cancelled."], "announced once, when the report appears")

        appState.dismissArchiveSession()
        XCTAssertNil(appState.archiveSession)
        XCTAssertFalse(appState.isModalPresentationActive)
    }

    func testCancellingBeforeAnythingIsStagedEndsOnTheSameCancelledReport() async throws {
        let announcer = RecordingAccessibilityAnnouncer()
        let appState = makeAppState(announcer: announcer)
        _ = try presentArchiveReview(on: appState)

        // The task has not started when the cancel arrives, so the service
        // stops before it opens the archive.
        appState.confirmArchiveImport()
        appState.cancelArchiveImport()
        await waitForTerminalPhase(appState)

        let open = try XCTUnwrap(appState.archiveSession, "a cancelled import must not close the sheet")
        XCTAssertEqual(open.phase, .report)
        let report = try XCTUnwrap(open.report)
        XCTAssertTrue(report.wasCancelled)
        XCTAssertTrue(report.items.isEmpty, "nothing had been staged")
        XCTAssertEqual(BatchImportReportPresentation.archiveTitle(for: report), "Import Cancelled")
        XCTAssertEqual(
            BatchImportReportPresentation.archiveNotice(for: report),
            BatchImportReportPresentation.cancelledNotice
        )

        await assertLibraryUntouched(appState)
        XCTAssertEqual(appState.operationState, .idle)
        XCTAssertTrue(appState.isModalPresentationActive, "the report is the open sheet")
        XCTAssertEqual(announcer.messages, ["Import cancelled."], "announced once, when the report appears")
    }

    func testANormalCompletionStillEndsOnImportComplete() async throws {
        let appState = makeAppState(announcer: RecordingAccessibilityAnnouncer())
        _ = try presentArchiveReview(on: appState)

        appState.confirmArchiveImport()
        await waitForTerminalPhase(appState)

        let open = try XCTUnwrap(appState.archiveSession)
        XCTAssertEqual(open.phase, .report)
        let report = try XCTUnwrap(open.report)
        XCTAssertFalse(report.wasCancelled)
        XCTAssertFalse(report.commitFailed)
        XCTAssertEqual(report.importedCount, 3)
        XCTAssertEqual(BatchImportReportPresentation.archiveTitle(for: report), "Import Complete")
        XCTAssertNil(BatchImportReportPresentation.archiveNotice(for: report))
        XCTAssertEqual(appState.workouts.count, 3)
    }
}

// MARK: - Synthetic archive

/// A minimal ZIP writer for synthetic fixtures: stored (uncompressed) entries
/// only. The Studio tests do not link ZIPFoundation, and a few stored entries
/// are all an archive import needs to read.
private enum StoredZip {

    static func build(_ entries: [(path: String, data: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let size = UInt32(entry.data.count)
            let checksum = crc32(entry.data)
            let offset = UInt32(archive.count)

            archive.append(littleEndian: UInt32(0x0403_4B50))   // local file header
            archive.append(littleEndian: UInt16(20))            // version needed
            archive.append(littleEndian: UInt16(0))             // flags
            archive.append(littleEndian: UInt16(0))             // method: stored
            archive.append(littleEndian: UInt16(0))             // time
            archive.append(littleEndian: UInt16(0x21))          // date
            archive.append(littleEndian: checksum)
            archive.append(littleEndian: size)                  // compressed
            archive.append(littleEndian: size)                  // uncompressed
            archive.append(littleEndian: UInt16(name.count))
            archive.append(littleEndian: UInt16(0))             // extra length
            archive.append(name)
            archive.append(entry.data)

            directory.append(littleEndian: UInt32(0x0201_4B50)) // central directory header
            directory.append(littleEndian: UInt16(20))          // version made by
            directory.append(littleEndian: UInt16(20))          // version needed
            directory.append(littleEndian: UInt16(0))           // flags
            directory.append(littleEndian: UInt16(0))           // method: stored
            directory.append(littleEndian: UInt16(0))           // time
            directory.append(littleEndian: UInt16(0x21))        // date
            directory.append(littleEndian: checksum)
            directory.append(littleEndian: size)                // compressed
            directory.append(littleEndian: size)                // uncompressed
            directory.append(littleEndian: UInt16(name.count))
            directory.append(littleEndian: UInt16(0))           // extra length
            directory.append(littleEndian: UInt16(0))           // comment length
            directory.append(littleEndian: UInt16(0))           // disk number
            directory.append(littleEndian: UInt16(0))           // internal attributes
            directory.append(littleEndian: UInt32(0))           // external attributes
            directory.append(littleEndian: offset)
            directory.append(name)
        }

        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(littleEndian: UInt32(0x0605_4B50))       // end of central directory
        archive.append(littleEndian: UInt16(0))                 // this disk
        archive.append(littleEndian: UInt16(0))                 // directory disk
        archive.append(littleEndian: UInt16(entries.count))
        archive.append(littleEndian: UInt16(entries.count))
        archive.append(littleEndian: UInt32(directory.count))
        archive.append(littleEndian: directoryOffset)
        archive.append(littleEndian: UInt16(0))                 // comment length
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        let table: [UInt32] = (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            return value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append<Integer: FixedWidthInteger>(littleEndian value: Integer) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
