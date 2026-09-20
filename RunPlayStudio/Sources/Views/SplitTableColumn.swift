import Foundation

/// The columns the distance-splits table can render, in display order.
///
/// Extracted from `DistanceSplitsTableView` so the question "which columns
/// does this workout's splits table show?" is answerable — and testable —
/// without driving the GUI.
///
/// History worth keeping: Power and Elapsed Pace were once mutually
/// exclusive, because `TableColumnBuilder` accepts at most ten *direct*
/// children and the table already had ten. That is a result-builder limit,
/// not a `Table` limit, and wrapping columns in `Group` lifts it. Power is
/// now additive — it never displaces a column the user relies on.
enum SplitTableColumn: String, CaseIterable, Sendable {
    case split
    case distance
    case elapsed
    case active
    case moving
    case movingPace
    case activePace
    case elapsedPace
    case power
    case heartRate
    case elevation

    /// Columns shown for a workout, in display order.
    ///
    /// Power is the only conditional column: it appears when the workout
    /// carries power data and is omitted otherwise, so the table never shows
    /// a permanently empty column. Every other column is always present.
    static func visibleColumns(showsPower: Bool) -> [SplitTableColumn] {
        allCases.filter { $0 != .power || showsPower }
    }

    /// UserDefaults key for the user's saved show/hide and ordering choice.
    /// The raw values above are the stable customization IDs stored inside
    /// it, so renaming a case would orphan a saved layout — add cases, do
    /// not rename them.
    static let customizationDefaultsKey = "splitTable.columnCustomization"
}
