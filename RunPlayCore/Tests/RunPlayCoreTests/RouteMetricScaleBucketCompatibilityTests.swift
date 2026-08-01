import XCTest
@testable import RunPlayCore

final class RouteMetricScaleBucketCompatibilityTests: XCTestCase {
    typealias Oracle = SwiftRouteMetricScaleBucketOracle

    func testOriginMainNumericEdgeMatrix() {
        assertResult([], [], scale: nil, assignments: [], validCount: 0, noDataCount: 0, coverage: 0)
        assertResult([7], [1], scale: .init(lowerBound: 7, median: 7, upperBound: 7), assignments: [.init(normalizedValue: 0.5, bucketIndex: 3)], validCount: 1, noDataCount: 0, coverage: 1)
        assertResult([nil, nil], [1, 2], scale: nil, assignments: [.init(normalizedValue: nil, bucketIndex: nil), .init(normalizedValue: nil, bucketIndex: nil)], validCount: 0, noDataCount: 2, coverage: 0)
        assertResult([5, 10], [0, 2], scale: .init(lowerBound: 10, median: 10, upperBound: 10), assignments: [.init(normalizedValue: 0.5, bucketIndex: 3), .init(normalizedValue: 0.5, bucketIndex: 3)], validCount: 1, noDataCount: 0, coverage: 2)
        assertResult([4, 4, 4], [1, 2, 3], scale: .init(lowerBound: 4, median: 4, upperBound: 4), assignments: Array(repeating: .init(normalizedValue: 0.5, bucketIndex: 3), count: 3), validCount: 3, noDataCount: 0, coverage: 6)
    }

    func testOriginMainPolicyEdges() {
        let metrics: [Double?] = [1, 2, 3]
        let weights = [1.0, 2.0, 1.0]
        XCTAssertEqual(result(metrics, weights, lower: 0, upper: 1).scale, .init(lowerBound: 1, median: 2, upperBound: 3))
        XCTAssertEqual(result(metrics, weights, lower: -10, upper: 10).scale, .init(lowerBound: 1, median: 2, upperBound: 3))
        XCTAssertNil(result(metrics, weights, lower: .nan, upper: 1).scale)
        XCTAssertNil(result(metrics, weights, lower: 0, upper: .infinity).scale)
        XCTAssertEqual(result(metrics, weights, lower: 0.5, upper: 0.5).scale, .init(lowerBound: 2, median: 2, upperBound: 2))
        XCTAssertNotNil(result(metrics, weights, minimumSpan: .nan).scale)
        XCTAssertNotNil(result(metrics, weights, minimumSpan: -.infinity).scale)
        XCTAssertNil(result(metrics, weights, minimumSpan: .infinity).scale)
        XCTAssertNil(result(metrics, weights, minimumValid: 4).scale)
        XCTAssertEqual(result(metrics, weights, bucketCount: 2).assignments.map(\.bucketIndex), [0, 1, 1])
        XCTAssertEqual(result(metrics, weights, bucketCount: 9).assignments.map(\.bucketIndex), [0, 4, 8])
    }

    func testOriginMainLargeWeightsAndNonFinitePresentValues() {
        let huge = Double.greatestFiniteMagnitude
        let large = result([1, 2, 3], [huge, huge, huge])
        XCTAssertEqual(large.scale, .init(lowerBound: 1, median: 2, upperBound: 3))
        XCTAssertTrue(large.validCoverageDistanceMeters.isInfinite)

        let nonFinite = result([1, .nan, .infinity, 3], [1, 0, 0, 1])
        XCTAssertEqual(nonFinite.scale, .init(lowerBound: 1, median: 1, upperBound: 3))
        XCTAssertEqual(nonFinite.assignments[1], .init(normalizedValue: 0.5, bucketIndex: 3))
        XCTAssertEqual(nonFinite.assignments[2], .init(normalizedValue: 0.5, bucketIndex: 3))
        XCTAssertEqual(nonFinite.validIntervalCount, 2)
        XCTAssertEqual(nonFinite.noDataIntervalCount, 0)
    }

    private func assertResult(
        _ metrics: [Double?],
        _ weights: [Double],
        scale: Oracle.Scale?,
        assignments: [Oracle.Assignment],
        validCount: Int,
        noDataCount: Int,
        coverage: Double
    ) {
        let actual = result(metrics, weights)
        XCTAssertEqual(actual.scale, scale)
        XCTAssertEqual(actual.assignments, assignments)
        XCTAssertEqual(actual.validIntervalCount, validCount)
        XCTAssertEqual(actual.noDataIntervalCount, noDataCount)
        XCTAssertEqual(actual.validCoverageDistanceMeters, coverage)
    }

    private func result(
        _ metrics: [Double?],
        _ weights: [Double],
        lower: Double = 0,
        upper: Double = 1,
        minimumSpan: Double = 0,
        minimumValid: Int = 1,
        bucketCount: Int = 7
    ) -> Oracle.Result {
        Oracle.assign(
            metricValues: metrics,
            weightsMeters: weights,
            lowerQuantile: lower,
            upperQuantile: upper,
            minimumScaleSpan: minimumSpan,
            minimumValidIntervalCount: minimumValid,
            bucketCount: bucketCount
        )
    }
}
