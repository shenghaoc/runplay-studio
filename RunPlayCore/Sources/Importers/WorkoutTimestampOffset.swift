import Foundation

/// Extracts the literal UTC offset encoded in an ISO 8601 timestamp string.
///
/// Calendar features place a run on its recorded local date, so importers
/// capture the offset exactly as the source wrote it: `Z` is offset `0`,
/// `+09:00` is `32_400`, `-05:00` is `-18_000`. Files whose timestamps carry
/// no zone designator — none of the supported text formats, which all require
/// one — yield `nil` and the app falls back to the system zone. FIT logs UTC
/// instants only and records no offset.
enum WorkoutTimestampOffsetScanner {
    /// Offset in seconds east of Greenwich, or `nil` when no valid designator
    /// is present. Accepts `Z`/`z` and `±HH:MM`, `±HHMM`, `±HH` tails.
    static func utcOffsetSeconds(inISO8601Text text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return nil }
        if last == "Z" || last == "z" {
            return 0
        }
        // The designator is the later of the final '+' or '-': date
        // separators also use '-' but always precede the time part.
        let plusIndex = trimmed.lastIndex(of: "+")
        let minusIndex = trimmed.lastIndex(of: "-")
        guard let signIndex = [plusIndex, minusIndex].compactMap({ $0 }).max() else {
            return nil
        }
        let sign = trimmed[signIndex]
        let tail = trimmed[trimmed.index(after: signIndex)...]
        let digits = tail.filter { $0 != ":" }
        guard digits.count == 2 || digits.count == 4,
              digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        let hours = Int(digits.prefix(2)) ?? -1
        let minutes = digits.count == 4 ? (Int(digits.suffix(2)) ?? -1) : 0
        guard (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
        let magnitude = hours * 3_600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }
}
