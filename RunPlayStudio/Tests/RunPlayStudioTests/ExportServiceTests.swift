import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class ExportServiceTests: XCTestCase {

    let exportService = ExportService()

    // MARK: - Splits CSV

    func testSplitsCSVHasHeader() {
        let workout = createSampleWorkout()
        let csv = exportService.generateSplitsCSV(workout: workout)
        let lines = csv.split(separator: "\n").map(String.init)

        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines[0].contains("Split"))
        XCTAssertTrue(lines[0].contains("Pace"))
        XCTAssertTrue(lines[0].contains("Duration"))
    }

    func testSplitsCSVHasExpectedRowCount() {
        let workout = createSampleWorkout()
        let csv = exportService.generateSplitsCSV(workout: workout)
        let lines = csv.split(separator: "\n").map(String.init)

        // Header + data rows
        XCTAssertEqual(lines.count, workout.splits.count + 1)
    }

    func testSplitsCSVContainsSplitData() {
        let workout = createSampleWorkout()
        let csv = exportService.generateSplitsCSV(workout: workout)

        // Should contain formatted split data
        XCTAssertTrue(csv.contains("1")) // Split number
        XCTAssertTrue(csv.contains("km")) // Distance unit in header
    }

    // MARK: - Segments CSV

    func testSegmentsCSVHasHeader() {
        let segments = createSampleSegments()
        let csv = exportService.generateSegmentsCSV(segments: segments)
        let lines = csv.split(separator: "\n").map(String.init)

        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines[0].contains("Type"))
        XCTAssertTrue(lines[0].contains("Title"))
        XCTAssertTrue(lines[0].contains("Pace"))
    }

    func testSegmentsCSVIncludesAllTypes() {
        let segments = createSampleSegments()
        let csv = exportService.generateSegmentsCSV(segments: segments)

        XCTAssertTrue(csv.contains("fastest400m"))
        XCTAssertTrue(csv.contains("fastest1km"))
        XCTAssertTrue(csv.contains("slowest1km"))
        XCTAssertTrue(csv.contains("biggestClimb"))
        XCTAssertTrue(csv.contains("biggestDescent"))
    }

    func testSegmentsCSVHasExpectedRowCount() {
        let segments = createSampleSegments()
        let csv = exportService.generateSegmentsCSV(segments: segments)
        let lines = csv.split(separator: "\n").map(String.init)

        // Header + data rows
        XCTAssertEqual(lines.count, segments.count + 1)
    }

    // MARK: - CSV Escaping

    func testCSVEscapingForCommas() {
        let result = CSVRow.escape("hello, world")
        XCTAssertEqual(result, "\"hello, world\"")
    }

    func testCSVEscapingForQuotes() {
        let result = CSVRow.escape("say \"hello\"")
        XCTAssertEqual(result, "\"say \"\"hello\"\"\"")
    }

    func testCSVEscapingForNewlines() {
        let result = CSVRow.escape("line1\nline2")
        XCTAssertEqual(result, "\"line1\nline2\"")
    }

    func testCSVEscapingNormalText() {
        let result = CSVRow.escape("normal text")
        XCTAssertEqual(result, "normal text")
    }

    func testCSVRowJoined() {
        let row = CSVRow.joined(["a", "b,c", "d"])
        XCTAssertEqual(row, "a,\"b,c\",d")
    }

    // MARK: - JSON Export

    func testJSONSummaryContainsKeyFields() throws {
        let workout = createSampleWorkout()
        let segments = createSampleSegments()
        let result = try exportService.exportWorkoutSummaryJSON(workout: workout, segments: segments)

        let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        XCTAssertNotNil(json)

        XCTAssertEqual(json?["appName"] as? String, "RunPlay Studio")
        XCTAssertEqual(json?["exportVersion"] as? String, "1.0")
        XCTAssertNotNil(json?["privacyNote"])
        XCTAssertNotNil(json?["workoutTitle"])
        XCTAssertNotNil(json?["totalDistanceMeters"])
        XCTAssertNotNil(json?["totalDurationSeconds"])
        XCTAssertNotNil(json?["averagePaceSecondsPerKilometer"])
    }

    func testJSONSummaryContainsSplits() throws {
        let workout = createSampleWorkout()
        let segments = createSampleSegments()
        let result = try exportService.exportWorkoutSummaryJSON(workout: workout, segments: segments)

        let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let splits = json?["splits"] as? [[String: Any]]
        XCTAssertNotNil(splits)
        XCTAssertFalse(splits!.isEmpty)
    }

    func testJSONSummaryContainsSegments() throws {
        let workout = createSampleWorkout()
        let segments = createSampleSegments()
        let result = try exportService.exportWorkoutSummaryJSON(workout: workout, segments: segments)

        let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let segs = json?["segments"] as? [[String: Any]]
        XCTAssertNotNil(segs)
        XCTAssertEqual(segs!.count, segments.count)
    }

    func testJSONSummaryPrivacyNote() throws {
        let workout = createSampleWorkout()
        let result = try exportService.exportWorkoutSummaryJSON(workout: workout, segments: [])

        let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let note = json?["privacyNote"] as? String
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("local") || note!.contains("Local"))
    }

    func testBundledDemoExportSmokeUsesSyntheticData() throws {
        let workout = try loadFixture("sample_run.json")
        let segments = SegmentDetector.detectSegments(from: workout)

        let json = try exportService.exportWorkoutSummaryJSON(workout: workout, segments: segments)
        let splits = try exportService.exportSplitsCSV(workout: workout)
        let segmentCSV = try exportService.exportSegmentsCSV(segments: segments)
        let combined = try exportService.exportCombinedCSV(workout: workout, segments: segments)

        XCTAssertFalse(json.data.isEmpty)
        XCTAssertFalse(splits.data.isEmpty)
        XCTAssertFalse(segmentCSV.data.isEmpty)
        XCTAssertFalse(combined.data.isEmpty)
        XCTAssertEqual(json.format, .json)
        XCTAssertEqual(splits.format, .splitsCSV)
        XCTAssertEqual(segmentCSV.format, .segmentsCSV)
        XCTAssertEqual(combined.format, .combinedCSV)

        let jsonText = try XCTUnwrap(String(data: json.data, encoding: .utf8))
        let splitsText = try XCTUnwrap(String(data: splits.data, encoding: .utf8))
        let segmentText = try XCTUnwrap(String(data: segmentCSV.data, encoding: .utf8))
        let combinedText = try XCTUnwrap(String(data: combined.data, encoding: .utf8))

        XCTAssertTrue(jsonText.contains("RunPlay Studio"))
        XCTAssertTrue(splitsText.contains("Split"))
        XCTAssertTrue(segmentText.contains("Type"))
        XCTAssertTrue(combinedText.contains("# Splits"))
        XCTAssertDemoExportContainsNoPrivateMarkers(jsonText)
        XCTAssertDemoExportContainsNoPrivateMarkers(splitsText)
        XCTAssertDemoExportContainsNoPrivateMarkers(segmentText)
        XCTAssertDemoExportContainsNoPrivateMarkers(combinedText)

        do {
            let png = try PNGExportService.exportSummaryPNG(workout: workout, segments: segments)
            XCTAssertGreaterThan(png.data.count, 8)
            XCTAssertEqual(Array(png.data.prefix(8)), pngSignature)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rendering") ||
                         error.localizedDescription.contains("size"),
                         "Unexpected error: \(error.localizedDescription)")
        }
    }

    // MARK: - Filename Builder

    func testFilenameBuilderProducesSafeFilename() {
        let workout = createSampleWorkout()
        let filename = ExportFilenameBuilder.filename(for: workout, format: .json)

        XCTAssertTrue(filename.hasSuffix(".json"))
        XCTAssertFalse(filename.contains(" "))
        XCTAssertFalse(filename.contains("/"))
        XCTAssertTrue(filename.count <= 80) // Reasonable length
    }

    func testFilenameBuilderForCSV() {
        let filename = ExportFilenameBuilder.filename(for: nil, format: .splitsCSV)
        XCTAssertTrue(filename.hasSuffix(".csv"))
        XCTAssertTrue(filename.contains("runplay"))
    }

    func testFilenameBuilderForPNG() {
        let workout = createSampleWorkout()
        let filename = ExportFilenameBuilder.filename(for: workout, format: .png)
        XCTAssertTrue(filename.hasSuffix(".png"))
    }

    // MARK: - Edge Cases

    func testEmptySplitsDoesNotCrash() {
        let workout = RunWorkout(routePoints: createSamplePoints())
        let csv = exportService.generateSplitsCSV(workout: workout)
        XCTAssertTrue(csv.contains("Split")) // Header only
    }

    func testEmptySegmentsDoesNotCrash() {
        let csv = exportService.generateSegmentsCSV(segments: [])
        XCTAssertTrue(csv.contains("Type")) // Header only
    }

    func testMissingOptionalMetricsDoNotCrash() {
        // Workout without HR or elevation
        let points = (0..<10).map { i in
            RoutePoint(
                timestamp: Date(),
                latitude: 37.7749 + Double(i) * 0.001,
                longitude: -122.4194,
                altitudeMeters: nil,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 30
            )
        }
        let workout = RunWorkout(routePoints: points)

        // Should not crash
        let csv = exportService.generateSplitsCSV(workout: workout)
        XCTAssertFalse(csv.isEmpty)
    }

    func testDeterministicOutput() {
        let workout = createSampleWorkout()
        let csv1 = exportService.generateSplitsCSV(workout: workout)
        let csv2 = exportService.generateSplitsCSV(workout: workout)
        XCTAssertEqual(csv1, csv2, "CSV output should be deterministic")
    }

    // MARK: - PNG Export

    func testSummaryCardModelBuildsFromWorkout() {
        let workout = createSampleWorkout()
        let segments = createSampleSegments()
        let model = ExportSummaryCardModel(workout: workout, segments: segments)

        XCTAssertEqual(model.appBranding, "RunPlay Studio")
        XCTAssertFalse(model.workoutTitle.isEmpty)
        XCTAssertFalse(model.dateText.isEmpty)
        XCTAssertTrue(model.distanceText.contains("km"))
        XCTAssertTrue(model.durationText.contains(":"))
        XCTAssertTrue(model.paceText.contains("/km"))
        XCTAssertTrue(model.elevationGainText.contains("m"))
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertFalse(model.splits.isEmpty)
    }

    func testSummaryCardModelHandlesMissingHeartRate() {
        let points = (0..<10).map { i in
            RoutePoint(
                timestamp: Date(),
                latitude: 37.7749,
                longitude: -122.4194,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 30
            )
        }
        let workout = RunWorkout(routePoints: points)
        let model = ExportSummaryCardModel(workout: workout, segments: [])

        XCTAssertNil(model.heartRateText)
        XCTAssertNil(model.maxHeartRateText)
        XCTAssertFalse(model.distanceText.isEmpty)
    }

    func testSummaryCardModelHandlesEmptySegments() {
        let workout = createSampleWorkout()
        let model = ExportSummaryCardModel(workout: workout, segments: [])

        XCTAssertTrue(model.segments.isEmpty)
        XCTAssertFalse(model.splits.isEmpty)
    }

    func testSummaryCardModelPrivacyNote() {
        let workout = createSampleWorkout()
        let model = ExportSummaryCardModel(workout: workout, segments: [])

        XCTAssertTrue(model.privacyNote.contains("RunPlay Studio"))
        XCTAssertTrue(model.privacyNote.contains("local") || model.privacyNote.contains("Local"))
    }

    func testFilenameBuilderSupportsPNG() {
        let workout = createSampleWorkout()
        let filename = ExportFilenameBuilder.filename(for: workout, format: .png)
        XCTAssertTrue(filename.hasSuffix(".png"))
        XCTAssertFalse(filename.contains(" "))
    }

    func testFilenameBuilderHandlesDemoExportNames() {
        let workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Morning Park Demo / Export: Test", activityType: "running"),
            source: .json,
            routePoints: createSamplePoints()
        )

        let filename = ExportFilenameBuilder.filename(for: workout, format: .json)

        XCTAssertTrue(filename.hasPrefix("morning-park-demo-export-test"))
        XCTAssertTrue(filename.hasSuffix(".json"))
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(":"))
        XCTAssertFalse(filename.contains(" "))
    }

    func testPNGExportReturnsNonEmptyData() throws {
        let workout = createSampleWorkout()
        let segments = createSampleSegments()

        // PNG rendering requires window context, may fail in headless CI
        do {
            let result = try PNGExportService.exportSummaryPNG(workout: workout, segments: segments)
            XCTAssertGreaterThan(result.data.count, 0)
            XCTAssertEqual(result.format, .png)
            XCTAssertTrue(result.filename.hasSuffix(".png"))
        } catch {
            // Expected in headless CI - verify error is about rendering, not data
            XCTAssertTrue(error.localizedDescription.contains("rendering") ||
                         error.localizedDescription.contains("size"),
                         "Unexpected error: \(error.localizedDescription)")
        }
    }

    func testPNGDataHasValidSignature() throws {
        let workout = createSampleWorkout()

        // PNG rendering requires window context, may fail in headless CI
        do {
            let result = try PNGExportService.exportSummaryPNG(workout: workout, segments: [])
            let data = result.data
            XCTAssertGreaterThanOrEqual(data.count, 8)
            XCTAssertEqual(Array(data.prefix(8)), pngSignature)
        } catch {
            // Expected in headless CI
            XCTAssertTrue(error.localizedDescription.contains("rendering") ||
                         error.localizedDescription.contains("size"))
        }
    }

    // MARK: - Helpers

    private func createSampleWorkout() -> RunWorkout {
        var points: [RoutePoint] = []
        let startDate = Date()

        for i in 0..<100 {
            let dist = Double(i) * 50
            let time = Double(i) * 15
            points.append(RoutePoint(
                timestamp: startDate.addingTimeInterval(time),
                latitude: 37.7749 + dist / 111000,
                longitude: -122.4194,
                altitudeMeters: 10 + Double(i) * 0.5,
                distanceFromStartMeters: dist,
                elapsedSeconds: time,
                heartRateBPM: 120 + Double(i % 20)
            ))
        }

        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Test Run", activityType: "running", startDate: startDate),
            source: .json,
            routePoints: points
        )

        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)
        return workout
    }

    private func createSamplePoints() -> [RoutePoint] {
        (0..<10).map { i in
            RoutePoint(
                timestamp: Date(),
                latitude: 37.7749,
                longitude: -122.4194,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 30
            )
        }
    }

    private func createSampleSegments() -> [SegmentHighlight] {
        [
            SegmentHighlight(type: .fastest400m, title: "Fastest 400m", subtitle: "4:00 /km", startDistanceMeters: 0, endDistanceMeters: 400, startElapsedSeconds: 0, endElapsedSeconds: 96, durationSeconds: 96, distanceMeters: 400, paceSecondsPerKilometer: 240, sourcePointRange: 0..<10, displayPriority: 1),
            SegmentHighlight(type: .fastest1km, title: "Fastest Kilometer", subtitle: "4:15 /km", startDistanceMeters: 0, endDistanceMeters: 1000, startElapsedSeconds: 0, endElapsedSeconds: 255, durationSeconds: 255, distanceMeters: 1000, paceSecondsPerKilometer: 255, sourcePointRange: 0..<20, displayPriority: 2),
            SegmentHighlight(type: .slowest1km, title: "Slowest Kilometer", subtitle: "6:00 /km", startDistanceMeters: 2000, endDistanceMeters: 3000, startElapsedSeconds: 600, endElapsedSeconds: 960, durationSeconds: 360, distanceMeters: 1000, paceSecondsPerKilometer: 360, sourcePointRange: 40..<60, displayPriority: 3),
            SegmentHighlight(type: .biggestClimb, title: "Biggest Climb", subtitle: "+50 m ↑", startDistanceMeters: 1000, endDistanceMeters: 2000, startElapsedSeconds: 255, endElapsedSeconds: 600, durationSeconds: 345, distanceMeters: 1000, elevationDeltaMeters: 50, sourcePointRange: 20..<40, displayPriority: 4),
            SegmentHighlight(type: .biggestDescent, title: "Biggest Descent", subtitle: "-30 m ↓", startDistanceMeters: 3000, endDistanceMeters: 4000, startElapsedSeconds: 960, endElapsedSeconds: 1260, durationSeconds: 300, distanceMeters: 1000, elevationDeltaMeters: -30, sourcePointRange: 60..<80, displayPriority: 5)
        ]
    }

    private var pngSignature: [UInt8] {
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }

    private func loadFixture(_ relativePath: String) throws -> RunWorkout {
        let baseURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ExportServiceTests
            .deletingLastPathComponent()  // RunPlayStudioTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Resources")
        let url = baseURL.appendingPathComponent(relativePath)
        return try JSONWorkoutImporter().importWorkout(from: url)
    }

    private func XCTAssertDemoExportContainsNoPrivateMarkers(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for marker in ["activity_", "local-workouts", "private-workouts", "23487672964"] {
            XCTAssertFalse(text.contains(marker), "Demo export contains private marker: \(marker)", file: file, line: line)
        }
    }
}
