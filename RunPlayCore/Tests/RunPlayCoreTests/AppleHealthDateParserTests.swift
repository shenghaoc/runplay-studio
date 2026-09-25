import Foundation
import XCTest
@testable import RunPlayCore

/// Covers ``AppleHealthDateParser``: the fixed-width `yyyy-MM-dd HH:mm:ss ±hhmm`
/// format Apple Health writes.
///
/// The parser is pure integer arithmetic, so every expected value here is a
/// literal that holds identically on macOS and Linux. Several tests cross-check
/// against `DateFormatter` with `en_US_POSIX`, which is an independent
/// implementation of the same calendar — agreement between the two is the
/// evidence that the hand-rolled civil-date math is right, not just stable.
final class AppleHealthDateParserTests: XCTestCase {

    // MARK: - Oracle

    /// An independent check of the same format, using `DateFormatter`.
    ///
    /// `en_US_POSIX` is mandatory here: with a user locale such as `ar_SA` a
    /// Gregorian pattern can emit non-ASCII digits and the round trip breaks.
    /// The offset pattern is `Z`, which renders `+0800` — **not** `ZZZZ`, which
    /// expects a localized zone name like "GMT+08:00".
    private static let oracle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    private func assertParses(
        _ text: String,
        expectedInstant: TimeInterval,
        expectedOffset: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let parsed = AppleHealthDateParser.parse(text) else {
            XCTFail("failed to parse \(text)", file: file, line: line)
            return
        }
        XCTAssertEqual(
            parsed.date.timeIntervalSince1970,
            expectedInstant,
            accuracy: 0,
            "instant for \(text)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            parsed.utcOffsetSeconds,
            expectedOffset,
            "offset for \(text)",
            file: file,
            line: line
        )
        // Cross-check against the independent implementation.
        guard let oracleDate = Self.oracle.date(from: text) else {
            XCTFail("oracle rejected \(text)", file: file, line: line)
            return
        }
        XCTAssertEqual(
            parsed.date.timeIntervalSince1970,
            oracleDate.timeIntervalSince1970,
            accuracy: 0,
            "disagrees with DateFormatter for \(text)",
            file: file,
            line: line
        )
    }

    // MARK: - The four required offsets

    // Expected instants below were computed with an independent oracle
    // (Python's `datetime.strptime` with `%z`), not by hand — a hand-computed
    // literal that happens to match a hand-rolled parser proves nothing.

    func testPositiveHourOffsetIsKeptInSecondsEast() {
        // 2026-09-01 08:00:00 +0800 is 2026-09-01 00:00:00 UTC.
        assertParses(
            "2026-09-01 08:00:00 +0800",
            expectedInstant: 1_788_220_800,
            expectedOffset: 28_800
        )
    }

    func testNegativeHourOffsetIsKeptInSecondsEast() {
        // 2026-09-01 08:00:00 -0500 is 2026-09-01 13:00:00 UTC.
        assertParses(
            "2026-09-01 08:00:00 -0500",
            expectedInstant: 1_788_267_600,
            expectedOffset: -18_000
        )
    }

    func testZeroOffsetParsesAsUTC() {
        assertParses(
            "2026-09-01 08:00:00 +0000",
            expectedInstant: 1_788_249_600,
            expectedOffset: 0
        )
    }

    func testNonHourOffsetParsesCorrectly() {
        // 2026-09-01 08:00:00 +0530 is 2026-09-01 02:30:00 UTC. Half-hour
        // zones are where an hours-only offset parser goes wrong.
        assertParses(
            "2026-09-01 08:00:00 +0530",
            expectedInstant: 1_788_229_800,
            expectedOffset: 19_800
        )
    }

    func testNegativeNonHourOffsetParsesCorrectly() {
        // 2026-09-01 08:00:00 -0930 is 2026-09-01 17:30:00 UTC.
        assertParses(
            "2026-09-01 08:00:00 -0930",
            expectedInstant: 1_788_283_800,
            expectedOffset: -34_200
        )
    }

    // MARK: - The offset is what trends needs, not just the instant

    func testSameInstantDifferentOffsetsBucketToDifferentLocalDays() {
        // One instant seen from two zones: 2026-08-31 17:00:00 UTC. In +0800 it
        // is already 1 September; in -0500 it is still 31 August. Trends must
        // place each on its own local date, which requires keeping the offset —
        // the instant alone cannot recover it.
        let east = AppleHealthDateParser.parse("2026-09-01 01:00:00 +0800")
        let west = AppleHealthDateParser.parse("2026-08-31 12:00:00 -0500")
        XCTAssertNotNil(east)
        XCTAssertNotNil(west)

        // Same instant.
        XCTAssertEqual(
            east!.date.timeIntervalSince1970,
            west!.date.timeIntervalSince1970,
            accuracy: 0
        )
        XCTAssertEqual(east!.date.timeIntervalSince1970, 1_788_195_600, accuracy: 0)
        // Different local civil dates.
        XCTAssertEqual(east!.year, 2026)
        XCTAssertEqual(east!.month, 9)
        XCTAssertEqual(east!.day, 1)
        XCTAssertEqual(west!.year, 2026)
        XCTAssertEqual(west!.month, 8)
        XCTAssertEqual(west!.day, 31)

        // And the bucketing zone trends builds from each differs.
        let fallback = TimeZone(secondsFromGMT: 0)!
        let eastZone = WorkoutTrendsAggregator.bucketingTimeZone(
            recordedUTCOffsetSeconds: east!.utcOffsetSeconds,
            fallback: fallback
        )
        let westZone = WorkoutTrendsAggregator.bucketingTimeZone(
            recordedUTCOffsetSeconds: west!.utcOffsetSeconds,
            fallback: fallback
        )
        XCTAssertEqual(eastZone.secondsFromGMT(), 28_800)
        XCTAssertEqual(westZone.secondsFromGMT(), -18_000)
        XCTAssertNotEqual(eastZone.secondsFromGMT(), westZone.secondsFromGMT())
    }

