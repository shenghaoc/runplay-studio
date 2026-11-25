import Foundation

// Studio's strings live in `RunPlayStudio/Localization/Localizable.xcstrings`.
//
// Studio is the app target of RunPlayStudio.xcodeproj, so Xcode compiles this
// catalog into the app's main bundle (`Contents/Resources/<language>.lproj`).
// SwiftUI literals (`Text("Overview")`, `Button("Export")`, `.help("…")`)
// resolve against the main bundle. Strings built in Swift go through
// `studioLocalized`, which reads the main bundle too and therefore resolves
// identically in the app and in its tests, which the app hosts.
//
// Same rules as `coreLocalized`: English source text as the key, interpolate
// only `String` and integer values, and write the plural English form for
// counts (`"\(count) runs"`); the catalog carries the "1 run" variant.

/// Resolves a Studio string in the app's language, or in `locale`'s language
/// when one is given (the PNG summary card and tests that pin a language).
///
/// The explicit-locale path costs tens of microseconds per call; render
/// paths resolve once and reuse the text.
func studioLocalized(_ keyAndValue: String.LocalizationValue, locale: Locale? = nil) -> String {
    guard let locale else {
        return String(localized: keyAndValue, bundle: .main)
    }
    return String(
        localized: LocalizedStringResource(
            keyAndValue,
            locale: locale,
            bundle: .atURL(Bundle.main.bundleURL)
        )
    )
}

/// Studio's resource bundle. Tests read its compiled tables directly.
enum StudioLocalization {
    static var bundle: Bundle { .main }
}
