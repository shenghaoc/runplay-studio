import CoreGraphics

/// The columns of the multi-session FIT review table, in display order, and
/// the widths they start at.
///
/// Extracted from `FITSessionImportView` so the sheet's minimum width follows
/// from its columns instead of being declared separately, and so the
/// arithmetic is testable without driving the GUI. A separately declared
/// 940 pt sheet once held columns that needed 996 pt, and the Status column
/// was clipped at the sheet's edge.
enum FITSessionTableColumn: CaseIterable, Sendable {
    case include
    case session
    case date
    case sport
    case elapsed
    case distance
    case gpsPoints
    case laps
    case status

    /// Width the column starts at, in points.
    var idealWidth: CGFloat {
        switch self {
        case .include: return 58
        case .session: return 172
        // The widest en_US, zh_CN and zh_TW dates on one line, such as
        // "Sep 28, 2021 at 10:03 AM" and "2021年12月28日 上午10:03".
        case .date: return 142
        // The longest word in a sport name ("paddleboarding"), so a name
        // that needs two lines wraps between words.
        case .sport: return 98
        case .elapsed: return 62
        case .distance: return 66
        case .gpsPoints: return 68
        case .laps: return 46
        // "Unsupported sport" on one line; longer statuses wrap.
        case .status: return 120
        }
    }

    /// Narrowest width the user can drag the column to, or `nil` for a
    /// fixed-width column.
    var minimumWidth: CGFloat? {
        switch self {
        case .include, .laps: return nil
        case .session: return 150
        case .date: return 105
        case .sport: return 70
        case .elapsed: return 58
        case .distance: return 60
        case .gpsPoints: return 60
        case .status: return 100
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
