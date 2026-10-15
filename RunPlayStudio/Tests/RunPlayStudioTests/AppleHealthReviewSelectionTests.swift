import XCTest
import RunPlayCore
@testable import RunPlayPlatform
@testable import RunPlayStudio

/// Space toggles the import checkbox of the rows selected in the review table.
///
/// The rule is `AppleHealthReviewPresentation.toggledImportSelection`; the
/// session applies it to the rows the table shows; the view only forwards the
/// key. Every value here is invented.
@MainActor
final class AppleHealthReviewSelectionTests: XCTestCase {

    // MARK: - The rule

    func testOneUncheckedRowBecomesChecked() {
        XCTAssertEqual(
            AppleHealthReviewPresentation.toggledImportSelection(["a"], togglingRows: ["b"]),
            ["a", "b"]
        )
    }

    func testOneCheckedRowBecomesUnchecked() {
        XCTAssertEqual(
            AppleHealthReviewPresentation.toggledImportSelection(["a", "b"], togglingRows: ["b"]),
            ["a"]
        )
    }

    func testSeveralCheckedRowsAllBecomeUnchecked() {
        XCTAssertEqual(
            AppleHealthReviewPresentation.toggledImportSelection(["a", "b", "c"], togglingRows: ["a", "b"]),
            ["c"]
        )
    }

    /// Any unchecked row in the selection means check them all, so a second
    /// press unchecks all of them rather than flipping each one back.
    func testAMixedSelectionIsCheckedThenUncheckedAsOne() {
        let once = AppleHealthReviewPresentation.toggledImportSelection(["a", "z"], togglingRows: ["a", "b"])
        XCTAssertEqual(once, ["a", "b", "z"])
        XCTAssertEqual(
            AppleHealthReviewPresentation.toggledImportSelection(once, togglingRows: ["a", "b"]),
            ["z"]
        )
    }

    func testNoSelectedRowsChangeNothing() {
        XCTAssertEqual(
            AppleHealthReviewPresentation.toggledImportSelection(["a"], togglingRows: []),
            ["a"]
        )
    }

    // MARK: - The session

    func testSpaceOnOneRowUpdatesTheCountAndTheImportButton() {
        let session = makeSession(readyCount: 3)
        XCTAssertEqual(session.selectedCount, 3)

        session.tableSelection = ["ready-1"]
        XCTAssertTrue(session.toggleImportForTableSelection())
        XCTAssertEqual(session.selectedIDs, ["ready-0", "ready-2"])
        XCTAssertEqual(session.selectedCount, 2)
        XCTAssertEqual(importTitle(session), "Import 2 Workouts")

        XCTAssertTrue(session.toggleImportForTableSelection())
        XCTAssertEqual(session.selectedCount, 3)
        XCTAssertEqual(importTitle(session), "Import 3 Workouts")
    }

    func testSpaceOnSeveralRowsTogglesEveryOne() {
        let session = makeSession(readyCount: 3)
        session.tableSelection = ["ready-0", "ready-2"]

        session.toggleImportForTableSelection()
        XCTAssertEqual(session.selectedIDs, ["ready-1"])
        XCTAssertEqual(importTitle(session), "Import 1 Workout")

        session.toggleImportForTableSelection()
        XCTAssertEqual(session.selectedIDs, ["ready-0", "ready-1", "ready-2"])
    }

    /// A flagged row starts unchecked and toggles like any other; with nothing
    /// else checked, the Import button goes from disabled to enabled and back.
    func testAFlaggedRowTogglesLikeAnyOtherAndEnablesImport() {
        let session = makeSession(readyCount: 0, flaggedCount: 1)
        XCTAssertEqual(session.selectedCount, 0)
        XCTAssertEqual(importTitle(session), "Import 0 Workouts")
        XCTAssertFalse(AppleHealthReviewPresentation.canImport(selectedCount: session.selectedCount))

        session.tableSelection = ["flagged-0"]
        session.toggleImportForTableSelection()
        XCTAssertEqual(session.selectedIDs, ["flagged-0"])
        XCTAssertEqual(importTitle(session), "Import 1 Workout")
        XCTAssertTrue(AppleHealthReviewPresentation.canImport(selectedCount: session.selectedCount))

        session.toggleImportForTableSelection()
        XCTAssertEqual(session.selectedCount, 0)
        XCTAssertFalse(AppleHealthReviewPresentation.canImport(selectedCount: session.selectedCount))
    }

