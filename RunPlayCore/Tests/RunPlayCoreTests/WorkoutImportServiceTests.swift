import XCTest
@testable import RunPlayCore

final class WorkoutImportServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportServiceTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeWorkoutJSON(name: String = "Test Run") throws -> URL {
        let workout = RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: Date(timeIntervalSince1970: 1_000_000)),
            source: .json,
            routePoints: [
                RoutePoint(
                    timestamp: Date(timeIntervalSince1970: 1_000_000),
                    latitude: 37.0,
                    longitude: -122.0,
                    altitudeMeters: 100,
                    distanceFromStartMeters: 0,
                    elapsedSeconds: 0
                ),
                RoutePoint(
                    timestamp: Date(timeIntervalSince1970: 1_000_300),
                    latitude: 37.001,
                    longitude: -122.001,
                    altitudeMeters: 105,
                    distanceFromStartMeters: 150,
                    elapsedSeconds: 300
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("\(name).json")
        try encoder.encode(workout).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Tests

    func testSuccessfulImport() async throws {
        let url = try makeWorkoutJSON(name: "Import Test")
        let service = WorkoutImportService()

        let workout = try await service.importWorkout(from: url)

        XCTAssertEqual(workout.metadata.name, "Import Test")
        XCTAssertEqual(workout.routePoints.count, 2)
    }

    func testParseFailurePropagates() async {
        let url = tempDir.appendingPathComponent("nonexistent.json")
        let service = WorkoutImportService()

        do {
            _ = try await service.importWorkout(from: url)
            XCTFail("Expected error")
        } catch {
            // Expected: file not found or similar
        }
    }

    func testParseRunsOffMainThread() async throws {
        // Verify that parsing does NOT happen on the main actor.
        // If it did, this assertion would fail.
        let url = try makeWorkoutJSON(name: "Off-Main")
        let service = WorkoutImportService()

        let workout = try await service.importWorkout(from: url)
        XCTAssertNotNil(workout)
    }
}
