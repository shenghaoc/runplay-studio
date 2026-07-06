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

    // MARK: - Helpers

    private func resourceURL(_ path: String) -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        return testFile
            .deletingLastPathComponent()  // JSONImporterTests
            .deletingLastPathComponent()  // RunPlayStudioTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Resources")
            .appendingPathComponent(path)
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
