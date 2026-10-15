import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// The All Runs Filters menu's one-of-many rows: Date's presets and Custom
/// Date Range…, Tags' Any Tags and Untagged Only, and Route's Any Route and
/// Not on a Route. Which row is checked, and what choosing a row does.
@MainActor
final class WorkoutLibraryFilterMenuChoiceTests: XCTestCase {
    private let pickerStart = Date(timeIntervalSince1970: 1_700_000_000)
    private let pickerEnd = Date(timeIntervalSince1970: 1_702_000_000)
    private let savedStart = Date(timeIntervalSince1970: 1_690_000_000)
    private let hills = UUID()
    private let tempo = UUID()

    // MARK: - Date

    private func checkedDateRows(for filter: WorkoutLibraryDateFilter) -> [WorkoutLibraryDateMenuChoice] {
        let range = (start: pickerStart, end: pickerEnd)
        return WorkoutLibraryDateMenuChoice.allCases.filter { choice in
            choice.menuCheck(filter: { filter }, customRange: { range }, setFilter: { _ in }).wrappedValue
        }
    }

    func testEachDateFilterChecksOnlyItsOwnRow() {
        let expected: [(WorkoutLibraryDateFilter, WorkoutLibraryDateMenuChoice)] = [
            (.allTime, .allTime),
            (.last30Days, .last30Days),
            (.last90Days, .last90Days),
            (.currentCalendarYear, .currentCalendarYear),
            (.custom(start: pickerStart, end: pickerEnd), .customRange),
        ]
        for (filter, row) in expected {
            XCTAssertEqual(checkedDateRows(for: filter), [row], "\(filter)")
        }
    }

    func testEveryCustomRangeChecksCustomDateRange() {
        // A smart collection can hold a one-sided range, and a range with
        // neither bound still counts as a filter and shows the date pickers.
        for filter in [
            WorkoutLibraryDateFilter.custom(start: savedStart, end: nil),
            .custom(start: nil, end: pickerEnd),
            .custom(start: nil, end: nil),
        ] {
            XCTAssertEqual(checkedDateRows(for: filter), [.customRange], "\(filter)")
        }
    }

    func testChoosingADatePresetAppliesItAndMovesTheCheck() {
        var filter = WorkoutLibraryDateFilter.allTime
        let range = (start: pickerStart, end: pickerEnd)
        let allTime = WorkoutLibraryDateMenuChoice.allTime.menuCheck(
            filter: { filter }, customRange: { range }, setFilter: { filter = $0 }
        )
        let last90Days = WorkoutLibraryDateMenuChoice.last90Days.menuCheck(
            filter: { filter }, customRange: { range }, setFilter: { filter = $0 }
        )
        XCTAssertTrue(allTime.wrappedValue)

        last90Days.wrappedValue = true

        XCTAssertEqual(filter, .last90Days)
        XCTAssertTrue(last90Days.wrappedValue)
        XCTAssertFalse(allTime.wrappedValue)
    }

    func testChoosingCustomDateRangeAppliesThePickersDatesWhenChosen() {
        var filter = WorkoutLibraryDateFilter.last30Days
        var range = (start: pickerStart, end: pickerEnd)
        let custom = WorkoutLibraryDateMenuChoice.customRange.menuCheck(
            filter: { filter }, customRange: { range }, setFilter: { filter = $0 }
        )
        let later = pickerEnd.addingTimeInterval(86_400)
        range.end = later

        custom.wrappedValue = true

        XCTAssertEqual(filter, .custom(start: pickerStart, end: later))
        XCTAssertTrue(custom.wrappedValue)
    }

    func testChoosingTheCheckedDatePresetAppliesItAgain() {
        // A menu sends `false` when its checked Toggle row is chosen again.
        var filter = WorkoutLibraryDateFilter.last90Days
        var writes: [WorkoutLibraryDateFilter] = []
        let range = (start: pickerStart, end: pickerEnd)
        let last90Days = WorkoutLibraryDateMenuChoice.last90Days.menuCheck(
            filter: { filter },
            customRange: { range },
            setFilter: {
                writes.append($0)
                filter = $0
            }
        )

        last90Days.wrappedValue = false

        XCTAssertEqual(writes, [.last90Days], "the Button applied the preset again too")
        XCTAssertTrue(last90Days.wrappedValue)
    }

    func testChoosingTheCheckedCustomRowAppliesThePickersDatesAgain() {
        // As the Button did, the pickers' dates replace a one-sided range.
        var filter = WorkoutLibraryDateFilter.custom(start: savedStart, end: nil)
        let range = (start: pickerStart, end: pickerEnd)
        let custom = WorkoutLibraryDateMenuChoice.customRange.menuCheck(
            filter: { filter }, customRange: { range }, setFilter: { filter = $0 }
        )
        XCTAssertTrue(custom.wrappedValue)

        custom.wrappedValue = false

        XCTAssertEqual(filter, .custom(start: pickerStart, end: pickerEnd))
        XCTAssertTrue(custom.wrappedValue)
    }

