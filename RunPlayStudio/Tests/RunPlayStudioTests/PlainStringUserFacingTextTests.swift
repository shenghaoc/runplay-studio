import Foundation
import XCTest

/// The catalog check proves that every string the compiler *extracts* has a
/// translation. It cannot see text that never reaches the catalog: a label built
/// as a plain `String` and handed to `Text(_:)` as a variable, an error message
/// returned from a presentation helper, a report line assembled from English
/// fragments. Those shipped untranslated twice (the Apple Health sheets, the
/// route-less run banner), because nothing failed.
///
/// This test closes that gap from the other side. It reads Studio's and
/// Platform's sources and fails on a string literal that reads like user-facing
/// prose (two or more words, or a capitalised word passed to a call) unless it
/// sits inside something that localises it.
///
/// **If it fails on your string:**
/// - User-facing text: wrap it in `studioLocalized(…)` / `platformLocalized(…)`
///   (or pass a `LocalizedStringKey` / `String.LocalizationValue` parameter), then
///   run `scripts/check-localization.sh --update` and translate the new key.
/// - Not user-facing (a developer diagnostic, a file name, a persisted raw
///   value): add `// l10n-exempt: <why>` to the same line, or list the whole file
///   in `exemptFiles` with the reason.
final class PlainStringUserFacingTextTests: XCTestCase {

    /// Whole files whose strings are never shown in the app's UI.
    private static let exemptFiles: [String: String] = [
        "RunPlayStudio/Sources/DemoAssets/":
            "headless README-asset command line: its output goes to a terminal, not a window",
        "RunPlayStudio/Sources/Services/AppSessionValidator.swift":
            "validation issues are developer diagnostics; no view reads them",
    ]

