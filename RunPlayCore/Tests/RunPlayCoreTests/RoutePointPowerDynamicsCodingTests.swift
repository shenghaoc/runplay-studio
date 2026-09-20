import Foundation
import XCTest
@testable import RunPlayCore

final class RoutePointPowerDynamicsCodingTests: XCTestCase {
    func testLegacySnapshotWithoutPowerOrDynamicsDecodesWithNilOptionals() throws {
        // A snapshot written before power/dynamics fields existed carries no
        // matching keys; every new optional must decode as nil.
        let legacyJSON = """
        {
          "id": "51D6F2C6-4C4A-4E14-9E1B-BA1F5A0D3E7B",
          "timestamp": 700000000,
          "latitude": 1.25,
          "longitude": -103.5,
          "distanceFromStartMeters": 100,
          "elapsedSeconds": 25,
          "heartRateBPM": 150,
          "cadence": 178,
          "routeSegmentIndex": 1
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))

        let point = try JSONDecoder().decode(RoutePoint.self, from: data)

        XCTAssertNil(point.powerWatts)
        XCTAssertNil(point.groundContactTimeMilliseconds)
        XCTAssertNil(point.verticalOscillationMillimeters)
        XCTAssertNil(point.verticalRatioPercent)
        XCTAssertNil(point.stanceTimeBalancePercent)
        XCTAssertNil(point.stepLengthMeters)
        XCTAssertEqual(point.heartRateBPM, 150)
        XCTAssertEqual(point.routeSegmentIndex, 1)
    }

    func testPowerAndDynamicsFieldsRoundTripThroughCodable() throws {
        let point = RoutePoint(
            timestamp: Date(timeIntervalSinceReferenceDate: 700_000_100.5),
            latitude: 1.5,
            longitude: -103.75,
            powerWatts: 242.5,
            groundContactTimeMilliseconds: 249.25,
            verticalOscillationMillimeters: 9.25,
            verticalRatioPercent: 6.125,
            stanceTimeBalancePercent: 50.25,
            stepLengthMeters: 1.075,
            routeSegmentIndex: 2
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(
            RoutePoint.self,
            from: encoder.encode(point)
        )

        XCTAssertEqual(decoded.powerWatts, 242.5)
        XCTAssertEqual(decoded.groundContactTimeMilliseconds, 249.25)
        XCTAssertEqual(decoded.verticalOscillationMillimeters, 9.25)
        XCTAssertEqual(decoded.verticalRatioPercent, 6.125)
        XCTAssertEqual(decoded.stanceTimeBalancePercent, 50.25)
        XCTAssertEqual(decoded.stepLengthMeters, 1.075)
        XCTAssertEqual(decoded.routeSegmentIndex, 2)
    }

    func testInterpolationCarriesPowerAndDynamicsFields() throws {
        let points = [
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 0),
                latitude: 1.0,
                longitude: 1.0,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0,
                powerWatts: 200,
                groundContactTimeMilliseconds: 240,
                verticalOscillationMillimeters: 8,
                verticalRatioPercent: 5,
                stanceTimeBalancePercent: 48,
                stepLengthMeters: 1
            ),
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 100),
                latitude: 1.001,
                longitude: 1.001,
                distanceFromStartMeters: 150,
                elapsedSeconds: 100,
                powerWatts: 300,
                groundContactTimeMilliseconds: 260,
                verticalOscillationMillimeters: 10,
                verticalRatioPercent: 7,
                stanceTimeBalancePercent: 52,
                stepLengthMeters: 1.2
            )
        ]

        let midpoint = try XCTUnwrap(RoutePointInterpolator.point(at: 75, in: points))

        XCTAssertEqual(midpoint.powerWatts, 250)
        XCTAssertEqual(midpoint.groundContactTimeMilliseconds, 250)
        XCTAssertEqual(midpoint.verticalOscillationMillimeters, 9)
        XCTAssertEqual(midpoint.verticalRatioPercent, 6)
        XCTAssertEqual(midpoint.stanceTimeBalancePercent, 50)
        XCTAssertEqual(midpoint.stepLengthMeters ?? 0, 1.1, accuracy: 0.0001)
    }

    func testInterpolationKeepsMissingPowerNilAtEndpoints() throws {
        let points = [
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 0),
                latitude: 1.0,
                longitude: 1.0,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0
            ),
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 100),
                latitude: 1.001,
                longitude: 1.001,
                distanceFromStartMeters: 150,
                elapsedSeconds: 100,
                powerWatts: 280,
                groundContactTimeMilliseconds: 250
            )
        ]

        let start = try XCTUnwrap(RoutePointInterpolator.point(at: 0, in: points))
        let end = try XCTUnwrap(RoutePointInterpolator.point(at: 150, in: points))
        let middle = try XCTUnwrap(RoutePointInterpolator.point(at: 75, in: points))

        XCTAssertNil(start.powerWatts)
        XCTAssertEqual(end.powerWatts, 280)
        XCTAssertEqual(end.groundContactTimeMilliseconds, 250)
        XCTAssertNil(middle.powerWatts, "A half-known optional stays unknown")
    }
}