    func testChoosingTheCheckedDateRowStillEditsAnOpenSmartCollection() {
        let collection = WorkoutSmartCollection(
            name: "Since spring",
            query: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(date: .custom(start: savedStart, end: nil))
            )
        )
        let vm = WorkoutLibraryViewModel()
        vm.replaceLibrary(
            workouts: [],
            favoriteIDs: [],
            organization: WorkoutLibraryOrganizationSnapshot(smartCollections: [collection])
        )
        vm.openSmartCollection(id: collection.id)
        XCTAssertEqual(vm.queryContext, .smartCollection(id: collection.id, isModified: false))
        // Wired as WorkoutLibraryView wires the Custom Date Range… row.
        let custom = WorkoutLibraryDateMenuChoice.customRange.menuCheck(
            filter: { vm.dateFilter },
            customRange: { (vm.customDateStart, vm.customDateEnd) },
            setFilter: { vm.dateFilter = $0 }
        )
        XCTAssertTrue(custom.wrappedValue)

        custom.wrappedValue = false

        // The collection's start fills the From picker; the To picker keeps
        // its own date, which now bounds the range.
        XCTAssertEqual(vm.dateFilter, .custom(start: savedStart, end: vm.customDateEnd))
        XCTAssertEqual(vm.queryContext, .smartCollection(id: collection.id, isModified: true))
        XCTAssertTrue(custom.wrappedValue)
    }

    // MARK: - Tags

    private func checkedTagRows(for filter: WorkoutLibraryTagFilter) -> [WorkoutLibraryTagMenuChoice] {
        WorkoutLibraryTagMenuChoice.allCases.filter { choice in
            choice.menuCheck(filter: { filter }, setFilter: { _ in }).wrappedValue
        }
    }

    func testAnyTagsAndUntaggedOnlyEachCheckOnlyTheirOwnFilter() {
        XCTAssertEqual(checkedTagRows(for: .anyTags), [.anyTags])
        XCTAssertEqual(checkedTagRows(for: .untaggedOnly), [.untaggedOnly])
    }

    func testNeitherTagRowIsCheckedWhileTagsAreSelected() {
        // The Match Any Selected and Match All Selected submenus mark them.
        for filter in [
            WorkoutLibraryTagFilter.selected(tagIDs: [hills], match: .any),
            .selected(tagIDs: [hills, tempo], match: .all),
        ] {
            XCTAssertEqual(checkedTagRows(for: filter), [], "\(filter)")
        }
    }

    func testAnEmptyTagSelectionChecksAnyTags() {
        // An empty selection restricts nothing, as Any Tags does.
        XCTAssertEqual(checkedTagRows(for: .selected(tagIDs: [], match: .all)), [.anyTags])
    }

    func testChoosingATagRowAppliesItsFilterEvenWhenChecked() {
        var filter = WorkoutLibraryTagFilter.selected(tagIDs: [hills], match: .all)
        var writes: [WorkoutLibraryTagFilter] = []
        let setFilter: @MainActor (WorkoutLibraryTagFilter) -> Void = {
            writes.append($0)
            filter = $0
        }
        let anyTags = WorkoutLibraryTagMenuChoice.anyTags.menuCheck(filter: { filter }, setFilter: setFilter)
        let untaggedOnly = WorkoutLibraryTagMenuChoice.untaggedOnly.menuCheck(
            filter: { filter }, setFilter: setFilter
        )

        untaggedOnly.wrappedValue = true
        XCTAssertTrue(untaggedOnly.wrappedValue)
        XCTAssertFalse(anyTags.wrappedValue)

        anyTags.wrappedValue = true
        anyTags.wrappedValue = false

        XCTAssertEqual(writes, [.untaggedOnly, .anyTags, .anyTags])
        XCTAssertTrue(anyTags.wrappedValue)
        XCTAssertFalse(untaggedOnly.wrappedValue)
    }

    // MARK: - Route

    private func checkedRouteRows(for filter: WorkoutLibraryRouteFilter) -> [WorkoutLibraryRouteMenuChoice] {
        WorkoutLibraryRouteMenuChoice.allCases.filter { choice in
            choice.menuCheck(filter: { filter }, setFilter: { _ in }).wrappedValue
        }
    }

    func testAnyRouteAndNotOnARouteEachCheckOnlyTheirOwnFilter() {
        XCTAssertEqual(checkedRouteRows(for: .anyRoute), [.anyRoute])
        XCTAssertEqual(checkedRouteRows(for: .ungroupedOnly), [.ungroupedOnly])
    }

    func testNeitherRouteRowIsCheckedWhileOneRouteIsTheFilter() {
        // That route's own row is checked instead.
        XCTAssertEqual(checkedRouteRows(for: .group(UUID())), [])
    }

    func testChoosingARouteRowAppliesItsFilterEvenWhenChecked() {
        var filter = WorkoutLibraryRouteFilter.group(UUID())
        var writes: [WorkoutLibraryRouteFilter] = []
        let setFilter: @MainActor (WorkoutLibraryRouteFilter) -> Void = {
            writes.append($0)
            filter = $0
        }
        let anyRoute = WorkoutLibraryRouteMenuChoice.anyRoute.menuCheck(filter: { filter }, setFilter: setFilter)
        let ungroupedOnly = WorkoutLibraryRouteMenuChoice.ungroupedOnly.menuCheck(
            filter: { filter }, setFilter: setFilter
        )

        ungroupedOnly.wrappedValue = true
        ungroupedOnly.wrappedValue = false
        XCTAssertTrue(ungroupedOnly.wrappedValue)

        anyRoute.wrappedValue = true

        XCTAssertEqual(writes, [.ungroupedOnly, .ungroupedOnly, .anyRoute])
        XCTAssertTrue(anyRoute.wrappedValue)
        XCTAssertFalse(ungroupedOnly.wrappedValue)
    }
}
