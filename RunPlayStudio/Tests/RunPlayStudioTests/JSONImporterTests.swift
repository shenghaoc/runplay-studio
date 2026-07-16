import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class JSONImporterTests: XCTestCase {

    func testSampleFixtureLoads() throws {
        let resourcesURL = resourceURL("sample_run.json")

        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            XCTFail("sample_run.json not found at \(resourcesURL.path)")
            return
        }

        let workout = try JSONWorkoutImporter().importWorkout(from: resourcesURL)
        validateWorkout(workout)
    }

    func testComparisonFixtureLoads() throws {
        let resourcesURL = resourceURL("fixtures/comparison_park_run.json")

        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            XCTFail("comparison_park_run.json not found at \(resourcesURL.path)")
            return
        }

        let workout = try JSONWorkoutImporter().importWorkout(from: resourcesURL)
        validateWorkout(workout)
        XCTAssertEqual(workout.displayName, "Morning Park Progression Run")
        XCTAssertGreaterThanOrEqual(workout.splits.count, 7)
    }

    func testJSONImporterParsesRoutePoints() throws {
        let json = """
        {
            "metadata": { "name": "Test Run", "activityType": "running" },
            "source": "json",
            "routePoints": [
                { "timestamp": "2026-01-01T00:00:00Z", "latitude": 37.7749, "longitude": -122.4194, "altitudeMeters": 10, "distanceFromStartMeters": 0, "elapsedSeconds": 0 },
                { "timestamp": "2026-01-01T00:05:00Z", "latitude": 37.7759, "longitude": -122.4184, "altitudeMeters": 20, "distanceFromStartMeters": 1000, "elapsedSeconds": 300 }
            ]
        }
        """

        let data = Data(json.utf8)
        let importer = JSONWorkoutImporter()
        let workout = try importer.importWorkout(from: data)

        XCTAssertEqual(workout.routePoints.count, 2)
        XCTAssertEqual(workout.routePoints[0].latitude, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(workout.routePoints[1].latitude, 37.7759, accuracy: 0.0001)
        XCTAssertEqual(workout.routePoints[0].distanceFromStartMeters, 0)
        XCTAssertEqual(workout.routePoints[1].distanceFromStartMeters, 1000)
    }

    func testDistanceCalculationReturnsNonzero() throws {
        let json = """
        {
            "routePoints": [
                { "timestamp": "2026-01-01T00:00:00Z", "latitude": 37.7749, "longitude": -122.4194 },
                { "timestamp": "2026-01-01T00:05:00Z", "latitude": 37.7759, "longitude": -122.4184 }
            ]
        }
        """

        let data = Data(json.utf8)
        let workout = try JSONWorkoutImporter().importWorkout(from: data)

        XCTAssertGreaterThan(workout.summary.totalDistanceMeters, 0)
    }

    func testPaceCalculationReturnsPlausibleValues() throws {
        let json = """
        {
            "routePoints": [
                { "timestamp": "2026-01-01T00:00:00Z", "latitude": 37.7749, "longitude": -122.4194 },
                { "timestamp": "2026-01-01T00:05:00Z", "latitude": 37.7759, "longitude": -122.4184 }
            ]
        }
        """

        let data = Data(json.utf8)
        let workout = try JSONWorkoutImporter().importWorkout(from: data)

        // Pace should be positive and finite
        let pace = workout.summary.averagePaceSecondsPerKilometer
        XCTAssertGreaterThan(pace, 0, "Pace should be positive")
        XCTAssertTrue(pace.isFinite, "Pace should be finite")
        XCTAssertFalse(pace.isNaN, "Pace should not be NaN")
    }

    func testMixedSuppliedDistancesAreRecomputedInsteadOfMixed() throws {
        let json = """
        {
            "routePoints": [
                { "timestamp": "2026-01-01T00:00:00Z", "latitude": 37.7749, "longitude": -122.4194, "distanceFromStartMeters": 1000 },
                { "timestamp": "2026-01-01T00:01:00Z", "latitude": 37.7759, "longitude": -122.4184 },
                { "timestamp": "2026-01-01T00:02:00Z", "latitude": 37.7769, "longitude": -122.4174, "distanceFromStartMeters": 500 }
            ]
        }
        """

        let workout = try JSONWorkoutImporter().importWorkout(from: Data(json.utf8))

        let firstDistance = try XCTUnwrap(workout.routePoints.first?.distanceFromStartMeters)
        XCTAssertEqual(firstDistance, 0, accuracy: 0.001)
        for index in 1..<workout.routePoints.count {
            XCTAssertGreaterThanOrEqual(
                workout.routePoints[index].distanceFromStartMeters,
                workout.routePoints[index - 1].distanceFromStartMeters
            )
        }
    }

    func testInvalidSegmentMakesCompleteJSONDistanceSeriesFallBackAsAWhole() throws {
        let json = """
        {
            "routePoints": [
                { "timestamp": "2026-01-01T00:00:00Z", "latitude": 1.0000, "longitude": 103.0, "distanceFromStartMeters": 0, "routeSegmentIndex": 0 },
                { "timestamp": "2026-01-01T00:00:10Z", "latitude": 1.0002, "longitude": 103.0, "distanceFromStartMeters": 100, "routeSegmentIndex": 0 },
                { "timestamp": "2026-01-01T00:00:20Z", "latitude": 1.0004, "longitude": 103.0, "distanceFromStartMeters": 100, "routeSegmentIndex": 1 },
                { "timestamp": "2026-01-01T00:00:30Z", "latitude": 1.0006, "longitude": 103.0, "distanceFromStartMeters": 50, "routeSegmentIndex": 1 }
            ]
        }
        """

        let workout = try JSONWorkoutImporter().importWorkout(from: Data(json.utf8))

        XCTAssertEqual(workout.routeDistanceSource, .coordinateDerived)
        XCTAssertEqual(
            workout.routeDistanceProvenance.segmentSources,
            [.coordinateDerived, .coordinateDerived]
        )
    }

    func testInvalidCoordinateIsCountedInPersistedQualityDiagnostics() throws {
        let json = """
        {
            "routePoints": [
                { "timestamp": "2026-01-01T00:00:00Z", "latitude": 1.0, "longitude": 103.0 },
                { "timestamp": "2026-01-01T00:00:10Z", "latitude": 91.0, "longitude": 103.0 },
                { "timestamp": "2026-01-01T00:00:20Z", "latitude": 1.0002, "longitude": 103.0 }
            ]
        }
        """

        let workout = try JSONWorkoutImporter().importWorkout(from: Data(json.utf8))

        XCTAssertEqual(workout.routePoints.count, 2)
        XCTAssertEqual(workout.qualityDiagnostics.invalidCoordinatePointCount, 1)
    }

    func testRouteSegmentsPreservePauseAwareClocksAndGlobalDistance() throws {
        let json = """
        {
            "metadata": { "name": "Paused JSON Run", "activityType": "running" },
            "routePoints": [
                { "timestamp": "2026-01-01T00:00:00Z", "latitude": 1.0, "longitude": 1.0, "distanceFromStartMeters": 0, "routeSegmentIndex": 0 },
                { "timestamp": "2026-01-01T00:03:00Z", "latitude": 1.006, "longitude": 1.0, "distanceFromStartMeters": 600, "routeSegmentIndex": 0 },
                { "timestamp": "2026-01-01T00:53:00Z", "latitude": 1.006, "longitude": 1.0, "distanceFromStartMeters": 600, "routeSegmentIndex": 1 },
                { "timestamp": "2026-01-01T00:55:00Z", "latitude": 1.01, "longitude": 1.0, "distanceFromStartMeters": 1000, "routeSegmentIndex": 1 }
            ]
        }
        """

        let workout = try JSONWorkoutImporter().importWorkout(from: Data(json.utf8))

        XCTAssertEqual(workout.routePoints.map(\.routeSegmentIndex), [0, 0, 1, 1])
        XCTAssertEqual(workout.routePoints.map(\.distanceFromStartMeters), [0, 600, 600, 1_000])
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 3_300, accuracy: 0.001)
        XCTAssertEqual(workout.summary.totalActiveSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(workout.summary.totalPausedSeconds, 3_000, accuracy: 0.001)
        XCTAssertEqual(workout.analysisVersion, RunWorkout.currentAnalysisVersion)
        XCTAssertEqual(workout.splits.count, 1)
    }

    func testNativeJSONRecordedLapRoundTripsAndReanalyzes() throws {
        let workout = try JSONWorkoutImporter().importWorkout(from: nativeWorkoutJSON())

        XCTAssertEqual(workout.recordedLaps.count, 1)
        XCTAssertEqual(workout.recordedLaps[0].trigger, .manual)
        XCTAssertEqual(workout.recordedLaps[0].distanceMeters, 1_000, accuracy: 0.001)
        XCTAssertEqual(workout.recordedLaps[0].reportedMetrics?.rawIntensityValue, "Active")
        XCTAssertEqual(
            workout.sourceStructureVersion,
            RunWorkout.currentSourceStructureVersion
        )
    }

    func testMalformedOptionalJSONLapDoesNotRejectValidRoute() throws {
        let validData = try nativeWorkoutJSON()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        var laps = try XCTUnwrap(object["recordedLaps"] as? [[String: Any]])
        laps.append(["lapIndex": "not-an-integer"])
        object["recordedLaps"] = laps

        let workout = try JSONWorkoutImporter().importWorkout(
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(workout.routePoints.count, 2)
        XCTAssertEqual(workout.recordedLaps.count, 1)
        XCTAssertEqual(workout.recordedLapDiagnostics.sourceLapCount, 2)
        XCTAssertEqual(workout.recordedLapDiagnostics.importedLapCount, 1)
        XCTAssertEqual(workout.recordedLapDiagnostics.malformedLapCount, 1)
        XCTAssertTrue(workout.analysisWarnings.contains(.recordedLapsMalformedSkipped))
    }

    func testMalformedRecordedLapContainerDoesNotRejectValidRoute() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: nativeWorkoutJSON()) as? [String: Any]
        )
        object["recordedLaps"] = ["unexpected": true]

        let workout = try JSONWorkoutImporter().importWorkout(
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(workout.routePoints.count, 2)
        XCTAssertTrue(workout.recordedLaps.isEmpty)
        XCTAssertEqual(workout.recordedLapDiagnostics.sourceLapCount, 1)
        XCTAssertEqual(workout.recordedLapDiagnostics.importedLapCount, 0)
        XCTAssertEqual(workout.recordedLapDiagnostics.malformedLapCount, 1)
        XCTAssertTrue(workout.analysisWarnings.contains(.recordedLapsMalformedSkipped))
    }

    // MARK: - Helpers

    private func resourceURL(_ path: String) -> URL {
        let testFile = URL(filePath: #filePath)
        return testFile
            .deletingLastPathComponent()  // JSONImporterTests
            .deletingLastPathComponent()  // RunPlayStudioTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Resources")
            .appendingPathComponent(path)
    }

    private func nativeWorkoutJSON() throws -> Data {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let routePoints = [
            RoutePoint(
                timestamp: start,
                latitude: 1,
                longitude: 103,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(300),
                latitude: 1.001,
                longitude: 103,
                distanceFromStartMeters: 1_000,
                elapsedSeconds: 300
            )
        ]
        let lap = RecordedLap(
            lapIndex: 1,
            source: .json,
            trigger: .manual,
            sourceStartDate: start,
            sourceEndDate: start.addingTimeInterval(300),
            startElapsedSeconds: 0,
            endElapsedSeconds: 300,
            startDistanceMeters: 0,
            endDistanceMeters: 1_000,
            elapsedSeconds: 300,
            activeSeconds: 300,
            movingSeconds: 300,
            reportedMetrics: RecordedLapReportedMetrics(
                elapsedSeconds: 300,
                distanceMeters: 1_000,
                rawIntensityValue: "Active",
                rawTriggerValue: "Manual"
            )
        )
        let workout = RunWorkout(
            source: .json,
            routePoints: routePoints,
            recordedLaps: [lap]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(workout)
    }

    private func validateWorkout(_ workout: RunWorkout) {
        XCTAssertFalse(workout.routePoints.isEmpty, "Workout should have route points")
        XCTAssertGreaterThan(workout.summary.totalDistanceMeters, 0, "Distance should be > 0")
        XCTAssertGreaterThan(workout.summary.totalElapsedSeconds, 0, "Elapsed time should be > 0")

        // Verify no NaN or infinity
        XCTAssertFalse(workout.summary.totalDistanceMeters.isNaN)
        XCTAssertFalse(workout.summary.totalDistanceMeters.isInfinite)
        XCTAssertFalse(workout.summary.averagePaceSecondsPerKilometer.isNaN)
        XCTAssertFalse(workout.summary.averagePaceSecondsPerKilometer.isInfinite)

        // Verify splits exist
        XCTAssertFalse(workout.splits.isEmpty, "Workout should have splits")
    }
}
