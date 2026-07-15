import XCTest
@testable import RunPlayCore

final class MetricValidationTests: XCTestCase {

    // MARK: - isValidHeartRate

    func testValidHeartRateMidpoint() {
        XCTAssertTrue(MetricValidation.isValidHeartRate(150))
    }

    func testValidHeartRateLowerBound() {
        XCTAssertTrue(MetricValidation.isValidHeartRate(30))
    }

    func testValidHeartRateUpperBound() {
        XCTAssertTrue(MetricValidation.isValidHeartRate(230))
    }

    func testInvalidHeartRateJustBelowRange() {
        XCTAssertFalse(MetricValidation.isValidHeartRate(29.9))
    }

    func testInvalidHeartRateJustAboveRange() {
        XCTAssertFalse(MetricValidation.isValidHeartRate(230.1))
    }

    func testInvalidHeartRateNaN() {
        XCTAssertFalse(MetricValidation.isValidHeartRate(.nan))
    }

    func testInvalidHeartRateInfinity() {
        XCTAssertFalse(MetricValidation.isValidHeartRate(.infinity))
    }

    func testInvalidHeartRateNegativeInfinity() {
        XCTAssertFalse(MetricValidation.isValidHeartRate(-.infinity))
    }

    func testInvalidHeartRateNegative() {
        XCTAssertFalse(MetricValidation.isValidHeartRate(-50))
    }

    func testInvalidHeartRateZero() {
        XCTAssertFalse(MetricValidation.isValidHeartRate(0))
    }

    // MARK: - isValidCadence

    func testCadenceValidationAcceptsSupportedRange() {
        XCTAssertTrue(MetricValidation.isValidCadence(0))
        XCTAssertTrue(MetricValidation.isValidCadence(180))
        XCTAssertTrue(MetricValidation.isValidCadence(300))
    }

    func testCadenceValidationRejectsMalformedValues() {
        XCTAssertFalse(MetricValidation.isValidCadence(-1))
        XCTAssertFalse(MetricValidation.isValidCadence(301))
        XCTAssertFalse(MetricValidation.isValidCadence(.nan))
        XCTAssertFalse(MetricValidation.isValidCadence(.infinity))
    }

    // MARK: - DisplayFormatter.formatPaceShort

    func testFormatPaceShortNormal() {
        XCTAssertEqual(DisplayFormatter.formatPaceShort(300), "5:00")
    }

    func testFormatPaceShortNilReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPaceShort(nil), "--:--")
    }

    func testFormatPaceShortNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPaceShort(.nan), "--:--")
    }

    func testFormatPaceShortInfinityReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPaceShort(.infinity), "--:--")
    }

    func testFormatPaceShortZeroReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPaceShort(0), "--:--")
    }

    func testFormatPaceShortNegativeReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPaceShort(-240), "--:--")
    }
}
