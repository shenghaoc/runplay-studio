import XCTest
@testable import RunPlayCore

/// Route-size and payload-size limits shared by every import path.
///
/// The importer cases inject a small limit so they exercise the real parse and
/// rejection path without building a million-point fixture. The production
/// default is asserted separately, and the central `RouteQualityProcessor`
/// preflight is exercised at the real limit.
final class WorkoutImportResourceLimitsTests: XCTestCase {

    // MARK: - Policy

    func testProductLimitsAreTheDocumentedValues() {
        XCTAssertEqual(WorkoutImportResourceLimits.maxRoutePointCount, 1_000_000)
        XCTAssertEqual(WorkoutImportResourceLimits.maxSourceFileBytes, 100 * 1024 * 1024)
    }

    /// The engine ceiling must stay at least 25% above the product limit so a
    /// route the app accepts can never be rejected at the C++ boundary.
    func testEngineCeilingKeepsDocumentedMarginOverProductLimit() {
        let engineCeiling = RunPlayEngineLimits.maxRouteInputSamples
        let productLimit = WorkoutImportResourceLimits.maxRoutePointCount

        XCTAssertGreaterThanOrEqual(
            Double(engineCeiling),
            Double(productLimit) * 1.25,
            "max_route_input_samples must stay at least 1.25x maxRoutePointCount"
        )
        XCTAssertEqual(engineCeiling, 1_250_000)
    }

    /// Every format shares one payload ceiling rather than restating it.
    func testFITLimitsDeriveFromTheSharedPolicy() {
        XCTAssertEqual(FITParser.maxFileSize, WorkoutImportResourceLimits.maxSourceFileBytes)
        XCTAssertEqual(
            FITMultiSessionImportPolicy.default.maxContainerBytes,
            WorkoutImportResourceLimits.maxSourceFileBytes
        )
        XCTAssertEqual(
            FITMultiSessionImportPolicy.default.maxRecords,
            WorkoutImportResourceLimits.maxRoutePointCount
        )
    }

    func testValidatorsAcceptTheLimitAndRejectOneMore() throws {
        let limit = WorkoutImportResourceLimits.maxRoutePointCount
        XCTAssertNoThrow(try WorkoutImportResourceLimits.validateRoutePointCount(limit))
        XCTAssertThrowsError(
            try WorkoutImportResourceLimits.validateRoutePointCount(limit + 1)
        ) { error in
            XCTAssertEqual(
                error as? WorkoutResourceLimitError,
                .routePointLimitExceeded(count: limit + 1, limit: limit)
            )
        }

        let bytes = WorkoutImportResourceLimits.maxSourceFileBytes
        XCTAssertNoThrow(try WorkoutImportResourceLimits.validateSourceByteCount(bytes))
        XCTAssertThrowsError(
            try WorkoutImportResourceLimits.validateSourceByteCount(bytes + 1)
        )
    }

    /// The message is user-visible, so it must name the limit rather than show
    /// an opaque enum case.
    func testResourceLimitErrorMessageStatesTheLimit() throws {
        let error = WorkoutResourceLimitError.routePointLimitExceeded(
            count: 1_000_001,
            limit: 1_000_000
        )
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(
            message.contains("1,000,000") || message.contains("1000000"),
            "expected the point limit in: \(message)"
        )
        XCTAssertFalse(message.contains("routePointLimitExceeded"))

        let sizeMessage = try XCTUnwrap(
            WorkoutResourceLimitError
                .sourceFileTooLarge(limitBytes: 100 * 1024 * 1024)
                .errorDescription
        )
        XCTAssertTrue(sizeMessage.contains("100 MB"), sizeMessage)
    }

    // MARK: - Central route-processing preflight