    /// A checked ready row and an unchecked flagged one: the first press checks
    /// both, the second unchecks both.
    func testAMixedSelectionOfReadyAndFlaggedRows() {
        let session = makeSession(readyCount: 1, flaggedCount: 1)
        session.tableSelection = ["ready-0", "flagged-0"]

        session.toggleImportForTableSelection()
        XCTAssertEqual(session.selectedIDs, ["ready-0", "flagged-0"])
        XCTAssertEqual(importTitle(session), "Import 2 Workouts")

        session.toggleImportForTableSelection()
        XCTAssertEqual(session.selectedIDs, [])
        XCTAssertEqual(importTitle(session), "Import 0 Workouts")
    }

    /// A row hidden by "Flagged only" keeps its checkbox even if it stayed
    /// selected; with only hidden rows selected, Space toggles nothing.
    func testARowTheTableHidesIsNotToggled() {
        let session = makeSession(readyCount: 1, flaggedCount: 1)
        session.flaggedOnly = true
        session.tableSelection = ["ready-0", "flagged-0"]

        XCTAssertTrue(session.toggleImportForTableSelection())
        XCTAssertEqual(session.selectedIDs, ["ready-0", "flagged-0"])

        session.tableSelection = ["ready-0"]
        XCTAssertFalse(session.toggleImportForTableSelection())
        XCTAssertEqual(session.selectedIDs, ["ready-0", "flagged-0"])
    }

    func testNoTableSelectionTogglesNothing() {
        let session = makeSession(readyCount: 2)
        XCTAssertFalse(session.toggleImportForTableSelection())
        XCTAssertEqual(session.selectedCount, 2)
    }

    // MARK: - Fixtures

    private func importTitle(_ session: AppleHealthImportSession) -> String {
        AppleHealthReviewPresentation.importButtonTitle(selectedCount: session.selectedCount)
    }

    /// Ready rows start checked, flagged rows unchecked, as in a real review.
    private func makeSession(readyCount: Int, flaggedCount: Int = 0) -> AppleHealthImportSession {
        func candidate(_ id: String, _ index: Int, flagged: Bool) -> AppleHealthWorkoutCandidate {
            let start = Int64(1_700_000_000 + index * 86_400)
            return AppleHealthWorkoutCandidate(
                id: id,
                sourceIndex: index,
                window: AppleHealthWorkoutWindow(
                    startSeconds: start,
                    endSeconds: start + 1_800,
                    activityType: "HKWorkoutActivityTypeRunning",
                    utcOffsetSeconds: 0
                ),
                status: flagged ? .duplicate : .ready,
                duplicateOrigin: flagged ? .existingLibrary : nil
            )
        }
        let candidates = (0..<readyCount).map { candidate("ready-\($0)", $0, flagged: false) }
            + (0..<flaggedCount).map { candidate("flagged-\($0)", readyCount + $0, flagged: true) }
        let result = AppleHealthArchiveScanResult(
            scan: AppleHealthExportScan(
                workouts: candidates.map {
                    AppleHealthExportScan.WorkoutEntry(
                        window: $0.window, statistics: [], routeArchivePath: nil, heartRate: []
                    )
                },
                droppedWorkoutCount: 0
            ),
            candidates: candidates,
            exportXMLEntryPath: "apple_health_export/export.xml",
            usedCaseInsensitiveXMLLookup: false,
            report: AppleHealthArchiveReport(
                workoutCount: candidates.count,
                candidateCount: candidates.count,
                duplicateCandidateCount: flaggedCount,
                droppedWorkoutCount: 0,
                unmatchedRouteReferenceCount: 0,
                routeEntryCount: 0,
                entryCount: 1,
                uncompressedXMLBytes: 0
            )
        )
        return AppleHealthImportSession(
            archiveURL: FileManager.default.temporaryDirectory.appendingPathComponent("export.zip"),
            scanResult: result,
            securityScoped: false
        )
    }
}
