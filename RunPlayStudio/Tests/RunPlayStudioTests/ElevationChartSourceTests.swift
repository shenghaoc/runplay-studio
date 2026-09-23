import Foundation
import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// The elevation chart's deliberate behaviour at a source change: the line
/// breaks there, and the fallback source is dashed when a run shows both.
final class ElevationChartSourceTests: XCTestCase {
    private func points(_ count: Int, segmentBreakAt: Int? = nil) -> [RoutePoint] {
        (0..<count).map { index in
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                latitude: 46.44,
                longitude: 7.3,
                distanceFromStartMeters: Double(index) * 10,
                routeSegmentIndex: segmentBreakAt.map { index >= $0 ? 1 : 0 } ?? 0
            )
        }
    }

    func testASourceSwitchStartsANewSeriesAndDashesTheFallback() {
        let values: [Double?] = [100, 101, 130, 131, 132, 102]
        let recordedFallback = ElevationChartSourceSplit(
            sourceIsDEM: [false, false, true, true, true, false],
            fallbackIsDEM: false
        )

        let data = MetricChartDataBuilder.build(routePoints: points(6), values: values, sourceSplit: recordedFallback)

        XCTAssertEqual(data.map(\.seriesID), [1, 1, 2, 2, 2, 3], "the line breaks at each switch")
        XCTAssertEqual(data.map(\.dashed), [true, true, false, false, false, true], "recorded fallback dashed")

        let barometric = ElevationChartSourceSplit(sourceIsDEM: recordedFallback.sourceIsDEM, fallbackIsDEM: true)
        XCTAssertEqual(
            MetricChartDataBuilder.build(routePoints: points(6), values: values, sourceSplit: barometric).map(\.dashed),
            [false, false, true, true, true, false],
            "DEM gap fill is the fallback of a barometric run"
        )
    }

    func testOneSourceIsNeverDashedAndGapsStillBreak() {
        let values: [Double?] = [100, nil, 102, 103]
        let allDEM = ElevationChartSourceSplit(sourceIsDEM: [true, false, true, true], fallbackIsDEM: false)

        let data = MetricChartDataBuilder.build(routePoints: points(4), values: values, sourceSplit: allDEM)

        XCTAssertEqual(data.map(\.seriesID), [1, 2, 2], "the missing point breaks the line, not its source flag")
        XCTAssertFalse(data.contains(where: \.dashed), "a point without elevation does not make a run mixed")
        XCTAssertEqual(
            MetricChartDataBuilder.build(routePoints: points(4, segmentBreakAt: 2), values: [1, 2, 3, 4]).map(\.seriesID),
            [1, 1, 2, 2],
            "route segments still break the line without a source split"
        )
    }

    func testLegendNamesTheDashedSource() {
        XCTAssertEqual(
            ElevationChartSourceSplit(sourceIsDEM: [], fallbackIsDEM: false).legend,
            "Dashed sections use recorded altitude where no DEM tile covers the route."
        )
        XCTAssertEqual(
            ElevationChartSourceSplit(sourceIsDEM: [], fallbackIsDEM: true).legend,
            "Dashed sections are DEM elevation filling gaps in the barometric altitude."
        )
    }

    func testChartDescriptorNamesTheElevationSource() {
        let model = ChartAccessibilityModel.make(
            metricName: "Elevation",
            unit: "m",
            values: [100, 110],
            seriesIDs: [1, 1],
            currentValue: nil,
            totalDistanceMeters: 20
        )
        let descriptor = MetricChartDescriptor(
            model: model,
            samples: [],
            metric: .elevation,
            elevationSourceLabel: "DEM tiles and recorded altitude"
        ).makeChartDescriptor()

        XCTAssertEqual(descriptor.summary, "\(model.spokenSummary) Source: DEM tiles and recorded altitude.")
    }
}
