import XCTest
@testable import RunPlayCore

final class MetricSmootherTests: XCTestCase {

    func testMovingAveragePreservesLengthAndAveragesWindow() {
        let values = [1.0, 2.0, 3.0, 4.0, 5.0]
        let smoothed = MetricSmoother.movingAverage(values, windowSize: 3)

        XCTAssertEqual(smoothed.count, values.count)
        // Window centered at index 0: [1, 2]
        XCTAssertEqual(smoothed[0], 1.5, accuracy: 1e-9)
        // Window centered at index 2: [2, 3, 4]
        XCTAssertEqual(smoothed[2], 3.0, accuracy: 1e-9)
        // Window centered at index 4: [4, 5]
        XCTAssertEqual(smoothed[4], 4.5, accuracy: 1e-9)
    }

    func testMovingAverageShortSeriesIsUnchanged() {
        XCTAssertEqual(MetricSmoother.movingAverage([], windowSize: 5), [])
        XCTAssertEqual(MetricSmoother.movingAverage([7.0], windowSize: 5), [7.0])
    }
}
