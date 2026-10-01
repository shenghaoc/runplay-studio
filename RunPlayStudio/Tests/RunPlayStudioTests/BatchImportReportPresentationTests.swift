import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// What the Strava archive and multi-session FIT report sheets say about a
/// finished pass, with a cancelled pass as the case that matters: it must read
/// as cancelled, say nothing was saved, and never call a rolled-back session
/// imported.
final class BatchImportReportPresentationTests: XCTestCase {

    private func stagedSession(status: FITSessionCandidateStatus = .ready) -> FITSessionImportItemResult {
        FITSessionImportItemResult(
            candidateID: "session-0",
            sourceIndex: 0,
            sessionName: "Morning run",
            status: status,
            importedWorkoutID: status == .ready ? UUID() : nil
        )
    }

    // MARK: - Notice

    func testTheCancelledNoticeSaysNothingWasSaved() {
        XCTAssertTrue(BatchImportReportPresentation.cancelledNotice.contains("Nothing was saved"))
        XCTAssertTrue(BatchImportReportPresentation.cancelledNotice.contains("unchanged"))
    }

    // MARK: - Strava archive

    func testACancelledArchiveReportIsTitledCancelledAndStatesNothingWasSaved() {
        let report = WorkoutBatchImportReport(wasCancelled: true)

        XCTAssertEqual(BatchImportReportPresentation.archiveTitle(for: report), "Import Cancelled")
        XCTAssertEqual(
            BatchImportReportPresentation.archiveNotice(for: report),
            BatchImportReportPresentation.cancelledNotice
        )
    }

    func testAnArchiveReportKeepsItsOtherTitlesAndCarriesNoCancelNotice() {
        let completed = WorkoutBatchImportReport(importedWorkoutIDs: [UUID()])
        XCTAssertEqual(BatchImportReportPresentation.archiveTitle(for: completed), "Import Complete")
        XCTAssertNil(BatchImportReportPresentation.archiveNotice(for: completed))

        let failed = WorkoutBatchImportReport(commitFailed: true, errorMessage: "disk full")
        XCTAssertEqual(BatchImportReportPresentation.archiveTitle(for: failed), "Import Incomplete")
        XCTAssertNil(BatchImportReportPresentation.archiveNotice(for: failed))
    }

    // MARK: - Multi-session FIT

    func testACancelledFITReportIsTitledCancelledAndStatesNothingWasSaved() {
        let report = FITSessionBatchImportReport(wasCancelled: true)

        XCTAssertEqual(BatchImportReportPresentation.fitTitle(for: report), "Import Cancelled")
        XCTAssertEqual(
            BatchImportReportPresentation.fitNotice(for: report),
            BatchImportReportPresentation.cancelledNotice
        )
    }

    func testAFITReportKeepsItsOtherTitlesAndCarriesNoCancelNotice() {
        let completed = FITSessionBatchImportReport(importedWorkoutIDs: [UUID()])
        XCTAssertEqual(BatchImportReportPresentation.fitTitle(for: completed), "Import Complete")
        XCTAssertNil(BatchImportReportPresentation.fitNotice(for: completed))

        let failed = FITSessionBatchImportReport(commitFailed: true, errorMessage: "disk full")
        XCTAssertEqual(BatchImportReportPresentation.fitTitle(for: failed), "Import Failed")
        XCTAssertNil(BatchImportReportPresentation.fitNotice(for: failed))
    }

    func testACancelledFITReportNeverCallsARolledBackSessionImported() {
        let item = stagedSession()

        let committed = FITSessionBatchImportReport(items: [item], importedWorkoutIDs: [UUID()])
        XCTAssertEqual(BatchImportReportPresentation.fitItemLabel(item, in: committed), "Imported")

        let cancelled = FITSessionBatchImportReport(items: [item], wasCancelled: true)
        XCTAssertEqual(BatchImportReportPresentation.fitItemLabel(item, in: cancelled), "Not saved")

        let failed = FITSessionBatchImportReport(items: [item], commitFailed: true)
        XCTAssertEqual(BatchImportReportPresentation.fitItemLabel(item, in: failed), "Not saved")
    }

    func testAFITRowThatWasNeverStagedKeepsItsOwnReasonInACancelledReport() {
        let duplicate = stagedSession(status: .duplicate)
        let cancelled = FITSessionBatchImportReport(items: [duplicate], wasCancelled: true)

        XCTAssertEqual(
            BatchImportReportPresentation.fitItemLabel(duplicate, in: cancelled),
            FITSessionCandidateStatus.duplicate.userFacingSummary
        )
    }
}
