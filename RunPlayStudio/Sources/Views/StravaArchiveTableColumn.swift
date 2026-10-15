import CoreGraphics

/// The columns of the Strava archive review table, in display order, and the
/// widths they start at.
///
/// Extracted from `StravaArchiveImportView` so the sheet's minimum width
/// follows from its columns instead of being declared separately, and so the
/// arithmetic is testable without driving the GUI. A separately declared
/// 720 pt sheet once held columns that needed 843 pt, and the Status column
/// was clipped at the sheet's edge.
enum StravaArchiveTableColumn: CaseIterable, Sendable {
    /// The "Import" checkbox.
    case selection
    case date
    case name
    case type
    case format
    case status

    /// Width the column starts at, in points.
    var idealWidth: CGFloat {
        switch self {
        case .selection: return 56
        // The widest en_US, zh_CN and zh_TW dates on one line, such as
        // "May 28, 2021" and "2021年10月28日".
        case .date: return 90
        case .name: return 220
        case .type: return 100
        // "Unsupported", the widest format name.
        case .format: return 84
        // "Unsupported activity type" on one line; longer statuses wrap.
        case .status: return 160
        }
    }

    /// Narrowest width the user can drag the column to, or `nil` for a
    /// fixed-width column.
    var minimumWidth: CGFloat? {
        switch self {
        case .selection, .format: return nil
        case .date: return 70
        case .name: return 140
        case .type: return 80
        case .status: return 120
        }
    }

    /// Width an inset-style table adds around its columns: 17 pt between
    /// neighbouring columns, and 16 pt at each outer edge (a 10 pt inset plus
    /// 6 pt of cell padding). Measured from `NSTableView` on macOS 27.
    static func chromeWidth(columnCount: Int) -> CGFloat {
        17 * CGFloat(max(columnCount - 1, 0)) + 2 * 16
    }

    /// Width the table needs to show every column at its ideal width. The
    /// table spans the review sheet edge to edge, so this is also the sheet's
    /// minimum width.
    static var idealTableWidth: CGFloat {
        allCases.reduce(0) { $0 + $1.idealWidth } + chromeWidth(columnCount: allCases.count)
    }
}
