import XCTest
import ZIPFoundation
import RunPlayCore
@testable import RunPlayPlatform

final class StravaArchiveImportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StravaArchive-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeGPX(name: String, lat: Double = 37.77, lon: Double = -122.42) -> Data {
        let t0 = "2024-01-01T08:00:00Z"
        let t1 = "2024-01-01T08:00:30Z"
        let t2 = "2024-01-01T08:01:00Z"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RunPlayTest">
          <trk><name>\(name)</name><trkseg>
            <trkpt lat="\(lat)" lon="\(lon)"><ele>10</ele><time>\(t0)</time></trkpt>
            <trkpt lat="\(lat + 0.001)" lon="\(lon)"><ele>12</ele><time>\(t1)</time></trkpt>
            <trkpt lat="\(lat + 0.002)" lon="\(lon + 0.001)"><ele>11</ele><time>\(t2)</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        return Data(xml.utf8)
    }

    private func writeZip(
        named: String,
        root: String? = "export",
        entries: [(path: String, data: Data)]
    ) throws -> URL {
        let url = tempDir.appendingPathComponent(named)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            let fullPath = root.map { "\($0)/\(entry.path)" } ?? entry.path
            try archive.addEntry(
                with: fullPath,
                type: .file,
                uncompressedSize: Int64(entry.data.count),
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, entry.data.count)
                    return entry.data.subdata(in: start..<end)
                }
            )
        }
        return url
    }

    private func activitiesCSV(rows: [(id: String, name: String, type: String, file: String)]) -> Data {
        var csv = "Activity ID,Activity Name,Activity Type,Activity Date,Filename\n"
        for row in rows {
            // Quote the date so embedded commas do not shift columns.
            csv += "\(row.id),\(row.name),\(row.type),\"2024-01-01T08:00:00Z\",\(row.file)\n"
        }
        return Data(csv.utf8)
    }

    // MARK: - Scan

    func testRecognizedStravaArchiveWithRoot() async throws {
        let gpx = makeGPX(name: "Morning")
        let csv = activitiesCSV(rows: [
            (id: "101", name: "Morning", type: "Run", file: "activities/101.gpx")
        ])
        let zip = try writeZip(named: "strava.zip", entries: [
            ("activities.csv", csv),
            ("activities/101.gpx", gpx)
        ])

        let service = StravaArchiveService()
        let result = try await service.scanArchive(at: zip, existingWorkouts: [])
        XCTAssertTrue(result.isRecognizedStravaExport)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].status, .ready)
        XCTAssertTrue(result.candidates[0].isSelectedByDefault)
    }

    func testRejectsPlainGPXZip() async throws {
        let gpx = makeGPX(name: "Only")
        let zip = try writeZip(named: "plain.zip", root: nil, entries: [
            ("run.gpx", gpx)
        ])
        let service = StravaArchiveService()
        let result = try await service.scanArchive(at: zip, existingWorkouts: [])
        XCTAssertFalse(result.isRecognizedStravaExport)
        XCTAssertNotNil(result.rejectionMessage)
    }

    func testUnsupportedCyclingUnselected() async throws {
        let gpx = makeGPX(name: "Ride")
        let csv = activitiesCSV(rows: [
            (id: "1", name: "Ride", type: "Ride", file: "activities/1.gpx"),
            (id: "2", name: "Run", type: "Run", file: "activities/2.gpx")
        ])
        let zip = try writeZip(named: "mixed.zip", entries: [
            ("activities.csv", csv),
            ("activities/1.gpx", gpx),
            ("activities/2.gpx", makeGPX(name: "Run", lat: 38))
        ])
        let service = StravaArchiveService()
        let result = try await service.scanArchive(at: zip, existingWorkouts: [])
        let ride = result.candidates.first { $0.providerActivityID == "1" }
        let run = result.candidates.first { $0.providerActivityID == "2" }
        XCTAssertEqual(ride?.status, .unsupportedActivityType)
        XCTAssertFalse(ride?.isSelectedByDefault ?? true)
        XCTAssertEqual(run?.status, .ready)
        XCTAssertTrue(run?.isSelectedByDefault ?? false)
    }

    func testPathTraversalEntrySkippedAsUnsafe() async throws {
        // ZIPFoundation may reject adding traversal paths; simulate scan diagnostics via validator.
        if case .rejected = WorkoutArchivePathValidator.validate("../../evil.gpx") {
            // ok
        } else {
            XCTFail("path traversal should be rejected")
        }
    }

    func testIgnoresMacOSXAndPhotos() async throws {
        let gpx = makeGPX(name: "Run")
        let csv = activitiesCSV(rows: [
            (id: "1", name: "Run", type: "Run", file: "activities/1.gpx")
        ])
        let zip = try writeZip(named: "junk.zip", entries: [
            ("activities.csv", csv),
            ("activities/1.gpx", gpx),
            ("__MACOSX/._activities.csv", Data([0])),
            ("photos/1.jpg", Data([0xFF, 0xD8]))
        ])
        let service = StravaArchiveService()
        let result = try await service.scanArchive(at: zip, existingWorkouts: [])
        XCTAssertTrue(result.isRecognizedStravaExport)
        XCTAssertGreaterThan(result.diagnostics.ignoredEntryCount, 0)
    }

    func testDuplicateExactArchivePathIsSurfacedAsUnsafe() async throws {
        let csv = activitiesCSV(rows: [
            (id: "1", name: "Run", type: "Run", file: "activities/1.gpx")
        ])
        let zip = try writeZip(named: "duplicate-path.zip", entries: [
            ("activities.csv", csv),
            ("activities/1.gpx", makeGPX(name: "First")),
            ("activities/1.gpx", makeGPX(name: "Second", lat: 38))
        ])

        let result = try await StravaArchiveService().scanArchive(at: zip, existingWorkouts: [])
        XCTAssertTrue(result.isRecognizedStravaExport)
        XCTAssertEqual(result.candidates.first?.status, .unsafeArchiveEntry)
        XCTAssertGreaterThan(result.diagnostics.unsafeEntryCount, 0)
    }

    func testScanAndImportEnforceTotalCandidateSizeLimit() async throws {
        let gpx = makeGPX(name: "Limited")
        let csv = activitiesCSV(rows: [
            (id: "1", name: "Limited", type: "Run", file: "activities/1.gpx")
        ])
        let zip = try writeZip(named: "size-limit.zip", entries: [
            ("activities.csv", csv),
            ("activities/1.gpx", gpx)
        ])
        let policy = WorkoutArchiveSecurityPolicy(
            maxUncompressedEntryBytes: Int64(gpx.count * 2),
            maxTotalCandidateUncompressedBytes: Int64(gpx.count - 1)
        )
        let service = StravaArchiveService(policy: policy)
        let scan = try await service.scanArchive(at: zip, existingWorkouts: [])
        XCTAssertEqual(scan.candidates.first?.status, .exceedsResourceLimit)
        XCTAssertFalse(scan.candidates.first?.isSelectedByDefault ?? true)

        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("size-limit-lib"))
        let selection = WorkoutBatchImportSelection(
            selectedCandidateIDs: scan.candidates.map(\.id),
            candidates: scan.candidates
        )
        do {
            _ = try await service.importCandidates(
                selection,
                from: zip,
                existingWorkouts: [],
                storeActor: WorkoutLibraryStoreActor(store: store)
            )
            XCTFail("a force-selected oversized candidate must be rejected before staging")
        } catch let error as WorkoutArchiveError {
            XCTAssertTrue(error.localizedDescription.contains("total size limit"))
        }
    }

    // MARK: - Import end-to-end

    func testImportValidActivitiesAndSecondImportDuplicates() async throws {
        let gpx1 = makeGPX(name: "A", lat: 37.1)
        let gpx2 = makeGPX(name: "B", lat: 37.2)
        let csv = activitiesCSV(rows: [
            (id: "201", name: "A", type: "Run", file: "activities/201.gpx"),
            (id: "202", name: "B", type: "Trail Run", file: "activities/202.gpx")
        ])
        let zip = try writeZip(named: "import.zip", entries: [
            ("activities.csv", csv),
            ("activities/201.gpx", gpx1),
            ("activities/202.gpx", gpx2)
        ])

        let libraryRoot = tempDir.appendingPathComponent("lib")
        let store = FileWorkoutLibraryStore(rootURL: libraryRoot)
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let service = StravaArchiveService()

        let scan = try await service.scanArchive(at: zip, existingWorkouts: [])
        XCTAssertEqual(scan.readyCount, 2)

        let selection = WorkoutBatchImportSelection(
            selectedCandidateIDs: scan.candidates.map(\.id),
            candidates: scan.candidates
        )
        let report = try await service.importCandidates(
            selection,
            from: zip,
            existingWorkouts: [],
            storeActor: storeActor
        )
        XCTAssertEqual(report.importedCount, 2)
        XCTAssertFalse(report.commitFailed)
        XCTAssertNotNil(report.selectedWorkoutID)

        let loaded = await storeActor.loadLibrary()
        guard case .workouts(let workouts, _, _, _, _) = loaded else {
            return XCTFail("expected workouts")
        }
        XCTAssertEqual(workouts.count, 2)
        XCTAssertEqual(workouts.first?.importProvenance?.provider, .stravaBulkExport)
        XCTAssertNotNil(workouts.first?.importProvenance?.contentSHA256)

        // Second import: zero new workouts.
        let scan2 = try await service.scanArchive(at: zip, existingWorkouts: workouts)
        XCTAssertEqual(scan2.duplicateCount, 2)
        let selection2 = WorkoutBatchImportSelection(
            selectedCandidateIDs: scan2.candidates.map(\.id),
            candidates: scan2.candidates
        )
        let report2 = try await service.importCandidates(
            selection2,
            from: zip,
            existingWorkouts: workouts,
            storeActor: storeActor
        )
        XCTAssertEqual(report2.importedCount, 0)

        let loaded2 = await storeActor.loadLibrary()
        guard case .workouts(let workouts2, _, _, _, _) = loaded2 else {
            return XCTFail("expected workouts")
        }
        XCTAssertEqual(workouts2.count, 2)
    }

    func testProviderIDWithDifferentContentIsReportedAsConflict() async throws {
        let csv = activitiesCSV(rows: [
            (id: "301", name: "Original", type: "Run", file: "activities/301.gpx")
        ])
        let zip = try writeZip(named: "provider-conflict.zip", entries: [
            ("activities.csv", csv),
            ("activities/301.gpx", makeGPX(name: "Original", lat: 37.1))
        ])
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("provider-conflict-lib"))
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let service = StravaArchiveService()

        let initialScan = try await service.scanArchive(at: zip, existingWorkouts: [])
        let initialSelection = WorkoutBatchImportSelection(
            selectedCandidateIDs: initialScan.candidates.map(\.id),
            candidates: initialScan.candidates
        )
        _ = try await service.importCandidates(
            initialSelection,
            from: zip,
            existingWorkouts: [],
            storeActor: storeActor
        )
        guard case .workouts(let existing, _, _, _, _) = await storeActor.loadLibrary() else {
            return XCTFail("expected imported workout")
        }

        _ = try writeZip(named: "provider-conflict.zip", entries: [
            ("activities.csv", csv),
            ("activities/301.gpx", makeGPX(name: "Changed", lat: 38.1))
        ])
        let conflictScan = try await service.scanArchive(at: zip, existingWorkouts: existing)
        XCTAssertEqual(conflictScan.candidates.first?.status, .duplicate)

        let conflictSelection = WorkoutBatchImportSelection(
            selectedCandidateIDs: conflictScan.candidates.map(\.id),
            candidates: conflictScan.candidates
        )
        let report = try await service.importCandidates(
            conflictSelection,
            from: zip,
            existingWorkouts: existing,
            storeActor: storeActor
        )
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertEqual(report.count(for: .providerConflict), 1)
    }

    func testImportRevalidatesEntryCountAfterArchiveChanges() async throws {
        let csv = activitiesCSV(rows: [
            (id: "401", name: "Count", type: "Run", file: "activities/401.gpx")
        ])
        let zip = try writeZip(named: "entry-count.zip", entries: [
            ("activities.csv", csv),
            ("activities/401.gpx", makeGPX(name: "Count"))
        ])
        let service = StravaArchiveService(
            policy: WorkoutArchiveSecurityPolicy(maxEntryCount: 2)
        )
        let scan = try await service.scanArchive(at: zip, existingWorkouts: [])
        let selection = WorkoutBatchImportSelection(
            selectedCandidateIDs: scan.candidates.map(\.id),
            candidates: scan.candidates
        )

        _ = try writeZip(named: "entry-count.zip", entries: [
            ("activities.csv", csv),
            ("activities/401.gpx", makeGPX(name: "Count")),
            ("later-added.txt", Data("changed after scan".utf8))
        ])
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("entry-count-lib"))
        do {
            _ = try await service.importCandidates(
                selection,
                from: zip,
                existingWorkouts: [],
                storeActor: WorkoutLibraryStoreActor(store: store)
            )
            XCTFail("the reopened archive must enforce the entry count")
        } catch let error as WorkoutArchiveError {
            XCTAssertEqual(error, .tooManyEntries)
        }
    }

    func testCorruptSiblingDoesNotBlockValid() async throws {
        let good = makeGPX(name: "Good")
        let bad = Data("not a gpx".utf8)
        let csv = activitiesCSV(rows: [
            (id: "1", name: "Good", type: "Run", file: "activities/1.gpx"),
            (id: "2", name: "Bad", type: "Run", file: "activities/2.gpx")
        ])
        let zip = try writeZip(named: "partial.zip", entries: [
            ("activities.csv", csv),
            ("activities/1.gpx", good),
            ("activities/2.gpx", bad)
        ])
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib2"))
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let service = StravaArchiveService()
        let scan = try await service.scanArchive(at: zip, existingWorkouts: [])
        let selection = WorkoutBatchImportSelection(
            selectedCandidateIDs: scan.candidates.map(\.id),
            candidates: scan.candidates
        )
        let report = try await service.importCandidates(
            selection,
            from: zip,
            existingWorkouts: [],
            storeActor: storeActor
        )
        XCTAssertEqual(report.importedCount, 1)
        XCTAssertEqual(report.count(for: .parseFailed) + report.count(for: .noGPSRoute), 1)
    }

    func testCancellationLeavesLibraryUnchanged() async throws {
        let gpx = makeGPX(name: "Cancel")
        let csv = activitiesCSV(rows: [
            (id: "1", name: "Cancel", type: "Run", file: "activities/1.gpx")
        ])
        let zip = try writeZip(named: "cancel.zip", entries: [
            ("activities.csv", csv),
            ("activities/1.gpx", gpx)
        ])
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib3"))
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let service = StravaArchiveService()
        let scan = try await service.scanArchive(at: zip, existingWorkouts: [])
        let selection = WorkoutBatchImportSelection(
            selectedCandidateIDs: scan.candidates.map(\.id),
            candidates: scan.candidates
        )

        let task = Task {
            try await service.importCandidates(
                selection,
                from: zip,
                existingWorkouts: [],
                storeActor: storeActor
            ) { _ in }
        }
        task.cancel()
        do {
            let report = try await task.value
            // Either cancelled with zero imports or completed (race) — never partial commit.
            if report.wasCancelled {
                XCTAssertEqual(report.importedCount, 0)
                XCTAssertThrowsError(try store.loadManifest())
            } else {
                XCTAssertTrue(report.importedCount == 0 || report.importedCount == 1)
            }
        } catch is CancellationError {
            // Thrown cancellation is also acceptable; library must stay empty.
            XCTAssertThrowsError(try store.loadManifest())
        }
    }

    func testContentHasherStable() {
        let data = Data("stable".utf8)
        let a = ContentHasher.sha256Hex(of: data)
        let b = ContentHasher.sha256Hex(of: data)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a, a.lowercased())
    }
}
