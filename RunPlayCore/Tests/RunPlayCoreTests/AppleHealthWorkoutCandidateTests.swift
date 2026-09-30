import Foundation
import XCTest
@testable import RunPlayCore

/// Candidate construction and duplicate flagging.
///
/// Scans are built directly rather than parsed, so each case states the exact
/// windows and heart rate it is about. One end-to-end test parses a small
/// document to show the scan's in-window join reaching a candidate unchanged.
/// Every value here is invented.
final class AppleHealthWorkoutCandidateTests: XCTestCase {

    // MARK: - Builders

    private func window(
        _ start: Int64,
        _ end: Int64,
        activityType: String = "HKWorkoutActivityTypeRunning"
    ) -> AppleHealthWorkoutWindow {
        AppleHealthWorkoutWindow(
            startSeconds: start,
            endSeconds: end,
            activityType: activityType,
            utcOffsetSeconds: 0
        )
    }

    private func entry(
        _ start: Int64,
        _ end: Int64,
        route: String? = nil,
        activityType: String = "HKWorkoutActivityTypeRunning",
        heartRate: [AppleHealthHeartRateReading] = [],
        statistics: [AppleHealthWorkoutStatistic] = []
    ) -> AppleHealthExportScan.WorkoutEntry {
        AppleHealthExportScan.WorkoutEntry(
            window: window(start, end, activityType: activityType),
            statistics: statistics,
            routeArchivePath: route,
            heartRate: heartRate
        )
    }

    private func scan(_ entries: [AppleHealthExportScan.WorkoutEntry]) -> AppleHealthExportScan {
        AppleHealthExportScan(workouts: entries)
    }

    private func distanceStatistic(
        _ sum: Double,
        unit: String = "km"
    ) -> AppleHealthWorkoutStatistic {
        AppleHealthWorkoutStatistic(
            type: "HKQuantityTypeIdentifierDistanceWalkingRunning",
            unit: unit,
            sum: sum
        )
    }

    // MARK: - Running-only policy

    func testMixedActivitiesKeepOnlyRunsAndPreserveDocumentOrdinals() {
        let input = scan([
            entry(0, 100, activityType: "HKWorkoutActivityTypeCycling"),
            entry(200, 300),
            entry(400, 500, activityType: "HKWorkoutActivityTypeWalking"),
            entry(600, 700),
            entry(800, 900, activityType: "HKWorkoutActivityTypeMadeUp"),
        ])
        let result = AppleHealthWorkoutCandidateBuilder.build(from: input)
        XCTAssertEqual(result.candidates.map(\.sourceIndex), [1, 3])
        XCTAssertTrue(result.candidates.allSatisfy { $0.window.activityType == "HKWorkoutActivityTypeRunning" })
        XCTAssertEqual(result.excludedWorkoutCount, 3)
        XCTAssertEqual(AppleHealthWorkoutCandidateBuilder.candidates(from: input), result.candidates)
    }

    func testExcludedWorkoutsAreCountedByActivityIdentifier() {
        let result = AppleHealthWorkoutCandidateBuilder.build(from: scan([
            entry(0, 100, activityType: "HKWorkoutActivityTypeCycling"),
            entry(200, 300, activityType: "HKWorkoutActivityTypeCycling"),
            entry(400, 500, activityType: "HKWorkoutActivityTypeSwimming"),
            entry(600, 700),
        ]))
        XCTAssertEqual(result.excludedWorkoutsByActivityType, [
            "HKWorkoutActivityTypeCycling": 2,
            "HKWorkoutActivityTypeSwimming": 1,
        ])
        XCTAssertEqual(result.excludedWorkoutCount, 3)
        XCTAssertEqual(result.candidates.count + result.excludedWorkoutCount, 4)
    }

