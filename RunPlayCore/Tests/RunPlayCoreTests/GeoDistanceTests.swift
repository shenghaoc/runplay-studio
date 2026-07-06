import XCTest
@testable import RunPlayCore

final class GeoDistanceTests: XCTestCase {

    // MARK: - Known Distance Tests

    func testDistanceBetweenSamePointIsZero() {
        let distance = GeoDistance.distanceMeters(
            fromLat: 37.7749, lon: -122.4194,
            toLat: 37.7749, lon: -122.4194
        )
        XCTAssertEqual(distance, 0, accuracy: 0.001)
    }

    func testDistanceSanFranciscoToLosAngeles() {
        // SF to LA is approximately 559 km
        let distance = GeoDistance.distanceMeters(
            fromLat: 37.7749, lon: -122.4194,
            toLat: 34.0522, lon: -118.2437
        )
        // Allow 5% tolerance
        XCTAssertGreaterThan(distance, 530_000)
        XCTAssertLessThan(distance, 590_000)
    }

    func testDistanceOneDegreeLatitude() {
        // One degree of latitude is approximately 111 km
        let distance = GeoDistance.distanceMeters(
            fromLat: 0, lon: 0,
            toLat: 1, lon: 0
        )
        XCTAssertGreaterThan(distance, 110_000)
        XCTAssertLessThan(distance, 112_000)
    }

    func testDistanceEquatorOneDegreeLongitude() {
        // At the equator, one degree of longitude is approximately 111 km
        let distance = GeoDistance.distanceMeters(
            fromLat: 0, lon: 0,
            toLat: 0, lon: 1
        )
        XCTAssertGreaterThan(distance, 110_000)
        XCTAssertLessThan(distance, 112_000)
    }

    func testDistanceIsSymmetric() {
        let d1 = GeoDistance.distanceMeters(
            fromLat: 37.7749, lon: -122.4194,
            toLat: 34.0522, lon: -118.2437
        )
        let d2 = GeoDistance.distanceMeters(
            fromLat: 34.0522, lon: -118.2437,
            toLat: 37.7749, lon: -122.4194
        )
        XCTAssertEqual(d1, d2, accuracy: 0.001)
    }

    // MARK: - Invalid Coordinate Tests

    func testInvalidLatitudeReturnsZero() {
        let distance = GeoDistance.distanceMeters(
            fromLat: 91, lon: 0,
            toLat: 0, lon: 0
        )
        XCTAssertEqual(distance, 0)
    }

    func testInvalidLongitudeReturnsZero() {
        let distance = GeoDistance.distanceMeters(
            fromLat: 0, lon: 181,
            toLat: 0, lon: 0
        )
        XCTAssertEqual(distance, 0)
    }

    func testNaNLatitudeReturnsZero() {
        let distance = GeoDistance.distanceMeters(
            fromLat: .nan, lon: 0,
            toLat: 0, lon: 0
        )
        XCTAssertEqual(distance, 0)
    }

    func testInfinityLongitudeReturnsZero() {
        let distance = GeoDistance.distanceMeters(
            fromLat: 0, lon: .infinity,
            toLat: 0, lon: 0
        )
        XCTAssertEqual(distance, 0)
    }

    // MARK: - Coordinate Validation

    func testValidCoordinateAccepted() {
        XCTAssertTrue(GeoDistance.isValidCoordinate(lat: 37.7749, lon: -122.4194))
        XCTAssertTrue(GeoDistance.isValidCoordinate(lat: -90, lon: -180))
        XCTAssertTrue(GeoDistance.isValidCoordinate(lat: 90, lon: 180))
        XCTAssertTrue(GeoDistance.isValidCoordinate(lat: 0, lon: 0))
    }

    func testInvalidLatitudeRejected() {
        XCTAssertFalse(GeoDistance.isValidCoordinate(lat: 91, lon: 0))
        XCTAssertFalse(GeoDistance.isValidCoordinate(lat: -91, lon: 0))
    }

    func testInvalidLongitudeRejected() {
        XCTAssertFalse(GeoDistance.isValidCoordinate(lat: 0, lon: 181))
        XCTAssertFalse(GeoDistance.isValidCoordinate(lat: 0, lon: -181))
    }

    func testNaNCoordinateRejected() {
        XCTAssertFalse(GeoDistance.isValidCoordinate(lat: .nan, lon: 0))
        XCTAssertFalse(GeoDistance.isValidCoordinate(lat: 0, lon: .nan))
    }

    func testInfinityCoordinateRejected() {
        XCTAssertFalse(GeoDistance.isValidCoordinate(lat: .infinity, lon: 0))
        XCTAssertFalse(GeoDistance.isValidCoordinate(lat: 0, lon: -.infinity))
    }

    // MARK: - Negative Coordinates (Southern/Western Hemisphere)

    func testSouthernHemisphereDistance() {
        // Sydney to Melbourne is approximately 714 km
        let distance = GeoDistance.distanceMeters(
            fromLat: -33.8688, lon: 151.2093,
            toLat: -37.8136, lon: 144.9631
        )
        XCTAssertGreaterThan(distance, 700_000)
        XCTAssertLessThan(distance, 730_000)
    }

    func testWesternHemisphereDistance() {
        // New York to London is approximately 5,570 km
        let distance = GeoDistance.distanceMeters(
            fromLat: 40.7128, lon: -74.0060,
            toLat: 51.5074, lon: -0.1278
        )
        XCTAssertGreaterThan(distance, 5_500_000)
        XCTAssertLessThan(distance, 5_600_000)
    }
}
