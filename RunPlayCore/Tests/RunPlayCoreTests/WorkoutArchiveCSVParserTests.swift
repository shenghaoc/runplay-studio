import XCTest
@testable import RunPlayCore

final class WorkoutArchiveCSVParserTests: XCTestCase {

    private let parser = WorkoutArchiveCSVParser()

    func testUTF8BOMAndCRLF() throws {
        // Explicit CRLF + UTF-8 BOM (avoid multiline-string whitespace rules).
        let body = "Activity ID,Activity Name,Activity Type,Activity Date,Filename\r\n"
            + "1,Morning Run,Run,2024-01-01T08:00:00Z,activities/1.gpx\r\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: body.utf8)

        let rows = try parser.parseRows(from: data)
        XCTAssertEqual(rows.count, 2, "header + one body row expected, got \(rows)")

        let table = try parser.parseStravaActivitiesCSV(from: data)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].activityID, "1")
        XCTAssertEqual(table.rows[0].activityName, "Morning Run")
        XCTAssertEqual(table.rows[0].activityType, "Run")
        XCTAssertEqual(table.rows[0].filename, "activities/1.gpx")
        XCTAssertNotNil(table.rows[0].activityDate)
        XCTAssertTrue(table.hasFilenameColumn)
    }

    func testQuotedCommasAndEscapedQuotes() throws {
        let csv = """
        Activity ID,Activity Name,Activity Type,Filename
        2,"Run, ""fast"" loop",Run,activities/2.fit
        """
        let table = try parser.parseStravaActivitiesCSV(from: Data(csv.utf8))
        XCTAssertEqual(table.rows[0].activityName, "Run, \"fast\" loop")
    }

    func testEmbeddedNewlineInQuotes() throws {
        let csv = "Activity ID,Activity Name,Filename\n3,\"Line1\nLine2\",activities/3.gpx\n"
        let table = try parser.parseStravaActivitiesCSV(from: Data(csv.utf8))
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].activityName, "Line1\nLine2")
    }

    func testReorderedAndUnknownColumns() throws {
        let csv = """
        Filename,Extra,Activity Type,Activity ID,Activity Name
        activities/9.tcx,ignore-me,Trail Run,9,Hill
        """
        let table = try parser.parseStravaActivitiesCSV(from: Data(csv.utf8))
        XCTAssertEqual(table.rows[0].activityID, "9")
        XCTAssertEqual(table.rows[0].activityType, "Trail Run")
        XCTAssertTrue(table.unknownHeaders.contains("Extra"))
    }

    func testMissingFilenameColumn() throws {
        let csv = """
        Activity ID,Activity Name,Activity Type
        5,No File,Run
        """
        let table = try parser.parseStravaActivitiesCSV(from: Data(csv.utf8))
        XCTAssertFalse(table.hasFilenameColumn)
        XCTAssertNil(table.rows[0].filename)
    }

    func testEmptyFields() throws {
        let csv = "Activity ID,Activity Name,Activity Type,Filename\n6,,Run,\n"
        let table = try parser.parseStravaActivitiesCSV(from: Data(csv.utf8))
        XCTAssertEqual(table.rows[0].activityID, "6")
        XCTAssertNil(table.rows[0].activityName)
        XCTAssertNil(table.rows[0].filename)
    }

    func testOversizedField() {
        let policy = WorkoutArchiveSecurityPolicy(maxCSVFieldBytes: 8)
        let p = WorkoutArchiveCSVParser(policy: policy)
        let csv = "Activity ID,Activity Name\n1,toolongname\n"
        XCTAssertThrowsError(try p.parseStravaActivitiesCSV(from: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? WorkoutArchiveCSVError, .oversizedField)
        }
    }

    func testMalformedQuotation() {
        let csv = "Activity ID,Activity Name\n1,\"unterminated\n"
        XCTAssertThrowsError(try parser.parseStravaActivitiesCSV(from: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? WorkoutArchiveCSVError, .malformedQuotation)
        }
    }

    func testCancellation() {
        let csv = "Activity ID,Activity Name\n1,A\n2,B\n3,C\n"
        let policy = WorkoutArchiveSecurityPolicy(cancellationCheckStride: 1)
        let p = WorkoutArchiveCSVParser(policy: policy)
        var count = 0
        XCTAssertThrowsError(try p.parseStravaActivitiesCSV(from: Data(csv.utf8), isCancelled: {
            count += 1
            return count > 3
        })) { error in
            XCTAssertEqual(error as? WorkoutArchiveCSVError, .cancelled)
        }
    }

    func testPathMatchExactAndCaseInsensitiveAndAmbiguous() {
        let entries = ["export/activities/1.gpx", "export/activities/2.FIT"]
        if case .exact(let p) = WorkoutArchivePathValidator.matchPath("export/activities/1.gpx", in: entries) {
            XCTAssertEqual(p, "export/activities/1.gpx")
        } else {
            XCTFail("expected exact")
        }
        if case .caseInsensitive(let p) = WorkoutArchivePathValidator.matchPath("export/activities/2.fit", in: entries) {
            XCTAssertEqual(p, "export/activities/2.FIT")
        } else {
            XCTFail("expected case insensitive")
        }
        let amb = ["dirA/same.gpx", "dirB/same.gpx"]
        switch WorkoutArchivePathValidator.matchPath("same.gpx", in: amb) {
        case .ambiguous:
            break
        default:
            XCTFail("expected ambiguous for duplicate basenames")
        }
    }

    func testPathMatchRejectsDuplicateExactEntries() {
        switch WorkoutArchivePathValidator.matchPath(
            "activities/1.gpx",
            in: ["activities/1.gpx", "activities/1.gpx"]
        ) {
        case .ambiguous:
            break
        default:
            XCTFail("duplicate exact paths must not select an arbitrary archive entry")
        }
    }

    func testCandidateIDsRemainDistinctForDuplicateProviderIDs() {
        let rows = [
            StravaActivityMetadataRow(
                activityID: "42",
                activityName: "First",
                activityType: "Run",
                filename: "activities/first.gpx",
                rowIndex: 0
            ),
            StravaActivityMetadataRow(
                activityID: "42",
                activityName: "Second",
                activityType: "Run",
                filename: "activities/second.gpx",
                rowIndex: 1
            )
        ]
        let built = WorkoutArchiveCandidateBuilder.buildCandidates(
            metadataRows: rows,
            entryPaths: ["activities/first.gpx", "activities/second.gpx"],
            entrySizes: [:],
            existingWorkouts: [],
            hasFilenameColumn: true
        )

        XCTAssertEqual(Set(built.candidates.map(\.id)).count, 2)
        XCTAssertEqual(built.candidates[1].status, .duplicate)
    }

    func testPathTraversalRejected() {
        if case .rejected = WorkoutArchivePathValidator.validate("../etc/passwd") {
            // ok
        } else {
            XCTFail("expected rejection")
        }
        if case .rejected = WorkoutArchivePathValidator.validate("/abs/path") {
            // ok
        } else {
            XCTFail("expected absolute rejection")
        }
        if case .rejected = WorkoutArchivePathValidator.validate("C:\\Windows\\x") {
            // ok
        } else {
            XCTFail("expected drive rejection")
        }
    }
}
