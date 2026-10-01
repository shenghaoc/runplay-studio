import AppKit
import RunPlayCore

/// Font-measured column bounds shared by the sheet and the native table.
@MainActor
struct AppleHealthReviewColumnLayout {
    enum Column: String, CaseIterable {
        case selection = "Import", date = "Date", type = "Type"
        case duration = "Duration", distance = "Distance"
        case route = "Route", heartRate = "HR", flag = "Flag"
    }

    struct Width {
        let minimum: CGFloat
        let ideal: CGFloat
    }

    private let widths: [Column: Width]
    // Native inset table margins and inter-column gutters have their own budget,
    // separate from the padding inside each measured cell.
    private let chromeWidth = 2 * AppDesign.Spacing.large
        + CGFloat(Column.allCases.count - 1) * AppDesign.Spacing.small

    init(candidates: [AppleHealthWorkoutCandidate], fontSize: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let headingFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let cellPadding = 2 * AppDesign.Spacing.small
        func measure(_ text: String, font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        var bounds: [Column: Width] = [:]
        for column in Column.allCases {
            var minimum = measure(column.rawValue, font: headingFont)
            if column == .flag {
                // Reserve a readable status, not space for an unbounded reason.
                minimum = max(minimum, measure("Possible duplicate", font: font))
            } else {
                for candidate in candidates {
                    let text: String
                    switch column {
                    case .date: text = AppleHealthReviewPresentation.dateText(candidate.window)
                    case .type: text = AppleHealthReviewPresentation.activityName(candidate.window.activityType)
                    case .duration: text = AppleHealthReviewPresentation.durationText(candidate.window)
                    case .distance: text = AppleHealthReviewPresentation.distanceText(candidate)
                    case .selection, .route, .heartRate: text = "✓"
                    case .flag: text = ""
                    }
                    let valueFont = column == .duration || column == .distance ? numberFont : font
                    minimum = max(minimum, measure(text, font: valueFont))
                }
            }
            minimum += cellPadding
            bounds[column] = Width(minimum: minimum, ideal: minimum + fontSize)
        }
        widths = bounds
    }

    subscript(column: Column) -> Width { widths[column]! }

    var minimumSheetWidth: CGFloat {
        Column.allCases.reduce(chromeWidth) { $0 + self[$1].minimum }
    }

    /// Fixed columns get at most their ideal. Flag receives everything left.
    /// At the sheet minimum every fixed column uses exactly its minimum, so
    /// native preferred widths cannot push the final column off the sheet.
    func width(_ column: Column, availableWidth: CGFloat) -> CGFloat {
        let surplus = max(0, availableWidth - minimumSheetWidth)
        let fixedColumns = Column.allCases.filter { $0 != .flag }
        func fixedWidth(_ column: Column) -> CGFloat {
            min(self[column].ideal, self[column].minimum + surplus / CGFloat(fixedColumns.count))
        }
        if column == .flag {
            return max(self[.flag].minimum,
                       availableWidth - chromeWidth - fixedColumns.reduce(0) { $0 + fixedWidth($1) })
        }
        return fixedWidth(column)
    }
}
