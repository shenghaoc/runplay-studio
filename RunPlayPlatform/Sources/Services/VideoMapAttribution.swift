import AppKit
import CoreGraphics
import CoreText
import Foundation
import RunPlayCore

/// The Apple Maps credit on every Route Replay and Comparison Replay frame and
/// poster.
///
/// Both videos composite an `MKMapSnapshotter` basemap, and on macOS the
/// snapshot image carries no Apple Maps logo or legal text, so the renderers
/// draw the credit themselves. The wording matches the map-inclusive PNG
/// card's footer (`ExportSummaryCardModel.mapInclusivePrivacyNote`).
///
/// The badge never changes during an export, so it is rasterized once per
/// appearance and only composited per frame, the way the prepared basemap is.
/// Its sizes are output pixels, like the rest of the HUD: the same badge
/// serves the 1920×1080 video and the 960×540 poster.
enum VideoMapAttribution {
    static let text = "Map imagery via Apple Maps"

    static let fontSize: CGFloat = 13
    static let badgeHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 10

    /// Inset from the frame's right edge; the HUD's outer margin.
    static let margin: CGFloat = 28

    /// Baseline of the credit text, shared with the progress caption so the two
    /// read as one footer row, below the progress bar.
    static let baselineY: CGFloat = 28

    /// Minimum space between the end of the progress caption and the badge.
    static let captionGap: CGFloat = 16

    /// Badge background and text colours. The background is the HUD panel
    /// colour; the text is the HUD's secondary text colour.
    struct Colors {
        let background: NSColor
        let text: NSColor

        init(appearance: PNGSummaryExportAppearance) {
            switch appearance {
            case .light:
                background = NSColor(calibratedWhite: 1.0, alpha: 0.88)
                text = NSColor(calibratedWhite: 0.28, alpha: 1)
            case .dark:
                background = NSColor(calibratedWhite: 0.12, alpha: 0.88)
                text = NSColor(calibratedWhite: 0.72, alpha: 1)
            }
        }
    }

    /// The rasterized badge for `appearance`. Throws when Core Graphics could
    /// not allocate it, so a frame fails rather than ship map imagery uncredited.
    static func badge(for appearance: PNGSummaryExportAppearance) throws -> CGImage {
        let badge: CGImage?
        switch appearance {
        case .light: badge = lightBadge
        case .dark: badge = darkBadge
        }
        guard let badge else {
            throw WorkoutVideoExportError.frameRenderingFailed(
                "Could not prepare the Apple Maps attribution"
            )
        }
        return badge
    }

    /// Where `badge` sits in a frame of `bounds` (bottom-left origin): flush
    /// with the HUD's right margin, its text on the progress caption's
    /// baseline. Whole pixels, so compositing copies the badge unscaled.
    static func frame(for badge: CGImage, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.maxX - margin - CGFloat(badge.width),
            y: bounds.minY + baselineY - textBaselineOffset,
            width: CGFloat(badge.width),
            height: CGFloat(badge.height)
        )
    }

    /// Widest the progress caption may draw, starting at the HUD margin, so it
    /// always ends `captionGap` before the badge.
    static func captionMaxWidth(besideBadgeFrame badgeFrame: CGRect, in bounds: CGRect) -> CGFloat {
        max(0, badgeFrame.minX - captionGap - (bounds.minX + margin))
    }

    // MARK: - Rasterization

    private static let lightBadge = render(appearance: .light)
    private static let darkBadge = render(appearance: .dark)

    /// Text baseline height inside the badge: centres the capital letters.
    private static let textBaselineOffset = ((badgeHeight - makeFont().capHeight) / 2).rounded()

    private static func makeFont() -> NSFont {
        NSFont.systemFont(ofSize: fontSize, weight: .medium)
    }

    private static func render(appearance: PNGSummaryExportAppearance) -> CGImage? {
        let colors = Colors(appearance: appearance)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: makeFont(), .foregroundColor: colors.text]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let width = Int((textWidth + horizontalPadding * 2).rounded(.up))
        let height = Int(badgeHeight)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                      | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = badgeHeight / 2
        context.addPath(CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(colors.background.cgColor)
        context.fillPath()

        context.textPosition = CGPoint(x: horizontalPadding, y: textBaselineOffset)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
