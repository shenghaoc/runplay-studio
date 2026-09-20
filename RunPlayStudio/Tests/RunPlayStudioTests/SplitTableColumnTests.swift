import XCTest
@testable import RunPlayStudio

/// Which columns the distance-splits table shows.
///
/// Regression context: Power and Elapsed Pace were once mutually exclusive.
/// `TableColumnBuilder` accepts at most ten *direct* children and the table
/// already had ten, so adding Power displaced Elapsed Pace — the app silently
/// dropped a column the user relied on because a different column appeared.
/// That is a result-builder limit, not a `Table` limit; wrapping columns in
/// `Group` lifts it. These tests pin the outcome so the trade-off cannot
/// quietly come back.
final class SplitTableColumnTests: XCTestCase {

    /// The regression this fix exists for.
    func testPowerWorkoutStillExposesElapsedPace() {
        let columns = SplitTableColumn.visibleColumns(showsPower: true)

        XCTAssertTrue(
            columns.contains(.elapsedPace),
            "Power must not displace Elapsed Pace: \(columns)"
        )
        XCTAssertTrue(columns.contains(.power))
    }

    /// Power is additive — it adds a column rather than swapping one out, so
    /// the power table is exactly the no-power table plus Power.
    func testPowerIsAdditiveNotASubstitution() {
        let withoutPower = SplitTableColumn.visibleColumns(showsPower: false)
        let withPower = SplitTableColumn.visibleColumns(showsPower: true)

        XCTAssertEqual(withPower.count, withoutPower.count + 1)
        XCTAssertEqual(withPower.filter { $0 != .power }, withoutPower)
    }

    /// Eleven columns is the point: it is more than the ten a
    /// `TableColumnBuilder` accepts as direct children, which is why the view
    /// wraps them in `Group`. If this drops back to ten, the grouping was
    /// probably removed and Power is displacing something again.
    func testPowerTableExceedsTheTenColumnBuilderLimit() {
        let columns = SplitTableColumn.visibleColumns(showsPower: true)

        XCTAssertEqual(columns.count, 11)
        XCTAssertGreaterThan(
            columns.count,
            10,
            "the table must be able to exceed TableColumnBuilder's ten direct children"
        )
    }

    /// Power is the only conditional column; nothing else depends on the
    /// workout's contents, so a no-power workout loses Power and nothing else.
    func testPowerIsTheOnlyConditionalColumn() {
        let withoutPower = SplitTableColumn.visibleColumns(showsPower: false)

        XCTAssertFalse(withoutPower.contains(.power))
        XCTAssertEqual(withoutPower.count, SplitTableColumn.allCases.count - 1)
        for column in SplitTableColumn.allCases where column != .power {
            XCTAssertTrue(withoutPower.contains(column), "missing \(column)")
        }
    }

    /// Display order is stable and matches the declaration order in the view.
    /// Order is also what the saved customization is expressed against.
    func testColumnOrderIsStable() {
        XCTAssertEqual(SplitTableColumn.visibleColumns(showsPower: true), [
            .split, .distance, .elapsed, .active, .moving,
            .movingPace, .activePace, .elapsedPace, .power,
            .heartRate, .elevation,
        ])
    }

    /// The raw values are persisted as customization IDs in UserDefaults, so
    /// renaming a case silently orphans a user's saved column layout.
    func testCustomizationIDsAreStable() {
        XCTAssertEqual(SplitTableColumn.elapsedPace.rawValue, "elapsedPace")
        XCTAssertEqual(SplitTableColumn.power.rawValue, "power")
        XCTAssertEqual(
            SplitTableColumn.customizationDefaultsKey,
            "splitTable.columnCustomization"
        )
        XCTAssertEqual(
            Set(SplitTableColumn.allCases.map(\.rawValue)).count,
            SplitTableColumn.allCases.count,
            "customization IDs must be unique"
        )
    }
}
