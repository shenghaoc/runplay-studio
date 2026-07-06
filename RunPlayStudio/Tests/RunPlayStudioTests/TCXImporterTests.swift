import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class TCXImporterTests: XCTestCase {

    let importer = TCXImporter()

    // MARK: - Fixture Loading

    func testTCXFixtureLoadsSuccessfully() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        XCTAssertNotNil(workout)
    }

    func testTCXImporterReturnsRunWorkout() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        XCTAssertEqual(workout.source, .tcx)
    }

    func testTCXRoutePointCountAboveMinimum() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        XCTAssertGreaterThanOrEqual(workout.routePoints.count, 20, "Should have at least 20 trackpoints")
    }

    // MARK: - Distance and Duration

    func testTCXDistanceIsNonzero() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        XCTAssertGreaterThan(workout.summary.totalDistanceMeters, 0)
    }

    func testTCXDurationIsNonzero() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        XCTAssertGreaterThan(workout.summary.totalElapsedSeconds, 0)
    }

    // MARK: - Timestamps

    func testTCXTimestampsAreMonotonic() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        let points = workout.routePoints

        for i in 1..<points.count {
            XCTAssertGreaterThanOrEqual(
                points[i].timestamp.timeIntervalSince1970,
                points[i-1].timestamp.timeIntervalSince1970,
                "Timestamps should be monotonic at index \(i)"
            )
        }
    }

    func testTCXCumulativeDistanceIsNondecreasing() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        let points = workout.routePoints

        for i in 1..<points.count {
            XCTAssertGreaterThanOrEqual(
                points[i].distanceFromStartMeters,
                points[i-1].distanceFromStartMeters,
                "Cumulative distance should be nondecreasing at index \(i)"
            )
        }
    }

    // MARK: - Parsed Fields

    func testTCXElevationIsParsed() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        let hasElevation = workout.routePoints.contains { $0.altitudeMeters != nil }
        XCTAssertTrue(hasElevation, "Should have elevation data")
    }

    func testTCXHeartRateIsParsed() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        let hasHR = workout.routePoints.contains { $0.heartRateBPM != nil }
        XCTAssertTrue(hasHR, "Should have heart rate data")
    }

    func testTCXCadenceIsParsed() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        let hasCadence = workout.routePoints.contains { $0.cadence != nil }
        XCTAssertTrue(hasCadence, "Should have cadence data")
    }

    func testTCXMetadataIsExtracted() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        XCTAssertNotNil(workout.metadata.startDate)
        XCTAssertFalse(workout.metadata.activityType.isEmpty)
    }

    // MARK: - Splits and Segments

    func testTCXSplitGenerationWorks() throws {
        let url = try fixtureURL("sample-run")
        var workout = try importer.importWorkout(from: url)
        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)

        XCTAssertFalse(workout.splits.isEmpty, "Should generate splits")
        for split in workout.splits {
            XCTAssertGreaterThan(split.paceSecondsPerKilometer, 0, "Split pace should be positive")
            XCTAssertTrue(split.paceSecondsPerKilometer.isFinite, "Split pace should be finite")
        }
    }

    func testTCXSegmentDetectionWorks() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)
        let segments = SegmentDetector.detectSegments(from: workout)

        XCTAssertFalse(segments.isEmpty, "Should detect segments")
    }

    // MARK: - Edge Cases

    func testTCXMissingDistanceFallsBackToComputed() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2026-07-05T07:30:00.000Z</Id>
              <Lap StartTime="2026-07-05T07:30:00.000Z">
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:00.000Z</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                    <AltitudeMeters>12.0</AltitudeMeters>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:10.000Z</Time>
                    <Position><LatitudeDegrees>1.2976</LatitudeDegrees><LongitudeDegrees>103.7774</LongitudeDegrees></Position>
                    <AltitudeMeters>15.0</AltitudeMeters>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:20.000Z</Time>
                    <Position><LatitudeDegrees>1.2986</LatitudeDegrees><LongitudeDegrees>103.7784</LongitudeDegrees></Position>
                    <AltitudeMeters>18.0</AltitudeMeters>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let url = try createTempTCX(tcx)
        let workout = try importer.importWorkout(from: url)

        XCTAssertEqual(workout.routePoints.count, 3)
        XCTAssertGreaterThan(workout.summary.totalDistanceMeters, 0, "Should compute distance from coordinates")
    }

    func testTCXFirstNonzeroDistanceIsRebased() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2026-07-05T07:30:00.000Z</Id>
              <Lap StartTime="2026-07-05T07:30:00.000Z">
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:00.000Z</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                    <DistanceMeters>50</DistanceMeters>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:10.000Z</Time>
                    <Position><LatitudeDegrees>1.2976</LatitudeDegrees><LongitudeDegrees>103.7774</LongitudeDegrees></Position>
                    <DistanceMeters>150</DistanceMeters>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let url = try createTempTCX(tcx)
        let workout = try importer.importWorkout(from: url)

        XCTAssertEqual(workout.routePoints[0].distanceFromStartMeters, 0, accuracy: 0.001)
        XCTAssertEqual(workout.routePoints[1].distanceFromStartMeters, 100, accuracy: 0.001)
    }

    func testTCXMissingHRDoesNotCrash() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2026-07-05T07:30:00.000Z</Id>
              <Lap StartTime="2026-07-05T07:30:00.000Z">
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:00.000Z</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:10.000Z</Time>
                    <Position><LatitudeDegrees>1.2976</LatitudeDegrees><LongitudeDegrees>103.7774</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let url = try createTempTCX(tcx)
        let workout = try importer.importWorkout(from: url)

        XCTAssertEqual(workout.routePoints.count, 2)
        XCTAssertFalse(workout.hasHeartRateData)
    }

    func testTCXMalformedXMLThrowsError() {
        let tcx = "this is not valid xml at all"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("malformed.tcx")
        try? tcx.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try importer.importWorkout(from: url)) { error in
            XCTAssertTrue(error is WorkoutImportError, "Should throw WorkoutImportError")
        }
    }

    func testTCXEmptyFileThrowsError() {
        let tcx = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><TrainingCenterDatabase></TrainingCenterDatabase>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty.tcx")
        try? tcx.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try importer.importWorkout(from: url)) { error in
            XCTAssertTrue(error is WorkoutImportError, "Should throw WorkoutImportError")
        }
    }

    func testTCXNoNaNOrInfiniteMetrics() throws {
        let url = try fixtureURL("sample-run")
        let workout = try importer.importWorkout(from: url)

        for point in workout.routePoints {
            XCTAssertTrue(point.latitude.isFinite, "Latitude should be finite")
            XCTAssertTrue(point.longitude.isFinite, "Longitude should be finite")
            XCTAssertTrue(point.distanceFromStartMeters.isFinite, "Distance should be finite")
            XCTAssertTrue(point.elapsedSeconds.isFinite, "Elapsed should be finite")

            if let alt = point.altitudeMeters {
                XCTAssertTrue(alt.isFinite, "Altitude should be finite")
            }
            if let hr = point.heartRateBPM {
                XCTAssertTrue(hr.isFinite, "HR should be finite")
            }
        }
    }

    // MARK: - Helpers

    private func fixtureURL(_ name: String) throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixturesURL = testFile
            .deletingLastPathComponent()  // TCXImporterTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RunPlayStudio
            .appendingPathComponent("Resources")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("\(name).tcx")

        guard FileManager.default.fileExists(atPath: fixturesURL.path) else {
            XCTFail("Fixture \(name).tcx not found at \(fixturesURL.path)")
            throw WorkoutImportError.fileNotFound(fixturesURL)
        }

        return fixturesURL
    }

    private func createTempTCX(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).tcx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
