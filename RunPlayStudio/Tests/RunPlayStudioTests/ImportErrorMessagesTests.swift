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
}