    /// Programmatic callers bypass the importers, so the processor rejects an
    /// oversized route before building the native input buffer.
    func testRouteProcessorPreflightRejectsOversizedRouteAtTheRealLimit() {
        let overLimit = WorkoutImportResourceLimits.maxRoutePointCount + 1
        var points: [RoutePoint] = []
        points.reserveCapacity(overLimit)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for index in 0..<overLimit {
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(Double(index)),
                    latitude: 1.0,
                    longitude: 103.0,
                    distanceFromStartMeters: 0,
                    elapsedSeconds: Double(index)
                )
            )
        }

        XCTAssertThrowsError(
            try RouteQualityProcessor().process(
                points,
                distancePolicy: .computeFromCoordinates,
                isCancelled: { false }
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkoutResourceLimitError,
                .routePointLimitExceeded(
                    count: overLimit,
                    limit: WorkoutImportResourceLimits.maxRoutePointCount
                )
            )
        }
    }

    func testRouteProcessorAcceptsRouteAtTheLimitBoundary() throws {
        // Exactly at the limit is accepted; only one more is rejected. Uses a
        // tiny route with the shared validator to keep the assertion cheap.
        XCTAssertNoThrow(
            try WorkoutImportResourceLimits.validateRoutePointCount(
                WorkoutImportResourceLimits.maxRoutePointCount
            )
        )
        let result = try RouteQualityProcessor().process(
            Self.smallRoute(count: 3),
            distancePolicy: .computeFromCoordinates,
            isCancelled: { false }
        )
        XCTAssertEqual(result.routePoints.count, 3)
    }

    // MARK: - GPX

    func testGPXRejectsRouteBeyondLimitAndStopsParsing() {
        let data = Self.gpxData(trackpointCount: 12)
        XCTAssertThrowsError(
            try GPXImporter().importWorkout(
                data: data,
                suggestedName: "over",
                maxRoutePointCount: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkoutResourceLimitError,
                .routePointLimitExceeded(count: 11, limit: 10),
                "GPX must fail on point limit + 1, not after building the route"
            )
        }
    }

    func testGPXAcceptsRouteExactlyAtLimit() throws {
        let workout = try GPXImporter().importWorkout(
            data: Self.gpxData(trackpointCount: 10),
            suggestedName: "at-limit",
            maxRoutePointCount: 10
        )
        XCTAssertEqual(workout.routePoints.count, 10)
    }

    // MARK: - TCX

    func testTCXRejectsSelectedActivityBeyondLimit() {
        XCTAssertThrowsError(
            try TCXImporter().importWorkout(
                data: Self.tcxData(trackpointCount: 12),
                suggestedName: "over",
                maxRoutePointCount: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkoutResourceLimitError,
                .routePointLimitExceeded(count: 11, limit: 10)
            )
        }
    }

    func testTCXAcceptsActivityExactlyAtLimit() throws {
        let workout = try TCXImporter().importWorkout(
            data: Self.tcxData(trackpointCount: 10),
            suggestedName: "at-limit",
            maxRoutePointCount: 10
        )
        XCTAssertEqual(workout.routePoints.count, 10)
    }

    // MARK: - JSON

    func testJSONRejectsDecodedRouteBeyondLimit() {
        XCTAssertThrowsError(
            try JSONWorkoutImporter().importWorkout(
                from: WorkoutImportInput(
                    data: Self.jsonData(pointCount: 12),
                    fileExtension: "json",
                    suggestedName: "over"
                ),
                maxRoutePointCount: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkoutResourceLimitError,
                .routePointLimitExceeded(count: 12, limit: 10)
            )
        }
    }

    func testJSONAcceptsRouteExactlyAtLimit() throws {
        let workout = try JSONWorkoutImporter().importWorkout(
            from: WorkoutImportInput(
                data: Self.jsonData(pointCount: 10),
                fileExtension: "json",
                suggestedName: "at-limit"
            ),
            maxRoutePointCount: 10
        )
        XCTAssertEqual(workout.routePoints.count, 10)
    }

    // MARK: - Bounded source reader

    /// The reader consumes at most `limit + 1` bytes rather than trusting file
    /// metadata before an unbounded read.
    func testBoundedReaderRejectsPayloadOverLimit() throws {
        let url = try Self.temporaryFile(byteCount: 4_096)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try GPXImporter().readBoundedSourceData(at: url, limit: 1_024)
        ) { error in
            XCTAssertEqual(
                error as? WorkoutResourceLimitError,
                .sourceFileTooLarge(
                    limitBytes: WorkoutImportResourceLimits.maxSourceFileBytes
                )
            )
        }
    }

    func testBoundedReaderAcceptsPayloadExactlyAtLimit() throws {
        let url = try Self.temporaryFile(byteCount: 1_024)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try GPXImporter().readBoundedSourceData(at: url, limit: 1_024)
        XCTAssertEqual(data.count, 1_024)
    }

    func testInMemoryImportRejectsOversizedPayload() {
        let oversized = Data(
            repeating: 0x20,
            count: WorkoutImportResourceLimits.maxSourceFileBytes + 1
        )
        for importer in [
            AnyImporter(GPXImporter()),
            AnyImporter(TCXImporter()),
            AnyImporter(JSONWorkoutImporter()),
            AnyImporter(FITImporter()),
        ] {
            XCTAssertThrowsError(
                try importer.importWorkout(
                    from: WorkoutImportInput(
                        data: oversized,
                        fileExtension: importer.fileExtension,
                        suggestedName: "oversized"
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? WorkoutResourceLimitError,
                    .sourceFileTooLarge(
                        limitBytes: WorkoutImportResourceLimits.maxSourceFileBytes
                    ),
                    "\(importer.fileExtension) must reject an oversized payload"
                )
            }
        }
    }

    // MARK: - Fixtures

    private struct AnyImporter {
        let fileExtension: String
        private let importClosure: (WorkoutImportInput) throws -> RunWorkout

        init<Importer: WorkoutImporting>(_ importer: Importer) {
            self.fileExtension = importer.supportedExtensions[0]
            self.importClosure = { try importer.importWorkout(from: $0) }
        }

        func importWorkout(from input: WorkoutImportInput) throws -> RunWorkout {
            try importClosure(input)
        }
    }

    private static func smallRoute(count: Int) -> [RoutePoint] {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return (0..<count).map { index in
            RoutePoint(
                timestamp: start.addingTimeInterval(Double(index)),
                latitude: 1.0 + Double(index) * 0.0001,
                longitude: 103.0,
                distanceFromStartMeters: 0,
                elapsedSeconds: Double(index)
            )
        }
    }

    private static func temporaryFile(byteCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runplay-bounded-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        return url
    }

    private static func gpxData(trackpointCount: Int) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"><trk><trkseg>
        """
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        for index in 0..<trackpointCount {
            let time = formatter.string(from: start.addingTimeInterval(Double(index)))
            xml += """
            <trkpt lat="\(1.0 + Double(index) * 0.0001)" lon="103.0">\
            <ele>10</ele><time>\(time)</time></trkpt>
            """
        }
        xml += "</trkseg></trk></gpx>"
        return Data(xml.utf8)
    }

    private static func tcxData(trackpointCount: Int) -> Data {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase><Activities><Activity Sport="Running">\
        <Id>\(formatter.string(from: start))</Id>\
        <Lap StartTime="\(formatter.string(from: start))"><Track>
        """
        for index in 0..<trackpointCount {
            let time = formatter.string(from: start.addingTimeInterval(Double(index)))
            xml += """
            <Trackpoint><Time>\(time)</Time><Position>\
            <LatitudeDegrees>\(1.0 + Double(index) * 0.0001)</LatitudeDegrees>\
            <LongitudeDegrees>103.0</LongitudeDegrees></Position>\
            <AltitudeMeters>10</AltitudeMeters></Trackpoint>
            """
        }
        xml += "</Track></Lap></Activity></Activities></TrainingCenterDatabase>"
        return Data(xml.utf8)
    }

    private static func jsonData(pointCount: Int) -> Data {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        let points = (0..<pointCount).map { index in
            """
            {"timestamp":"\(formatter.string(from: start.addingTimeInterval(Double(index))))",\
            "latitude":\(1.0 + Double(index) * 0.0001),"longitude":103.0,\
            "elapsedSeconds":\(index)}
            """
        }
        let json = """
        {"source":"json","routePoints":[\(points.joined(separator: ","))]}
        """
        return Data(json.utf8)
    }
}
