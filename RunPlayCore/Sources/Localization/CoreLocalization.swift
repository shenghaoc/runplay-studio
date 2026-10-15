import Foundation

// Core's user-facing strings resolve from Core's own String Catalog
// (`RunPlayCore/Localization/Localizable.xcstrings`), never from the host's
// main bundle, so tests and the app read the same tables.
//
// Keys are the English source text. Interpolate only `String` and integer
// values: a `Double` becomes `%lf`, which prints six decimals. Format numbers
// and measurements first (`DisplayFormatter`), then interpolate the text.
// Interpolated integers carry plural variants in the catalog, so write the
// plural English form (`"\(count) runs"`) and let the catalog supply "1 run".
//
// Swift Foundation on Linux has neither `String.LocalizationValue` nor
// `String(localized:)`, and the catalog is a macOS-only resource (see
// Package.swift). There every key resolves to its own English text, which is
// the plural ("other") form for count-bearing keys.

#if canImport(Darwin)
/// Resolves a Core string in the app's language, or in `locale`'s language
/// when one is given (exports and tests that pin a language).
///
/// An explicit locale also formats interpolated integers in that locale. The
/// explicit path costs tens of microseconds per call, so per-frame and
/// per-row callers resolve once and reuse the text.
func coreLocalized(_ keyAndValue: String.LocalizationValue, locale: Locale? = nil) -> String {
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

/// Core's resource bundle. Tests read its compiled tables directly.
enum CoreLocalization {
    static var bundle: Bundle { .module }
}
#else
func coreLocalized(_ keyAndValue: String, locale: Locale? = nil) -> String {
    keyAndValue
}
#endif
