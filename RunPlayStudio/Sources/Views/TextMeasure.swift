import AppKit

/// Width of a string in a font, for sizing a column or control to what it shows
/// instead of to a number picked for English.
///
/// Used where SwiftUI cannot size to content by itself: a `Table` column keeps
/// the width it is given at first layout, so a width chosen for "Sep 28" clips
/// "2026年6月25日 下午3:49".
enum TextMeasure {
    /// Typographic width of `string` in `font`, rounded up to a whole point.
    static func width(of string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The widest of `strings`.
    static func widest(of strings: [String], font: NSFont) -> CGFloat {
        strings.map { width(of: $0, font: font) }.max() ?? 0
    }

    /// Width a table column needs for its header and its widest cell, with room
    /// for an `accessory` (an icon and its spacing) drawn beside the cell text.
    static func columnWidth(
        header: String, cells: [String], accessory: CGFloat = 0, minimum: CGFloat = 30
    ) -> CGFloat {
        let headerWidth = width(of: header, font: SplitTableColumnWidths.headerFont) + SplitTableColumnWidths.headerPadding
        let cellWidth = widest(of: cells, font: SplitTableColumnWidths.cellFont) + accessory + SplitTableColumnWidths.cellPadding
        return max(minimum, headerWidth, cellWidth)
    }
}
