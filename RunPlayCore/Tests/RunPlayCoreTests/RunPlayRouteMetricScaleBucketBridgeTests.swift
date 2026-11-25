import Foundation
import XCTest
@testable import RunPlayCore

final class RunPlayRouteMetricScaleBucketBridgeTests: XCTestCase {
    func testEmptyInput() throws {
        let result = try bridge(metrics: [], weights: [])
        XCTAssertNil(result.scale)
        XCTAssertTrue(result.assignments.isEmpty)
        XCTAssertEqual(result.validCoverageDistanceMeters, 0)
        XCTAssertEqual(result.validIntervalCount, 0)
        XCTAssertEqual(result.noDataIntervalCount, 0)
    }

    func testInputContractAndPolicyErrors() throws {
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [-1])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [-.infinity])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [.nan])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [1], minimumValid: -1)) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidPolicy)
        }

        // Positive infinity is a legal weight: valid for coverage, not
        // quantile-eligible. Full public Int bucket counts are preserved.
        let infiniteWeight = try bridge(metrics: [1, 2], weights: [.infinity, 1])
        XCTAssertNotNil(infiniteWeight.scale)
        XCTAssertEqual(infiniteWeight.validIntervalCount, 2)
        XCTAssertTrue(infiniteWeight.validCoverageDistanceMeters.isInfinite)

        let maxBuckets = try bridge(metrics: [0, 1], weights: [1, 1], bucketCount: Int.max)
        XCTAssertEqual(maxBuckets.assignments[0].bucketIndex, 0)
        XCTAssertEqual(maxBuckets.assignments[1].bucketIndex, Int.max - 1)

        let aboveInt32 = try bridge(
            metrics: [0, 1],
            weights: [1, 1],
            bucketCount: Int(Int32.max) + 1
        )
        XCTAssertEqual(aboveInt32.assignments[1].bucketIndex, Int(Int32.max))
    }

    func testFiniteWeightOverflowCoverageIsPositiveInfinity() throws {
        let huge = Double.greatestFiniteMagnitude
        let result = try bridge(metrics: [1, 2, 3], weights: [huge, huge, huge])
        XCTAssertEqual(result.scale?.lowerBound, 1)
        XCTAssertEqual(result.scale?.median, 2)
        XCTAssertEqual(result.scale?.upperBound, 3)
        XCTAssertEqual(result.validIntervalCount, 3)
        XCTAssertTrue(result.validCoverageDistanceMeters.isInfinite)
        XCTAssertGreaterThan(result.validCoverageDistanceMeters, 0)
    }

    func testNegativeZeroWeightAcceptedAndEchoed() throws {
        let result = try bridge(metrics: [5, 10], weights: [-0.0, 1.0])
        XCTAssertEqual(result.validIntervalCount, 1)
        XCTAssertEqual(result.validCoverageDistanceMeters, 1)
        XCTAssertEqual(result.scale?.lowerBound, 10)
        XCTAssertEqual(result.assignments[0].bucketIndex, 3)
        XCTAssertEqual(result.assignments[1].bucketIndex, 3)
    }

    func testCancellationAtEveryBridgePhase() {
        let metrics: [Double?] = Array(repeating: 4, count: 10)
        let weights = Array(repeating: 1.0, count: 10)
        for targetCall in [1, 3, 7, 8, 10] {
            let probe = CancellationProbe(cancelAtCall: targetCall)
            XCTAssertThrowsError(try bridge(
                metrics: metrics,
                weights: weights,
                stride: 2,
                isCancelled: { probe.isCancelled() }
            ), "cancellation call \(targetCall)") { error in
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    private func bridge(
        metrics: [Double?],
        weights: [Double],
        lower: Double = 0,
        upper: Double = 1,
        minimumSpan: Double = 0,
        minimumValid: Int = 1,
        bucketCount: Int = 7,
        stride: Int = 512,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> RunPlayRouteMetricScaleBucketResult {
        try RunPlayRouteMetricScaleBucketBridge.assign(
            metricValues: metrics,
            weightsMeters: weights,
            lowerQuantile: lower,
            upperQuantile: upper,
            minimumScaleSpan: minimumSpan,
            minimumValidIntervalCount: minimumValid,
            bucketCount: bucketCount,
            cancellationCheckStride: stride,
            isCancelled: isCancelled
        )
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAtCall: Int
    private var callCount = 0

    init(cancelAtCall: Int) {
        self.cancelAtCall = cancelAtCall
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return callCount == cancelAtCall
    }
}
