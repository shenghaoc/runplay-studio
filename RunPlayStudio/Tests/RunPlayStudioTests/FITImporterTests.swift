import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class FITImporterTests: XCTestCase {

    let importer = FITImporter()

    // MARK: - Error Handling

    func testEmptyFileThrows() {
        let data = Data()
        let url = writeTempFIT(data: data)

        // Empty data should throw when trying to read header
        do {
            let _ = try importer.importWorkout(from: url)
            XCTFail("Should throw error for empty file")
        } catch {
            // Expected - any error is fine for empty data
        }
    }

    func testInvalidHeaderThrows() {
        let data = FITFixtureBuilder.buildInvalidHeader()
        let url = writeTempFIT(data: data)

        XCTAssertThrowsError(try importer.importWorkout(from: url))
    }

    func testInvalidDataTypeThrows() {
        let data = FITFixtureBuilder.buildInvalidDataType()
        let url = writeTempFIT(data: data)

        XCTAssertThrowsError(try importer.importWorkout(from: url))
    }

    // MARK: - Valid Import

    func testValidFixtureImports() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        XCTAssertNotNil(workout)
        XCTAssertEqual(workout.source, .fit)
    }

    func testImportedWorkoutHasNonzeroRoutePoints() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        XCTAssertGreaterThan(workout.routePoints.count, 0)
    }

    func testImportedWorkoutHasNonzeroDistance() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        XCTAssertGreaterThan(workout.summary.totalDistanceMeters, 0)
    }

    func testImportedWorkoutHasNonzeroDuration() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        XCTAssertGreaterThan(workout.summary.totalElapsedSeconds, 0)
    }

    // MARK: - Timestamps

    func testTimestampsAreMonotonic() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

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

    // MARK: - Distance

    func testCumulativeDistanceIsNondecreasing() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

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

    // MARK: - Coordinates

    func testCoordinatesAreValid() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)

        for point in workout.routePoints {
            XCTAssertTrue(point.latitude >= -90 && point.latitude <= 90,
                         "Latitude should be valid")
            XCTAssertTrue(point.longitude >= -180 && point.longitude <= 180,
                         "Longitude should be valid")
            XCTAssertTrue(point.latitude.isFinite)
            XCTAssertTrue(point.longitude.isFinite)
        }
    }

    // MARK: - Parsed Fields

    func testAltitudeIsParsed() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        let hasAltitude = workout.routePoints.contains { $0.altitudeMeters != nil }
        XCTAssertTrue(hasAltitude, "Should have altitude data")
    }

    func testSpeedIsParsed() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        let hasSpeed = workout.routePoints.contains { $0.speedMetersPerSecond != nil }
        XCTAssertTrue(hasSpeed, "Should have speed data")
    }

    func testHeartRateIsParsed() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        let hasHR = workout.routePoints.contains { $0.heartRateBPM != nil }
        XCTAssertTrue(hasHR, "Should have heart rate data")
    }

    func testCadenceIsParsed() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        let hasCadence = workout.routePoints.contains { $0.cadence != nil }
        XCTAssertTrue(hasCadence, "Should have cadence data")
    }

    // MARK: - Splits and Segments

    func testSplitGenerationWorks() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        XCTAssertFalse(workout.splits.isEmpty, "Should generate splits")

        for split in workout.splits {
            XCTAssertGreaterThan(split.paceSecondsPerKilometer, 0)
            XCTAssertTrue(split.paceSecondsPerKilometer.isFinite)
        }
    }

    func testSegmentDetectionWorks() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        let segments = SegmentDetector.detectSegments(from: workout)
        XCTAssertFalse(segments.isEmpty, "Should detect segments")
    }

    // MARK: - HR Route Coloring Compatibility

    func testHRRouteColoringWorks() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)
        let projection = RouteProjectionService()
        let scenePoints = projection.project(workout.routePoints)

        let coloringService = RouteColoringService()
        let hasHR = coloringService.hasHeartRateData(points: scenePoints)
        XCTAssertTrue(hasHR, "FIT HR data should be usable for coloring")

        if hasHR {
            let scale = coloringService.computeHeartRateScale(points: scenePoints)
            XCTAssertNotNil(scale)
            if let scale = scale {
                XCTAssertTrue(scale.lowHR.isFinite)
                XCTAssertTrue(scale.highHR.isFinite)
            }
        }
    }

    // MARK: - No NaN/Infinity

    func testNoNaNOrInfiniteMetrics() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let url = writeTempFIT(data: data)

        let workout = try importer.importWorkout(from: url)

        for point in workout.routePoints {
            XCTAssertTrue(point.latitude.isFinite)
            XCTAssertTrue(point.longitude.isFinite)
            XCTAssertTrue(point.distanceFromStartMeters.isFinite)
            XCTAssertTrue(point.elapsedSeconds.isFinite)

            if let alt = point.altitudeMeters {
                XCTAssertTrue(alt.isFinite)
            }
            if let speed = point.speedMetersPerSecond {
                XCTAssertTrue(speed.isFinite)
            }
            if let hr = point.heartRateBPM {
                XCTAssertTrue(hr.isFinite)
            }
        }
    }

    // MARK: - Helpers

    private func writeTempFIT(data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).fit")
        try? data.write(to: url)
        return url
    }
}
