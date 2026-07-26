import XCTest
@testable import RunPlayCore

final class FITSessionCandidateClassifierTests: XCTestCase {

    func testUnsupportedSportWinsOverOtherProblems() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .unsupported,
            sportDisplayName: "Cycling",
            isUniqueWithinFile: false,
            isExistingInLibrary: true,
            boundaryProblem: .missingStart,
            isAmbiguous: true,
            overLimit: true,
            gpsRecordCount: 0
        )
        XCTAssertEqual(result.status, .unsupportedSport)
        XCTAssertTrue(result.detail?.contains("Cycling") == true)
    }

    func testWithinFileDuplicateBeforeLibraryDuplicate() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .running,
            sportDisplayName: "Running",
            isUniqueWithinFile: false,
            isExistingInLibrary: true,
            boundaryProblem: nil,
            isAmbiguous: false,
            overLimit: false,
            gpsRecordCount: 10
        )
        XCTAssertEqual(result.status, .duplicate)
        XCTAssertTrue(result.detail?.contains("this file") == true)
    }

    func testLibraryDuplicate() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .running,
            sportDisplayName: "Running",
            isUniqueWithinFile: true,
            isExistingInLibrary: true,
            boundaryProblem: nil,
            isAmbiguous: false,
            overLimit: false,
            gpsRecordCount: 10
        )
        XCTAssertEqual(result.status, .duplicate)
        XCTAssertTrue(result.detail?.contains("library") == true)
    }

    func testBoundaryProblemBeforeAmbiguous() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .running,
            sportDisplayName: "Running",
            isUniqueWithinFile: true,
            isExistingInLibrary: false,
            boundaryProblem: .missingEnd,
            isAmbiguous: true,
            overLimit: false,
            gpsRecordCount: 10
        )
        XCTAssertEqual(result.status, .invalidBoundaries)
    }

    func testAmbiguousBeforeResourceLimit() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .running,
            sportDisplayName: "Running",
            isUniqueWithinFile: true,
            isExistingInLibrary: false,
            boundaryProblem: nil,
            isAmbiguous: true,
            overLimit: true,
            gpsRecordCount: 0
        )
        XCTAssertEqual(result.status, .ambiguousAttribution)
    }

    func testResourceLimitBeforeNoGPS() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .running,
            sportDisplayName: "Running",
            isUniqueWithinFile: true,
            isExistingInLibrary: false,
            boundaryProblem: nil,
            isAmbiguous: false,
            overLimit: true,
            gpsRecordCount: 0
        )
        XCTAssertEqual(result.status, .exceedsResourceLimit)
    }

    func testNoGPSWhenOtherwiseReady() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .running,
            sportDisplayName: "Running",
            isUniqueWithinFile: true,
            isExistingInLibrary: false,
            boundaryProblem: nil,
            isAmbiguous: false,
            overLimit: false,
            gpsRecordCount: 0
        )
        XCTAssertEqual(result.status, .noGPSRoute)
    }

    func testUnknownSportIsReadyWithWarning() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .unknownTreatedAsRunning,
            sportDisplayName: "Unknown",
            isUniqueWithinFile: true,
            isExistingInLibrary: false,
            boundaryProblem: nil,
            isAmbiguous: false,
            overLimit: false,
            gpsRecordCount: 5
        )
        XCTAssertEqual(result.status, .ready)
        XCTAssertTrue(result.detail?.contains("recognised sport") == true)
    }

    func testRunningIsReadyWithoutDetail() {
        let result = FITSessionCandidateClassifier.classify(
            sport: .running,
            sportDisplayName: "Running",
            isUniqueWithinFile: true,
            isExistingInLibrary: false,
            boundaryProblem: nil,
            isAmbiguous: false,
            overLimit: false,
            gpsRecordCount: 5
        )
        XCTAssertEqual(result.status, .ready)
        XCTAssertNil(result.detail)
    }

    func testReportLabelDoesNotTreatReadyAsImportedWhenCommitFailed() {
        let item = FITSessionImportItemResult(
            candidateID: "id",
            sourceIndex: 0,
            sessionName: "Run",
            status: .ready,
            importedWorkoutID: UUID()
        )
        XCTAssertEqual(item.reportLabel(commitFailed: true), "Not saved")
        XCTAssertEqual(item.reportLabel(commitFailed: false), "Imported")
        XCTAssertEqual(
            FITSessionImportItemResult(
                candidateID: "id",
                sourceIndex: 0,
                sessionName: "Run",
                status: .duplicate
            ).reportLabel(commitFailed: false),
            "Already imported"
        )
    }
}
