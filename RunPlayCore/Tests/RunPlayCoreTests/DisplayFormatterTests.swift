import XCTest
@testable import RunPlayCore

final class DisplayFormatterTests: XCTestCase {

    // MARK: - Duration

    func testFormatDurationNilReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDuration(nil), "--:--")
    }

    func testFormatDurationNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDuration(.nan), "--:--")
    }

    func testFormatDurationInfinityReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDuration(.infinity), "--:--")
        XCTAssertEqual(DisplayFormatter.formatDuration(-.infinity), "--:--")
    }

    func testFormatDurationNegativeReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDuration(-10), "--:--")
    }

    func testFormatDurationZeroReturnsValid() {
        XCTAssertEqual(DisplayFormatter.formatDuration(0), "00:00")
    }

    func testFormatDurationNormal() {
        XCTAssertEqual(DisplayFormatter.formatDuration(125), "02:05")
        XCTAssertEqual(DisplayFormatter.formatDuration(3725), "1:02:05")
    }

    func testFormatElapsedNormal() {
        XCTAssertEqual(DisplayFormatter.formatElapsed(65), "1:05")
        XCTAssertEqual(DisplayFormatter.formatElapsed(nil), "--:--")
    }

    func testFormatElapsedNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatElapsed(.nan), "--:--")
    }

    func testFormatElapsedInfinityReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatElapsed(.infinity), "--:--")
        XCTAssertEqual(DisplayFormatter.formatElapsed(-.infinity), "--:--")
    }

    func testFormatElapsedNegativeReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatElapsed(-10), "--:--")
    }

    // MARK: - Pace

    func testFormatPaceNilReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPace(nil), "--:-- /km")
    }

    func testFormatPaceNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPace(.nan), "--:-- /km")
    }

    func testFormatPaceInfinityReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPace(.infinity), "--:-- /km")
    }

    func testFormatPaceZeroReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPace(0), "--:-- /km")
    }

    func testFormatPaceNegativeReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatPace(-240), "--:-- /km")
    }

    func testFormatPaceNormal() {
        XCTAssertEqual(DisplayFormatter.formatPace(300), "5:00 /km")
        XCTAssertEqual(DisplayFormatter.formatPace(245), "4:05 /km")
    }

    // MARK: - Distance

    func testFormatDistanceKmNilReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDistanceKm(nil), "--- km")
    }

    func testFormatDistanceKmNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDistanceKm(.nan), "--- km")
    }

    func testFormatDistanceKmInfinityReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDistanceKm(.infinity), "--- km")
    }

    func testFormatDistanceKmNegativeReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDistanceKm(-100), "--- km")
    }

    func testFormatDistanceKmNormal() {
        XCTAssertEqual(DisplayFormatter.formatDistanceKm(5432), "5.43 km")
    }

    func testFormatDistanceMeters() {
        XCTAssertEqual(DisplayFormatter.formatDistance(500), "500 m")
        XCTAssertEqual(DisplayFormatter.formatDistance(1500), "1.5 km")
        XCTAssertEqual(DisplayFormatter.formatDistance(nil), "---")
    }

    func testFormatDistanceNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDistance(.nan), "---")
    }

    func testFormatDistanceInfinityReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDistance(.infinity), "---")
    }

    func testFormatDistanceNegativeReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatDistance(-100), "---")
    }

    // MARK: - Elevation

    func testFormatElevationNilReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatElevation(nil), "--- m")
    }

    func testFormatElevationNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatElevation(.nan), "--- m")
    }

    func testFormatElevationDeltaNormal() {
        XCTAssertEqual(DisplayFormatter.formatElevationDelta(50), "+50 m")
        XCTAssertEqual(DisplayFormatter.formatElevationDelta(-30), "-30 m")
        XCTAssertEqual(DisplayFormatter.formatElevationDelta(nil), "")
    }

    // MARK: - Heart Rate

    func testFormatHeartRateNilReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatHeartRate(nil), "--- bpm")
    }

    func testFormatHeartRateNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatHeartRate(.nan), "--- bpm")
    }

    func testFormatHeartRateInfinityReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatHeartRate(.infinity), "--- bpm")
    }

    func testFormatHeartRateNormal() {
        XCTAssertEqual(DisplayFormatter.formatHeartRate(145.7), "146 bpm")
    }

    // MARK: - Speed

    func testFormatSpeedNilReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatSpeed(nil), "--- m/s")
    }

    func testFormatSpeedNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatSpeed(.nan), "--- m/s")
    }

    func testFormatSpeedNegativeReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatSpeed(-1), "--- m/s")
    }

    func testFormatSpeedKmhNormal() {
        XCTAssertEqual(DisplayFormatter.formatSpeedKmh(3.0), "10.8 km/h")
    }

    // MARK: - Cadence

    func testFormatCadenceNilReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatCadence(nil), "--- spm")
    }

    func testFormatCadenceNaNReturnsFallback() {
        XCTAssertEqual(DisplayFormatter.formatCadence(.nan), "--- spm")
    }

    // MARK: - Numbers

    func testFormatNumberNaNReturnsEmpty() {
        XCTAssertEqual(DisplayFormatter.formatNumber(.nan), "")
    }

    func testFormatNumberInfinityReturnsEmpty() {
        XCTAssertEqual(DisplayFormatter.formatNumber(.infinity), "")
        XCTAssertEqual(DisplayFormatter.formatNumber(-.infinity), "")
    }

    func testFormatNumberInteger() {
        XCTAssertEqual(DisplayFormatter.formatNumber(42), "42")
    }

    func testFormatNumberDecimal() {
        XCTAssertEqual(DisplayFormatter.formatNumber(3.14), "3.14")
    }

    func testFormatOptionalNumberNilReturnsEmpty() {
        XCTAssertEqual(DisplayFormatter.formatOptionalNumber(nil), "")
    }

    func testFormatOptionalNumberNaNReturnsEmpty() {
        XCTAssertEqual(DisplayFormatter.formatOptionalNumber(.nan), "")
    }
}
