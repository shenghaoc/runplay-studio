import Foundation
import XCTest
@testable import RunPlayCore

/// "Correct new imports": each FIT session is corrected before it is staged,
/// the report rows carry the record, and a correction that cannot finish
/// never fails the import.
final class DEMImportElevationCorrectionTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DEMImportElevationCorrectionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSessionsAreCorrectedBeforeTheyAreSaved() async throws {
        let source = SyntheticDEMTiles(height: 42, tiles: nil)
        let (report, store) = try await importTwoSessions(
            correction: DEMImportElevationCorrection(source: source)
        )

        XCTAssertEqual(report.importedCount, 2)
        XCTAssertEqual(source.requests.count, 2, "one tile request per session")
        for item in report.items {
            let record = try XCTUnwrap(item.elevationCorrection, item.sessionName)
            XCTAssertEqual(record.outcome, .applied)
            let saved = try store.loadWorkout(id: try XCTUnwrap(item.importedWorkoutID))
            // The library stores whole-second dates, so compare the rest.
            XCTAssertEqual(saved.demElevationCorrection?.coverage, record.coverage)
            XCTAssertEqual(saved.demElevationCorrection?.tileSet, source.tileSet)
            XCTAssertTrue(saved.routePoints.allSatisfy { $0.demAltitudeMeters == 42 })
            XCTAssertEqual(
                record.coverage.replacedRecordedPointCount,
                saved.routePoints.count,
                "the fixture's altitude comes from an unstated sensor"
            )
        }
    }

    func testACorrectionThatCannotFinishLeavesTheImportIntact() async throws {
        struct FolderVanished: Error {}
        let source = SyntheticDEMTiles(height: 42, tiles: nil)
        source.loadError = FolderVanished()

        let (report, store) = try await importTwoSessions(
            correction: DEMImportElevationCorrection(source: source)
        )

        XCTAssertEqual(report.importedCount, 2)
        for item in report.items {
            XCTAssertNil(item.elevationCorrection)
            let saved = try store.loadWorkout(id: try XCTUnwrap(item.importedWorkoutID))
            XCTAssertNil(saved.demElevationCorrection, "a later library pass picks it up")
            XCTAssertTrue(saved.routePoints.allSatisfy { $0.demAltitudeMeters == nil })
        }
    }

    func testImportsWithoutACorrectionAreUnchanged() async throws {
        let (report, store) = try await importTwoSessions(correction: nil)

        XCTAssertEqual(report.importedCount, 2)
        for item in report.items {
            XCTAssertNil(item.elevationCorrection)
            XCTAssertNil(try store.loadWorkout(id: try XCTUnwrap(item.importedWorkoutID)).demElevationCorrection)
        }
    }

    func testApplyReturnsNilOnFailureAndRethrowsCancellation() throws {
        let original = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        struct Unreadable: Error {}
        let failing = SyntheticDEMTiles(height: 250)
        failing.loadError = Unreadable()

        var workout = original
        XCTAssertNil(try DEMImportElevationCorrection(source: failing).apply(to: &workout))
        XCTAssertEqual(workout.routePoints, original.routePoints)
        XCTAssertNil(workout.demElevationCorrection)

        XCTAssertThrowsError(
            try DEMImportElevationCorrection(source: SyntheticDEMTiles(height: 250))
                .apply(to: &workout, isCancelled: { true })
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNil(workout.demElevationCorrection)
    }

    // MARK: - Helpers

    private func importTwoSessions(
        correction: DEMImportElevationCorrection?
    ) async throws -> (FITSessionBatchImportReport, FileWorkoutLibraryStore) {
        let url = tempDir.appendingPathComponent("two-sessions.fit")
        try FITMultiSessionFixtureBuilder.twoSequentialRuns().write(to: url, options: .atomic)
        let service = FITSessionImportService(digest: TestContentDigest())
        let scan = try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("library"))

        let report = try await service.importSessions(
            FITSessionImportSelection(
                selectedCandidateIDs: scan.candidates.map(\.providerActivityID),
                candidates: scan.candidates
            ),
            from: url,
            existingWorkouts: [],
            storeActor: WorkoutLibraryStoreActor(store: store),
            elevationCorrection: correction
        )
        return (report, store)
    }
}
