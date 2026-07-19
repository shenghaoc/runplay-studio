import XCTest
@testable import RunPlayCore

final class WorkoutDataImporterTests: XCTestCase {

    func testJSONURLAndDataPathsEquivalent() throws {
        let workout = makeMinimalWorkout()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(RawExport(workout: workout))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("data-import-\(UUID().uuidString).json")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fromURL = try WorkoutImporterFactory.importWorkout(from: tmp)
        let fromData = try WorkoutImporterFactory.importWorkout(from: WorkoutImportInput(
            data: data,
            fileExtension: "json",
            suggestedName: "data-import",
            provenance: WorkoutImportProvenance(provider: .singleFile, contentSHA256: "abc")
        ))

        XCTAssertEqual(fromURL.routePoints.count, fromData.routePoints.count)
        XCTAssertEqual(fromData.importProvenance?.contentSHA256, "abc")
        XCTAssertEqual(fromURL.importProvenance?.provider, .singleFile)
    }

    func testProvenanceDecodesFromLegacySnapshots() throws {
        let workout = makeMinimalWorkout()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(workout)
        // Ensure new field optional: decode after strip
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RunWorkout.self, from: data)
        XCTAssertNil(decoded.importProvenance)

        var withProv = workout
        withProv.importProvenance = WorkoutImportProvenance(
            provider: .stravaBulkExport,
            providerActivityID: "123",
            contentSHA256: "deadbeef",
            originalFilename: "1.gpx"
        )
        data = try encoder.encode(withProv)
        let decoded2 = try decoder.decode(RunWorkout.self, from: data)
        XCTAssertEqual(decoded2.importProvenance?.providerActivityID, "123")
        XCTAssertEqual(decoded2.importProvenance?.contentSHA256, "deadbeef")
    }

    func testUnsupportedExtension() {
        XCTAssertThrowsError(try WorkoutImporterFactory.importWorkout(from: WorkoutImportInput(
            data: Data(),
            fileExtension: "xyz",
            suggestedName: "x"
        ))) { error in
            guard case WorkoutImportError.unsupportedFormat = error else {
                XCTFail("expected unsupportedFormat")
                return
            }
        }
    }

    private func makeMinimalWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<5 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i) * 10),
                latitude: 37.0 + Double(i) * 0.0001,
                longitude: -122.0,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(i) * 20,
                elapsedSeconds: Double(i) * 10
            ))
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Mini", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 80, totalElapsedSeconds: 40)
        )
    }

    /// Minimal JSON that JSONWorkoutImporter accepts (RawWorkout shape).
    private struct RawExport: Encodable {
        let metadata: WorkoutMetadata
        let source: String
        let routePoints: [RoutePoint]

        init(workout: RunWorkout) {
            metadata = workout.metadata
            source = "json"
            routePoints = workout.routePoints
        }
    }
}
