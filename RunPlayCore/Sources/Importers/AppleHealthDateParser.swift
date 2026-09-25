import Foundation

/// A parsed Apple Health timestamp: the instant, the local civil fields, and the
/// UTC offset the source literally wrote.
///
/// The offset is kept separately because calendar features place a run on its
/// **recorded local date**, not its UTC date. `WorkoutMetadata.recordedUTCOffsetSeconds`
/// carries it into `WorkoutTrendsAggregator.bucketingTimeZone`. One instant seen
/// from two zones is two different local days, so the instant alone cannot
/// recover the bucket the run belongs in.
///
/// The civil fields are the **local** ones the source wrote, not their UTC
/// rendering. `2026-09-01 01:00:00 +0800` reports day 1 even though the same
/// instant is 31 August in UTC.
struct AppleHealthTimestamp: Equatable, Sendable {
    /// The instant, in absolute terms.
    var date: Date

    /// Offset in seconds east of Greenwich, exactly as written (`+0800` is
    /// `28_800`, `-0500` is `-18_000`, `+0000` is `0`). Matches the convention
    /// `WorkoutTimestampOffsetScanner` already establishes.
    var utcOffsetSeconds: Int

    /// Local civil fields as written by the source.
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
}

/// Parses the fixed-width timestamp shape Apple Health writes into
/// `export.xml`, using integer arithmetic only.
///
/// ## The shape is not ISO 8601
///
/// Measured over 253 `Workout@startDate` values in a real export, every one is
/// exactly 25 characters, uses a **space** between date and time, carries no
/// fractional seconds, and never ends in `Z`:
///
/// ```text
/// length distribution: {25: 253}   has 'T' separator: 0 / 253
/// has space separator: 253 / 253   ends with 'Z':     0 / 253
/// ```
///
/// So it is `yyyy-MM-dd HH:mm:ss ±hhmm`, and neither existing tool applies:
///
/// - `WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text:)` returns
///   `nil` at its `T`-separator guard, because there is no `T`.
/// - `ISO8601DateFormatter` rejects a space separator.
///
/// ## Why hand-rolled rather than `DateFormatter`
///
/// Parsing is positional and pure integer arithmetic. A real export carries
/// 3.15M `Record` elements plus 1,444 `Workout` elements, each with several
/// timestamps, so this runs millions of times per import; a formatter would
/// dominate it. Integer arithmetic is also exactly reproducible across macOS and
/// Linux, which a locale- and ICU-backed formatter is not.
///
/// If a formatter is ever introduced here, note that a numeric offset such as
/// `+0800` is pattern `Z` (or `xx`), **not** `ZZZZ` — `ZZZZ` expects the
/// localized GMT form (`GMT+08:00`) and would fail on this input. Any formatter
/// must also set `locale = Locale(identifier: "en_US_POSIX")` and
/// `timeZone = TimeZone(secondsFromGMT: 0)`, or a non-Gregorian user calendar
/// and a non-UTC default zone silently corrupt the result.
enum AppleHealthDateParser {

    /// Exact character count of one timestamp: 19 for `yyyy-MM-dd HH:mm:ss`,
    /// one space, and 5 for `±hhmm`.
    static let fieldLength = 25

    /// Parses one timestamp, or returns `nil` when the text does not match the
    /// documented shape exactly.
    ///
    /// Only the `±hhmm` form is accepted. `Z`, a colon-separated `±hh:mm`, and
    /// fractional seconds are all rejected rather than guessed at: a real export
    /// writes none of them (0 of 253 sampled), so accepting them would widen the
    /// contract beyond what the format is known to produce, and a silently
    /// mis-assumed zone would misplace the run's local date.
    static func parse(_ text: String) -> AppleHealthTimestamp? {
        var utf8 = Array(text.utf8)
        return parse(&utf8)
    }

    /// Parses one timestamp held in a caller-owned UTF-8 buffer.
    ///
    /// The buffer form exists so the streaming parser can hand attribute bytes
    /// straight over without allocating a `String` per timestamp. It agrees with
    /// the `String` overload on every input.
    static func parse(_ utf8: inout [UInt8]) -> AppleHealthTimestamp? {
        guard utf8.count == fieldLength else { return nil }
        return parse(utf8, at: 0)
    }

