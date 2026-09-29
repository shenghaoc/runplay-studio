import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import RunPlayCore

/// Streaming scan of an Apple Health `export.xml`.
///
/// Fixtures are generated in the test and carry invented values only. Nothing
/// here is copied from a real export. The large-document case is written to a
/// temporary file at test time and parsed through `InputStream`, so it is never
/// a committed fixture and never held as one `Data` value.
final class AppleHealthExportParserTests: XCTestCase {

    private let parser = AppleHealthExportParser()

    // MARK: - Fixture

    /// A value-free DTD in the export's declaration shape: `#REQUIRED` and
    /// `#IMPLIED` only, which is what a real export carries and what the elider
    /// must accept.
    private func document(
        records: String,
        workouts: String,
        exportDate: String = "2026-09-02 09:00:00 +0800"
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE HealthData [
        <!ELEMENT HealthData (ExportDate,Record*,Workout*)>
        <!ATTLIST HealthData locale CDATA #REQUIRED>
        <!ELEMENT ExportDate EMPTY>
        <!ATTLIST ExportDate value CDATA #REQUIRED>
        <!ELEMENT Record EMPTY>
        <!ATTLIST Record type CDATA #REQUIRED unit CDATA #IMPLIED \
        value CDATA #IMPLIED startDate CDATA #REQUIRED endDate CDATA #REQUIRED>
        <!ELEMENT Workout (WorkoutStatistics*,WorkoutRoute*)>
        <!ATTLIST Workout workoutActivityType CDATA #REQUIRED \
        startDate CDATA #REQUIRED endDate CDATA #REQUIRED>
        <!ELEMENT WorkoutStatistics EMPTY>
        <!ATTLIST WorkoutStatistics type CDATA #REQUIRED startDate CDATA #IMPLIED \
        endDate CDATA #IMPLIED sum CDATA #IMPLIED unit CDATA #IMPLIED>
        <!ELEMENT WorkoutRoute (FileReference*)>
        <!ELEMENT FileReference EMPTY>
        <!ATTLIST FileReference path CDATA #REQUIRED>
        ]>
        <HealthData locale="en_US">
        <ExportDate value="\(exportDate)"/>
        \(records)
        \(workouts)
        </HealthData>
        """
    }

    private func record(
        type: String,
        value: String,
        start: String,
        end: String
    ) -> String {
        "<Record type=\"\(type)\" value=\"\(value)\" "
            + "startDate=\"\(start)\" endDate=\"\(end)\"/>"
    }

    private func heartRate(_ value: String, start: String, end: String) -> String {
        record(
            type: "HKQuantityTypeIdentifierHeartRate",
            value: value,
            start: start,
            end: end
        )
    }

    private func runningWorkout(
        start: String,
        end: String,
        distanceKm: String = "5.2",
        route: String? = "/workout-routes/route_1.gpx",
        nestedRecord: String? = nil
    ) -> String {
        let statistics = "<WorkoutStatistics type=\"HKQuantityTypeIdentifierDistanceWalkingRunning\" "
            + "sum=\"\(distanceKm)\" unit=\"km\"/>"
        let routeXML = route.map {
            "<WorkoutRoute><FileReference path=\"\($0)\"/></WorkoutRoute>"
        } ?? ""
        let nested = nestedRecord ?? ""
        return "<Workout workoutActivityType=\"HKWorkoutActivityTypeRunning\" "
            + "startDate=\"\(start)\" endDate=\"\(end)\">"
            + statistics + routeXML + nested + "</Workout>"
    }

    private func parse(_ xml: String, ceiling: Int? = nil) throws -> AppleHealthExportScan {
        let data = Data(xml.utf8)
        let subject = ceiling.map { AppleHealthExportParser(heartRateCeiling: $0) } ?? parser
        return try subject.parse(openStream: { InputStream(data: data) })
    }

    private func seconds(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Int64 {
        let parsed = AppleHealthDateParser.parse(text)
        XCTAssertNotNil(parsed, text, file: file, line: line)
        return Int64(parsed!.date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: - What the scan keeps

    func testRunningWorkoutCarriesDistanceRouteAndOffset() throws {
        let start = "2026-09-01 08:00:00 +0800"
        let end = "2026-09-01 09:00:00 +0800"
        let scan = try parse(document(
            records: heartRate("150", start: "2026-09-01 08:30:00 +0800", end: "2026-09-01 08:30:00 +0800"),
            workouts: runningWorkout(start: start, end: end)
        ))

        XCTAssertEqual(scan.locale, "en_US")
        XCTAssertEqual(scan.passCount, 1)
        XCTAssertFalse(scan.usedFilteredSecondPass)
        XCTAssertEqual(scan.workouts.count, 1)

        let workout = try XCTUnwrap(scan.workouts.first)
        XCTAssertEqual(workout.window.activityType, "HKWorkoutActivityTypeRunning")
        XCTAssertEqual(workout.window.startSeconds, seconds(start))
        XCTAssertEqual(workout.window.endSeconds, seconds(end))
        XCTAssertEqual(workout.window.utcOffsetSeconds, 28_800)
        XCTAssertEqual(
            workout.routeArchivePath,
            "apple_health_export/workout-routes/route_1.gpx"
        )
        XCTAssertEqual(workout.statistics.count, 1)
        XCTAssertEqual(workout.statistics[0].sum, 5.2)
        XCTAssertEqual(workout.statistics[0].unit, "km")
        XCTAssertEqual(workout.heartRate.count, 1)
        XCTAssertEqual(workout.heartRate[0].beatsPerMinute, 150)
    }

    func testNonHourOffsetIsExposedOnTheWindow() throws {
        let start = "2026-09-01 08:00:00 +0530"
        let scan = try parse(document(
            records: "",
            workouts: runningWorkout(start: start, end: "2026-09-01 09:00:00 +0530", route: nil)
        ))
        XCTAssertEqual(scan.workouts.first?.window.utcOffsetSeconds, 19_800)
        XCTAssertEqual(scan.workouts.first?.window.startSeconds, seconds(start))
    }

    func testNegativeOffsetIsExposedOnTheWindow() throws {
        let scan = try parse(document(
            records: "",
            workouts: runningWorkout(
                start: "2026-09-01 08:00:00 -0500",
                end: "2026-09-01 09:00:00 -0500",
                route: nil
            )
        ))
        XCTAssertEqual(scan.workouts.first?.window.utcOffsetSeconds, -18_000)
    }

    func testHeartRateJoinsByTimeAndDropsEverythingElse() throws {
        let inside = "2026-09-01 08:30:00 +0800"
        let before = "2026-09-01 07:00:00 +0800"
        let atEnd = "2026-09-01 09:00:00 +0800"
        let records = [
            heartRate("140", start: before, end: before),
            record(
                type: "HKQuantityTypeIdentifierStepCount",
                value: "10",
                start: inside,
                end: inside
            ),
            record(
                type: "HKQuantityTypeIdentifierRestingHeartRate",
                value: "48",
                start: inside,
                end: inside
            ),
            heartRate("151.5", start: inside, end: inside),
            heartRate("160", start: atEnd, end: atEnd),
        ].joined()
        let scan = try parse(document(
            records: records,
            workouts: runningWorkout(
                start: "2026-09-01 08:00:00 +0800",
                end: "2026-09-01 09:00:00 +0800",
                route: nil
            )
        ))

        XCTAssertEqual(scan.heartRateRecordCount, 3)
        // The scan publishes only what it joined: the 140 bpm reading that ends
        // before the window is counted, but is not reachable from the result,
        // because whole-life heart rate never leaves the pass.
        let joined = try XCTUnwrap(scan.workouts.first).heartRate
        XCTAssertEqual(joined.map(\.beatsPerMinute), [151.5, 160])
    }

    func testReadingThatStartsBeforeTheWindowStillJoinsWhenItOverlaps() throws {
        // 07:59:00 for 120 seconds reaches 08:01:00, so it overlaps an 08:00 start.
        let scan = try parse(document(
            records: heartRate(
                "130",
                start: "2026-09-01 07:59:00 +0800",
                end: "2026-09-01 08:01:00 +0800"
            ),
            workouts: runningWorkout(
                start: "2026-09-01 08:00:00 +0800",
                end: "2026-09-01 09:00:00 +0800",
                route: nil
            )
        ))
        let joined = try XCTUnwrap(scan.workouts.first).heartRate
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].durationSeconds, 120)
        XCTAssertEqual(joined[0].beatsPerMinute, 130)
    }

    func testNestedRecordInsideAWorkoutIsNotIndexed() throws {
        let instant = "2026-09-01 08:30:00 +0800"
        let nested = record(
            type: "HKQuantityTypeIdentifierHeartRate",
            value: "999",
            start: instant,
            end: instant
        )
        let scan = try parse(document(
            records: heartRate("150", start: instant, end: instant),
            workouts: runningWorkout(
                start: "2026-09-01 08:00:00 +0800",
                end: "2026-09-01 09:00:00 +0800",
                route: nil,
                nestedRecord: nested
            )
        ))
        XCTAssertEqual(scan.nestedRecordCount, 1)
        XCTAssertEqual(scan.heartRateRecordCount, 1)
        XCTAssertEqual(scan.workouts.first?.heartRate.map(\.beatsPerMinute), [150])
    }

    func testOtherActivityTypesAreKeptForALaterLayerToFilter() throws {
        let cycling = "<Workout workoutActivityType=\"HKWorkoutActivityTypeCycling\" "
            + "startDate=\"2026-09-01 10:00:00 +0800\" endDate=\"2026-09-01 11:00:00 +0800\"/>"
        let scan = try parse(document(
            records: "",
            workouts: runningWorkout(
                start: "2026-09-01 08:00:00 +0800",
                end: "2026-09-01 09:00:00 +0800",
                route: nil
            ) + cycling
        ))
        XCTAssertEqual(
            scan.workouts.map(\.window.activityType),
            ["HKWorkoutActivityTypeRunning", "HKWorkoutActivityTypeCycling"]
        )
    }

    func testRoutePathIsResolvedAndATraversalIsRejected() throws {
        let ok = runningWorkout(
            start: "2026-09-01 08:00:00 +0800",
            end: "2026-09-01 09:00:00 +0800",
            route: "apple_health_export/workout-routes/route_2.gpx"
        )
        let escape = runningWorkout(
            start: "2026-09-02 08:00:00 +0800",
            end: "2026-09-02 09:00:00 +0800",
            route: "/../secret.gpx"
        )
        let scan = try parse(document(records: "", workouts: ok + escape))
        XCTAssertEqual(
            scan.workouts.map(\.routeArchivePath),
            ["apple_health_export/workout-routes/route_2.gpx", nil]
        )
    }

    func testRecordWithNoBeatsPerMinuteIsDropped() throws {
        let instant = "2026-09-01 08:30:00 +0800"
        let missing = "<Record type=\"HKQuantityTypeIdentifierHeartRate\" "
            + "startDate=\"\(instant)\" endDate=\"\(instant)\"/>"
        let scan = try parse(document(
            records: missing,
            workouts: runningWorkout(
                start: "2026-09-01 08:00:00 +0800",
                end: "2026-09-01 09:00:00 +0800",
                route: nil
            )
        ))
        XCTAssertEqual(scan.heartRateRecordCount, 1)
        XCTAssertEqual(scan.workouts.first?.heartRate.count, 0)
    }

    // MARK: - The lossless guard and document shape

    func testQuotedAttributeDefaultFailsInsteadOfImporting() {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE HealthData [
        <!ATTLIST Record value CDATA "supplied">
        ]>
        <HealthData locale="en_US">
        <Record type="HKQuantityTypeIdentifierHeartRate" startDate="2026-09-01 08:00:00 +0800" \
        endDate="2026-09-01 08:00:00 +0800"/>
        </HealthData>
        """
        XCTAssertThrowsError(try parse(xml)) { error in
            guard case AppleHealthExportError.dtdSuppliesValue(let message) = error else {
                return XCTFail("expected dtdSuppliesValue, got \(error)")
            }
            XCTAssertTrue(message.contains("quoted"), message)
        }
    }

