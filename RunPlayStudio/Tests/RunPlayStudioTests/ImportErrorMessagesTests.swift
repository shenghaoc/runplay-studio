import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// Import failure wording shared between the manual file-import path and the
/// watch-folder path.
///
/// Parse-level failures are worded in exactly one place so the two entry points
/// cannot drift. `.unsupportedFormat` and `.fileNotFound` are deliberately
/// caller-owned: "the selected file" and "import a file instead" are both wrong
/// for a file that arrived by itself in a watched folder.
@MainActor
final class ImportErrorMessagesTests: XCTestCase {

    private let fileNotFoundURL = URL(fileURLWithPath: "/tmp/run.gpx")

    /// Locks the user-visible strings the manual import path has always shown.
    /// Unifying the shared cases must not change what a picker-based import
    /// tells the user.
    func testManualImportWordingIsUnchanged() {
        let appState = AppState(storeActor: nil, importService: nil)

        XCTAssertEqual(
            appState.importErrorMessage(for: .unsupportedFormat("zip"), filename: "run.zip"),
            "'run.zip' uses the .zip format, which isn't supported. Import a GPX, TCX, FIT, or JSON file instead."
        )
        XCTAssertEqual(
            appState.importErrorMessage(for: .fileNotFound(fileNotFoundURL), filename: "run.gpx"),
            "Couldn't find the selected file. Try importing again."
        )
        XCTAssertEqual(
            appState.importErrorMessage(for: .parsingError("bad XML"), filename: "run.gpx"),
            "'run.gpx' couldn't be parsed. bad XML"
        )
        XCTAssertEqual(
            appState.importErrorMessage(for: .missingData("no trackpoints"), filename: "run.gpx"),
            "'run.gpx' is missing required data. no trackpoints"
        )
        XCTAssertEqual(
            appState.importErrorMessage(for: .invalidFormat("truncated"), filename: "run.fit"),
            "'run.fit' has an invalid format. truncated"
        )
    }

    func testSharedParseLevelWordingIsTheSingleSource() {
        XCTAssertEqual(
            AppState.parseLevelImportErrorMessage(
                for: .parsingError("bad XML"),
                filename: "run.gpx"
            ),
            "'run.gpx' couldn't be parsed. bad XML"
        )
        XCTAssertEqual(
            AppState.parseLevelImportErrorMessage(
                for: .missingData("no trackpoints"),
                filename: "run.gpx"
            ),
            "'run.gpx' is missing required data. no trackpoints"
        )
        XCTAssertEqual(
            AppState.parseLevelImportErrorMessage(
                for: .invalidFormat("truncated"),
                filename: "run.fit"
            ),
            "'run.fit' has an invalid format. truncated"
        )
    }

    /// The two context-dependent cases must stay with each caller. If this ever
    /// returns non-nil, the shared helper has taken over wording that only
    /// makes sense for one entry point.
    func testContextDependentCasesAreCallerOwned() {
        XCTAssertNil(AppState.parseLevelImportErrorMessage(
            for: .unsupportedFormat("zip"),
            filename: "run.zip"
        ))
        XCTAssertNil(AppState.parseLevelImportErrorMessage(
            for: .fileNotFound(fileNotFoundURL),
            filename: "run.gpx"
        ))
    }

    /// The manual path must keep delegating to the shared helper rather than
    /// growing its own second copy of the parse-level strings.
    func testManualPathDelegatesToSharedWording() {
        let appState = AppState(storeActor: nil, importService: nil)
        let cases: [WorkoutImportError] = [
            .parsingError("bad XML"),
            .missingData("no trackpoints"),
            .invalidFormat("truncated"),
        ]
        for error in cases {
            XCTAssertEqual(
                appState.importErrorMessage(for: error, filename: "run.gpx"),
                AppState.parseLevelImportErrorMessage(for: error, filename: "run.gpx")
            )
        }
    }

    func testMalformedJSONMetadataIsAnImportFailureInBothPaths() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("malformed.json")
        try Data(#"{"metadata":{"name":42},"routePoints":[]}"#.utf8).write(to: file)

        XCTAssertThrowsError(try JSONWorkoutImporter().importWorkout(from: file)) { error in
            guard case WorkoutImportError.parsingError = error else {
                return XCTFail("Expected the JSON importer to translate its decoding error, got \(error)")
            }
        }

        let app = makeAppState(at: root.appendingPathComponent("library"))
        await expectFailures(in: app, importing: file, prefix: "'malformed.json' couldn't be parsed.")
    }

    func testActualWorkoutSaveFailureIsReportedAsPersistenceInBothPaths() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("valid.json")
        try Data(
            #"{"routePoints":[{"timestamp":"2026-01-01T00:00:00Z","latitude":1.3,"longitude":103.8},{"timestamp":"2026-01-01T00:00:10Z","latitude":1.3003,"longitude":103.8}]}"#.utf8
        ).write(to: file)
        _ = try JSONWorkoutImporter().importWorkout(from: file)

        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        // A regular file prevents the store from creating the workouts directory.
        try Data().write(to: library.appendingPathComponent("workouts"))
        let app = makeAppState(at: library)
        await expectFailures(in: app, importing: file, prefix: "Imported but could not save to your library.")
    }

    func testUnexpectedImporterFailureDoesNotClaimThatASaveFailed() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("unreadable.json")
        let app = makeAppState(at: root.appendingPathComponent("library"), importer: ReadFailingImporter())
        await expectFailures(in: app, importing: file, prefix: "'unreadable.json' couldn't be parsed.")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunPlayImportErrors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeAppState(
        at library: URL,
        importer: any WorkoutImportServicing = WorkoutImportService()
    ) -> AppState {
        AppState(
            storeActor: WorkoutLibraryStoreActor(store: FileWorkoutLibraryStore(rootURL: library)),
            importService: importer
        )
    }

    private func expectFailures(in app: AppState, importing file: URL, prefix: String) async {
        let result = await app.performWatchFolderImport(
            from: file,
            configuration: WatchFolderConfiguration(displayName: "Inbox", bookmarkData: Data())
        )
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.failureDetail.hasPrefix(prefix), result.failureDetail)
        XCTAssertFalse(app.showingError, "watch-folder failures are non-modal")

        await app.importWorkout(from: file)
        XCTAssertTrue(app.showingError)
        XCTAssertTrue(app.errorMessage?.hasPrefix(prefix) == true, app.errorMessage ?? "no manual failure")
        XCTAssertEqual(app.operationState, .idle)
        XCTAssertTrue(app.workouts.isEmpty)
    }
}

private struct ReadFailingImporter: WorkoutImportServicing {
    func importWorkout(from url: URL) async throws -> RunWorkout {
        throw CocoaError(.fileReadUnknown)
    }

    func importWorkout(from input: WorkoutImportInput) async throws -> RunWorkout {
        throw CocoaError(.fileReadUnknown)
    }
}
