import XCTest
import RunPlayCore
import RunPlayPlatform
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

    func testAgreeingSessionClockTotalsProduceNoWarning() throws {
        let data = FITFixtureBuilder.buildSampleRunWithSession(
            elapsedSeconds: 290,
            timerSeconds: 290
        )
        let workout = try importer.importWorkout(from: writeTempFIT(data: data))

        XCTAssertEqual(workout.summary.totalElapsedSeconds, 290, accuracy: 0.001)
        XCTAssertEqual(workout.summary.totalActiveSeconds, 290, accuracy: 0.001)
        XCTAssertTrue(workout.analysisWarnings.isEmpty)
    }

    func testInconsistentSessionClockTotalsWarnWhileRouteRemainsAuthoritative() throws {
        let data = FITFixtureBuilder.buildSampleRunWithSession(
            elapsedSeconds: 1_000,
            timerSeconds: 900
        )
        let workout = try importer.importWorkout(from: writeTempFIT(data: data))

        XCTAssertEqual(workout.summary.totalElapsedSeconds, 290, accuracy: 0.001)
        XCTAssertEqual(workout.summary.totalActiveSeconds, 290, accuracy: 0.001)
        XCTAssertTrue(workout.analysisWarnings.contains(.sourceElapsedTimeMismatch))
        XCTAssertTrue(workout.analysisWarnings.contains(.sourceActiveTimeMismatch))
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

    // MARK: - Recorded laps

    func testFITLapsPreservedFromSelectedSession() throws {
        let data = FITFixtureBuilder.buildSampleRunWithLaps()
        let workout = try importer.importWorkout(from: writeTempFIT(data: data))

        XCTAssertEqual(workout.recordedLaps.count, 2)
        XCTAssertEqual(workout.recordedLaps[0].trigger, .manual)
        XCTAssertEqual(workout.recordedLaps[1].trigger, .distance)
        XCTAssertEqual(workout.recordedLaps[0].reportedMetrics?.distanceMeters ?? -1, 2_500, accuracy: 0.1)
        XCTAssertEqual(workout.recordedLaps[0].reportedMetrics?.calories, 180)
        XCTAssertEqual(workout.recordedLaps[1].reportedMetrics?.calories, 190)
        XCTAssertEqual(workout.sourceStructureVersion, RunWorkout.currentSourceStructureVersion)

        // Lap messages must not create route segments by themselves.
        // Without timer events, the sample remains a single continuous segment.
        let segments = Set(workout.routePoints.map(\.routeSegmentIndex))
        XCTAssertEqual(segments.count, 1)

        // Canonical metrics are finite and satisfy clock invariants.
        for lap in workout.recordedLaps {
            XCTAssertEqual(lap.elapsedSeconds, lap.activeSeconds + lap.pausedSeconds, accuracy: 0.001)
            XCTAssertEqual(lap.activeSeconds, lap.movingSeconds + lap.stoppedSeconds, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(lap.distanceMeters, 0)
        }
    }

    func testFITWithoutLapsRemainsValid() throws {
        let data = FITFixtureBuilder.buildSampleRun()
        let workout = try importer.importWorkout(from: writeTempFIT(data: data))
        XCTAssertTrue(workout.recordedLaps.isEmpty)
        XCTAssertEqual(workout.sourceStructureVersion, RunWorkout.currentSourceStructureVersion)
        XCTAssertGreaterThan(workout.routePoints.count, 0)
    }

    func testInvalidSelectedSessionStartFallsBackWithoutDiscardingLap() throws {
        let data = FITFixtureBuilder.buildMultiSessionRunWithInvalidSelectedStartAndLap()
        let workout = try importer.importWorkout(from: writeTempFIT(data: data))

        XCTAssertFalse(workout.routePoints.isEmpty)
        XCTAssertEqual(workout.recordedLaps.count, 1)
        XCTAssertEqual(workout.recordedLaps[0].trigger, .manual)
        XCTAssertEqual(workout.recordedLapDiagnostics.sourceLapCount, 1)
        XCTAssertEqual(workout.recordedLapDiagnostics.malformedLapCount, 0)
    }

    func testMalformedSelectedSessionLapIsDiagnosedWithoutRejectingRoute() throws {
        let data = FITFixtureBuilder.buildSampleRunWithMalformedLap()
        let workout = try importer.importWorkout(from: writeTempFIT(data: data))

        XCTAssertFalse(workout.routePoints.isEmpty)
        XCTAssertTrue(workout.recordedLaps.isEmpty)
        XCTAssertEqual(workout.recordedLapDiagnostics.sourceLapCount, 1)
        XCTAssertEqual(workout.recordedLapDiagnostics.malformedLapCount, 1)
        XCTAssertTrue(workout.analysisWarnings.contains(.recordedLapsMalformedSkipped))
    }

    // MARK: - Shared canonical builder

    /// The direct import path and the explicit decode-by-index builder must
    /// produce identical workouts for an ordinary one-session file. If they
    /// ever diverge, direct and batch import have two implementations again.
    func testDirectImportMatchesExplicitSessionBuilderFieldByField() throws {
        let data = FITFixtureBuilder.buildSampleRunWithLaps()
        let url = writeTempFIT(data: data)

        let direct = try importer.importWorkout(from: url)
        let decodedFile = try FITParser.parse(data: data)
        let viaBuilder = try importer.importSession(
            from: decodedFile,
            sessionIndex: 0,
            suggestedName: direct.metadata.name ?? "",
            provenance: direct.importProvenance
        )

        XCTAssertEqual(viaBuilder.source, direct.source)
        XCTAssertEqual(viaBuilder.metadata.name, direct.metadata.name)
        XCTAssertEqual(viaBuilder.metadata.activityType, direct.metadata.activityType)
        XCTAssertEqual(viaBuilder.metadata.startDate, direct.metadata.startDate)
        XCTAssertEqual(viaBuilder.metadata.endDate, direct.metadata.endDate)
        XCTAssertEqual(viaBuilder.metadata.deviceName, direct.metadata.deviceName)
        XCTAssertEqual(viaBuilder.routePoints.count, direct.routePoints.count)
        XCTAssertEqual(
            viaBuilder.routePoints.map(\.routeSegmentIndex),
            direct.routePoints.map(\.routeSegmentIndex)
        )
        XCTAssertEqual(
            viaBuilder.routePoints.map(\.latitude),
            direct.routePoints.map(\.latitude)
        )
        XCTAssertEqual(
            viaBuilder.routePoints.map(\.distanceFromStartMeters),
            direct.routePoints.map(\.distanceFromStartMeters)
        )
        XCTAssertEqual(viaBuilder.summary, direct.summary)
        XCTAssertEqual(viaBuilder.splits.count, direct.splits.count)
        XCTAssertEqual(viaBuilder.segments.count, direct.segments.count)
        XCTAssertEqual(viaBuilder.recordedLaps.count, direct.recordedLaps.count)
        XCTAssertEqual(
            viaBuilder.recordedLaps.map(\.trigger),
            direct.recordedLaps.map(\.trigger)
        )
        XCTAssertEqual(
            viaBuilder.recordedLaps.map(\.reportedMetrics),
            direct.recordedLaps.map(\.reportedMetrics)
        )
        XCTAssertEqual(viaBuilder.analysisWarnings, direct.analysisWarnings)
        XCTAssertEqual(viaBuilder.normalizationVersion, direct.normalizationVersion)
        XCTAssertEqual(viaBuilder.analysisVersion, direct.analysisVersion)
        XCTAssertEqual(viaBuilder.sourceStructureVersion, direct.sourceStructureVersion)
        XCTAssertEqual(viaBuilder.routeDistanceSource, direct.routeDistanceSource)
        XCTAssertEqual(
            viaBuilder.routeDistanceProvenance.segmentSources,
            direct.routeDistanceProvenance.segmentSources
        )
    }

    func testOrdinaryFITImportKeepsSingleFileProvenance() throws {
        let url = writeTempFIT(data: FITFixtureBuilder.buildSampleRunWithLaps())
        let workout = try WorkoutImporterFactory.importWorkout(from: url)
        XCTAssertEqual(workout.importProvenance?.provider, .singleFile)
        XCTAssertNil(workout.importProvenance?.sourceContainerSHA256)
    }

    // MARK: - Archive compatibility

    /// A Strava archive entry containing several running sessions must stay
    /// fail-safe: the shared data-based factory rejects it, so archive import
    /// reports the entry rather than presenting a nested review sheet.
    func testMultiSessionFITThroughArchiveEntryPathIsRejected() {
        let input = WorkoutImportInput(
            data: FITFixtureBuilder.buildTwoRunningSessions(),
            fileExtension: "fit",
            suggestedName: "activity.fit"
        )
        XCTAssertThrowsError(try WorkoutImporterFactory.importWorkout(from: input)) { error in
            guard case WorkoutImportError.parsingError(let detail) = error else {
                return XCTFail("Expected a parsing error, got \(error)")
            }
            XCTAssertTrue(detail.contains("2 runs"), "Got: \(detail)")
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