    func testDocumentThatIsNotAHealthExportIsRejected() {
        let xml = "<?xml version=\"1.0\"?><Root><A/></Root>"
        XCTAssertThrowsError(try parse(xml)) { error in
            guard case AppleHealthExportError.notAHealthExport = error else {
                return XCTFail("expected notAHealthExport, got \(error)")
            }
        }
    }

    func testCancellationBeforeTheParseThrows() {
        let xml = document(records: "", workouts: "")
        XCTAssertThrowsError(try parser.parse(
            openStream: { InputStream(data: Data(xml.utf8)) },
            isCancelled: { true }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Ceiling and the second pass

    func testCeilingForcesAFilteredSecondPassThatKeepsOnlyInWindowReadings() throws {
        let inside = "2026-09-01 08:30:00 +0800"
        let outsideA = "2026-09-01 06:00:00 +0800"
        let outsideB = "2026-09-01 12:00:00 +0800"
        let xml = document(
            records: [
                heartRate("100", start: outsideA, end: outsideA),
                heartRate("150", start: inside, end: inside),
                heartRate("110", start: outsideB, end: outsideB),
            ].joined(),
            workouts: runningWorkout(
                start: "2026-09-01 08:00:00 +0800",
                end: "2026-09-01 09:00:00 +0800",
                route: nil
            )
        )
        let scan = try parse(xml, ceiling: 2)
        XCTAssertEqual(scan.passCount, 2)
        XCTAssertTrue(scan.usedFilteredSecondPass)
        // Only the in-window reading survives the filtered pass; both
        // out-of-window readings were dropped before they could be retained.
        XCTAssertEqual(scan.workouts.first?.heartRate.map(\.beatsPerMinute), [150])
    }

    func testSingleStreamThatCannotBeRereadFailsWhenTheCeilingIsHit() {
        let instant = "2026-09-01 08:30:00 +0800"
        let xml = document(
            records: heartRate("150", start: instant, end: instant)
                + heartRate("151", start: instant, end: instant),
            workouts: ""
        )
        let subject = AppleHealthExportParser(heartRateCeiling: 1)
        XCTAssertThrowsError(try subject.parse(stream: InputStream(data: Data(xml.utf8)))) { error in
            guard case AppleHealthExportError.heartRateIndexNeedsSecondPass = error else {
                return XCTFail("expected heartRateIndexNeedsSecondPass, got \(error)")
            }
        }
    }

    func testFilteredPassThatStillExceedsTheCeilingIsRefused() {
        let instant = "2026-09-01 08:30:00 +0800"
        let xml = document(
            records: heartRate("150", start: instant, end: instant)
                + heartRate("151", start: instant, end: instant),
            workouts: runningWorkout(
                start: "2026-09-01 08:00:00 +0800",
                end: "2026-09-01 09:00:00 +0800",
                route: nil
            )
        )
        XCTAssertThrowsError(try parse(xml, ceiling: 1)) { error in
            guard case AppleHealthExportError.heartRateCeilingExceededEvenWhenFiltered(let ceiling) = error else {
                return XCTFail("expected filtered ceiling, got \(error)")
            }
            XCTAssertEqual(ceiling, 1)
        }
    }

    // MARK: - Generated document, streamed from disk

    func testGeneratedDocumentIsStreamedRatherThanLoadedWhole() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-export-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }

        let recordCount = 4_000
        try writeGeneratedExport(to: url, heartRateCount: recordCount)
        let fileBytes = try Data(contentsOf: url).count

        let probe = ReadSizeProbe(upstream: try XCTUnwrap(InputStream(url: url)))
        let scan = try parser.parse(openStream: { probe })

        XCTAssertEqual(scan.heartRateRecordCount, recordCount)
        XCTAssertEqual(scan.workouts.count, 1)
        XCTAssertEqual(scan.workouts[0].heartRate.count, recordCount)
        XCTAssertGreaterThan(fileBytes, probe.largestRead, "the parser must not pull the file in one read")
        XCTAssertGreaterThan(probe.readCount, 1)
    }

    /// Writes `heartRateCount` instantaneous readings inside one running workout
    /// window, straight to disk, so the test never holds the document as a String.
    private func writeGeneratedExport(to url: URL, heartRateCount: Int) throws {
        // A throwing write rather than `createFile(atPath:contents:)`: that call
        // returns `Bool`, which `swift test -warnings-as-errors` rejects as an
        // unused result on Linux (corelibs does not mark it `@discardableResult`
        // the way Darwin does), and ignoring the result would hide a failed
        // create behind a confusing later `FileHandle` error.
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        func write(_ text: String) throws {
            try handle.write(contentsOf: Data(text.utf8))
        }

        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE HealthData [
        <!ELEMENT HealthData (Record*,Workout*)>
        <!ATTLIST HealthData locale CDATA #REQUIRED>
        <!ELEMENT Record EMPTY>
        <!ATTLIST Record type CDATA #REQUIRED value CDATA #REQUIRED \
        startDate CDATA #REQUIRED endDate CDATA #REQUIRED>
        <!ELEMENT Workout EMPTY>
        <!ATTLIST Workout workoutActivityType CDATA #REQUIRED \
        startDate CDATA #REQUIRED endDate CDATA #REQUIRED>
        ]>
        <HealthData locale="en_US">

        """)
        // 2026-09-01 08:00:01 +0000 onward, one second apart, all inside
        // 08:00:00–12:00:00. Hours roll so a minute never exceeds 59.
        for index in 0..<heartRateCount {
            let total = index + 1
            let hour = 8 + total / 3_600
            let minute = (total % 3_600) / 60
            let second = total % 60
            let stamp = String(format: "2026-09-01 %02d:%02d:%02d +0000", hour, minute, second)
            try write(
                "<Record type=\"HKQuantityTypeIdentifierHeartRate\" value=\"\(120 + index % 40)\" "
                    + "startDate=\"\(stamp)\" endDate=\"\(stamp)\"/>\n"
            )
        }
        try write("""
        <Workout workoutActivityType="HKWorkoutActivityTypeRunning" \
        startDate="2026-09-01 08:00:00 +0000" endDate="2026-09-01 12:00:00 +0000"/>
        </HealthData>
        """)
    }
}

/// Records how the parser pulls from its upstream, so a test can tell a
/// streaming read from one that swallowed the file.
private final class ReadSizeProbe: InputStream {
    private let upstream: InputStream
    private(set) var largestRead = 0
    private(set) var readCount = 0

    init(upstream: InputStream) {
        self.upstream = upstream
        super.init(data: Data())
    }

    override func open() { upstream.open() }
    override func close() { upstream.close() }
    override var streamStatus: Stream.Status { upstream.streamStatus }
    override var hasBytesAvailable: Bool { upstream.hasBytesAvailable }
    override var streamError: Error? { upstream.streamError }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        let n = upstream.read(buffer, maxLength: len)
        if n > 0 {
            readCount += 1
            largestRead = max(largestRead, n)
        }
        return n
    }
}
