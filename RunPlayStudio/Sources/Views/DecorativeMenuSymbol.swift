import AppKit
import SwiftUI

/// Icon for the label of a `Menu` whose accessibility label differs from its
/// visible title.
///
/// A macOS `Menu` is backed by an AppKit menu button. When the view carries
/// its own `accessibilityLabel`, AppKit fills the button's AXDescription from
/// the label image's `accessibilityDescription`, and for an SF Symbol with
/// none it synthesises one from the symbol name ("Downward point at the
/// top-left corner of …"). VoiceOver's focus announcement skips it, but the
/// Item Chooser (VO+I) reads it after the label. SwiftUI modifiers on the
/// `Image` — `accessibilityHidden(true)`, `accessibilityLabel` — never reach
/// that AppKit image, and an empty description counts as none, so the symbol
/// is built as an `NSImage` with a blank description instead. Menus without
/// an accessibility label override do not leak and do not need this.
enum DecorativeMenuSymbol {
    /// Non-empty so AppKit keeps it, but with nothing for VoiceOver to speak.
    static let blankAccessibilityDescription = " "

    static func nsImage(systemName: String) -> NSImage? {
        NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: blankAccessibilityDescription
        )
    }

    static func image(systemName: String) -> Image {
        guard let image = nsImage(systemName: systemName) else {
            return Image(systemName: systemName)
        }
        return Image(nsImage: image)
    }
}
