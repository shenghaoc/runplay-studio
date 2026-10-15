import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Text measurement and drawing shared by the workout and comparison video
/// renderers.
///
/// Every string is tagged with the export's language
/// (`kCTLanguageAttributeName`). Han characters shared by Simplified Chinese,
/// Traditional Chinese, and Japanese take a different fallback font per
/// language, and without the tag CoreText picks whichever the process's
/// preferred languages favour. Lines wider than their slot end in an ellipsis
/// rather than being clipped mid-glyph, and label columns are measured with the
/// real font instead of assuming Latin glyph widths.
enum VideoHUDText {
    /// BCP 47 language tag CoreText uses to choose CJK fallback fonts
    /// ("zh-Hant-TW", "zh-Hans-CN", "en-Latn-US").
    static func languageTag(for locale: Locale?) -> String {
        (locale ?? .current).language.maximalIdentifier
    }

    static func attributed(
        _ string: String,
        font: NSFont,
        color: NSColor,
        language: String
    ) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            NSAttributedString.Key(kCTLanguageAttributeName as String): language,
        ])
    }

    /// Typographic advance width of `string` in `font`.
    static func width(_ string: String, font: NSFont, language: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            attributed(string, font: font, color: .black, language: language)
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// A line no wider than `maxWidth`, truncated at the end with "…" when needed.
    static func fittedLine(
        _ string: String,
        font: NSFont,
        color: NSColor,
        language: String,
        maxWidth: CGFloat
    ) -> CTLine {
        let line = CTLineCreateWithAttributedString(
            attributed(string, font: font, color: color, language: language)
        )
        guard CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth, maxWidth > 0 else {
            return line
        }
        let ellipsis = CTLineCreateWithAttributedString(
            attributed("…", font: font, color: color, language: language)
        )
        return CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
    }

    static func draw(
        _ string: String,
        font: NSFont,
        color: NSColor,
        language: String,
        at origin: CGPoint,
        maxWidth: CGFloat,
        in context: CGContext
    ) {
        let line = fittedLine(string, font: font, color: color, language: language, maxWidth: maxWidth)
        context.saveGState()
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Horizontal layout of a panel of label/value rows.
    struct RowColumns: Equatable {
        /// Offset of the value column from the panel's leading edge.
        let valueOffset: CGFloat
        /// Panel width that fits the widest label and value.
        let panelWidth: CGFloat
        /// Space left for a value after the value offset and trailing inset.
        var valueWidth: CGFloat { max(0, panelWidth - valueOffset - inset) }
        let inset: CGFloat
    }

    /// Measures rows so the value column starts after the widest label, never
    /// earlier than `minimumValueOffset` (the original Latin layout), and the
    /// panel grows to the widest value up to `maximumPanelWidth`.
    static func rowColumns(
        labels: [String],
        values: [String],
        labelFont: NSFont,
        valueFont: NSFont,
        language: String,
        inset: CGFloat,
        gap: CGFloat,
        minimumValueOffset: CGFloat,
        minimumPanelWidth: CGFloat,
        maximumPanelWidth: CGFloat
    ) -> RowColumns {
        let labelWidth = labels.map { width($0, font: labelFont, language: language) }.max() ?? 0
        let valueWidth = values.map { width($0, font: valueFont, language: language) }.max() ?? 0
        let ceiling = max(minimumPanelWidth, maximumPanelWidth)
        // A label column may take at most half the panel; a longer label is
        // truncated rather than pushing every value off the panel.
        let valueOffset = min(
            max(minimumValueOffset, (inset + labelWidth + gap).rounded(.up)),
            ceiling / 2
        )
        let panelWidth = min(
            max(minimumPanelWidth, (valueOffset + valueWidth + inset).rounded(.up)),
            ceiling
        )
        return RowColumns(valueOffset: valueOffset, panelWidth: panelWidth, inset: inset)
    }
}
