import XCTest
@testable import RunPlayCore

/// Running power and running dynamics carried per route point through the
/// native JSON importer.
final class JSONWorkoutImporterPowerDynamicsTests: XCTestCase {

    func testPowerAndDynamicsReachRoutePoints() throws {
        let workout = try importJSON(points: [
            point(second: 0, fields: #""powerWatts": 250, "groundContactTimeMilliseconds": 240, "verticalOscillationMillimeters": 82.5, "verticalRatioPercent": 7.4, "stanceTimeBalancePercent": 49.6, "stepLengthMeters": 1.12"#),
            point(second: 5, fields: #""powerWatts": 270, "groundContactTimeMilliseconds": 236"#),
            point(second: 10, fields: #""powerWatts": 260"#),
        ])

        XCTAssertEqual(workout.routePoints.map(\.powerWatts), [250, 270, 260])
        let first = try XCTUnwrap(workout.routePoints.first)
        XCTAssertEqual(first.groundContactTimeMilliseconds, 240)
        XCTAssertEqual(first.verticalOscillationMillimeters, 82.5)
        XCTAssertEqual(first.verticalRatioPercent, 7.4)
        XCTAssertEqual(first.stanceTimeBalancePercent, 49.6)
        XCTAssertEqual(first.stepLengthMeters, 1.12)
        XCTAssertNil(workout.routePoints[2].groundContactTimeMilliseconds)

        XCTAssertTrue(workout.hasPowerData)
        XCTAssertNotNil(workout.summary.averagePowerWatts)
        XCTAssertEqual(workout.summary.maxPowerWatts, 270)
        XCTAssertEqual(workout.summary.averageGroundContactTimeMilliseconds, 238)
    }

    func testExportedWorkoutRoundTripsPowerAndDynamics() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<3).map { index in
            RoutePoint(
                timestamp: start.addingTimeInterval(Double(index) * 5),
                latitude: 37.7749 + Double(index) * 0.0001,
                longitude: -122.4194,
                elapsedSeconds: Double(index) * 5,
                powerWatts: 240 + Double(index),
                groundContactTimeMilliseconds: 250,
                verticalOscillationMillimeters: 80,
                verticalRatioPercent: 8,
                stanceTimeBalancePercent: 50,
                stepLengthMeters: 1.1
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Export(source: "json", routePoints: points))

        let workout = try JSONWorkoutImporter().importWorkout(from: data)

        XCTAssertEqual(workout.routePoints.map(\.powerWatts), [240, 241, 242])
        for imported in workout.routePoints {
            XCTAssertEqual(imported.groundContactTimeMilliseconds, 250)
            XCTAssertEqual(imported.verticalOscillationMillimeters, 80)
            XCTAssertEqual(imported.verticalRatioPercent, 8)
            XCTAssertEqual(imported.stanceTimeBalancePercent, 50)
            XCTAssertEqual(imported.stepLengthMeters, 1.1)
        }
    }

    func testOutOfRangeValuesAreDroppedPerFieldAndPerPoint() throws {
        let workout = try importJSON(points: [
            point(second: 0, fields: #""powerWatts": -40, "groundContactTimeMilliseconds": 1500, "verticalOscillationMillimeters": -1, "verticalRatioPercent": 101, "stanceTimeBalancePercent": 250, "stepLengthMeters": 6"#),
            point(second: 5, fields: #""powerWatts": 5001, "groundContactTimeMilliseconds": 245"#),
            point(second: 10, fields: #""powerWatts": 255, "stepLengthMeters": 0"#),
        ])

        let first = try XCTUnwrap(workout.routePoints.first)
        XCTAssertNil(first.powerWatts)
        XCTAssertNil(first.groundContactTimeMilliseconds)
        XCTAssertNil(first.verticalOscillationMillimeters)
        XCTAssertNil(first.verticalRatioPercent)
        XCTAssertNil(first.stanceTimeBalancePercent)
        XCTAssertNil(first.stepLengthMeters)

        // An invalid field does not take a valid neighbour on the same point
        // or the next point with it; range bounds are inclusive.
        XCTAssertNil(workout.routePoints[1].powerWatts)
        XCTAssertEqual(workout.routePoints[1].groundContactTimeMilliseconds, 245)
        XCTAssertEqual(workout.routePoints[2].powerWatts, 255)
        XCTAssertEqual(workout.routePoints[2].stepLengthMeters, 0)

        XCTAssertEqual(workout.summary.maxPowerWatts, 255)
        XCTAssertEqual(workout.summary.averagePowerWatts, 255)
    }

    func testOnlyInvalidPowerLeavesWorkoutWithoutPowerData() throws {
        let workout = try importJSON(points: [
            point(second: 0, fields: #""powerWatts": -1"#),
            point(second: 5, fields: #""powerWatts": 99999"#),
        ])

        XCTAssertTrue(workout.routePoints.allSatisfy { $0.powerWatts == nil })
        XCTAssertFalse(workout.hasPowerData)
        XCTAssertNil(workout.summary.averagePowerWatts)
    }

    /// JSON has no literal for NaN or infinity, and an overflowing number
    /// literal rejects the whole file exactly as it does for heart rate.
    func testNonRepresentablePowerRejectsFileLikeHeartRate() {
        for field in ["powerWatts", "stepLengthMeters", "heartRateBPM"] {
            XCTAssertThrowsError(
                try importJSON(points: [point(second: 0, fields: "\"\(field)\": 1e999")]),
                field
            )
            XCTAssertThrowsError(
                try importJSON(points: [point(second: 0, fields: "\"\(field)\": \"NaN\"")]),
                field
            )
        }
    }

    // MARK: - Helpers

    private struct Export: Encodable {
        let source: String
        let routePoints: [RoutePoint]
    }

    private func point(second: Int, fields: String) -> String {
        let timestamp = String(format: "2026-01-01T10:00:%02dZ", second)
        let latitude = 37.7749 + Double(second) * 0.00002
        return #"{"timestamp": "\#(timestamp)", "latitude": \#(latitude), "longitude": -122.4194, \#(fields)}"#
    }

    private func importJSON(points: [String]) throws -> RunWorkout {
        let json = #"{"source": "json", "routePoints": [\#(points.joined(separator: ","))]}"#
        return try JSONWorkoutImporter().importWorkout(from: Data(json.utf8))
    }
}
