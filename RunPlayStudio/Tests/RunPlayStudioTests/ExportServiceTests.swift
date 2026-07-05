import XCTest
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
}