    // MARK: - Civil-calendar edge cases

    func testCivilDateFieldsAreExtracted() {
        guard let parsed = AppleHealthDateParser.parse("2026-09-24 23:59:58 +0800") else {
            return XCTFail("failed to parse")
        }
        XCTAssertEqual(parsed.year, 2026)
        XCTAssertEqual(parsed.month, 9)
        XCTAssertEqual(parsed.day, 24)
        XCTAssertEqual(parsed.hour, 23)
        XCTAssertEqual(parsed.minute, 59)
        XCTAssertEqual(parsed.second, 58)
    }

    func testLeapDayParses() {
        assertParses("2024-02-29 12:00:00 +0000", expectedInstant: 1_709_208_000, expectedOffset: 0)
    }

    func testNonLeapYearFebruary29IsRejected() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-02-29 12:00:00 +0000"))
    }

    func testCenturyLeapRuleIsApplied() {
        // 1900 is not a leap year; 2000 is.
        XCTAssertTrue(AppleHealthDateParser.isLeapYear(2000))
        XCTAssertFalse(AppleHealthDateParser.isLeapYear(1900))
        XCTAssertTrue(AppleHealthDateParser.isLeapYear(1600))
        XCTAssertFalse(AppleHealthDateParser.isLeapYear(2026))
        XCTAssertTrue(AppleHealthDateParser.isLeapYear(2024))
    }

    func testEpochBoundaryParses() {
        assertParses("1970-01-01 00:00:00 +0000", expectedInstant: 0, expectedOffset: 0)
    }

    func testPreEpochDateParses() {
        // 1969-12-31 23:59:59 UTC is -1 second.
        assertParses("1969-12-31 23:59:59 +0000", expectedInstant: -1, expectedOffset: 0)
    }

    func testYearBoundariesAgreeWithOracle() {
        for text in [
            "1999-12-31 23:59:59 +0000",
            "2000-01-01 00:00:00 +0000",
            "2026-12-31 23:59:59 -0500",
            "2027-01-01 00:00:00 +0530",
        ] {
            guard let parsed = AppleHealthDateParser.parse(text),
                  let oracle = Self.oracle.date(from: text)
            else {
                XCTFail("one implementation rejected \(text)")
                continue
            }
            XCTAssertEqual(
                parsed.date.timeIntervalSince1970,
                oracle.timeIntervalSince1970,
                accuracy: 0,
                text
            )
        }
    }

    func testDaysFromCivilMatchesCalendarAcrossManyDates() {
        // Sweep a wide range so the era arithmetic is exercised, comparing
        // against Foundation's Calendar as the independent oracle.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var checked = 0
        for offsetDays in stride(from: -20_000, to: 20_000, by: 137) {
            guard let date = calendar.date(
                byAdding: .day,
                value: offsetDays,
                to: Date(timeIntervalSince1970: 0)
            ) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let y = components.year, let m = components.month, let d = components.day else {
                continue
            }
            let days = AppleHealthDateParser.daysFromCivil(year: y, month: m, day: d)
            XCTAssertEqual(
                days,
                Int64(offsetDays),
                "\(y)-\(m)-\(d)"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 250, "the sweep must actually compare dates")
    }

    // MARK: - Rejection of malformed input

    func testRejectsISO8601WithTSeparator() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01T08:00:00+08:00"))
    }

    func testRejectsTrailingZForm() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:00 Z"))
    }

    func testRejectsColonSeparatedOffset() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:00 +08:00"))
    }

    func testRejectsFractionalSeconds() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:00.500 +0800"))
    }

    func testRejectsWrongLength() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:00"))
        XCTAssertNil(AppleHealthDateParser.parse(""))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:00 +0800 "))
    }

    func testRejectsOutOfRangeComponents() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-13-01 08:00:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-00-01 08:00:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-00 08:00:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-32 08:00:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 24:00:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:60:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:60 +0800"))
    }

    func testRejectsOutOfRangeOffset() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:00 +2500"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:00 -2500"))
    }

    func testRejectsNonDigits() {
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-O1 08:00:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:0O:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08:00:00 *0800"))
    }

    func testRejectsMisplacedSeparators() {
        XCTAssertNil(AppleHealthDateParser.parse("2026/09/01 08:00:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01  08:00:00 +0800"))
        XCTAssertNil(AppleHealthDateParser.parse("2026-09-01 08-00-00 +0800"))
    }

    // MARK: - Buffer overload

    func testBufferOverloadAgreesWithStringOverload() {
        let text = "2026-09-01 08:00:00 +0530"
        var utf8 = Array(text.utf8)
        let fromBuffer = AppleHealthDateParser.parse(&utf8)
        let fromString = AppleHealthDateParser.parse(text)
        XCTAssertEqual(fromBuffer, fromString)
        XCTAssertNotNil(fromBuffer)
    }

    func testFieldLengthConstantMatchesRealFormat() {
        // The real export writes exactly 25 characters for every timestamp.
        XCTAssertEqual(AppleHealthDateParser.fieldLength, "2026-09-01 08:00:00 +0800".count)
    }
}
