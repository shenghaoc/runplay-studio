import Foundation

// Platform's user-facing strings resolve from Platform's own String Catalog
// (`RunPlayPlatform/Localization/Localizable.xcstrings`). Same rules as
// `coreLocalized`: English source text as the key, interpolate only `String`
// and integer values, and write the plural English form for counts.

/// Resolves a Platform string in the app's language, or in `locale`'s
/// language when one is given (exports and tests that pin a language).
///
/// The explicit-locale path costs tens of microseconds per call; per-frame
/// renderers resolve their labels once per export.
func platformLocalized(_ keyAndValue: String.LocalizationValue, locale: Locale? = nil) -> String {
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

/// Platform's resource bundle. Tests read its compiled tables directly.
enum PlatformLocalization {
    static var bundle: Bundle { .module }
}
