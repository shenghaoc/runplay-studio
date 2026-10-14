import XCTest
@testable import RunPlayCore

/// Weekly Trends buckets follow the user's week-start convention, with
/// ISO 8601 as the default every existing caller keeps.
final class WorkoutTrendsWeekConventionTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    /// en_US and zh_TW: weeks start on Sunday, the first week holds 1 January.
    private let sundayFirst = WorkoutTrendsWeekConvention(firstWeekday: 1, minimumDaysInFirstWeek: 1)

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func row(_ date: Date) -> WorkoutTrendsSummaryRow {
        WorkoutTrendsSummaryRow(
            id: UUID(),
            startDate: date,
            recordedUTCOffsetSeconds: nil,
            distanceMeters: 5_000,
            activeSeconds: 1_500,
            averageHeartRateBPM: nil,
            ascentMeters: nil
        )
    }

    func testDefaultConventionIsISO8601() {
        XCTAssertEqual(WorkoutTrendsWeekConvention.iso8601.firstWeekday, 2)
        XCTAssertEqual(WorkoutTrendsWeekConvention.iso8601.minimumDaysInFirstWeek, 4)
        // Sunday 13 September 2026 closes ISO week 37 whether or not the
        // convention is passed explicitly.
        let sunday = utcDate(2026, 9, 13)
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: sunday, period: .week, timeZone: utc),
            WorkoutTrendsAggregator.periodKey(for: sunday, period: .week, timeZone: utc, weekConvention: .iso8601)
        )
    }

    func testSundayStartWeekBeginsOnSunday() {
        let saturday = utcDate(2026, 9, 12)
        let sunday = utcDate(2026, 9, 13)
        let monday = utcDate(2026, 9, 14)

        // ISO: Saturday and Sunday share a week; Monday starts the next.
        let isoSaturday = WorkoutTrendsAggregator.periodKey(for: saturday, period: .week, timeZone: utc)
        let isoSunday = WorkoutTrendsAggregator.periodKey(for: sunday, period: .week, timeZone: utc)
        let isoMonday = WorkoutTrendsAggregator.periodKey(for: monday, period: .week, timeZone: utc)
        XCTAssertEqual(isoSaturday, isoSunday)
        XCTAssertNotEqual(isoSunday, isoMonday)

        // Sunday start: Sunday and Monday share a week; Saturday closes the last.
        let saturdayKey = WorkoutTrendsAggregator.periodKey(
            for: saturday, period: .week, timeZone: utc, weekConvention: sundayFirst
        )
        let sundayKey = WorkoutTrendsAggregator.periodKey(
            for: sunday, period: .week, timeZone: utc, weekConvention: sundayFirst
        )
        let mondayKey = WorkoutTrendsAggregator.periodKey(
            for: monday, period: .week, timeZone: utc, weekConvention: sundayFirst
        )
        XCTAssertNotEqual(saturdayKey, sundayKey)
        XCTAssertEqual(sundayKey, mondayKey)

        let bounds = WorkoutTrendsAggregator.periodBounds(
            for: sundayKey, timeZone: utc, weekConvention: sundayFirst
        )
        XCTAssertEqual(bounds.start, utcDate(2026, 9, 13, 0))
        XCTAssertEqual(bounds.end, utcDate(2026, 9, 20, 0))
    }

    func testAggregationBucketsByTheGivenConvention() {
        let rows = [row(utcDate(2026, 9, 12)), row(utcDate(2026, 9, 13)), row(utcDate(2026, 9, 14))]
        let now = utcDate(2026, 9, 15)

        let iso = WorkoutTrendsAggregator.aggregate(
            rows: rows, period: .week, range: .allTime, now: now,
            displayTimeZone: utc, fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(iso.buckets.map(\.runCount), [2, 1])

        let sundayStart = WorkoutTrendsAggregator.aggregate(
            rows: rows, period: .week, range: .allTime, now: now,
            displayTimeZone: utc, fallbackBucketingTimeZone: utc,
            weekConvention: sundayFirst
        )
        XCTAssertEqual(sundayStart.buckets.map(\.runCount), [1, 2])
        XCTAssertEqual(sundayStart.includedRunCount, 3)
    }

    func testSundayStartEnumeratesAcrossTheYearBoundary() {
        // Week enumeration walks keys in the convention's own numbering.
        let rows = [row(utcDate(2026, 12, 20)), row(utcDate(2027, 1, 5))]
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: rows, period: .week, range: .allTime, now: utcDate(2027, 1, 6),
            displayTimeZone: utc, fallbackBucketingTimeZone: utc,
            weekConvention: sundayFirst
        )
        XCTAssertEqual(aggregation.buckets.count, 3)
        XCTAssertEqual(aggregation.buckets.map(\.runCount), [1, 0, 1])
        let starts = aggregation.buckets.map {
            WorkoutTrendsAggregator.periodBounds(for: $0.id, timeZone: utc, weekConvention: sundayFirst).start
        }
        XCTAssertEqual(starts, [utcDate(2026, 12, 20, 0), utcDate(2026, 12, 27, 0), utcDate(2027, 1, 3, 0)])
    }

    func testConventionFromCalendarReadsItsFirstWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        XCTAssertEqual(WorkoutTrendsWeekConvention(calendar: calendar), sundayFirst)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        XCTAssertEqual(WorkoutTrendsWeekConvention(calendar: calendar), .iso8601)
    }

    func testConventionClampsOutOfRangeValues() {
        let clamped = WorkoutTrendsWeekConvention(firstWeekday: 9, minimumDaysInFirstWeek: 0)
        XCTAssertEqual(clamped.firstWeekday, 7)
        XCTAssertEqual(clamped.minimumDaysInFirstWeek, 1)
    }

    #if canImport(Darwin)
    /// The convention is whatever the locale's calendar says (CLDR week data,
    /// or the user's System Settings choice for the current locale), never a
    /// table of our own. Germany follows ISO; the United States starts on Sunday.
    func testConventionMirrorsTheLocalesCalendar() {
        for identifier in ["zh_CN", "zh_TW", "zh_HK", "en_US", "de_DE"] {
            let calendar = Locale(identifier: identifier).calendar
            let convention = WorkoutTrendsWeekConvention(calendar: calendar)
            XCTAssertEqual(convention.firstWeekday, calendar.firstWeekday, identifier)
            XCTAssertEqual(convention.minimumDaysInFirstWeek, calendar.minimumDaysInFirstWeek, identifier)
        }
        XCTAssertEqual(WorkoutTrendsWeekConvention(calendar: Locale(identifier: "de_DE").calendar), .iso8601)
        XCTAssertEqual(WorkoutTrendsWeekConvention(calendar: Locale(identifier: "en_US").calendar).firstWeekday, 1)
    }
    #endif
}
