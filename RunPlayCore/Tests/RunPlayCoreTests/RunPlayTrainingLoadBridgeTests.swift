import Foundation
import XCTest
@testable import RunPlayCore

final class RunPlayTrainingLoadBridgeTests: XCTestCase {
    private static let zones: [Double] = [0, 100, 120, 140, 160]

    private func bridge(
        rates: [Double?],
        weights: [Double],
        resting: Double = 50,
        maximum: Double = 150,
        multiplier: Double = 0.64,
        exponent: Double = 1.92,
        zones: [Double] = RunPlayTrainingLoadBridgeTests.zones,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RunPlayTrainingLoadResult {
        try RunPlayTrainingLoadBridge.compute(
            heartRatesBPM: rates,
            weightsSeconds: weights,
            restingHeartRateBPM: resting,
            maximumHeartRateBPM: maximum,
            coefficientMultiplier: multiplier,
            coefficientExponent: exponent,
            zoneLowerBoundsBPM: zones,
            cancellationCheckStride: 1,
            isCancelled: isCancelled
        )
    }

    /// Mirrors the native single-interval fixture: one minute at reserve 0.5
    /// gives `0.32 * exp(0.96) ≈ 0.8357428715`.
    func testSingleIntervalParity() throws {
        let result = try bridge(rates: [100], weights: [60])
        XCTAssertEqual(result.totalIntervalCount, 1)
        XCTAssertEqual(result.validIntervalCount, 1)
        XCTAssertEqual(result.validHeartRateSeconds, 60)
        XCTAssertEqual(result.coveredSeconds, 60)
        XCTAssertEqual(result.meanHeartRateBPM, 100)
        XCTAssertEqual(result.zoneSeconds, [0, 60, 0, 0, 0])
        XCTAssertEqual(result.totalTRIMP, 0.32 * exp(1.92 * 0.5), accuracy: 1e-12)
        XCTAssertEqual(result.totalTRIMP, 0.835_742_871_496_999, accuracy: 1e-9)
    }

    func testMixedIntervalsAndGapParity() throws {
        let result = try bridge(rates: [100, nil, 130], weights: [600, 120, 600])
        XCTAssertEqual(result.totalIntervalCount, 3)
        XCTAssertEqual(result.validIntervalCount, 2)
        XCTAssertEqual(result.coveredSeconds, 1_320)
        XCTAssertEqual(result.validHeartRateSeconds, 1_200)
        XCTAssertEqual(try XCTUnwrap(result.meanHeartRateBPM), 115, accuracy: 1e-12)
        XCTAssertEqual(result.zoneSeconds, [0, 600, 600, 0, 0])

        let easy = 10 * 0.5 * 0.64 * exp(1.92 * 0.5)
        let hard = 10 * 0.8 * 0.64 * exp(1.92 * 0.8)
        XCTAssertEqual(result.totalTRIMP, easy + hard, accuracy: 1e-12)
    }

    func testReserveClampingParity() throws {
        let below = try bridge(rates: [40], weights: [600])
        XCTAssertEqual(below.totalTRIMP, 0)
        XCTAssertEqual(below.validHeartRateSeconds, 600)
        XCTAssertEqual(below.zoneSeconds, [600, 0, 0, 0, 0])

        let above = try bridge(rates: [200], weights: [600])
        XCTAssertEqual(above.totalTRIMP, 10 * 0.64 * exp(1.92), accuracy: 1e-12)
    }

    func testEmptyInput() throws {
        let result = try bridge(rates: [], weights: [])
        XCTAssertEqual(result.totalTRIMP, 0)
        XCTAssertNil(result.meanHeartRateBPM)
        XCTAssertTrue(result.zoneSeconds.allSatisfy { $0 == 0 })
        XCTAssertEqual(result.totalIntervalCount, 0)
    }

    func testFemaleCoefficients() throws {
        let result = try bridge(
            rates: [100],
            weights: [60],
            multiplier: 0.86,
            exponent: 1.67
        )
        XCTAssertEqual(result.totalTRIMP, 0.5 * 0.86 * exp(1.67 * 0.5), accuracy: 1e-12)
    }

    func testInputContractErrors() throws {
        XCTAssertThrowsError(try bridge(rates: [100], weights: [])) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(rates: [100], weights: [-1])) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(rates: [100], weights: [.nan])) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(rates: [.nan], weights: [60])) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(rates: [0], weights: [60])) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(rates: [-5], weights: [60])) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidInputContract)
        }
    }

    func testPolicyErrors() throws {
        XCTAssertThrowsError(try bridge(rates: [100], weights: [60], resting: 0)) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidPolicy)
        }
        XCTAssertThrowsError(try bridge(rates: [100], weights: [60], resting: 160)) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidPolicy)
        }
        XCTAssertThrowsError(try bridge(rates: [100], weights: [60], maximum: .nan)) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidPolicy)
        }
        XCTAssertThrowsError(try bridge(rates: [100], weights: [60], multiplier: 0)) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidPolicy)
        }
        XCTAssertThrowsError(try bridge(rates: [100], weights: [60], exponent: 0)) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidPolicy)
        }
        XCTAssertThrowsError(try bridge(rates: [100], weights: [60], zones: [0, 100, 100, 140, 160])) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidPolicy)
        }
        XCTAssertThrowsError(try bridge(rates: [100], weights: [60], zones: [0, 100, 120, 140])) {
            XCTAssertEqual($0 as? RunPlayTrainingLoadBridgeError, .invalidPolicy)
        }
    }

    func testCancellationBeforeConversionThrows() {
        XCTAssertThrowsError(
            try bridge(rates: [100, 100], weights: [60, 60], isCancelled: { true })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testOneNativeCallPerPass() throws {
        let rates = (0..<10).map { _ in Double?.some(Double.random(in: 100...160)) }
        let weights = (0..<10).map { _ in Double.random(in: 30...90) }
        let (result, counts) = try NativeCallObserver.observing {
            try bridge(rates: rates, weights: weights)
        }
        XCTAssertEqual(counts.trainingLoad, 1)
        XCTAssertEqual(result.totalIntervalCount, 10)
    }
}
