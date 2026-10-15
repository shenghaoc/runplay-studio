import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// The All Runs Tags filter's Match Any Selected and Match All Selected
/// submenus: which rows are checked, and what choosing a row does.
@MainActor
final class WorkoutLibraryTagFilterMenuTests: XCTestCase {
    private let hills = UUID()
    private let tempo = UUID()
    private let race = UUID()

    // MARK: - Check marks

    func testEachSubmenuChecksOnlyTheTagsSelectedUnderItsMatchMode() {
        let filter = WorkoutLibraryTagFilter.selected(tagIDs: [hills, tempo], match: .all)

        XCTAssertTrue(filter.selects(hills, match: .all))
        XCTAssertTrue(filter.selects(tempo, match: .all))
        XCTAssertFalse(filter.selects(race, match: .all))
        for tag in [hills, tempo, race] {
            XCTAssertFalse(filter.selects(tag, match: .any), "the other submenu checks nothing")
        }
    }

    func testNoTagIsCheckedWithoutATagSelection() {
        for filter in [WorkoutLibraryTagFilter.anyTags, .untaggedOnly] {
            for match in [WorkoutLibraryTagMatchMode.any, .all] {
                XCTAssertFalse(filter.selects(hills, match: match), "\(filter) \(match)")
            }
        }
    }

    // MARK: - Choosing a tag

    func testChoosingTagsUnderOneMatchModeAddsAndRemovesThem() {
        var filter = WorkoutLibraryTagFilter.anyTags

        filter = filter.togglingTag(hills, match: .any)
        XCTAssertEqual(filter, .selected(tagIDs: [hills], match: .any))
        filter = filter.togglingTag(tempo, match: .any)
        XCTAssertEqual(filter, .selected(tagIDs: [hills, tempo], match: .any))
        filter = filter.togglingTag(hills, match: .any)
        XCTAssertEqual(filter, .selected(tagIDs: [tempo], match: .any))
    }

    func testRemovingTheLastSelectedTagClearsTheTagFilter() {
        let filter = WorkoutLibraryTagFilter.selected(tagIDs: [race], match: .all)

        XCTAssertEqual(filter.togglingTag(race, match: .all), .anyTags)
    }

    func testChoosingATagUnderTheOtherMatchModeRestartsTheSelection() {
        let filter = WorkoutLibraryTagFilter.selected(tagIDs: [hills, tempo], match: .any)

        XCTAssertEqual(filter.togglingTag(hills, match: .all), .selected(tagIDs: [hills], match: .all))
        XCTAssertEqual(filter.togglingTag(race, match: .all), .selected(tagIDs: [race], match: .all))
    }

    func testChoosingATagAfterUntaggedOnlySelectsJustThatTag() {
        XCTAssertEqual(
            WorkoutLibraryTagFilter.untaggedOnly.togglingTag(race, match: .any),
            .selected(tagIDs: [race], match: .any)
        )
    }

    // MARK: - Toggle binding

    func testChoosingAnUncheckedRowAddsItsTagAndChoosingACheckedRowRemovesIt() {
        var filter = WorkoutLibraryTagFilter.anyTags
        let hillsRow = WorkoutLibraryTagFilter.menuCheck(
            for: hills, match: .any, filter: { filter }, setFilter: { filter = $0 }
        )
        let tempoRow = WorkoutLibraryTagFilter.menuCheck(
            for: tempo, match: .any, filter: { filter }, setFilter: { filter = $0 }
        )
        XCTAssertFalse(hillsRow.wrappedValue)

        hillsRow.wrappedValue = true
        tempoRow.wrappedValue = true

        XCTAssertEqual(filter, .selected(tagIDs: [hills, tempo], match: .any))
        XCTAssertTrue(hillsRow.wrappedValue)
        XCTAssertTrue(tempoRow.wrappedValue)

        // A menu sends `false` when its checked Toggle row is chosen again.
        hillsRow.wrappedValue = false

        XCTAssertEqual(filter, .selected(tagIDs: [tempo], match: .any))
        XCTAssertFalse(hillsRow.wrappedValue)
        XCTAssertTrue(tempoRow.wrappedValue)

        tempoRow.wrappedValue = false

        XCTAssertEqual(filter, .anyTags)
        XCTAssertFalse(tempoRow.wrappedValue)
    }

    func testAWriteThatMatchesTheCheckMarkLeavesTheFilterAlone() {
        var filter = WorkoutLibraryTagFilter.selected(tagIDs: [hills], match: .any)
        var writes: [WorkoutLibraryTagFilter] = []
        let setFilter: @MainActor (WorkoutLibraryTagFilter) -> Void = {
            writes.append($0)
            filter = $0
        }
        let hillsRow = WorkoutLibraryTagFilter.menuCheck(
            for: hills, match: .any, filter: { filter }, setFilter: setFilter
        )
        let tempoRow = WorkoutLibraryTagFilter.menuCheck(
            for: tempo, match: .any, filter: { filter }, setFilter: setFilter
        )

        hillsRow.wrappedValue = true
        tempoRow.wrappedValue = false

        XCTAssertEqual(writes, [])
        XCTAssertEqual(filter, .selected(tagIDs: [hills], match: .any))
    }

    func testCheckingARowUnderTheOtherMatchModeMovesTheChecksThere() {
        var filter = WorkoutLibraryTagFilter.selected(tagIDs: [hills, tempo], match: .any)
        let hillsAll = WorkoutLibraryTagFilter.menuCheck(
            for: hills, match: .all, filter: { filter }, setFilter: { filter = $0 }
        )
        let hillsAny = WorkoutLibraryTagFilter.menuCheck(
            for: hills, match: .any, filter: { filter }, setFilter: { filter = $0 }
        )
        let tempoAny = WorkoutLibraryTagFilter.menuCheck(
            for: tempo, match: .any, filter: { filter }, setFilter: { filter = $0 }
        )
        XCTAssertFalse(hillsAll.wrappedValue)

        hillsAll.wrappedValue = true

        XCTAssertEqual(filter, .selected(tagIDs: [hills], match: .all))
        XCTAssertTrue(hillsAll.wrappedValue)
        XCTAssertFalse(hillsAny.wrappedValue)
        XCTAssertFalse(tempoAny.wrappedValue)
    }

    func testRowsFollowTheFilterWhenItChangesElsewhere() {
        // Any Tags, Untagged Only, and Clear Filters set the filter directly.
        var filter = WorkoutLibraryTagFilter.selected(tagIDs: [race], match: .all)
        let raceRow = WorkoutLibraryTagFilter.menuCheck(
            for: race, match: .all, filter: { filter }, setFilter: { filter = $0 }
        )
        XCTAssertTrue(raceRow.wrappedValue)

        filter = .untaggedOnly

        XCTAssertFalse(raceRow.wrappedValue)
    }
}
