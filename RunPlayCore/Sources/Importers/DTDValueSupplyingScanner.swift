import Foundation

/// Why an inline DTD could not be safely elided.
///
/// `DTDStrippingInputStream` removes a document's leading `<!DOCTYPE …>` so that
/// Foundation's `XMLParser` can parse it on Linux, where an inline DTD carrying
/// an `ATTLIST` declaration makes the parser segfault. Eliding is only lossless
/// when the DTD supplies no value, and that is a property of the *document*, not
/// of DTDs in general — so it is enforced here rather than assumed.
///
/// Each case names a construct that could supply a value, or change one: an
/// attribute declared with any type but `CDATA` has its value normalized by the
/// parser using the declaration (XML 1.0 §3.3.3, which trims and collapses
/// spaces), so eliding the DTD would hand the importer a different value. A
/// real Apple Health export contains none of them (measured: 24 `ELEMENT`, 23
/// `ATTLIST`, 0 `ENTITY`, 0 `NOTATION`, 0 `#FIXED`, 0 quoted defaults), so the
/// guard is invisible in practice. It exists for the case a future iOS release
/// adds one: then the import fails loudly instead of silently dropping an
/// attribute from every record that omits it, which would misreport distance,
/// duration or heart rate for an entire library with no error anywhere.
enum DTDPolicyViolation: Error, Equatable, CustomStringConvertible {
    case entityDeclaration
    case notationDeclaration
    case fixedAttributeDefault
    case quotedAttributeDefault
    /// The declared type, or "enumeration" for a list such as `(a|b)`.
    case nonCDATAAttributeType(String)
    case internalSubsetTooLarge(observedBytes: Int, limit: Int)

    var description: String {
        switch self {
        case .entityDeclaration:
            return "This file's DTD declares an entity, which could expand into "
                + "content. RunPlay Studio does not elide such a DTD."
        case .notationDeclaration:
            return "This file's DTD declares a notation, which could carry an "
                + "unparsed-entity default. RunPlay Studio does not elide such a DTD."
        case .fixedAttributeDefault:
            return "This file's DTD pins an attribute value with #FIXED, which "
                + "eliding it would silently drop."
        case .quotedAttributeDefault:
            return "This file's DTD supplies a quoted attribute default, which "
                + "eliding it would silently drop."
        case .nonCDATAAttributeType(let type):
            return "This file's DTD declares an attribute of type \(type), whose "
                + "value the XML parser normalizes using the DTD. Eliding the DTD "
                + "would silently change that value."
        case .internalSubsetTooLarge(let observedBytes, let limit):
            return "This file's DTD internal subset is \(observedBytes) bytes, "
                + "above the \(limit)-byte limit RunPlay Studio inspects, so it "
                + "cannot be proven free of default values."
        }
    }
}

/// Scans an XML internal subset for any construct that could supply a value.
///
/// Returns the first violation found, or `nil` when the subset is value-free and
/// therefore safe to elide. Comments and processing instructions are skipped, so
/// a keyword appearing inside one is prose rather than a declaration and does not
/// produce a false positive.
///
/// This is a pure function over bytes with no streaming state, which is why it
/// lives apart from `DTDStrippingInputStream`: it can be tested directly against
/// every construct it must recognise, independently of chunk boundaries.
///
/// Every index here is an absolute `Int` into one flat `[UInt8]`. Declaration
/// bodies are passed as explicit `Range<Int>` bounds rather than as slices, so no
/// helper can return an index in a different index space than its caller expects
/// — a `Data`-slice indexing mistake in this area already cost one debugging
/// cycle during this work.
enum DTDValueSupplyingScanner {

    static func findViolation(in text: String) -> DTDPolicyViolation? {
        findViolation(in: Array(text.utf8))
    }

