import XCTest
import RunPlayCore
import SwiftUI
@testable import RunPlayStudio

/// The From and To row that edits a custom All Runs date range: which bounds
/// are on, what each picker shows and offers, what an edit applies, and how
/// the view model applies it.
@MainActor
final class WorkoutLibraryCustomDateRangeTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func day(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0,
        calendar: Calendar = utc
    ) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        )!
    }

    private static func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private let utc = WorkoutLibraryCustomDateRangeTests.utc
    private let rememberedStart = WorkoutLibraryCustomDateRangeTests.day(2026, 9, 1, hour: 9)
    private let rememberedEnd = WorkoutLibraryCustomDateRangeTests.day(2026, 9, 30, hour: 18)

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        Self.day(year, month, day, hour: hour, minute: minute, second: second)
    }

    private func range(start: Date?, end: Date?, calendar: Calendar = utc) -> WorkoutLibraryCustomDateRange {
        WorkoutLibraryCustomDateRange(
            filter: .custom(start: start, end: end),
            rememberedStart: rememberedStart,
            rememberedEnd: rememberedEnd,
            calendar: calendar
        )!
    }

    // MARK: - Which bounds are on

    func testPresetsShowNoRow() {
        for filter in [WorkoutLibraryDateFilter.allTime, .last30Days, .last90Days, .currentCalendarYear] {
            XCTAssertNil(
                WorkoutLibraryCustomDateRange(
                    filter: filter,
                    rememberedStart: rememberedStart,
                    rememberedEnd: rememberedEnd,
                    calendar: utc
                ),
                "\(filter)"
            )
        }
    }

    func testATwoSidedRangeShowsBothBoundsOnAtTheirOwnDates() {
        let start = day(2026, 10, 1)
        let end = day(2026, 10, 14)
        let range = range(start: start, end: end)

        XCTAssertTrue(range.includes(.start))
        XCTAssertTrue(range.includes(.end))
        XCTAssertEqual(range.pickerDate(for: .start), start)
        XCTAssertEqual(range.pickerDate(for: .end), end)
        XCTAssertTrue(range.canExclude(.start))
        XCTAssertTrue(range.canExclude(.end))
        XCTAssertEqual(range.filter, .custom(start: start, end: end))
    }

    func testAOneSidedRangeShowsItsOpenSideOffAtTheRememberedDate() {
        let start = day(2022, 1, 1)
        let range = range(start: start, end: nil)

        XCTAssertTrue(range.includes(.start))
        XCTAssertFalse(range.includes(.end))
        XCTAssertEqual(range.pickerDate(for: .start), start)
        XCTAssertEqual(range.pickerDate(for: .end), rememberedEnd)
        XCTAssertEqual(range.filter, .custom(start: start, end: nil))
    }

    func testAnOpenSideNeverShowsADateOnTheWrongSideOfTheOtherBound() {
        // The remembered end, 30 September, is before this range starts, and
        // the remembered start, 1 September, is after the other one ends.
        let openEnd = range(start: day(2026, 11, 5, hour: 12), end: nil)
        let openStart = range(start: nil, end: day(2026, 8, 1, hour: 12))

        XCTAssertEqual(openEnd.pickerDate(for: .end), day(2026, 11, 5))
        XCTAssertEqual(openStart.pickerDate(for: .start), day(2026, 8, 1, hour: 23, minute: 59, second: 59))
    }

    // MARK: - Picking a date

    func testPickingTheStartOfAnOpenEndedRangeKeepsItsEndOpen() {
        var range = range(start: day(2022, 1, 1), end: nil)
        let picked = day(2023, 3, 1)

        range.pick(picked, for: .start)

        XCTAssertEqual(range.filter, .custom(start: picked, end: nil))
        XCTAssertEqual(range.rememberedStart, picked)
        XCTAssertEqual(range.rememberedEnd, rememberedEnd)
    }

    func testPickingTheEndOfAnOpenStartedRangeKeepsItsStartOpen() {
        var range = range(start: nil, end: day(2026, 9, 30, hour: 20))
        let picked = day(2026, 10, 31)

        range.pick(picked, for: .end)

        XCTAssertEqual(range.filter, .custom(start: nil, end: picked))
        XCTAssertEqual(range.rememberedEnd, picked)
        XCTAssertEqual(range.rememberedStart, rememberedStart)
    }

    func testPickingAStartAfterTheOpenEndsDateMovesThatDateToo() {
        var range = range(start: day(2026, 3, 1), end: day(2026, 3, 31))
        range.setIncluded(false, for: .end)

        range.pick(day(2026, 6, 1, hour: 9), for: .start)

        XCTAssertEqual(range.filter, .custom(start: day(2026, 6, 1, hour: 9), end: nil))
        XCTAssertEqual(range.rememberedEnd, day(2026, 6, 1))
        XCTAssertEqual(range.pickerDate(for: .end), day(2026, 6, 1))
    }

    func testPickingAnEndBeforeTheOpenStartsDateMovesThatDateToo() {
        var range = range(start: day(2026, 3, 1), end: day(2026, 3, 31))
        range.setIncluded(false, for: .start)

        range.pick(day(2026, 2, 10, hour: 9), for: .end)

        XCTAssertEqual(range.filter, .custom(start: nil, end: day(2026, 2, 10, hour: 9)))
        XCTAssertEqual(range.rememberedStart, day(2026, 2, 10, hour: 23, minute: 59, second: 59))
    }

    func testARangeMayStartAndEndOnTheSameDay() {
        // The query compares days, so a start later in the day than the
        // end's time of day still includes that whole day.
        var range = range(start: day(2026, 10, 1, hour: 8), end: day(2026, 10, 14, hour: 7))
        let sameDayEvening = day(2026, 10, 14, hour: 20)

        range.pick(sameDayEvening, for: .start)

        XCTAssertEqual(range.filter, .custom(start: sameDayEvening, end: day(2026, 10, 14, hour: 7)))
    }

    func testAStartPickedAfterTheEndDayIsClampedToTheEndDay() {
        var range = range(start: day(2026, 10, 1), end: day(2026, 10, 14, hour: 7))

        range.pick(day(2026, 10, 20), for: .start)

        XCTAssertEqual(range.start, day(2026, 10, 14, hour: 23, minute: 59, second: 59))
        XCTAssertEqual(range.end, day(2026, 10, 14, hour: 7))
    }

    func testAnEndPickedBeforeTheStartDayIsClampedToTheStartDay() {
        var range = range(start: day(2026, 10, 10, hour: 15), end: day(2026, 10, 20))

        range.pick(day(2026, 10, 3), for: .end)

        XCTAssertEqual(range.end, day(2026, 10, 10))
        XCTAssertEqual(range.start, day(2026, 10, 10, hour: 15))
    }

    // MARK: - Turning a bound on or off

    func testTurningABoundOnAppliesTheDateItsPickerShows() {
        var range = range(start: day(2026, 8, 1), end: nil)
        var late = self.range(start: day(2026, 11, 5, hour: 12), end: nil)
        let lateShown = late.pickerDate(for: .end)

        range.setIncluded(true, for: .end)
        late.setIncluded(true, for: .end)

        XCTAssertEqual(range.filter, .custom(start: day(2026, 8, 1), end: rememberedEnd))
        XCTAssertEqual(late.end, lateShown)
        XCTAssertEqual(late.end, day(2026, 11, 5))
    }

    func testTurningABoundOffOpensThatSideAndKeepsShowingItsDate() {
        let start = day(2026, 10, 1)
        let end = day(2026, 10, 14)
        var range = range(start: start, end: end)

        range.setIncluded(false, for: .end)

        XCTAssertEqual(range.filter, .custom(start: start, end: nil))
        XCTAssertEqual(range.pickerDate(for: .end), end, "the disabled picker keeps the date")
        XCTAssertFalse(range.canExclude(.start))

        range.setIncluded(true, for: .end)

        XCTAssertEqual(range.filter, .custom(start: start, end: end))
    }

    func testTheOnlyBoundThatIsOnCannotBeTurnedOff() {
        // A range with neither bound would count as a filter yet match every
        // run, so the last date stays.
        let start = day(2022, 1, 1)
        var range = range(start: start, end: nil)
        XCTAssertFalse(range.canExclude(.start))

        range.setIncluded(false, for: .start)

        XCTAssertEqual(range.filter, .custom(start: start, end: nil))
    }

    func testARangeWithNeitherBoundCanTurnEitherOn() {
        var range = range(start: nil, end: nil)
        XCTAssertFalse(range.includes(.start))
        XCTAssertFalse(range.includes(.end))

        range.setIncluded(true, for: .start)

        XCTAssertEqual(range.filter, .custom(start: rememberedStart, end: nil))
    }

    // MARK: - What each picker offers

    func testAPickerOffersEveryDateWhileTheOtherBoundIsOpen() {
        let everyDate = Date.distantPast...Date.distantFuture

        XCTAssertEqual(range(start: day(2022, 1, 1), end: nil).selectableDates(for: .start), everyDate)
        XCTAssertEqual(range(start: nil, end: day(2026, 12, 1)).selectableDates(for: .end), everyDate)
    }

    func testAPickerStopsAtTheOtherBoundsDay() {
        let range = range(start: day(2026, 10, 1, hour: 8), end: day(2026, 10, 14, hour: 7))

        XCTAssertEqual(
            range.selectableDates(for: .start),
            Date.distantPast...day(2026, 10, 14, hour: 23, minute: 59, second: 59)
        )
        XCTAssertEqual(range.selectableDates(for: .end), day(2026, 10, 1)...Date.distantFuture)
    }

    func testAPickerAlwaysOffersTheStoredDateAndAnEditEndsTheInversion() {
        // A stored range that ends before it starts is shown as stored.
        let inverted = range(start: day(2026, 10, 20), end: day(2026, 10, 10))
        XCTAssertTrue(inverted.selectableDates(for: .start).contains(day(2026, 10, 20)))
        XCTAssertTrue(inverted.selectableDates(for: .end).contains(day(2026, 10, 10)))

        var edited = inverted
        edited.pick(day(2026, 10, 18), for: .start)

        XCTAssertEqual(edited.start, day(2026, 10, 10, hour: 23, minute: 59, second: 59))
    }

    func testDatesBeyondTheFarPastAndFutureKeepEveryRangeInOrder() {
        // A hand-edited manifest can hold dates outside distantPast and
        // distantFuture; an inverted ClosedRange would trap.
        let farFuture = Date.distantFuture.addingTimeInterval(1_000 * 365 * 86_400)
        let farPast = Date.distantPast.addingTimeInterval(-365 * 86_400)
        var late = range(start: farFuture, end: nil)
        let early = range(start: nil, end: farPast)

        XCTAssertTrue(late.selectableDates(for: .start).contains(farFuture))
        XCTAssertTrue(late.selectableDates(for: .end).contains(late.pickerDate(for: .end)))
        XCTAssertTrue(early.selectableDates(for: .start).contains(early.pickerDate(for: .start)))
        XCTAssertTrue(early.selectableDates(for: .end).contains(farPast))

        late.setIncluded(true, for: .end)

        XCTAssertEqual(late.end, utc.startOfDay(for: farFuture))
    }

    func testTheEndDayFollowsTheCalendarAcrossADaylightSavingChange() {
        // Clocks in New York go back on 1 November 2026, a 25-hour day.
        let newYork = Self.calendar("America/New_York")
        let end = Self.day(2026, 11, 1, hour: 9, calendar: newYork)
        let range = range(start: Self.day(2026, 10, 1, calendar: newYork), end: end, calendar: newYork)

        let lastStart = range.selectableDates(for: .start).upperBound

        XCTAssertEqual(lastStart.addingTimeInterval(1), Self.day(2026, 11, 2, calendar: newYork))
        XCTAssertEqual(newYork.startOfDay(for: lastStart), newYork.startOfDay(for: end))
    }

    func testTheEndDayStaysOnItsDayWhenTheDayStartsAtOneInTheMorning() {
        // Chile skips midnight on 6 September 2026, so that day starts at
        // 01:00 and the next one at 00:00.
        let santiago = Self.calendar("America/Santiago")
        let end = Self.day(2026, 9, 6, hour: 12, calendar: santiago)
        var range = range(start: Self.day(2026, 9, 1, hour: 12, calendar: santiago), end: end, calendar: santiago)

        let lastStart = range.selectableDates(for: .start).upperBound
        range.pick(Self.day(2026, 9, 7, minute: 30, calendar: santiago), for: .start)

        XCTAssertEqual(lastStart.addingTimeInterval(1), Self.day(2026, 9, 7, calendar: santiago))
        XCTAssertEqual(range.start.map(santiago.startOfDay(for:)), santiago.startOfDay(for: end))
    }

    // MARK: - Query semantics

    func testTheQueryIncludesTheWholeOfTheEditedEndDay() {
        var range = range(start: day(2026, 10, 1, hour: 12), end: day(2026, 10, 3))

        range.pick(day(2026, 10, 14, hour: 7), for: .end)
        let bounds = WorkoutLibraryQueryService.resolveDateBounds(
            filter: range.filter,
            now: day(2026, 10, 15),
            calendar: utc
        )

        XCTAssertEqual(bounds.start, day(2026, 10, 1))
        XCTAssertEqual(bounds.end, day(2026, 10, 15))
        XCTAssertTrue(bounds.endExclusive)
    }

    func testTheQueryLeavesTheOpenSideOfAnEditedRangeUnbounded() {
        var range = range(start: day(2022, 1, 1), end: nil)

        range.pick(day(2023, 6, 1, hour: 12), for: .start)
        let bounds = WorkoutLibraryQueryService.resolveDateBounds(
            filter: range.filter,
            now: day(2026, 10, 15),
            calendar: utc
        )

        XCTAssertEqual(bounds.start, day(2023, 6, 1))
        XCTAssertNil(bounds.end)
    }

    // MARK: - View model

    private func makeWorkout(name: String, start: Date) -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: start),
            source: .gpx,
            summary: RunSummary(totalDistanceMeters: 5_000, totalElapsedSeconds: 1_800)
        )
    }

    /// The Date submenu row `choice`, wired as WorkoutLibraryView wires it.
    private func dateMenuCheck(
        _ choice: WorkoutLibraryDateMenuChoice,
        of vm: WorkoutLibraryViewModel
    ) -> Binding<Bool> {
        choice.menuCheck(
            filter: { vm.dateFilter },
            customRange: { (vm.customDateStart, vm.customDateEnd) },
            setFilter: { vm.dateFilter = $0 }
        )
    }

    private func openCollection(
        start: Date,
        in vm: WorkoutLibraryViewModel = WorkoutLibraryViewModel(calendar: WorkoutLibraryCustomDateRangeTests.utc)
    ) -> (WorkoutLibraryViewModel, WorkoutSmartCollection) {
        let collection = WorkoutSmartCollection(
            name: "Since 2022",
            query: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(date: .custom(start: start, end: nil))
            )
        )
        vm.replaceLibrary(
            workouts: [],
            favoriteIDs: [],
            organization: WorkoutLibraryOrganizationSnapshot(smartCollections: [collection])
        )
        vm.openSmartCollection(id: collection.id)
        return (vm, collection)
    }

    func testTheRowShowsOnlyWhileACustomRangeIsActive() {
        let vm = WorkoutLibraryViewModel(calendar: utc)
        XCTAssertNil(vm.customDateRange)

        vm.dateFilter = .last90Days
        XCTAssertNil(vm.customDateRange)

        vm.dateFilter = .custom(start: vm.customDateStart, end: vm.customDateEnd)
        XCTAssertNotNil(vm.customDateRange)

        vm.clearFilters()
        XCTAssertNil(vm.customDateRange)
    }

    func testOpeningAOneSidedCollectionShowsItsOpenSideOffWithoutModifyingIt() throws {
        let savedStart = day(2022, 1, 1)
        let (vm, collection) = openCollection(start: savedStart)

        let row = try XCTUnwrap(vm.customDateRange)

        XCTAssertTrue(row.includes(.start))
        XCTAssertFalse(row.includes(.end))
        XCTAssertEqual(row.pickerDate(for: .start), savedStart)
        XCTAssertEqual(vm.queryContext, .smartCollection(id: collection.id, isModified: false))
    }

    func testEditingTheStartOfAOneSidedCollectionKeepsItsEndOpenUntilReverted() {
        let savedStart = day(2022, 1, 1)
        let (vm, collection) = openCollection(start: savedStart)
        let newStart = day(2023, 6, 1)

        vm.pickCustomDate(newStart, for: .start)

        XCTAssertEqual(vm.dateFilter, .custom(start: newStart, end: nil))
        XCTAssertEqual(vm.currentSavedQuery().filter.date, .custom(start: newStart, end: nil))
        XCTAssertEqual(vm.customDateStart, newStart)
        XCTAssertEqual(vm.queryContext, .smartCollection(id: collection.id, isModified: true))

        vm.revertActiveCollection()

        XCTAssertEqual(vm.dateFilter, .custom(start: savedStart, end: nil))
        XCTAssertEqual(vm.customDateRange?.pickerDate(for: .start), savedStart)
        XCTAssertEqual(vm.queryContext, .smartCollection(id: collection.id, isModified: false))
    }

    func testTurningOnTheOpenSideOfACollectionRangeAppliesTheRememberedDate() {
        let savedStart = day(2022, 1, 1)
        let (vm, collection) = openCollection(start: savedStart)
        let rememberedEnd = vm.customDateEnd

        vm.setCustomDateBound(.end, isIncluded: true)

        XCTAssertEqual(vm.dateFilter, .custom(start: savedStart, end: rememberedEnd))
        XCTAssertEqual(vm.queryContext, .smartCollection(id: collection.id, isModified: true))
    }

    func testAnEditThatChangesNothingLeavesACollectionUnmodified() {
        let savedStart = day(2022, 1, 1)
        let (vm, collection) = openCollection(start: savedStart)

        vm.pickCustomDate(savedStart, for: .start)
        vm.setCustomDateBound(.start, isIncluded: false)
        vm.setCustomDateBound(.end, isIncluded: false)

        XCTAssertEqual(vm.dateFilter, .custom(start: savedStart, end: nil))
        XCTAssertEqual(vm.queryContext, .smartCollection(id: collection.id, isModified: false))
    }

    /// A view model whose remembered custom dates do not depend on today.
    private func makeViewModel() -> WorkoutLibraryViewModel {
        let vm = WorkoutLibraryViewModel(calendar: utc)
        vm.customDateStart = day(2026, 1, 1)
        vm.customDateEnd = day(2026, 12, 31)
        return vm
    }

    func testEditsKeepCustomDateRangeCheckedAndChoosingItAgainAppliesTheRowsDates() {
        let vm = makeViewModel()
        let custom = dateMenuCheck(.customRange, of: vm)
        custom.wrappedValue = true
        let start = day(2026, 3, 1)
        let end = day(2026, 3, 31)

        vm.pickCustomDate(start, for: .start)
        vm.pickCustomDate(end, for: .end)

        XCTAssertEqual(vm.dateFilter, .custom(start: start, end: end))
        XCTAssertTrue(custom.wrappedValue)

        dateMenuCheck(.allTime, of: vm).wrappedValue = true
        XCTAssertNil(vm.customDateRange)
        custom.wrappedValue = true

        XCTAssertEqual(vm.dateFilter, .custom(start: start, end: end))
    }

    func testCustomDateRangeNeverAppliesARangeThatEndsBeforeItStarts() {
        // From moves past the remembered To while To is off.
        let vm = makeViewModel()
        let custom = dateMenuCheck(.customRange, of: vm)
        custom.wrappedValue = true
        vm.pickCustomDate(day(2026, 3, 1), for: .start)
        vm.pickCustomDate(day(2026, 3, 31), for: .end)
        vm.setCustomDateBound(.end, isIncluded: false)
        vm.pickCustomDate(day(2026, 6, 1), for: .start)

        // Choosing the checked row again, and choosing it after a preset,
        // both apply the dates the row shows.
        custom.wrappedValue = false
        XCTAssertEqual(vm.dateFilter, .custom(start: day(2026, 6, 1), end: day(2026, 6, 1)))
        dateMenuCheck(.last30Days, of: vm).wrappedValue = true
        custom.wrappedValue = true
        XCTAssertEqual(vm.dateFilter, .custom(start: day(2026, 6, 1), end: day(2026, 6, 1)))
    }

    func testOpeningACollectionThatStartsAfterTheRememberedEndKeepsTheDatesInOrder() {
        let vm = WorkoutLibraryViewModel(calendar: utc)
        vm.customDateStart = day(2026, 1, 1)
        vm.customDateEnd = day(2026, 1, 31)
        let (_, collection) = openCollection(start: day(2026, 3, 1), in: vm)

        XCTAssertEqual(vm.customDateStart, day(2026, 3, 1))
        XCTAssertEqual(vm.customDateEnd, day(2026, 3, 1))
        XCTAssertEqual(vm.queryContext, .smartCollection(id: collection.id, isModified: false))

        dateMenuCheck(.customRange, of: vm).wrappedValue = false

        XCTAssertEqual(vm.dateFilter, .custom(start: day(2026, 3, 1), end: day(2026, 3, 1)))
    }

    func testRestoringAOneSidedManualRangeKeepsTheDatesInOrder() {
        let vm = WorkoutLibraryViewModel(calendar: utc)
        vm.customDateStart = day(2026, 1, 1)
        vm.customDateEnd = day(2026, 1, 31)

        vm.restoreSessionState(
            manualQuery: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(date: .custom(start: day(2026, 3, 1), end: nil))
            ),
            activeSmartCollectionID: nil,
            activeSmartCollectionModified: false,
            modifiedWorkingQuery: nil
        )

        XCTAssertEqual(vm.dateFilter, .custom(start: day(2026, 3, 1), end: nil))
        XCTAssertEqual(vm.customDateEnd, day(2026, 3, 1))
    }

    func testATrendsPeriodShowsItsLastDayInTheToPicker() throws {
        let vm = WorkoutLibraryViewModel(calendar: utc)

        vm.applyTrendsPeriodFilter(start: day(2026, 9, 1), end: day(2026, 10, 1))

        let row = try XCTUnwrap(vm.customDateRange)
        XCTAssertEqual(row.pickerDate(for: .start), day(2026, 9, 1))
        XCTAssertEqual(row.pickerDate(for: .end), day(2026, 9, 30, hour: 23, minute: 59, second: 59))
    }

    func testTheEditedRangeShowsRunsOnItsWholeFirstAndLastDays() async {
        let vm = makeViewModel()
        let dayBefore = makeWorkout(name: "Day before", start: day(2026, 2, 28, hour: 23, minute: 50))
        let firstDay = makeWorkout(name: "First day", start: day(2026, 3, 1, hour: 0, minute: 10))
        let lastDay = makeWorkout(name: "Last day", start: day(2026, 3, 31, hour: 23, minute: 30))
        let dayAfter = makeWorkout(name: "Day after", start: day(2026, 4, 1, hour: 0, minute: 30))
        vm.replaceLibrary(workouts: [dayBefore, firstDay, lastDay, dayAfter], favoriteIDs: [])
        vm.dateFilter = .custom(start: vm.customDateStart, end: vm.customDateEnd)

        vm.pickCustomDate(day(2026, 3, 1, hour: 12), for: .start)
        vm.pickCustomDate(day(2026, 3, 31, hour: 9), for: .end)

        for _ in 0..<200 {
            if vm.loadState == .ready, vm.filteredCount == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Set(vm.resultIDs), [firstDay.id, lastDay.id])
    }
}
