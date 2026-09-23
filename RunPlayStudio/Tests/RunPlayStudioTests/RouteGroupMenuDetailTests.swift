import XCTest
@testable import RunPlayCore
@testable import RunPlayStudio

/// The route filter menus' secondary line (issue #134): run count and date
/// span per route, derived from library entries.
final class RouteGroupMenuDetailTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func entry(group: UUID?, start: Date?) -> WorkoutLibraryEntry {
        var workout = RunWorkout(routePoints: [])
        workout.metadata.startDate = start
        return WorkoutLibraryEntry.make(
            from: workout,
            manifestIndex: 0,
            isFavorite: false,
            routeGroupID: group
        )
    }

    private func subtitle(_ detail: RouteGroupMenuDetail) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return detail.subtitle(locale: english, calendar: calendar, timeZone: utc)
    }

    func testDetailsCountMembersAndSpanTheirDates() throws {
        let route = UUID()
        let other = UUID()
        let details = RouteGroupMenuDetail.details(for: [
            entry(group: route, start: date(2026, 8, 20)),
            entry(group: route, start: date(2026, 3, 2)),
            entry(group: route, start: nil),
            entry(group: other, start: date(2026, 5, 1)),
            entry(group: nil, start: date(2026, 1, 1))
        ])

        XCTAssertEqual(details.count, 2, "ungrouped runs contribute to no route")
        let detail = try XCTUnwrap(details[route])
        XCTAssertEqual(detail.runCount, 3, "an undated member still counts as a run")
        XCTAssertEqual(detail.firstRunDate, date(2026, 3, 2))
        XCTAssertEqual(detail.lastRunDate, date(2026, 8, 20))
        XCTAssertEqual(details[other]?.runCount, 1)
    }

    func testSubtitleShowsCountAndMonthSpan() {
        let text = subtitle(RouteGroupMenuDetail(
            runCount: 5,
            firstRunDate: date(2026, 3, 2),
            lastRunDate: date(2026, 8, 20)
        ))
        XCTAssertTrue(text.hasPrefix("5 runs · "), "got \(text)")
        XCTAssertTrue(text.contains("Mar"), "got \(text)")
        XCTAssertTrue(text.hasSuffix("Aug 2026"), "got \(text)")
    }

    func testSubtitleCollapsesASingleMonthAndSingularisesOneRun() {
        XCTAssertEqual(
            subtitle(RouteGroupMenuDetail(runCount: 1, firstRunDate: date(2026, 3, 2), lastRunDate: date(2026, 3, 2))),
            "1 run · Mar 2026"
        )
        XCTAssertEqual(
            subtitle(RouteGroupMenuDetail(runCount: 2, firstRunDate: date(2026, 3, 2), lastRunDate: date(2026, 3, 30))),
            "2 runs · Mar 2026"
        )
    }

    func testSubtitleWithoutDatesIsTheCountAlone() {
        XCTAssertEqual(subtitle(RouteGroupMenuDetail(runCount: 4)), "4 runs")
    }

    /// Two routes whose names collide on the bare base name still read
    /// differently on the secondary line.
    func testSpanningYearsNamesBothYears() {
        let text = subtitle(RouteGroupMenuDetail(
            runCount: 12,
            firstRunDate: date(2025, 11, 5),
            lastRunDate: date(2026, 2, 1)
        ))
        XCTAssertTrue(text.contains("2025") && text.contains("2026"), "got \(text)")
    }
}
