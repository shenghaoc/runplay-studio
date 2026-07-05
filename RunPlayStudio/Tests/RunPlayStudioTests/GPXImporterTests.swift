import XCTest
@testable import RunPlayStudio

final class GPXImporterTests: XCTestCase {

    // MARK: - Realistic Fixture Tests

    func testRealisticGPXFixtureLoads() throws {
        let url = try fixtureURL("realistic_5k_run")
        let workout = try GPXImporter().importWorkout(from: url)

        // Should have parsed all trackpoints (63 points in the fixture)
        XCTAssertGreaterThanOrEqual(workout.routePoints.count, 50, "Should parse at least 50 trackpoints")

        // Should have nonzero distance
        XCTAssertGreaterThan(workout.summary.totalDistanceMeters, 0, "Distance should be > 0")

        // Should have nonzero duration
        XCTAssertGreaterThan(workout.summary.totalElapsedSeconds, 0, "Duration should be > 0")

        // Should have splits (5K should produce at least 4-5 splits)
        XCTAssertGreaterThanOrEqual(workout.splits.count, 4, "5K run should have at least 4 splits")

        // Verify no NaN or infinity in key metrics
        XCTAssertFalse(workout.summary.totalDistanceMeters.isNaN)
        XCTAssertFalse(workout.summary.totalDistanceMeters.isInfinite)
        XCTAssertFalse(workout.summary.averagePaceSecondsPerKilometer.isNaN)
        XCTAssertFalse(workout.summary.averagePaceSecondsPerKilometer.isInfinite)
    }

    func testGPXRoutePointsHaveMonotonicElapsed() throws {
        let url = try fixtureURL("realistic_5k_run")
        let workout = try GPXImporter().importWorkout(from: url)

        // Elapsed time should be monotonically non-decreasing
        for i in 1..<workout.routePoints.count {
            XCTAssertGreaterThanOrEqual(
                workout.routePoints[i].elapsedSeconds,
                workout.routePoints[i - 1].elapsedSeconds,
                "Elapsed time should be monotonically non-decreasing at index \(i)"
            )
        }
    }

    func testGPXCumulativeDistanceIsNondecreasing() throws {
        let url = try fixtureURL("realistic_5k_run")
        let workout = try GPXImporter().importWorkout(from: url)

        // Cumulative distance should be non-decreasing
        for i in 1..<workout.routePoints.count {
            XCTAssertGreaterThanOrEqual(
                workout.routePoints[i].distanceFromStartMeters,
                workout.routePoints[i - 1].distanceFromStartMeters,
                "Cumulative distance should be non-decreasing at index \(i)"
            )
        }
    }

    func testGPXRoutePointsHaveValidCoordinates() throws {
        let url = try fixtureURL("realistic_5k_run")
        let workout = try GPXImporter().importWorkout(from: url)

        for (i, point) in workout.routePoints.enumerated() {
            // Latitude should be in valid range
            XCTAssertGreaterThanOrEqual(point.latitude, -90, "Latitude out of range at index \(i)")
            XCTAssertLessThanOrEqual(point.latitude, 90, "Latitude out of range at index \(i)")

            // Longitude should be in valid range
            XCTAssertGreaterThanOrEqual(point.longitude, -180, "Longitude out of range at index \(i)")
            XCTAssertLessThanOrEqual(point.longitude, 180, "Longitude out of range at index \(i)")

            // No NaN or infinity
            XCTAssertFalse(point.latitude.isNaN, "NaN latitude at index \(i)")
            XCTAssertFalse(point.longitude.isNaN, "NaN longitude at index \(i)")
            XCTAssertFalse(point.latitude.isInfinite, "Infinite latitude at index \(i)")
            XCTAssertFalse(point.longitude.isInfinite, "Infinite longitude at index \(i)")
        }
    }

    func testGPXRoutePointsHaveElevation() throws {
        let url = try fixtureURL("realistic_5k_run")
        let workout = try GPXImporter().importWorkout(from: url)

        // All points should have elevation data
        for (i, point) in workout.routePoints.enumerated() {
            XCTAssertNotNil(point.altitudeMeters, "Missing elevation at index \(i)")
            if let ele = point.altitudeMeters {
                XCTAssertFalse(ele.isNaN, "NaN elevation at index \(i)")
                XCTAssertFalse(ele.isInfinite, "Infinite elevation at index \(i)")
            }
        }

        // Should detect elevation changes
        XCTAssertTrue(workout.hasAltitudeData, "Workout should have altitude data")
    }

