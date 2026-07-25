import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class MetricChartAccessibilityTests: XCTestCase {
    func testDownsampleRetainsGapBoundariesAndDescriptorSeries() {
        let points = [
            MetricChartDataPoint(id: 0, distanceKm: 0, value: 1, seriesID: 1),
            MetricChartDataPoint(id: 1, distanceKm: 1, value: 2, seriesID: 1),
            MetricChartDataPoint(id: 2, distanceKm: 2, value: 3, seriesID: 2),
            MetricChartDataPoint(id: 3, distanceKm: 3, value: 4, seriesID: 2),
        ]
        let samples = MetricChartAccessibilityBuilder.downsample(
            points,
            maximumSampleCount: 2
        )
        let model = ChartAccessibilityModel.make(
            metricName: "Speed",
            unit: "m/s",
            values: points.map(\.value),
            seriesIDs: points.map(\.seriesID),
            currentValue: nil,
            totalDistanceMeters: 3_000
        )

        XCTAssertEqual(samples.map(\.seriesID), [1, 1, 2, 2])
        XCTAssertEqual(
            MetricChartDescriptor(
                model: model,
                samples: samples,
                metric: .speed
            ).makeChartDescriptor().series.count,
            2
        )
    }

    func testDownsampleRemainsBoundedForOneContinuousSeries() {
        let points = (0..<1_000).map {
            MetricChartDataPoint(
                id: $0,
                distanceKm: Double($0) / 10,
                value: Double($0 % 20),
                seriesID: 1
            )
        }

        let samples = MetricChartAccessibilityBuilder.downsample(points)

        XCTAssertLessThanOrEqual(samples.count, 82)
        XCTAssertEqual(samples.first?.distanceKm, points.first?.distanceKm)
        XCTAssertEqual(samples.last?.distanceKm, points.last?.distanceKm)
    }
}