    func testIndoorTreadmillRunIsKeptWithoutARoute() throws {
        let xml = """
        <HealthData>
        <Workout workoutActivityType="HKWorkoutActivityTypeRunning"
        startDate="2026-01-01 10:00:00 +0000" endDate="2026-01-01 10:30:00 +0000">
        <MetadataEntry key="HKIndoorWorkout" value="1"/>
        <WorkoutStatistics type="HKQuantityTypeIdentifierDistanceWalkingRunning" sum="3" unit="km"/>
        </Workout>
        </HealthData>
        """
        let parsed = try AppleHealthExportParser().parse(openStream: { InputStream(data: Data(xml.utf8)) })
        let result = AppleHealthWorkoutCandidateBuilder.build(from: parsed)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertFalse(result.candidates[0].hasRoute)
        XCTAssertEqual(result.candidates[0].sourceDistanceMeters, 3_000)
        XCTAssertTrue(result.candidates[0].isSelectedByDefault)
        XCTAssertTrue(result.excludedWorkoutsByActivityType.isEmpty)
    }

    func testOverlappingNonRunningWorkoutsCannotFlagARun() {
        let result = AppleHealthWorkoutCandidateBuilder.build(from: scan([
            entry(1_000, 2_000, activityType: "HKWorkoutActivityTypeCycling"),
            entry(1_000, 2_000),
            entry(1_500, 2_500, activityType: "HKWorkoutActivityTypeWalking"),
        ]))
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].status, .ready)
        XCTAssertNil(result.candidates[0].duplicateOrigin)
        XCTAssertTrue(result.candidates[0].isSelectedByDefault)
        XCTAssertEqual(result.excludedWorkoutCount, 2)
    }

    // MARK: - Route presence and provenance

    func testRouteLessCandidateReportsSourceReportedDistance() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000),
        ]))

        XCTAssertEqual(candidates.count, 1)
        let candidate = candidates[0]
        XCTAssertFalse(candidate.hasRoute)
        XCTAssertEqual(candidate.distanceProvenance, .sourceReported)
        XCTAssertEqual(candidate.status, .ready)
        XCTAssertTrue(candidate.isSelectedByDefault)
        XCTAssertNil(candidate.statusDetail)
    }

    func testRoutedCandidateReportsGPSDerivedDistance() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000, route: "apple_health_export/workout-routes/route_1.gpx"),
        ]))

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].hasRoute)
        XCTAssertEqual(candidates[0].distanceProvenance, .gpsDerived)
    }

    func testSourceDistanceIsConvertedToMeters() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000, statistics: [distanceStatistic(5.2)]),
        ]))

        XCTAssertEqual(candidates[0].sourceDistanceMeters, 5_200)
    }

    func testUnrecognizedDistanceUnitYieldsNoDistance() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000, statistics: [distanceStatistic(5.2, unit: "furlong")]),
        ]))

        XCTAssertNil(candidates[0].sourceDistanceMeters)
    }

    // MARK: - Heart rate

    func testCandidateCarriesTheInWindowHeartRateItWasGiven() {
        let reading = AppleHealthHeartRateReading(
            startSeconds: 1_500,
            durationSeconds: 0,
            beatsPerMinute: 150
        )
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000, heartRate: [reading]),
        ]))

        XCTAssertEqual(candidates[0].heartRate, [reading])
    }

    /// End to end: a reading inside the window survives to the candidate and one
    /// outside it never arrives.
    func testOnlyInWindowHeartRateReachesACandidate() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
        <Record type="HKQuantityTypeIdentifierHeartRate" value="150" \
        startDate="2026-09-01 08:30:00 +0000" endDate="2026-09-01 08:30:00 +0000"/>
        <Record type="HKQuantityTypeIdentifierHeartRate" value="99" \
        startDate="2026-09-01 06:00:00 +0000" endDate="2026-09-01 06:00:00 +0000"/>
        <Workout workoutActivityType="HKWorkoutActivityTypeRunning" \
        startDate="2026-09-01 08:00:00 +0000" endDate="2026-09-01 09:00:00 +0000"/>
        </HealthData>
        """
        let scan = try AppleHealthExportParser().parse(
            openStream: { InputStream(data: Data(xml.utf8)) }
        )
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].heartRate.map(\.beatsPerMinute), [150])
    }

    // MARK: - Overlap within the export

    func testExactDuplicateFlagsBothAndStartsThemUnchecked() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000),
            entry(1_000, 2_000),
        ]))

        for candidate in candidates {
            XCTAssertEqual(candidate.status, .duplicate)
            XCTAssertEqual(candidate.duplicateOrigin, .withinExport)
            XCTAssertFalse(candidate.isSelectedByDefault)
            XCTAssertEqual(
                candidate.statusDetail,
                AppleHealthDuplicateOrigin.withinExport.userFacingDetail
            )
        }
        // Different identities, so a review sheet can show both.
        XCTAssertNotEqual(candidates[0].id, candidates[1].id)
    }

    func testPartialOverlapIsAPossibleDuplicate() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000),
            entry(1_500, 2_500),
        ]))

        XCTAssertEqual(candidates.map(\.status), [.possibleDuplicate, .possibleDuplicate])
        XCTAssertTrue(candidates.allSatisfy { !$0.isSelectedByDefault })
    }

    func testAdjacentWorkoutsDoNotOverlap() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000),
            entry(2_000, 3_000),
        ]))

        XCTAssertEqual(candidates.map(\.status), [.ready, .ready])
        XCTAssertTrue(candidates.allSatisfy(\.isSelectedByDefault))
    }

    func testDisjointWorkoutsAreAllReady() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000),
            entry(5_000, 6_000),
            entry(9_000, 9_500),
        ]))

        XCTAssertEqual(candidates.map(\.status), [.ready, .ready, .ready])
        XCTAssertEqual(candidates.map(\.sourceIndex), [0, 1, 2])
    }

    // MARK: - Overlap with the library

    func testDuplicateOfALibraryRunIsFlaggedAndUnchecked() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(
            from: scan([entry(1_000, 2_000)]),
            existingLibraryRuns: [AppleHealthLibraryRunWindow(startSeconds: 1_000, endSeconds: 2_000)]
        )

        XCTAssertEqual(candidates[0].status, .duplicate)
        XCTAssertEqual(candidates[0].duplicateOrigin, .existingLibrary)
        XCTAssertFalse(candidates[0].isSelectedByDefault)
        XCTAssertEqual(
            candidates[0].statusDetail,
            AppleHealthDuplicateOrigin.existingLibrary.userFacingDetail
        )
    }

    func testLibraryOverlapThatIsNotExactIsAPossibleDuplicate() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(
            from: scan([entry(1_000, 2_000)]),
            existingLibraryRuns: [AppleHealthLibraryRunWindow(startSeconds: 1_500, endSeconds: 2_500)]
        )

        XCTAssertEqual(candidates[0].status, .possibleDuplicate)
        XCTAssertEqual(candidates[0].duplicateOrigin, .existingLibrary)
        XCTAssertFalse(candidates[0].isSelectedByDefault)
    }

    func testLibraryRunThatDoesNotOverlapLeavesTheCandidateReady() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(
            from: scan([entry(1_000, 2_000)]),
            existingLibraryRuns: [AppleHealthLibraryRunWindow(startSeconds: 2_000, endSeconds: 3_000)]
        )

        XCTAssertEqual(candidates[0].status, .ready)
        XCTAssertNil(candidates[0].duplicateOrigin)
        XCTAssertTrue(candidates[0].isSelectedByDefault)
    }

    /// A library match outranks an in-export one, because it is the one the user
    /// can act on.
    func testLibraryMatchOutranksAnInExportMatch() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(
            from: scan([entry(1_000, 2_000), entry(1_000, 2_000)]),
            existingLibraryRuns: [AppleHealthLibraryRunWindow(startSeconds: 1_000, endSeconds: 2_000)]
        )

        XCTAssertEqual(candidates.map(\.status), [.duplicate, .duplicate])
        XCTAssertEqual(candidates.map(\.duplicateOrigin), [.existingLibrary, .existingLibrary])
    }

    // MARK: - Shape

    func testEmptyScanYieldsNoCandidates() {
        XCTAssertTrue(AppleHealthWorkoutCandidateBuilder.candidates(from: scan([])).isEmpty)
    }

    /// Identity is deterministic, unique per workout, and never the route path —
    /// which the export shares between two workouts.
    func testIdentityIsDeterministicAndNotTheRoutePath() {
        let shared = "apple_health_export/workout-routes/route_1.gpx"
        let built = scan([entry(1_000, 2_000, route: shared), entry(3_000, 4_000, route: shared)])

        let first = AppleHealthWorkoutCandidateBuilder.candidates(from: built)
        let second = AppleHealthWorkoutCandidateBuilder.candidates(from: built)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertNotEqual(first[0].id, first[1].id)
        XCTAssertFalse(first.contains { $0.id.contains(shared) })
    }
}
