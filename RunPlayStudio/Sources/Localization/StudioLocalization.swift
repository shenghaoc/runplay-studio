import Foundation

// Studio's strings live in `RunPlayStudio/Localization/Localizable.xcstrings`.
//
// SwiftUI literals (`Text("Overview")`, `Button("Export")`, `.help("…")`)
// resolve against the main bundle, so the packaged app carries this catalog's
// compiled tables in `Contents/Resources/<language>.lproj` as well as in the
// module bundle (scripts/assemble-app-bundle.sh). Strings built in Swift go
// through `studioLocalized`, which reads the module bundle and therefore
// resolves identically in the app, in `swift run`, and in tests.
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
        return String(localized: keyAndValue, bundle: .module)
    }
    return String(
        localized: LocalizedStringResource(
            keyAndValue,
            locale: locale,
            bundle: .atURL(Bundle.module.bundleURL)
        )
    )
}

/// Studio's resource bundle. Tests read its compiled tables directly.
enum StudioLocalization {
    static var bundle: Bundle { .module }
}
