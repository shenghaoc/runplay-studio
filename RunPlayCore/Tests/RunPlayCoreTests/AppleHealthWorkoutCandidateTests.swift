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

    /// A route file the archive cannot supply leaves the run route-less. The
    /// candidate keeps the path, so the review can say what was named, but it
    /// neither has a route nor promises a distance measured from one.
    func testACandidateWhoseRouteFileIsMissingReportsNoRoute() {
        var candidate = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000, route: "apple_health_export/workout-routes/route_1.gpx"),
        ]))[0]
        // Only the archive scan can tell; a candidate built from the document
        // alone takes the named file to be there.
        XCTAssertFalse(candidate.isRouteFileMissing)
        XCTAssertFalse(candidate.namesMissingRouteFile)

        candidate.isRouteFileMissing = true

        XCTAssertEqual(candidate.routeArchivePath, "apple_health_export/workout-routes/route_1.gpx")
        XCTAssertTrue(candidate.namesMissingRouteFile)
        XCTAssertFalse(candidate.hasRoute)
        XCTAssertEqual(candidate.distanceProvenance, .sourceReported)
    }

    func testSourceDistanceIsConvertedToMeters() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000, statistics: [distanceStatistic(5.2)]),
        ]))

        XCTAssertEqual(candidates[0].sourceDistanceMeters, 5_200)
    }

    func testOnlyAWalkingRunningDistanceIsARunsDistance() {
        let cycling = AppleHealthWorkoutStatistic(
            type: "HKQuantityTypeIdentifierDistanceCycling",
            unit: "km",
            sum: 10
        )
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000, statistics: [cycling, distanceStatistic(5)]),
            entry(3_000, 4_000, statistics: [cycling]),
        ]))

        XCTAssertEqual(candidates.map(\.sourceDistanceMeters), [5_000, nil])
    }

    func testANegativeOrOverflowingDistanceIsNoDistance() {
        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(from: scan([
            entry(1_000, 2_000, statistics: [distanceStatistic(-5)]),
            entry(3_000, 4_000, statistics: [distanceStatistic(1e306)]),
            entry(5_000, 6_000, statistics: [distanceStatistic(-1), distanceStatistic(5)]),
        ]))

        XCTAssertEqual(candidates.map(\.sourceDistanceMeters), [nil, nil, 5_000])
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

    // MARK: - Cost of flagging

    /// Flagging compares only windows that can match, and must flag exactly
    /// what comparing every pair flags. Windows are crowded into a short span,
    /// with zero-length, reversed, touching, nested and shared-start windows,
    /// so the shortcuts are exercised far more often than a real export would.
    func testFlaggingMatchesComparingEveryPair() {
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<40 {
            let candidateCount = generator.next(below: 60)
            let libraryCount = generator.next(below: 30)
            var windows: [(Int64, Int64)] = []
            for _ in 0..<(candidateCount + libraryCount) {
                // Now and then repeat an earlier window exactly.
                if !windows.isEmpty, generator.next(below: 4) == 0 {
                    windows.append(windows[generator.next(below: windows.count)])
                    continue
                }
                let start = Int64(generator.next(below: 120))
                windows.append((start, start + Int64(generator.next(below: 50)) - 10))
            }
            let candidates = windows.prefix(candidateCount).enumerated().map { index, pair in
                AppleHealthWorkoutCandidate(
                    id: "\(index)",
                    sourceIndex: index,
                    window: window(pair.0, pair.1)
                )
            }
            let library = windows.dropFirst(candidateCount).map {
                AppleHealthLibraryRunWindow(startSeconds: $0.0, endSeconds: $0.1)
            }

            var flagged = candidates
            AppleHealthWorkoutCandidateBuilder.flagDuplicates(in: &flagged, existingLibraryRuns: library)
            let expected = flaggedByComparingEveryPair(candidates, library: library)

            XCTAssertEqual(flagged.map(\.status), expected.map(\.status), "\(windows)")
            XCTAssertEqual(flagged.map(\.duplicateOrigin), expected.map(\.duplicateOrigin), "\(windows)")
        }
    }

    /// Chronologically separate workouts are not compared pair by pair. Every
    /// pair would be about 6.8 million comparisons here.
    func testSeparateWorkoutsAreNotComparedPairwise() {
        var candidates: [AppleHealthWorkoutCandidate] = []
        var library: [AppleHealthLibraryRunWindow] = []
        for run in 0..<2_000 {
            let start = Int64(run) * 100
            // Every tenth run appears twice in the export.
            for _ in 0..<(run % 10 == 0 ? 2 : 1) {
                candidates.append(candidate(start, start + 60, index: candidates.count))
            }
            // A stored run that overlaps this one's last ten seconds.
            library.append(AppleHealthLibraryRunWindow(startSeconds: start + 50, endSeconds: start + 90))
        }

        let reads = AppleHealthWorkoutCandidateBuilder.flagDuplicates(
            in: &candidates,
            existingLibraryRuns: library
        )

        XCTAssertLessThanOrEqual(reads, readBound(candidates: candidates.count, library: library.count))
        XCTAssertEqual(tally(candidates), [
            "duplicate withinExport": 400,
            "possibleDuplicate existingLibrary": 1_800,
        ])
    }

    /// Workouts that all overlap one another are not compared pair by pair
    /// either. An untrusted export can be built this way, and walking the pairs
    /// that overlap would still be millions of comparisons here.
    func testWorkoutsThatAllOverlapAreNotComparedPairwise() {
        var candidates: [AppleHealthWorkoutCandidate] = []
        var library: [AppleHealthLibraryRunWindow] = []
        for run in 0..<2_000 {
            let start = Int64(run)
            for _ in 0..<(run % 10 == 0 ? 2 : 1) {
                candidates.append(candidate(start, start + 1_000_000, index: candidates.count))
            }
            library.append(AppleHealthLibraryRunWindow(
                startSeconds: 500_000 + start,
                endSeconds: 600_000 + start
            ))
        }

        let reads = AppleHealthWorkoutCandidateBuilder.flagDuplicates(
            in: &candidates,
            existingLibraryRuns: library
        )

        XCTAssertLessThanOrEqual(reads, readBound(candidates: candidates.count, library: library.count))
        XCTAssertEqual(tally(candidates), [
            "duplicate withinExport": 400,
            "possibleDuplicate withinExport": 1_800,
        ])
    }

    private func candidate(_ start: Int64, _ end: Int64, index: Int) -> AppleHealthWorkoutCandidate {
        AppleHealthWorkoutCandidate(id: "\(index)", sourceIndex: index, window: window(start, end))
    }

    /// Two binary searches per candidate, each reading about log2 of the windows
    /// it searches and then one end.
    private func readBound(candidates: Int, library: Int) -> Int {
        let searchLength = Int.bitWidth - (candidates + library).leadingZeroBitCount + 1
        return 2 * candidates * searchLength
    }

    /// Candidates counted by status and origin.
    private func tally(_ candidates: [AppleHealthWorkoutCandidate]) -> [String: Int] {
        Dictionary(grouping: candidates) { candidate in
            "\(candidate.status) \(candidate.duplicateOrigin.map { "\($0)" } ?? "none")"
        }.mapValues(\.count)
    }

    /// The definition flagging must reproduce: every pair of candidates, then
    /// every candidate against every stored run.
    private func flaggedByComparingEveryPair(
        _ candidates: [AppleHealthWorkoutCandidate],
        library: [AppleHealthLibraryRunWindow]
    ) -> [AppleHealthWorkoutCandidate] {
        func match(
            _ start: Int64, _ end: Int64, _ otherStart: Int64, _ otherEnd: Int64
        ) -> AppleHealthCandidateStatus? {
            if start == otherStart, end == otherEnd { return .duplicate }
            if start < otherEnd, otherStart < end { return .possibleDuplicate }
            return nil
        }
        var candidates = candidates
        for first in candidates.indices {
            for second in candidates.indices where second > first {
                let lhs = candidates[first].window
                let rhs = candidates[second].window
                guard let status = match(
                    lhs.startSeconds, lhs.endSeconds, rhs.startSeconds, rhs.endSeconds
                ) else { continue }
                candidates[first].apply(status, origin: .withinExport)
                candidates[second].apply(status, origin: .withinExport)
            }
        }
        for index in candidates.indices {
            for run in library {
                let window = candidates[index].window
                guard let status = match(
                    window.startSeconds, window.endSeconds, run.startSeconds, run.endSeconds
                ) else { continue }
                candidates[index].apply(status, origin: .existingLibrary)
            }
        }
        return candidates
    }

    /// A fixed-seed generator, so a failing case reproduces exactly.
    private struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next(below bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
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
