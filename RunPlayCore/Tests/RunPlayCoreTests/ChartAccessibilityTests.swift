import XCTest
@testable import RunPlayCore

final class ChartAccessibilityTests: XCTestCase {

    func testPaceSeriesUnits() {
        let model = ChartAccessibilityModel.make(
            metricName: "Active Pace",
            unit: "s/km",
            values: [280, 300, 320],
            seriesIDs: [1, 1, 1],
            currentValue: 300,
            totalDistanceMeters: 3000
        )
        XCTAssertEqual(model.yAxisUnit, "s/km")
        XCTAssertTrue(model.spokenSummary.contains("per kilometre") || model.spokenSummary.contains("Average"))
    }

    func testElevationHeartRateAndSpeed() {
        for (name, unit, values) in [
            ("Elevation", "m", [12.0, 18.0, 15.0]),
            ("Heart Rate", "bpm", [130.0, 145.0, 150.0]),
            ("Speed", "m/s", [2.5, 3.1, 2.8])
        ] as [(String, String, [Double])] {
            let model = ChartAccessibilityModel.make(
                metricName: name,
                unit: unit,
                values: values,
                seriesIDs: Array(repeating: 1, count: values.count),
                currentValue: values[1],
                totalDistanceMeters: 2000
            )
            XCTAssertEqual(model.title, "\(name) chart")
            XCTAssertEqual(model.series.unit, unit)
            XCTAssertFalse(model.series.missingData)
            XCTAssertNotNil(model.series.average)
        }
    }

    func testComparisonStyleMissingSeries() {
        let model = ChartAccessibilityModel.make(
            metricName: "Pace Delta",
            unit: "s/km",
            values: [],
            seriesIDs: [],
            currentValue: nil,
            totalDistanceMeters: 0
        )
        XCTAssertTrue(model.series.missingData)
        XCTAssertEqual(model.gapCount, 0)
    }

    func testRouteGapsIncreaseSeriesCount() {
        let model = ChartAccessibilityModel.make(
            metricName: "Speed",
            unit: "m/s",
            values: [1, 2, 3, 4, 5],
            seriesIDs: [1, 1, 2, 3, 3],
            currentValue: 3,
            totalDistanceMeters: 4000
        )
        XCTAssertEqual(model.series.seriesCount, 3)
        XCTAssertEqual(model.gapCount, 2)
    }

    func testReplayValueUpdatePreservesCachedAggregates() {
        let base = ChartAccessibilityModel.make(
            metricName: "Speed",
            unit: "m/s",
            values: [1, 2, 3],
            seriesIDs: [1, 1, 1],
            currentValue: nil,
            totalDistanceMeters: 1_000
        )

        let updated = base.updatingCurrentValue(2.5)

        XCTAssertEqual(updated.series.minimum, base.series.minimum)
        XCTAssertEqual(updated.series.maximum, base.series.maximum)
        XCTAssertEqual(updated.series.average, base.series.average)
        XCTAssertEqual(updated.series.currentValue, 2.5)
    }

    func testBoundedRepresentationDoesNotRequirePerPointElements() {
        // The pure model holds aggregate facts only; UI downsampling is separate.
        let values = (0..<10_000).map { Double($0 % 50) }
        let model = ChartAccessibilityModel.make(
            metricName: "Elevation",
            unit: "m",
            values: values,
            seriesIDs: Array(repeating: 1, count: values.count),
            currentValue: 10,
            totalDistanceMeters: 20_000
        )
        XCTAssertEqual(model.series.pointCount, 10_000)
        XCTAssertTrue(model.spokenSummary.count < 500)
    }
}
