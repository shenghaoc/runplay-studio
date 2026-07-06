import XCTest
@testable import RunPlayCore

final class FITScalingTests: XCTestCase {

    // MARK: - semicirclesToDegrees

    func testSemicirclesToDegreesZero() {
        let degrees = FITParser.semicirclesToDegrees(0)
        XCTAssertEqual(degrees, 0, accuracy: 0.0001)
    }

    func testSemicirclesToDegreesPositive90() {
        // 90 degrees = 2^30 semicircles (since max semicircles = 2^31 = 180°)
        let semicircles = Int32(1 << 30) // 1073741824
        let degrees = FITParser.semicirclesToDegrees(semicircles)
        XCTAssertEqual(degrees, 90, accuracy: 0.0001)
    }

    func testSemicirclesToDegreesNegative() {
        // Negative semicircles for western/southern hemispheres
        let semicircles: Int32 = -(1 << 30) // -1073741824 = -90°
        let degrees = FITParser.semicirclesToDegrees(semicircles)
        XCTAssertEqual(degrees, -90, accuracy: 0.0001)
    }

    func testSemicirclesToDegreesSanFrancisco() {
        // SF is approximately 37.7749°N, 122.4194°W
        // In semicircles: lat = 37.7749 * 2^31 / 180 ≈ 449,837,xxx
        let latSemicircles = Int32(Double(37.7749) * Double(Int32.max) / 180.0)
        let latDegrees = FITParser.semicirclesToDegrees(latSemicircles)
        XCTAssertEqual(latDegrees, 37.7749, accuracy: 0.001)
    }

    // MARK: - timestampToDate

    func testTimestampToDateEpoch() {
        // FIT epoch is 1989-12-31 00:00:00 UTC (631065600 Unix timestamp)
        let date = FITParser.timestampToDate(0)
        XCTAssertEqual(date.timeIntervalSince1970, 631065600, accuracy: 0.001)
    }

    func testTimestampToDateOneSecond() {
        let date = FITParser.timestampToDate(1)
        XCTAssertEqual(date.timeIntervalSince1970, 631065601, accuracy: 0.001)
    }

    func testTimestampToDateKnownValue() {
        // 1000 seconds after FIT epoch
        let date = FITParser.timestampToDate(1000)
        XCTAssertEqual(date.timeIntervalSince1970, 631066600, accuracy: 0.001)
    }

    // MARK: - scaledAltitudeToMeters

    func testScaledAltitudeToMetersZero() {
        // 0 / 5.0 - 500 = -500
        let meters = FITParser.scaledAltitudeToMeters(0)
        XCTAssertEqual(meters, -500, accuracy: 0.001)
    }

    func testScaledAltitudeToMetersSeaLevel() {
        // Sea level: (500 * 5) / 5.0 - 500 = 0
        let scaled: UInt16 = 2500 // (0 + 500) * 5 = 2500
        let meters = FITParser.scaledAltitudeToMeters(scaled)
        XCTAssertEqual(meters, 0, accuracy: 0.001)
    }

    func testScaledAltitudeToMeters100m() {
        // 100m: (100 + 500) * 5 = 3000
        let scaled: UInt16 = 3000
        let meters = FITParser.scaledAltitudeToMeters(scaled)
        XCTAssertEqual(meters, 100, accuracy: 0.001)
    }

    // MARK: - scaledDistanceToMeters

    func testScaledDistanceToMetersZero() {
        let meters = FITParser.scaledDistanceToMeters(0)
        XCTAssertEqual(meters, 0, accuracy: 0.001)
    }

    func testScaledDistanceToMeters1km() {
        // 1 km = 1000m * 100 = 100000
        let scaled: UInt32 = 100000
        let meters = FITParser.scaledDistanceToMeters(scaled)
        XCTAssertEqual(meters, 1000, accuracy: 0.001)
    }

    func testScaledDistanceToMeters5km() {
        let scaled: UInt32 = 500000
        let meters = FITParser.scaledDistanceToMeters(scaled)
        XCTAssertEqual(meters, 5000, accuracy: 0.001)
    }

    // MARK: - scaledSpeedToMPS

    func testScaledSpeedToMPSZero() {
        let mps = FITParser.scaledSpeedToMPS(0)
        XCTAssertEqual(mps, 0, accuracy: 0.001)
    }

    func testScaledSpeedToMPS5minKm() {
        // 5:00/km = 3.333 m/s → 3333 scaled
        let scaled: UInt16 = 3333
        let mps = FITParser.scaledSpeedToMPS(scaled)
        XCTAssertEqual(mps, 3.333, accuracy: 0.01)
    }

    func testScaledSpeedToMPS10kmh() {
        // 10 km/h = 2.778 m/s → 2778 scaled
        let scaled: UInt16 = 2778
        let mps = FITParser.scaledSpeedToMPS(scaled)
        XCTAssertEqual(mps, 2.778, accuracy: 0.01)
    }
}
