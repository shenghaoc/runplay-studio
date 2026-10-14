import AppKit
import Foundation
import RunPlayCore

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

/// The widths the distance-splits table's columns start at, sized to what they
/// show: each column is as wide as its header or its widest cell, in the active
/// language.
///
/// A `Table` keeps the widths it is given at first layout, so fixed widths picked
/// for English headers ("Moving Pace (est.)") clipped the table at the pane's
/// right edge at the default window width, and any longer translation would too.
/// Measuring the strings the table will draw makes the table as wide as it needs
/// to be and no wider; at narrower windows it still scrolls, as before.
struct SplitTableColumnWidths: Equatable {
    private let widths: [SplitTableColumn: CGFloat]

    func width(_ column: SplitTableColumn) -> CGFloat {
        widths[column] ?? Self.minimumWidth
    }

    /// Narrowest a column is drawn: the Split column's marker and number.
    static let minimumWidth: CGFloat = 50

    /// Room the header cell and a value cell keep around their text. The header
    /// font is the table's 13 pt system font: the widths this table used to be
    /// given for English headers match that font's text widths ("Moving Pace
    /// (est.)" is 113 pt, in a 115 pt column).
    static let headerPadding: CGFloat = 8
    static let cellPadding: CGFloat = 6

    static var headerFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
    static var cellFont: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }

    /// The title a column shows, resolved the way the table resolves it.
    static func title(of column: SplitTableColumn, locale: Locale? = nil) -> String {
        switch column {
        case .split: return studioLocalized("Split", locale: locale)
        case .distance: return studioLocalized("Distance", locale: locale)
        case .elapsed: return studioLocalized("Elapsed", locale: locale)
        case .active: return studioLocalized("Active", locale: locale)
        case .moving: return studioLocalized("Moving (est.)", locale: locale)
        case .movingPace: return studioLocalized("Moving Pace (est.)", locale: locale)
        case .activePace: return studioLocalized("Active Pace", locale: locale)
        case .elapsedPace: return studioLocalized("Elapsed Pace", locale: locale)
        case .power: return studioLocalized("Power", locale: locale)
        case .heartRate: return studioLocalized("HR", locale: locale)
        case .elevation: return studioLocalized("Elev", locale: locale)
        }
    }

    /// What a column draws for one split, as text.
    static func cellText(_ column: SplitTableColumn, for split: RunSplit, locale: Locale? = nil) -> String {
        switch column {
        case .split: return "\(split.splitIndex)"
        case .distance: return DisplayFormatter.formatDistanceKm(split.distanceMeters, locale: locale)
        case .elapsed: return split.formattedElapsed
        case .active: return split.formattedActive
        case .moving: return split.formattedMoving
        case .movingPace: return split.formattedMovingPace
        case .activePace: return split.formattedPace
        case .elapsedPace: return split.formattedElapsedPace
        case .power: return split.averagePowerWatts.map { DisplayFormatter.formatPower($0, locale: locale) } ?? "—"
        case .heartRate: return split.averageHeartRateBPM.map { DisplayFormatter.formatHeartRate(Double(Int($0)), locale: locale) } ?? "—"
        case .elevation: return split.elevationGainMeters.map { DisplayFormatter.formatMeters($0, signed: true, locale: locale) } ?? "—"
        }
    }

    static func measure(
        splits: [RunSplit], columns: [SplitTableColumn], locale: Locale? = nil
    ) -> SplitTableColumnWidths {
        var widths: [SplitTableColumn: CGFloat] = [:]
        for column in columns {
            let header = TextMeasure.width(of: title(of: column, locale: locale), font: headerFont) + headerPadding
            let cells = TextMeasure.widest(of: splits.map { cellText(column, for: $0, locale: locale) }, font: cellFont) + cellPadding
            widths[column] = max(minimumWidth, header, cells)
        }
        return SplitTableColumnWidths(widths: widths)
    }

    /// Width a `Table` of `columnCount` inset-style columns needs at these
    /// widths: the columns, 17 pt between neighbours, and 16 pt at each edge
    /// (measured from `NSTableView` on macOS 27; see `FITSessionTableColumn`).
    func tableWidth(columns: [SplitTableColumn]) -> CGFloat {
        columns.reduce(0) { $0 + width($1) } + 17 * CGFloat(max(columns.count - 1, 0)) + 32
    }
}
