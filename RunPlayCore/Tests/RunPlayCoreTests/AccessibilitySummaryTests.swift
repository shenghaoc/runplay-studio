import XCTest
@testable import RunPlayCore

final class AccessibilitySummaryTests: XCTestCase {

    func testRouteSummaryWithoutGPS() {
        let summary = RouteAccessibilitySummary.make(routePoints: [])
        XCTAssertEqual(summary.spokenSummary, "No GPS route available.")
    }

    func testRouteSummaryIncludesSegmentsAndReplay() {
        let points = samplePoints(count: 10, segments: 2)
        let summary = RouteAccessibilitySummary.make(
            routePoints: points,
            currentDistanceMeters: 50,
            colorModeName: "Pace",
            coverageFraction: 0.8
        )
        let spoken = summary.spokenSummary
        XCTAssertTrue(spoken.contains("Colour mode Pace"))
        XCTAssertTrue(spoken.contains("2 disconnected route sections"))
        XCTAssertTrue(spoken.contains("Replay position"))
        XCTAssertTrue(spoken.contains("80 percent"))
    }

    func testComparisonSummaryUsesTextualIdentity() {
        let summary = ComparisonAccessibilitySummary(
            primaryName: "Morning",
            comparisonName: "Evening",
            commonDistanceMeters: 5000,
            selectedDistanceMeters: 2500,
            primaryTimeLabel: "12:00",
            comparisonTimeLabel: "12:30",
            deltaLabel: "+0:30",
            warnings: ["Different distances"]
        )
        let spoken = summary.spokenSummary
        XCTAssertTrue(spoken.contains("Primary P: Morning"))
        XCTAssertTrue(spoken.contains("Comparison C: Evening"))
        XCTAssertTrue(spoken.contains("Different distances"))
        XCTAssertFalse(spoken.lowercased().contains("blue"))
        XCTAssertFalse(spoken.lowercased().contains("orange"))
    }

    func testHeatmapSummary() {
        let summary = HeatmapAccessibilitySummary(
            includedRunCount: 12,
            totalDistanceMeters: 42_000,
            maximumOverlap: 4,
            requestedCellSizeMeters: 25,
            effectiveCellSizeMeters: 50,
            dateFilterDescription: "Last 30 Days",
            minimumRepeatCount: 2
        )
        let spoken = summary.spokenSummary
        XCTAssertTrue(spoken.contains("12 runs"))
        XCTAssertTrue(spoken.contains("Maximum overlap 4"))
        XCTAssertTrue(spoken.contains("increased"))
        XCTAssertTrue(spoken.contains("Minimum 2 runs"))
    }

    func testTagMixedStateWording() {
        XCTAssertEqual(TagSelectionAccessibilityState.unchecked.spokenValue, "Unchecked")
        XCTAssertEqual(TagSelectionAccessibilityState.checked.spokenValue, "Checked")
        XCTAssertEqual(TagSelectionAccessibilityState.mixed.spokenValue, "Mixed")
    }

    func testChartModelMissingData() {
        let model = ChartAccessibilityModel.make(
            metricName: "Heart Rate",
            unit: "bpm",
            values: [],
            seriesIDs: [],
            currentValue: nil,
            totalDistanceMeters: 5000
        )
        XCTAssertTrue(model.spokenSummary.contains("No data available"))
        XCTAssertTrue(model.series.missingData)
    }

    func testChartModelSummaryAndGaps() {
        let model = ChartAccessibilityModel.make(
            metricName: "Active Pace",
            unit: "s/km",
            values: [300, 310, 290, 305],
            seriesIDs: [1, 1, 2, 2],
            currentValue: 300,
            totalDistanceMeters: 5000
        )
        XCTAssertEqual(model.gapCount, 1)
        XCTAssertFalse(model.series.missingData)
        XCTAssertEqual(model.series.minimum, 290)
        XCTAssertEqual(model.series.maximum, 310)
        XCTAssertTrue(model.spokenSummary.contains("recording gaps"))
        XCTAssertTrue(model.spokenSummary.contains("Average"))
    }

    func testChartModelIgnoresNonFiniteValues() {
        let model = ChartAccessibilityModel.make(
            metricName: "Elevation",
            unit: "m",
            values: [10, .nan, .infinity, 20],
            seriesIDs: [1, 1, 1, 1],
            currentValue: .nan,
            totalDistanceMeters: 1000
        )
        XCTAssertEqual(model.series.pointCount, 2)
        XCTAssertEqual(model.series.minimum, 10)
        XCTAssertEqual(model.series.maximum, 20)
        XCTAssertNil(model.series.currentValue)
    }

    private func samplePoints(count: Int, segments: Int) -> [RoutePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { index in
            RoutePoint(
                timestamp: start.addingTimeInterval(Double(index)),
                latitude: 37.7 + Double(index) * 0.0001,
                longitude: -122.4,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(index) * 10,
                elapsedSeconds: Double(index),
                speedMetersPerSecond: 3,
                heartRateBPM: 140,
                routeSegmentIndex: min(segments - 1, index / max(1, count / segments))
            )
        }
    }
}
