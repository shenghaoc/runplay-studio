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

    func testInputContractAndPolicyErrors() {
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [-1])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [.infinity])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [1], minimumValid: -1)) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidPolicy)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [1], bucketCount: Int.max)) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidPolicy)
        }
    }

    func testOneThousandFiveHundredDeterministicOracleFixtures() throws {
        for seed in 0..<1_500 {
            var generator = Generator(seed: UInt64(seed + 1))
            let count = generator.int(upperBound: 80)
            var metrics: [Double?] = []
            var weights: [Double] = []
            metrics.reserveCapacity(count)
            weights.reserveCapacity(count)
            for index in 0..<count {
                let selector = generator.int(upperBound: 19)
                switch selector {
                case 0, 1:
                    metrics.append(nil)
                case 2:
                    metrics.append(.nan)
                case 3:
                    metrics.append(index.isMultiple(of: 2) ? .infinity : -.infinity)
                case 4...8:
                    metrics.append(Double(generator.int(upperBound: 9) - 4))
                default:
                    metrics.append((generator.unit() - 0.5) * 2_000)
                }
                let weightSelector = generator.int(upperBound: 12)
                if weightSelector < 3 {
                    weights.append(0)
                } else if weightSelector == 3 {
                    weights.append(Double.greatestFiniteMagnitude / 1_024)
                } else {
                    weights.append(generator.unit() * 100)
                }
            }

            let quantiles: [Double] = [-2, 0, 0.1, 0.5, 0.9, 1, 2, .nan, .infinity]
            let lower = quantiles[generator.int(upperBound: quantiles.count)]
            let upper = quantiles[generator.int(upperBound: quantiles.count)]
            let spans: [Double] = [-1, 0, 1e-12, 0.01, 10, .nan, .infinity]
            let span = spans[generator.int(upperBound: spans.count)]
            let minimumValid = generator.int(upperBound: count + 4)
            let bucketCount = generator.int(upperBound: 15) - 4

            let oracle = SwiftRouteMetricScaleBucketOracle.assign(
                metricValues: metrics,
                weightsMeters: weights,
                lowerQuantile: lower,
                upperQuantile: upper,
                minimumScaleSpan: span,
                minimumValidIntervalCount: minimumValid,
                bucketCount: bucketCount
            )
            let native = try bridge(
                metrics: metrics,
                weights: weights,
                lower: lower,
                upper: upper,
                minimumSpan: span,
                minimumValid: minimumValid,
                bucketCount: bucketCount
            )
            assertEqual(native, oracle, seed: seed)
        }
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

    private func assertEqual(
        _ native: RunPlayRouteMetricScaleBucketResult,
        _ oracle: SwiftRouteMetricScaleBucketOracle.Result,
        seed: Int
    ) {
        XCTAssertEqual(native.scale?.lowerBound, oracle.scale?.lowerBound, "lower seed \(seed)")
        XCTAssertEqual(native.scale?.median, oracle.scale?.median, "median seed \(seed)")
        XCTAssertEqual(native.scale?.upperBound, oracle.scale?.upperBound, "upper seed \(seed)")
        XCTAssertEqual(native.assignments.count, oracle.assignments.count, "count seed \(seed)")
        for index in native.assignments.indices {
            XCTAssertEqual(native.assignments[index].normalizedValue, oracle.assignments[index].normalizedValue, "normalized seed \(seed) index \(index)")
            XCTAssertEqual(native.assignments[index].bucketIndex, oracle.assignments[index].bucketIndex, "bucket seed \(seed) index \(index)")
        }
        XCTAssertEqual(native.validCoverageDistanceMeters, oracle.validCoverageDistanceMeters, "coverage seed \(seed)")
        XCTAssertEqual(native.validIntervalCount, oracle.validIntervalCount, "valid seed \(seed)")
        XCTAssertEqual(native.noDataIntervalCount, oracle.noDataIntervalCount, "no data seed \(seed)")
    }
}

private struct Generator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func int(upperBound: Int) -> Int {
        Int(next() % UInt64(max(1, upperBound)))
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
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