    func testGPXAnalyzerProducesValidSummary() throws {
        let url = try fixtureURL("realistic_5k_run")
        let workout = try GPXImporter().importWorkout(from: url)
        let summary = workout.summary

        // Distance should be roughly 5K (4000-6000 meters acceptable for synthetic data)
        XCTAssertGreaterThan(summary.totalDistanceMeters, 4000, "Distance should be > 4km")
        XCTAssertLessThan(summary.totalDistanceMeters, 6000, "Distance should be < 6km")

        // Duration should be roughly 15-25 minutes
        XCTAssertGreaterThan(summary.totalElapsedSeconds, 900, "Duration should be > 15 min")
        XCTAssertLessThan(summary.totalElapsedSeconds, 1500, "Duration should be < 25 min")

        // Pace should be plausible (4:00-8:00 min/km = 240-480 sec/km)
        let pace = summary.averagePaceSecondsPerKilometer
        XCTAssertGreaterThan(pace, 240, "Pace should be > 4:00/km")
        XCTAssertLessThan(pace, 480, "Pace should be < 8:00/km")
    }

    func testGPXSplitCalculatorDoesNotCrash() throws {
        let url = try fixtureURL("realistic_5k_run")
        let workout = try GPXImporter().importWorkout(from: url)

        // Splits should be valid
        for (i, split) in workout.splits.enumerated() {
            XCTAssertGreaterThan(split.distanceMeters, 0, "Split \(i) distance should be > 0")
            XCTAssertGreaterThan(split.elapsedSeconds, 0, "Split \(i) elapsed should be > 0")
            XCTAssertFalse(split.paceSecondsPerKilometer.isNaN, "Split \(i) pace should not be NaN")
            XCTAssertFalse(split.paceSecondsPerKilometer.isInfinite, "Split \(i) pace should not be infinite")
        }
    }

    // MARK: - Basic GPX Parsing Tests

    func testGPXImporterParsesBasicTrackpoints() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
          <trk>
            <trkseg>
              <trkpt lat="1.2966" lon="103.7764">
                <ele>10.0</ele>
                <time>2026-07-05T07:00:00Z</time>
              </trkpt>
              <trkpt lat="1.2970" lon="103.7770">
                <ele>15.0</ele>
                <time>2026-07-05T07:05:00Z</time>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = Data(gpx.utf8)
        let tempURL = try writeTempFile(data: data, extension: "gpx")
        let workout = try GPXImporter().importWorkout(from: tempURL)

        XCTAssertEqual(workout.routePoints.count, 2)
        XCTAssertEqual(workout.routePoints[0].latitude, 1.2966, accuracy: 0.0001)
        XCTAssertEqual(workout.routePoints[1].latitude, 1.2970, accuracy: 0.0001)
        XCTAssertEqual(workout.routePoints[0].altitudeMeters, 10.0)
        XCTAssertEqual(workout.routePoints[1].altitudeMeters, 15.0)
    }

    func testGPXImporterHandlesMissingElevation() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
          <trk>
            <trkseg>
              <trkpt lat="1.2966" lon="103.7764">
                <time>2026-07-05T07:00:00Z</time>
              </trkpt>
              <trkpt lat="1.2970" lon="103.7770">
                <time>2026-07-05T07:05:00Z</time>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = Data(gpx.utf8)
        let tempURL = try writeTempFile(data: data, extension: "gpx")
        let workout = try GPXImporter().importWorkout(from: tempURL)

        XCTAssertEqual(workout.routePoints.count, 2)
        XCTAssertNil(workout.routePoints[0].altitudeMeters)
        XCTAssertFalse(workout.hasAltitudeData)
    }

    func testGPXImporterHandlesMissingTime() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
          <trk>
            <trkseg>
              <trkpt lat="1.2966" lon="103.7764">
                <ele>10.0</ele>
              </trkpt>
              <trkpt lat="1.2970" lon="103.7770">
                <ele>15.0</ele>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = Data(gpx.utf8)
        let tempURL = try writeTempFile(data: data, extension: "gpx")
        let workout = try GPXImporter().importWorkout(from: tempURL)

        XCTAssertEqual(workout.routePoints.count, 2)
        // Should still have elapsed time (synthetic from index)
        XCTAssertEqual(workout.routePoints[0].elapsedSeconds, 0)
        XCTAssertEqual(workout.routePoints[1].elapsedSeconds, 1)
    }

    func testGPXImporterThrowsOnEmptyTrack() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
          <trk>
            <trkseg>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = Data(gpx.utf8)
        let tempURL = try writeTempFile(data: data, extension: "gpx")

        XCTAssertThrowsError(try GPXImporter().importWorkout(from: tempURL)) { error in
            guard case WorkoutImportError.missingData = error else {
                XCTFail("Expected missingData error, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    private func fixtureURL(_ name: String) throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let resourcesURL = testFile
            .deletingLastPathComponent()  // GPXImporterTests
            .deletingLastPathComponent()  // RunPlayStudioTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Resources")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("\(name).gpx")

        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            throw XCTSkip("Fixture \(name).gpx not found at \(resourcesURL.path)")
        }

        return resourcesURL
    }

    private func writeTempFile(data: Data, extension ext: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: tempURL)
        return tempURL
    }
}
