import XCTest
@testable import RunPlayCore

final class ImporterDispatchTests: XCTestCase {

    // MARK: - Extension Dispatch

    func testJSONImporterDispatchedByExtension() throws {
        let url = URL(filePath: "/tmp/test.json")
        let importer = try WorkoutImporterFactory.importer(for: url)
        XCTAssertTrue(importer is JSONWorkoutImporter)
    }

    func testGPXImporterDispatchedByExtension() throws {
        let url = URL(filePath: "/tmp/test.gpx")
        let importer = try WorkoutImporterFactory.importer(for: url)
        XCTAssertTrue(importer is GPXImporter)
    }

    func testTCXImporterDispatchedByExtension() throws {
        let url = URL(filePath: "/tmp/test.tcx")
        let importer = try WorkoutImporterFactory.importer(for: url)
        XCTAssertTrue(importer is TCXImporter)
    }

    func testFITImporterDispatchedByExtension() throws {
        let url = URL(filePath: "/tmp/test.fit")
        let importer = try WorkoutImporterFactory.importer(for: url)
        XCTAssertTrue(importer is FITImporter)
    }

    func testUnsupportedExtensionThrows() {
        let url = URL(filePath: "/tmp/test.xyz")
        XCTAssertThrowsError(try WorkoutImporterFactory.importer(for: url)) { error in
            guard case WorkoutImportError.unsupportedFormat = error else {
                XCTFail("Expected unsupportedFormat error, got \(error)")
                return
            }
        }
    }

    func testCaseInsensitiveExtension() throws {
        let url = URL(filePath: "/tmp/test.JSON")
        let importer = try WorkoutImporterFactory.importer(for: url)
        XCTAssertTrue(importer is JSONWorkoutImporter)
    }

    // MARK: - Supported Extensions

    func testSupportedExtensionsContainsJSON() {
        XCTAssertTrue(WorkoutImporterFactory.supportedExtensions.contains("json"))
    }

    func testSupportedExtensionsContainsGPX() {
        XCTAssertTrue(WorkoutImporterFactory.supportedExtensions.contains("gpx"))
    }

    func testSupportedExtensionsContainsTCX() {
        XCTAssertTrue(WorkoutImporterFactory.supportedExtensions.contains("tcx"))
    }

    func testSupportedExtensionsContainsFIT() {
        XCTAssertTrue(WorkoutImporterFactory.supportedExtensions.contains("fit"))
    }

    func testSupportedExtensionsCount() {
        // At minimum: json, gpx, tcx, fit
        XCTAssertGreaterThanOrEqual(WorkoutImporterFactory.supportedExtensions.count, 4)
    }

    // MARK: - SSRF Prevention (isFileURL guard)

    func testImportersRejectNonFileURLs() {
        let importers: [WorkoutImporting] = [
            JSONWorkoutImporter(),
            GPXImporter(),
            TCXImporter(),
            FITImporter()
        ]
        let httpURL = URL(string: "https://example.com/workout.json")!
        for importer in importers {
            XCTAssertThrowsError(try importer.importWorkout(from: httpURL),
                                 "\(type(of: importer)) should reject non-file URL") { error in
                guard case WorkoutImportError.invalidFormat = error else {
                    XCTFail("Expected invalidFormat error, got \(error)")
                    return
                }
            }
        }
    }

    func testImportersRejectMissingFiles() {
        let importers: [WorkoutImporting] = [
            JSONWorkoutImporter(),
            GPXImporter(),
            TCXImporter(),
            FITImporter()
        ]
        let missingURL = URL(filePath: "/nonexistent/path/workout.json")
        for importer in importers {
            XCTAssertThrowsError(try importer.importWorkout(from: missingURL),
                                 "\(type(of: importer)) should reject missing file") { error in
                guard case WorkoutImportError.fileNotFound = error else {
                    XCTFail("Expected fileNotFound error, got \(error)")
                    return
                }
            }
        }
    }

    // MARK: - Importer Protocol

    func testAllImportersHaveSupportedExtensions() {
        let importers: [WorkoutImporting] = [
            JSONWorkoutImporter(),
            GPXImporter(),
            TCXImporter(),
            FITImporter()
        ]
        for importer in importers {
            XCTAssertFalse(importer.supportedExtensions.isEmpty,
                           "\(type(of: importer)) should have supported extensions")
        }
    }
}
