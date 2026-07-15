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
                    <Time>2026-07-05T07:30:10.000Z</Time>
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

    func testTCXPartialMissingTimesAreInterpolated() throws {
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
                    <Position><LatitudeDegrees>1.2976</LatitudeDegrees><LongitudeDegrees>103.7774</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:20.000Z</Time>
                    <Position><LatitudeDegrees>1.2986</LatitudeDegrees><LongitudeDegrees>103.7784</LongitudeDegrees></Position>
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
        XCTAssertEqual(workout.routePoints[1].elapsedSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(workout.routePoints[2].elapsedSeconds, 20, accuracy: 0.001)
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

    // MARK: - Timestamp Parsing

    func testTCXStandardTimestampParses() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2026-07-05T07:30:00Z</Id>
              <Lap StartTime="2026-07-05T07:30:00Z">
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:00Z</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:35:00Z</Time>
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
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 300, accuracy: 1)
    }

    func testTCXFractionalTimestampParses() throws {
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
                    <Time>2026-07-05T07:35:00.500Z</Time>
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
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 300.5, accuracy: 0.01)
    }

    func testTCXInvalidTimestampRejectsFile() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>not-a-date</Id>
              <Lap StartTime="not-a-date">
                <Track>
                  <Trackpoint>
                    <Time>not-a-date</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>also-not-a-date</Time>
                    <Position><LatitudeDegrees>1.2976</LatitudeDegrees><LongitudeDegrees>103.7774</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let url = try createTempTCX(tcx)
        XCTAssertThrowsError(try importer.importWorkout(from: url)) { error in
            guard case WorkoutImportError.missingData = error else {
                XCTFail("Expected missingData error, got \(error)")
                return
            }
        }
    }

    // MARK: - Segment-Aware Tests

    func testTCXMultipleTracksGetDistinctSegmentIndexes() throws {
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
                    <Position><LatitudeDegrees>1.2970</LatitudeDegrees><LongitudeDegrees>103.7770</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:40:00.000Z</Time>
                    <Position><LatitudeDegrees>1.3000</LatitudeDegrees><LongitudeDegrees>103.7800</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:40:10.000Z</Time>
                    <Position><LatitudeDegrees>1.3010</LatitudeDegrees><LongitudeDegrees>103.7810</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let tempURL = try createTempTCX(tcx)
        let workout = try importer.importWorkout(from: tempURL)

        XCTAssertEqual(workout.routePoints.count, 4)
        // First track: segment 0
        XCTAssertEqual(workout.routePoints[0].routeSegmentIndex, 0)
        XCTAssertEqual(workout.routePoints[1].routeSegmentIndex, 0)
        // Second track: segment 1
        XCTAssertEqual(workout.routePoints[2].routeSegmentIndex, 1)
        XCTAssertEqual(workout.routePoints[3].routeSegmentIndex, 1)
    }

    func testTCXDistanceIsRebasedPerTrack() throws {
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
                    <DistanceMeters>1000</DistanceMeters>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:10.000Z</Time>
                    <Position><LatitudeDegrees>1.2970</LatitudeDegrees><LongitudeDegrees>103.7770</LongitudeDegrees></Position>
                    <DistanceMeters>1050</DistanceMeters>
                  </Trackpoint>
                </Track>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:40:00.000Z</Time>
                    <Position><LatitudeDegrees>1.3000</LatitudeDegrees><LongitudeDegrees>103.7800</LongitudeDegrees></Position>
                    <DistanceMeters>500</DistanceMeters>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:40:10.000Z</Time>
                    <Position><LatitudeDegrees>1.3010</LatitudeDegrees><LongitudeDegrees>103.7810</LongitudeDegrees></Position>
                    <DistanceMeters>550</DistanceMeters>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let tempURL = try createTempTCX(tcx)
        let workout = try importer.importWorkout(from: tempURL)

        XCTAssertEqual(workout.routePoints.count, 4)

        // First track: rebased from 1000 → starts at 0, second point at ~50
        XCTAssertEqual(workout.routePoints[0].distanceFromStartMeters, 0, accuracy: 0.01)
        XCTAssertEqual(workout.routePoints[1].distanceFromStartMeters, 50, accuracy: 1)

        // Second track: cumulative distance continues from prior segment end (~50).
        // The sanitizer adds computed distance from coordinates on top.
        let seg2Start = workout.routePoints[2].distanceFromStartMeters
        XCTAssertGreaterThanOrEqual(seg2Start, 49, "Second segment should continue from prior end")

        // Distance should be monotonically non-decreasing across segments.
        XCTAssertGreaterThanOrEqual(
            workout.routePoints[3].distanceFromStartMeters,
            seg2Start,
            "Distance should not decrease across segments"
        )
    }

    func testTCXNoPhantomDistanceAcrossLaps() throws {
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
                    <Position><LatitudeDegrees>1.2970</LatitudeDegrees><LongitudeDegrees>103.7770</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
              <!-- Far-away lap -->
              <Lap StartTime="2026-07-05T08:00:00.000Z">
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T08:00:00.000Z</Time>
                    <Position><LatitudeDegrees>2.0000</LatitudeDegrees><LongitudeDegrees>104.0000</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T08:00:10.000Z</Time>
                    <Position><LatitudeDegrees>2.0010</LatitudeDegrees><LongitudeDegrees>104.0010</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let tempURL = try createTempTCX(tcx)
        let workout = try importer.importWorkout(from: tempURL)

        XCTAssertEqual(workout.routePoints.count, 4)
        // Total distance should not include the ~100km GPS gap between laps.
        let totalDistance = workout.routePoints.last!.distanceFromStartMeters
        XCTAssertLessThan(totalDistance, 1000, "Total distance should not include GPS gap")
    }

    func testTCXMultipleGPSActivitiesThrowsError() throws {
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
                </Track>
              </Lap>
            </Activity>
            <Activity Sport="Running">
              <Id>2026-07-05T08:30:00.000Z</Id>
              <Lap StartTime="2026-07-05T08:30:00.000Z">
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T08:30:00.000Z</Time>
                    <Position><LatitudeDegrees>1.3000</LatitudeDegrees><LongitudeDegrees>103.7800</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let tempURL = try createTempTCX(tcx)
        XCTAssertThrowsError(try importer.importWorkout(from: tempURL)) { error in
            guard case WorkoutImportError.invalidFormat = error else {
                XCTFail("Expected invalidFormat error for multiple activities, got \(error)")
                return
            }
        }
    }

    // MARK: - Recorded laps

    func testTCXSeamlessLapsRemainOneRouteSegment() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2026-07-05T07:30:00.000Z</Id>
              <Lap StartTime="2026-07-05T07:30:00.000Z">
                <TotalTimeSeconds>20</TotalTimeSeconds>
                <DistanceMeters>200</DistanceMeters>
                <TriggerMethod>Manual</TriggerMethod>
                <AverageHeartRateBpm><Value>140</Value></AverageHeartRateBpm>
                <MaximumHeartRateBpm><Value>150</Value></MaximumHeartRateBpm>
                <Cadence>85</Cadence>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:00.000Z</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                    <DistanceMeters>0</DistanceMeters>
                    <HeartRateBpm><Value>140</Value></HeartRateBpm>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:20.000Z</Time>
                    <Position><LatitudeDegrees>1.2970</LatitudeDegrees><LongitudeDegrees>103.7770</LongitudeDegrees></Position>
                    <DistanceMeters>200</DistanceMeters>
                    <HeartRateBpm><Value>145</Value></HeartRateBpm>
                  </Trackpoint>
                </Track>
              </Lap>
              <Lap StartTime="2026-07-05T07:30:20.000Z">
                <TotalTimeSeconds>20</TotalTimeSeconds>
                <DistanceMeters>200</DistanceMeters>
                <TriggerMethod>Distance</TriggerMethod>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:20.000Z</Time>
                    <Position><LatitudeDegrees>1.2970</LatitudeDegrees><LongitudeDegrees>103.7770</LongitudeDegrees></Position>
                    <DistanceMeters>0</DistanceMeters>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:40.000Z</Time>
                    <Position><LatitudeDegrees>1.2974</LatitudeDegrees><LongitudeDegrees>103.7776</LongitudeDegrees></Position>
                    <DistanceMeters>200</DistanceMeters>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let workout = try importer.importWorkout(from: createTempTCX(tcx))

        XCTAssertEqual(workout.recordedLaps.count, 2)
        XCTAssertEqual(workout.recordedLaps[0].trigger, .manual)
        XCTAssertEqual(workout.recordedLaps[1].trigger, .distance)
        XCTAssertEqual(workout.recordedLaps[0].reportedMetrics?.averageHeartRateBPM, 140)
        XCTAssertEqual(workout.recordedLaps[0].reportedMetrics?.distanceMeters, 200)

        // Seamless lap boundary must not create a route gap.
        let segments = Set(workout.routePoints.map(\.routeSegmentIndex))
        XCTAssertEqual(segments.count, 1, "Seamless laps should remain one route segment")

        // Active time must not lose time at the lap boundary.
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 40, accuracy: 0.5)
        XCTAssertEqual(workout.summary.totalActiveSeconds, 40, accuracy: 0.5)
        XCTAssertEqual(workout.summary.totalPausedSeconds, 0, accuracy: 0.5)
        XCTAssertEqual(workout.routePoints.last?.distanceFromStartMeters ?? -1, 400, accuracy: 0.5)
        XCTAssertEqual(workout.sourceStructureVersion, RunWorkout.currentSourceStructureVersion)
    }

    func testTCXMultiTrackPauseCreatesRouteGap() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2026-07-05T07:30:00.000Z</Id>
              <Lap StartTime="2026-07-05T07:30:00.000Z">
                <TotalTimeSeconds>620</TotalTimeSeconds>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:00.000Z</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:10.000Z</Time>
                    <Position><LatitudeDegrees>1.2970</LatitudeDegrees><LongitudeDegrees>103.7770</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:40:00.000Z</Time>
                    <Position><LatitudeDegrees>1.2972</LatitudeDegrees><LongitudeDegrees>103.7772</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:40:10.000Z</Time>
                    <Position><LatitudeDegrees>1.2976</LatitudeDegrees><LongitudeDegrees>103.7778</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let workout = try importer.importWorkout(from: createTempTCX(tcx))
        let segments = Set(workout.routePoints.map(\.routeSegmentIndex))
        XCTAssertGreaterThan(segments.count, 1, "Long multi-track pause should create a route gap")
        XCTAssertEqual(workout.recordedLaps.count, 1)
        XCTAssertGreaterThan(workout.summary.totalPausedSeconds, 0)
    }

    func testTCXLapSummaryDoesNotReplaceCanonicalMetrics() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2026-07-05T07:30:00.000Z</Id>
              <Lap StartTime="2026-07-05T07:30:00.000Z">
                <TotalTimeSeconds>20</TotalTimeSeconds>
                <DistanceMeters>99999</DistanceMeters>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:00.000Z</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                    <DistanceMeters>0</DistanceMeters>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:20.000Z</Time>
                    <Position><LatitudeDegrees>1.2970</LatitudeDegrees><LongitudeDegrees>103.7770</LongitudeDegrees></Position>
                    <DistanceMeters>200</DistanceMeters>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let workout = try importer.importWorkout(from: createTempTCX(tcx))
        XCTAssertEqual(workout.recordedLaps.count, 1)
        XCTAssertEqual(workout.recordedLaps[0].reportedMetrics?.distanceMeters, 99_999)
        XCTAssertLessThan(workout.recordedLaps[0].distanceMeters, 1_000)
    }

    func testTCXLapTotalDefinesBoundaryAfterLastTrackpoint() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>2026-07-05T07:30:00.000Z</Id>
              <Lap StartTime="2026-07-05T07:30:00.000Z">
                <TotalTimeSeconds>20</TotalTimeSeconds>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:00.000Z</Time>
                    <Position><LatitudeDegrees>1.2966</LatitudeDegrees><LongitudeDegrees>103.7764</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:10.000Z</Time>
                    <Position><LatitudeDegrees>1.2970</LatitudeDegrees><LongitudeDegrees>103.7770</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
              <Lap StartTime="2026-07-05T07:30:20.000Z">
                <TotalTimeSeconds>10</TotalTimeSeconds>
                <Track>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:20.000Z</Time>
                    <Position><LatitudeDegrees>1.2974</LatitudeDegrees><LongitudeDegrees>103.7776</LongitudeDegrees></Position>
                  </Trackpoint>
                  <Trackpoint>
                    <Time>2026-07-05T07:30:30.000Z</Time>
                    <Position><LatitudeDegrees>1.2978</LatitudeDegrees><LongitudeDegrees>103.7782</LongitudeDegrees></Position>
                  </Trackpoint>
                </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """

        let workout = try importer.importWorkout(from: createTempTCX(tcx))

        XCTAssertEqual(workout.recordedLaps.count, 2)
        XCTAssertEqual(workout.recordedLaps[0].endElapsedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(workout.recordedLaps[0].elapsedSeconds, 20, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func fixtureURL(_ name: String) throws -> URL {
        let testFile = URL(filePath: #filePath)
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