    /// Parses one timestamp starting at `offset` in `utf8`, without copying.
    ///
    /// Returns `nil` when fewer than `fieldLength` bytes remain or the shape
    /// does not match. Used by the streaming parser, which reads attributes out
    /// of a shared buffer.
    static func parse(_ utf8: [UInt8], at offset: Int) -> AppleHealthTimestamp? {
        guard offset >= 0, offset + fieldLength <= utf8.count else { return nil }

        // Separator positions are part of the contract, so a misplacement is
        // rejected rather than tolerated.
        guard utf8[offset + 4] == dash, utf8[offset + 7] == dash else { return nil }
        guard utf8[offset + 10] == space else { return nil }
        guard utf8[offset + 13] == colon, utf8[offset + 16] == colon else { return nil }
        guard utf8[offset + 19] == space else { return nil }

        guard let year = digits(utf8, at: offset, count: 4),
              let month = digits(utf8, at: offset + 5, count: 2),
              let day = digits(utf8, at: offset + 8, count: 2),
              let hour = digits(utf8, at: offset + 11, count: 2),
              let minute = digits(utf8, at: offset + 14, count: 2),
              let second = digits(utf8, at: offset + 17, count: 2)
        else { return nil }

        guard let offsetSeconds = zoneOffset(utf8, at: offset + 20) else { return nil }

        guard (1...12).contains(month) else { return nil }
        guard day >= 1, day <= daysInMonth(year: year, month: month) else { return nil }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        // `60` would be a leap second. Apple Health does not write one, and
        // silently rolling it into the next minute would misplace the sample.
        guard (0...59).contains(second) else { return nil }

        // Days since the Unix epoch, then seconds within that day. The civil
        // fields are local, so the instant is that reading minus the offset.
        let days = daysFromCivil(year: year, month: month, day: day)
        let localSeconds = days * 86_400
            + Int64(hour) * 3_600
            + Int64(minute) * 60
            + Int64(second)
        let utcSeconds = localSeconds - Int64(offsetSeconds)

        return AppleHealthTimestamp(
            date: Date(timeIntervalSince1970: TimeInterval(utcSeconds)),
            utcOffsetSeconds: offsetSeconds,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    }

    // MARK: - Civil-date arithmetic

    /// Days from the Unix epoch to a proleptic Gregorian civil date.
    ///
    /// Howard Hinnant's `days_from_civil`, translated literally. Pure integer
    /// arithmetic with no library call, so it is bit-identical on every platform
    /// and correct for negative years.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        // Shift the year so March begins it, which makes the leap day fall at
        // the end of the shifted year and removes the special case.
        let shifted = Int64(year) - (month <= 2 ? 1 : 0)
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400                                    // [0, 399]
        let shiftedMonth = Int64(month + (month > 2 ? -3 : 9))                    // [0, 11]
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + Int64(day) - 1             // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear // [0, 146096]
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Gregorian leap-year rule: divisible by 4, except centuries unless also
    /// divisible by 400. So 2000 and 1600 are leap years and 1900 is not.
    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Days in a month, accounting for leap Februaries.
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    // MARK: - Field readers

    /// Reads `±hhmm` at `start`.
    ///
    /// The field is exactly five bytes wide and the caller has already verified
    /// that `fieldLength` bytes exist from the timestamp's own offset, so this
    /// only needs a containment check. Requiring the zone to end the buffer
    /// would reject every timestamp read out of the streaming parser's shared
    /// buffer, where unrelated bytes follow the field. Trailing garbage after a
    /// well-formed 25-byte field is not this reader's concern: the `String`
    /// overload rejects it via its exact-length guard, and in the buffer form the
    /// field width itself is the boundary.
    ///
    /// The hour and minute ranges match `WorkoutTimestampOffsetScanner`, so both
    /// scanners agree on what an offset can be.
    private static func zoneOffset(_ utf8: [UInt8], at start: Int) -> Int? {
        guard start >= 0, start + 5 <= utf8.count else { return nil }
        let sign = utf8[start]
        guard sign == plus || sign == minus else { return nil }
        guard let hours = digits(utf8, at: start + 1, count: 2),
              let minutes = digits(utf8, at: start + 3, count: 2)
        else { return nil }
        guard (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
        let magnitude = hours * 3_600 + minutes * 60
        return sign == minus ? -magnitude : magnitude
    }

    /// Reads exactly `count` ASCII digits at `at`, or nil.
    private static func digits(_ utf8: [UInt8], at start: Int, count: Int) -> Int? {
        guard start >= 0, start + count <= utf8.count else { return nil }
        var value = 0
        for i in 0..<count {
            let c = utf8[start + i]
            guard c >= zero, c <= nine else { return nil }
            value = value * 10 + Int(c - zero)
        }
        return value
    }

    // MARK: - ASCII constants

    private static let dash = UInt8(ascii: "-")
    private static let space = UInt8(ascii: " ")
    private static let colon = UInt8(ascii: ":")
    private static let plus = UInt8(ascii: "+")
    private static let minus = UInt8(ascii: "-")
    private static let zero = UInt8(ascii: "0")
    private static let nine = UInt8(ascii: "9")
}