    static func findViolation(in bytes: [UInt8]) -> DTDPolicyViolation? {
        var i = 0

        while i < bytes.count {
            if startsWith(bytes, at: i, "<!--") {
                guard let end = indexOf(bytes, from: i + 4, "-->") else { return nil }
                i = end + 3
                continue
            }
            if startsWith(bytes, at: i, "<?") {
                guard let end = indexOf(bytes, from: i + 2, "?>") else { return nil }
                i = end + 2
                continue
            }
            guard startsWith(bytes, at: i, "<!") else {
                i += 1
                continue
            }

            // Read the declaration keyword.
            var j = i + 2
            var name = [UInt8]()
            while j < bytes.count, isNameByte(bytes[j]) {
                name.append(bytes[j]); j += 1
            }
            let keyword = String(decoding: name, as: UTF8.self)

            // Read the body up to the closing `>`, honouring quotes so a `>`
            // inside a literal does not end the declaration early and hide a
            // later violation.
            var k = j
            var quote: UInt8?
            while k < bytes.count {
                let c = bytes[k]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                    quote = c
                } else if c == UInt8(ascii: ">") {
                    break
                }
                k += 1
            }
            let body = j..<min(k, bytes.count)

            switch keyword {
            case "ENTITY":
                return .entityDeclaration
            case "NOTATION":
                return .notationDeclaration
            case "ATTLIST":
                if contains(bytes, in: body, "#FIXED") {
                    return .fixedAttributeDefault
                }
                // A quote anywhere in an ATTLIST body is a supplied default:
                // every other token in it (a name, a type, `#REQUIRED`,
                // `#IMPLIED`) is unquoted.
                if indexOfByte(bytes, in: body, UInt8(ascii: "\"")) != nil
                    || indexOfByte(bytes, in: body, UInt8(ascii: "'")) != nil {
                    return .quotedAttributeDefault
                }
                if let type = firstNonCDATAAttributeType(bytes, in: body) {
                    return .nonCDATAAttributeType(type)
                }
            default:
                if contains(bytes, in: body, "#FIXED") {
                    return .fixedAttributeDefault
                }
            }

            i = (k < bytes.count) ? k + 1 : bytes.count
        }
        return nil
    }

    /// The declared type of the first attribute in an ATTLIST body that is not
    /// CDATA, or `nil` when every attribute is CDATA.
    ///
    /// The body is the element name followed by one name, type and default per
    /// attribute. The caller has already refused `#FIXED` and quoted defaults,
    /// so each default here is one `#REQUIRED` or `#IMPLIED` token. An
    /// enumeration such as `( a | b )` is one token, spaces included, and is
    /// reported as "enumeration"; `NOTATION (a|b)` is reported as "NOTATION".
    private static func firstNonCDATAAttributeType(_ bytes: [UInt8], in body: Range<Int>) -> String? {
        let tokens = declarationTokens(bytes, in: body)
        var t = 1
        while t + 1 < tokens.count {
            let type = tokens[t + 1]
            if bytes[type.lowerBound] == UInt8(ascii: "(") { return "enumeration" }
            let name = String(decoding: bytes[type], as: UTF8.self)
            if name != "CDATA" { return name }
            t += 3
        }
        return nil
    }

    // MARK: - Byte helpers (all indices absolute `Int` into `bytes`)

    /// The whitespace-separated tokens of a declaration body. A parenthesized
    /// group is one token, so an enumeration with spaces inside stays whole.
    private static func declarationTokens(_ bytes: [UInt8], in body: Range<Int>) -> [Range<Int>] {
        var tokens: [Range<Int>] = []
        let upper = min(body.upperBound, bytes.count)
        var i = max(body.lowerBound, 0)
        while i < upper {
            if isSpaceByte(bytes[i]) {
                i += 1
                continue
            }
            let start = i
            if bytes[i] == UInt8(ascii: "(") {
                while i < upper, bytes[i] != UInt8(ascii: ")") { i += 1 }
                i = min(i + 1, upper)
            } else {
                while i < upper, !isSpaceByte(bytes[i]), bytes[i] != UInt8(ascii: "(") { i += 1 }
            }
            tokens.append(start..<i)
        }
        return tokens
    }

    private static func isSpaceByte(_ c: UInt8) -> Bool {
        c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r")
    }

    private static func isNameByte(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
            || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
    }

    private static func startsWith(_ bytes: [UInt8], at i: Int, _ literal: String) -> Bool {
        let lit = Array(literal.utf8)
        guard i + lit.count <= bytes.count else { return false }
        for n in 0..<lit.count where bytes[i + n] != lit[n] { return false }
        return true
    }

    private static func contains(_ bytes: [UInt8], in range: Range<Int>, _ literal: String) -> Bool {
        indexOf(bytes, from: range.lowerBound, literal, limit: range.upperBound) != nil
    }

    /// First index at or after `start` where `literal` begins, or `nil`. The
    /// whole match must fit before `limit`, so a declaration body never matches
    /// a keyword belonging to a later declaration.
    private static func indexOf(
        _ bytes: [UInt8],
        from start: Int,
        _ literal: String,
        limit: Int? = nil
    ) -> Int? {
        let needle = Array(literal.utf8)
        guard !needle.isEmpty else { return nil }
        let upper = min(limit ?? bytes.count, bytes.count)
        guard start + needle.count <= upper else { return nil }
        var i = max(start, 0)
        while i + needle.count <= upper {
            var matched = true
            for n in 0..<needle.count where bytes[i + n] != needle[n] {
                matched = false
                break
            }
            if matched { return i }
            i += 1
        }
        return nil
    }

    private static func indexOfByte(_ bytes: [UInt8], in range: Range<Int>, _ byte: UInt8) -> Int? {
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, bytes.count)
        guard lower < upper else { return nil }
        var i = lower
        while i < upper {
            if bytes[i] == byte { return i }
            i += 1
        }
        return nil
    }
}
