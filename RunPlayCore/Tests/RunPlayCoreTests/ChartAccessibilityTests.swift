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

    // A VoiceOver user hears the descriptor's Range/Average on the same
    // screen a sighted user reads Max Power in the Power & Running Dynamics
    // panel. The panel shows raw max; the chart line is smoothed, so
    // aggregating the smoothed series contradicts the panel. Passing the
    // raw series through `aggregatesFromValues` pins the descriptor to the
    // raw extremes while the plot keeps its smoothed shape.
    func testAggregatesFromValuesOverrideMinMaxAverageWhilePlotStructureIsUnchanged() {
        let smoothedPlotSeries: [Double] = [400, 500, 600, 685.20, 660, 500, 400]
        let rawSameShape: [Double] = [400, 520, 640, 704, 700, 500, 400]
        let seriesIDs = Array(repeating: 1, count: smoothedPlotSeries.count)

        let smoothedOnly = ChartAccessibilityModel.make(
            metricName: "Power",
            unit: "W",
            values: smoothedPlotSeries,
            seriesIDs: seriesIDs,
            currentValue: nil,
            totalDistanceMeters: 3_000
        )
        XCTAssertEqual(smoothedOnly.series.maximum, 685.20)
        XCTAssertTrue(smoothedOnly.spokenSummary.contains("to 685.20 W"))

        let overridden = ChartAccessibilityModel.make(
            metricName: "Power",
            unit: "W",
            values: smoothedPlotSeries,
            seriesIDs: seriesIDs,
            currentValue: nil,
            totalDistanceMeters: 3_000,
            aggregatesFromValues: rawSameShape
        )
        XCTAssertEqual(overridden.series.minimum, 400)
        XCTAssertEqual(overridden.series.maximum, 704)
        XCTAssertEqual(overridden.series.average, rawSameShape.reduce(0, +) / Double(rawSameShape.count))
        XCTAssertTrue(overridden.spokenSummary.contains("Range 400.00 W to 704.00 W"))
        // Plot structure stays anchored to `values`: pointCount/gapCount come
        // from the smoothed series, not the override.
        XCTAssertEqual(overridden.series.pointCount, smoothedPlotSeries.count)
        XCTAssertEqual(overridden.series.seriesCount, 1)
        XCTAssertEqual(overridden.gapCount, 0)
    }

    func testAggregatesFromValuesEmptyKeepsSeriesMissingFromValues() {
        // If the override happens to be empty (all invalid), the descriptor
        // should still report missing rather than fall back to the smoothed
        // series' aggregates — an empty raw series is the honest state.
        let smoothedPlotSeries: [Double] = [300, 320, 310]
        let model = ChartAccessibilityModel.make(
            metricName: "Power",
            unit: "W",
            values: smoothedPlotSeries,
            seriesIDs: [1, 1, 1],
            currentValue: nil,
            totalDistanceMeters: 1_500,
            aggregatesFromValues: []
        )
        XCTAssertNil(model.series.minimum)
        XCTAssertNil(model.series.maximum)
        XCTAssertNil(model.series.average)
        XCTAssertFalse(model.series.missingData) // plot still has data
    }
}
