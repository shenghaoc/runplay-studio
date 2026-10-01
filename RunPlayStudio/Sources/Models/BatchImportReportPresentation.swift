import Foundation
import RunPlayCore

/// What the Strava archive and multi-session FIT report sheets say about a
/// finished pass.
///
/// The sheets lay out these values; they do not derive them, so the wording of a
/// cancelled import can be tested without a window. The Apple Health sheet keeps
/// its own presentation (`AppleHealthImportSummary`) and shares only the
/// cancelled notice, so the three sheets state a cancel in the same words.
enum BatchImportReportPresentation {

    /// What a cancelled pass guarantees. The batch seam rolls back everything a
    /// cancelled pass staged, so this holds however far the pass had got.
    static let cancelledNotice = "Nothing was saved. Your library was left unchanged."

    // MARK: - Strava archive

    static func archiveTitle(for report: WorkoutBatchImportReport) -> String {
        if report.commitFailed { return "Import Incomplete" }
        if report.wasCancelled { return "Import Cancelled" }
        return "Import Complete"
    }

    static func archiveNotice(for report: WorkoutBatchImportReport) -> String? {
        notice(wasCancelled: report.wasCancelled, commitFailed: report.commitFailed)
    }

    // MARK: - Multi-session FIT

    static func fitTitle(for report: FITSessionBatchImportReport) -> String {
        if report.commitFailed { return "Import Failed" }
        if report.wasCancelled { return "Import Cancelled" }
        return "Import Complete"
    }

    static func fitNotice(for report: FITSessionBatchImportReport) -> String? {
        notice(wasCancelled: report.wasCancelled, commitFailed: report.commitFailed)
    }

    /// The label for one session row of a FIT report.
    ///
    /// A session that staged cleanly is only "Imported" when the pass committed.
    /// A cancelled pass rolled it back exactly as a failed commit does, so the
    /// row reads "Not saved", never "Imported".
    static func fitItemLabel(
        _ item: FITSessionImportItemResult,
        in report: FITSessionBatchImportReport
    ) -> String {
        item.reportLabel(commitFailed: fitStagedSessionsWereRolledBack(in: report))
    }

    /// Whether the pass left its staged sessions unsaved. A failed commit and a
    /// cancel both roll them back, so neither may describe a session as
    /// imported: the row label and the elevation detail under it both ask this.
    static func fitStagedSessionsWereRolledBack(in report: FITSessionBatchImportReport) -> Bool {
        report.commitFailed || report.wasCancelled
    }

    // MARK: - Shared

    /// A failed commit is the louder outcome, so it is never softened by a
    /// cancel notice.
    private static func notice(wasCancelled: Bool, commitFailed: Bool) -> String? {
        wasCancelled && !commitFailed ? cancelledNotice : nil
    }
}