    func testStudioAndPlatformHoldNoPlainStringUserFacingText() throws {
        let root = Self.repositoryRoot
        var violations: [String] = []
        for directory in ["RunPlayStudio/Sources", "RunPlayPlatform/Sources"] {
            for path in try Self.swiftFiles(under: root.appendingPathComponent(directory)) {
                let relative = String(path.path.dropFirst(root.path.count + 1))
                if Self.exemptFiles.keys.contains(where: { relative.hasPrefix($0) }) { continue }
                let source = try String(contentsOf: path, encoding: .utf8)
                for hit in PlainStringScanner.suspects(in: source) {
                    violations.append("\(relative):\(hit.line): \"\(hit.text)\" (in \(hit.callee.isEmpty ? "a statement" : hit.callee))")
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Plain-String user-facing text. Localise it or mark it `// l10n-exempt: <why>`:\n"
                + violations.joined(separator: "\n")
        )
    }

    // MARK: - The scanner itself

    /// A plain label is caught, and each way of localising one is spared, so the
    /// guard cannot rot into a test that passes because it matches nothing.
    func testScannerFlagsPlainLabelsAndSparesLocalisedOnes() {
        let plain = """
        func a() -> String { "Imported without its route" }
        func b() { report("Workouts", 3) }
        let c = Text(verbatim: "Heart rate in bpm")
        func d() { errorMessage = "Apple Health import is unavailable in this session." }
        func e() -> String { "\\(count) runs were already in your library." }
        """
        XCTAssertEqual(
            PlainStringScanner.suspects(in: plain).map(\.text),
            [
                "Imported without its route",
                "Workouts",
                "Heart rate in bpm",
                "Apple Health import is unavailable in this session.",
                "\\(…) runs were already in your library.",
            ]
        )

        let localised = """
        func a() -> String { studioLocalized("Imported without its route") }
        func b() -> String { platformLocalized("Map imagery via Apple Maps", locale: locale) }
        let c = Text("Heart rate in bpm")
        let d = Button("Select All Ready") { }
        let e = view.help("Check every workout that carries no duplicate flag")
        let f = view.accessibilityLabel(isOn ? "Pause replay" : "Play replay")
        let g = String(localized: "Elevation", defaultValue: "Elevation", bundle: .module, comment: "Header metric")
        let h = CommandDefinition(id: .x, menuTitle: "Import File…", menu: "File", purpose: "Import a file", accessibilityDescription: "Import a single workout file")
        let i = ContentUnavailableView("Preview unavailable", systemImage: "x")
        let j = Chart { LineMark(x: .value("Time (min)", 1), y: .value("Heart Rate", 2)) }
        """
        XCTAssertEqual(PlainStringScanner.suspects(in: localised).map(\.text), [])

        let exempt = """
        enum Tab: String { case overview = "Overview Tab" }
        let a = name == "Running"
        let b = logger.debug("Something went wrong here")
        let c = Foo.failed("Could not lock the pixel buffer") // not a comment-only line
        let d = detail ?? "unknown writer error" // l10n-exempt: developer diagnostic
        // A comment that says "Not user facing" is not a literal.
        let e = "no-spaces-or_identifiers.json"
        """
        XCTAssertEqual(PlainStringScanner.suspects(in: exempt).map(\.text), ["Could not lock the pixel buffer"])
    }

    // MARK: - Files

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RunPlayStudioTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RunPlayStudio
            .deletingLastPathComponent()  // repository root
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}

/// Finds string literals that read as user-facing text and are not passed to
/// something that localises them. A heuristic by design: it is tuned to have
/// no false positives in the shipped sources, and the exemption marker handles
/// the rare one.
enum PlainStringScanner {
    struct Suspect: Equatable {
        let line: Int
        let text: String
        let callee: String
    }

    /// Calls whose literal argument is a `LocalizedStringKey` or a
    /// `String.LocalizationValue`, which the compiler extracts into the catalog.
    private static let localisingCalls: Set<String> = [
        "studioLocalized", "platformLocalized", "coreLocalized", "localized", "LocalizedStringKey",
        "LocalizedStringResource", "NSLocalizedString", "Text", "Button", "Label", "Toggle", "Picker",
        "Section", "TableColumn", "DisclosureGroup", "LabeledContent", "ProgressView", "Menu", "TextField",
        "Stepper", "Link", "GroupBox", "Slider", "DatePicker", "SecureField", "CommandMenu", "Gauge", "Tab",
        "ContentUnavailableView", "Window", "help", "accessibilityLabel", "accessibilityHint",
        "accessibilityValue", "accessibilityAction", "navigationTitle", "navigationSubtitle", "value",
        "confirmationDialog", "alert", "badge", "accessibilityInputLabels",
    ]

    /// Calls whose string arguments are identifiers, paths, logs or other text
    /// no user reads.
    private static let nonUICalls: Set<String> = [
        "Logger", "debug", "info", "error", "notice", "warning", "fault", "print", "debugPrint", "assert",
        "assertionFailure", "precondition", "preconditionFailure", "fatalError", "NSLog", "os_log", "Name", "URL",
        "Regex", "NSRegularExpression", "Image", "NSImage", "UTType", "forKey", "NSPredicate", "object",
        "appendingPathComponent", "appendingPathExtension", "caseInsensitiveCompare", "contains", "hasPrefix",
        "hasSuffix", "range", "firstIndex", "components", "environment",
    ]

    /// Argument labels whose literal is localised.
    private static let localisingLabels = [
        "menuTitle:", "purpose:", "accessibilityDescription:", "comment:", "defaultValue:", "localized:",
    ]

    /// Argument labels whose literal is an identifier or key.
    private static let identifierLabels = [
        "menu:", "id:", "kind:", "tabRaw:", "systemName:", "forKey:", "identifier:", "named:", "subsystem:",
        "category:", "key:", "format:", "rawValue:", "keyEquivalent:",
    ]

    static func suspects(in source: String) -> [Suspect] {
        let lines = source.components(separatedBy: "\n")
        return literals(in: source).compactMap { literal in
            guard looksUserFacing(literal.text) else { return nil }
            guard classify(literal) == .plain else { return nil }
            // A lone capitalised word ("Workouts") is only suspect as an argument
            // to a call: a bare one is a constant, a raw value or a comparison.
            if isSingleWord(literal.text), literal.callee.isEmpty || literal.callee == "[" { return nil }
            if literal.line - 1 < lines.count, lines[literal.line - 1].contains("l10n-exempt") { return nil }
            let shown = literal.text.replacingOccurrences(of: "\u{1}", with: "\\(…)")
            return Suspect(line: literal.line, text: shown, callee: literal.callee)
        }
    }

    // MARK: Classification

    private enum Kind { case localised, nonUI, plain }

    private static func classify(_ literal: Literal) -> Kind {
        let before = literal.before
        if before.hasSuffix("verbatim:") { return .plain }
        if before.hasSuffix("==") || before.hasSuffix("!=") { return .nonUI }
        if before.range(of: #"case\s+\w+\s*=\s*$"#, options: .regularExpression) != nil { return .nonUI }
        // A persisted raw value's default (`tabRaw: String = "Overview"`).
        if before.range(of: #"Raw:\s*String\s*=\s*$"#, options: .regularExpression) != nil { return .nonUI }
        if localisingLabels.contains(where: before.hasSuffix) { return .localised }
        if identifierLabels.contains(where: before.hasSuffix) { return .nonUI }
        let last = literal.callee.split(separator: ".").last.map(String.init) ?? ""
        if literal.callee.range(of: #"Error(\.\w+)?$"#, options: .regularExpression) != nil { return .nonUI }
        if localisingCalls.contains(last) { return .localised }
        if nonUICalls.contains(last) { return .nonUI }
        return .plain
    }

    private static func looksUserFacing(_ text: String) -> Bool {
        let visible = text.replacingOccurrences(of: "\u{1}", with: " ")
        let words = Self.words(in: visible)
        guard words.contains(where: { $0.count >= 3 }) else { return false }
        if visible.range(of: #"[_{}<>=]"#, options: .regularExpression) != nil { return false }
        if isSingleWord(visible) { return true }  // suspect only as an argument (see `suspects`)
        guard words.count >= 2, visible.contains(" ") else { return false }
        if visible.range(of: #"[/\\]"#, options: .regularExpression) != nil,
           visible.range(of: #"[.!?]\s*$"#, options: .regularExpression) == nil { return false }
        return true
    }

    private static func isSingleWord(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^[A-Z][A-Za-z]{3,}$"#, options: .regularExpression) != nil
    }

    private static func words(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z'\u{2019}]+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: Tokenizer

    struct Literal {
        let line: Int
        let text: String
        let callee: String
        let before: String
    }

    /// The string literals of `source`, with interpolations replaced by U+0001,
    /// each with the call it sits in (empty at statement level, "[" in an array).
    static func literals(in source: String) -> [Literal] {
        var scanner = LiteralScanner(bytes: Array(source.utf8))
        return scanner.scan()
    }

    /// A byte scanner over Swift source that tracks the line, the stack of
    /// open calls and brackets, and the literals found so far.
    private struct LiteralScanner {
        let bytes: [UInt8]
        var result: [Literal] = []
        var calls: [String] = []
        var line = 1
        var i = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var count: Int { bytes.count }

        func isIdentifierByte(_ b: UInt8) -> Bool {
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 46
        }

        func starts(_ s: String, at index: Int) -> Bool {
            let pattern = Array(s.utf8)
            guard index + pattern.count <= count else { return false }
            return Array(bytes[index..<index + pattern.count]) == pattern
        }

        mutating func scan() -> [Literal] {
            while i < count {
                let c = bytes[i]
                if c == 10 { line += 1; i += 1; continue }
                if starts("//", at: i) {
                    while i < count, bytes[i] != 10 { i += 1 }
                    continue
                }
                if starts("/*", at: i) {
                    skipBlockComment()
                    continue
                }
                if c == 40 || c == 91 {  // ( [
                    openCall(c)
                    continue
                }
                if c == 41 || c == 93 {  // ) ]
                    if !calls.isEmpty { calls.removeLast() }
                    i += 1
                    continue
                }
                if c == 34 {  // "
                    readStringLiteral()
                    continue
                }
                i += 1
            }
            return result
        }

        mutating func skipBlockComment() {
            i += 2
            while i < count, !starts("*/", at: i) { if bytes[i] == 10 { line += 1 }; i += 1 }
            i += 2
        }

        /// Pushes "[" for a bracket, or the identifier before a parenthesis.
        mutating func openCall(_ c: UInt8) {
            if c == 91 {
                calls.append("[")
            } else {
                var start = i
                while start > 0, isIdentifierByte(bytes[start - 1]) { start -= 1 }
                calls.append(String(decoding: bytes[start..<i], as: UTF8.self))
            }
            i += 1
        }

        /// Reads one single-line or multiline string literal at `i`, with each
        /// interpolation replaced by U+0001.
        mutating func readStringLiteral() {
            let multiline = starts("\"\"\"", at: i)
            let delimiter = multiline ? "\"\"\"" : "\""
            let literalLine = line
            let beforeStart = max(0, i - 40)
            let before = String(decoding: bytes[beforeStart..<i], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var j = i + delimiter.utf8.count
            var text: [UInt8] = []
            while j < count {
                if starts("\\(", at: j) {
                    text.append(1)
                    j = endOfInterpolation(from: j + 2)
                    continue
                }
                if starts(delimiter, at: j) { break }
                if !multiline, bytes[j] == 10 { break }
                if bytes[j] == 92, j + 1 < count { text.append(bytes[j]); text.append(bytes[j + 1]); j += 2; continue }
                if bytes[j] == 10 { line += 1 }
                text.append(bytes[j])
                j += 1
            }
            result.append(Literal(
                line: literalLine,
                text: String(decoding: text, as: UTF8.self),
                callee: calls.last ?? "",
                before: before
            ))
            i = j + delimiter.utf8.count
        }

        /// The index just past the parenthesis that closes an interpolation
        /// whose body starts at `start`, skipping nested strings.
        func endOfInterpolation(from start: Int) -> Int {
            var j = start
            var depth = 1
            while j < count, depth > 0 {
                if bytes[j] == 40 { depth += 1 } else if bytes[j] == 41 { depth -= 1 }
                else if bytes[j] == 34 {
                    j += 1
                    while j < count, bytes[j] != 34 { if bytes[j] == 92 { j += 1 }; j += 1 }
                }
                j += 1
            }
            return j
        }
    }
}
