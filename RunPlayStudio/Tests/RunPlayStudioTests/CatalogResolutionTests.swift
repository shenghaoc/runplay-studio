import Foundation
import XCTest
@testable import RunPlayCore
@testable import RunPlayPlatform
@testable import RunPlayStudio

/// Every String Catalog key resolves in every shipped language through the
/// compiled tables the app actually reads.
///
/// `scripts/check-localization.sh` proves the catalogs are complete; this
/// proves the build turned them into tables Foundation resolves: each module's
/// resource bundle has an `.lproj` per language, and looking a key up there
/// returns the catalog's translation instead of falling back to the key.
final class CatalogResolutionTests: XCTestCase {
    private struct Module {
        let name: String
        let bundle: Bundle
    }

    private var modules: [Module] {
        [
            Module(name: "RunPlayCore", bundle: CoreLocalization.bundle),
            Module(name: "RunPlayPlatform", bundle: PlatformLocalization.bundle),
            Module(name: "RunPlayStudio", bundle: StudioLocalization.bundle),
        ]
    }

    private static let translatedLanguages = ["zh-Hans", "zh-Hant"]
    private static let missing = "\u{1}missing\u{1}"

    func testEveryKeyResolvesInEveryChineseLocalization() throws {
        for module in modules {
            let catalog = try Self.catalog(named: module.name)
            for language in Self.translatedLanguages {
                let tables = try Self.tables(in: module.bundle, language: language)
                var unresolved: [String] = []
                var mismatched: [String] = []
                for (key, entry) in catalog {
                    guard entry.needsTranslation else { continue }
                    let resolved = tables.localizedString(forKey: key, value: Self.missing, table: "Localizable")
                    if resolved == Self.missing {
                        unresolved.append(key)
                    } else if let expected = entry.value(for: language), resolved != expected {
                        mismatched.append("\(key) → \(resolved) (catalog: \(expected))")
                    }
                }
                XCTAssertTrue(
                    unresolved.isEmpty,
                    "\(module.name) \(language): \(unresolved.count) keys do not resolve, e.g. \(unresolved.sorted().prefix(5))"
                )
                XCTAssertTrue(
                    mismatched.isEmpty,
                    "\(module.name) \(language): compiled value differs from the catalog: \(mismatched.prefix(5))"
                )
            }
        }
    }

    /// English needs a table entry only where the key is not its own English:
    /// semantic keys and plural variants.
    func testEnglishEntriesResolveForSemanticAndPluralKeys() throws {
        for module in modules {
            let catalog = try Self.catalog(named: module.name)
            let english = try Self.tables(in: module.bundle, language: "en")
            for (key, entry) in catalog where entry.hasEnglishEntry {
                let resolved = english.localizedString(forKey: key, value: Self.missing, table: "Localizable")
                XCTAssertNotEqual(resolved, Self.missing, "\(module.name) en: \(key)")
            }
        }
    }

    func testPluralVariantsPickTheRightForm() {
        let english = Locale(identifier: "en_US")
        let simplified = Locale(identifier: "zh-Hans_CN")
        let traditional = Locale(identifier: "zh-Hant_TW")
        XCTAssertEqual(studioLocalized("\(1) runs", locale: english), "1 run")
        XCTAssertEqual(studioLocalized("\(3) runs", locale: english), "3 runs")
        XCTAssertEqual(studioLocalized("\(1) runs", locale: simplified), "1 次跑步")
        XCTAssertEqual(studioLocalized("\(3) runs", locale: traditional), "3 次跑步")
        // Two counts in one sentence use catalog substitutions.
        XCTAssertEqual(
            studioLocalized("Corrected \(1) runs; \(0) runs needed no change.", locale: english),
            "Corrected 1 run; 0 runs needed no change."
        )
        XCTAssertEqual(
            studioLocalized("Corrected \(1) runs; \(1) runs needed no change.", locale: english),
            "Corrected 1 run; 1 run needed no change."
        )
        XCTAssertEqual(
            DisplayFormatter.formatCadence(180, locale: english),
            "180 spm"
        )
    }

    func testDefaultLookupsFollowTheProcessLanguage() {
        // The test host runs in English: the default path returns English text.
        XCTAssertEqual(studioLocalized("\(2) runs"), "2 runs")
        XCTAssertEqual(WorkoutRouteColorMode.pace.displayName, "Pace")
    }

    // MARK: - Catalog reading

    private struct Entry {
        let needsTranslation: Bool
        let hasEnglishEntry: Bool
        private let values: [String: String]

        init(json: [String: Any]) {
            let extraction = json["extractionState"] as? String
            needsTranslation = (json["shouldTranslate"] as? Bool) != false && extraction != "stale"
            let localizations = json["localizations"] as? [String: Any] ?? [:]
            hasEnglishEntry = localizations["en"] != nil
            var values: [String: String] = [:]
            for (language, payload) in localizations {
                guard let payload = payload as? [String: Any],
                      let unit = payload["stringUnit"] as? [String: Any],
                      payload["variations"] == nil,
                      payload["substitutions"] == nil,
                      let value = unit["value"] as? String
                else { continue }
                values[language] = value
            }
            self.values = values
        }

        func value(for language: String) -> String? { values[language] }
    }

    private static func catalog(named module: String, filePath: StaticString = #filePath) throws -> [String: Entry] {
        let url = URL(filePath: "\(filePath)")
            .deletingLastPathComponent() // CatalogResolutionTests.swift
            .deletingLastPathComponent() // RunPlayStudioTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RunPlayStudio
            .appendingPathComponent(module)
            .appendingPathComponent("Localization/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        var entries: [String: Entry] = [:]
        for (key, value) in strings {
            entries[key] = Entry(json: value as? [String: Any] ?? [:])
        }
        XCTAssertFalse(entries.isEmpty, "\(module) catalog is empty")
        return entries
    }

    /// One language's compiled tables, opened as a bundle so lookups use
    /// Foundation's own `.strings` / `.stringsdict` reading.
    private static func tables(in bundle: Bundle, language: String) throws -> Bundle {
        let url = try XCTUnwrap(
            bundle.url(forResource: language, withExtension: "lproj"),
            "\(bundle.bundleURL.lastPathComponent) has no \(language).lproj"
        )
        return try XCTUnwrap(Bundle(url: url))
    }
}
