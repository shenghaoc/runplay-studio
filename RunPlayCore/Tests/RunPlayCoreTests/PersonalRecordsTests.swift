import XCTest
@testable import RunPlayCore

/// Personal-record window detection, aggregation, persistence, and backfill.
///
/// All fixtures are synthetic constant-pace routes; no real workout data.
final class PersonalRecordsTests: XCTestCase {

    // MARK: - Fixtures

    /// Constant-pace synthetic route. `pauseAtDistance` inserts a recording
    /// gap at that distance: a plateau point in the next route segment whose
    /// elapsed clock jumps by `pauseDuration` while distance holds.
    private func makeRoute(
        totalDistance: Double,
        interval: Double = 100,
        secondsPerMeter: Double = 0.25,
        pauseAtDistance: Double? = nil,
        pauseDuration: Double = 500,
        start: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> [RoutePoint] {
        var points: [RoutePoint] = []
        var segment = 0
        var elapsed = 0.0
        var distance = 0.0
        while distance <= totalDistance {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 1 + distance / 100_000,
                longitude: 1,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                routeSegmentIndex: segment
            ))
            if distance == pauseAtDistance, distance < totalDistance {
                elapsed += pauseDuration
                segment += 1
                points.append(RoutePoint(
                    timestamp: start.addingTimeInterval(elapsed),
                    latitude: 1 + distance / 100_000,
                    longitude: 1,
                    distanceFromStartMeters: distance,
                    elapsedSeconds: elapsed,
                    routeSegmentIndex: segment
                ))
            }
            distance += interval
            elapsed += interval * secondsPerMeter
        }
        return points
    }

    private func detectRecords(_ points: [RoutePoint]) -> WorkoutPersonalRecords {
        let context = WorkoutAnalysisContext(
            routePoints: points,
            elevationProfile: ElevationProfile(routePoints: points)
        )
        return SegmentDetector.detectPersonalRecords(
            from: RunWorkout(routePoints: points),
            context: context
        )
    }

    // MARK: - Detection

    func testMarathonRouteAttemptsAllWindowsWithExactLengths() {
        let records = detectRecords(makeRoute(totalDistance: 43_000))
        let categories = Set(records.windows.map(\.category))
        XCTAssertEqual(categories, [
            .fastest400m, .fastest1km, .fastest1mile, .fastest5km,
            .fastest10km, .fastestHalfMarathon, .fastestMarathon
        ])
        for window in records.windows {
            let nominal = window.category.nominalWindowDistanceMeters
            XCTAssertEqual(
                window.endDistanceMeters - window.startDistanceMeters,
                nominal,
                "\(window.category.displayName) window must cover its nominal length exactly"
            )
            XCTAssertEqual(
                window.paceSecondsPerKilometer, 250, accuracy: 1e-6,
                "\(window.category.displayName) constant-pace value"
            )
        }
    }

    func testWindowsLongerThanRouteAreNotAttempted() {
        let records = detectRecords(makeRoute(totalDistance: 4_000))
        let categories = Set(records.windows.map(\.category))
        XCTAssertEqual(categories, [.fastest400m, .fastest1km, .fastest1mile])
        // Not attempted means absent, never a zero-valued placeholder.
        for window in records.windows {
            XCTAssertGreaterThan(window.paceSecondsPerKilometer, 0)
        }
    }

    func testRecordWindowSpanningPauseUsesActiveTime() {
        // Pause at 2 km so the first (tie-winning) 5 km window spans it.
        // Active pace is 250 s/km; elapsed pace would be far slower.
        let points = makeRoute(totalDistance: 5_000, pauseAtDistance: 2_000)
        let records = detectRecords(points)
        let window = records.window(for: .fastest5km)
        XCTAssertNotNil(window, "5 km record should be attempted")
        guard let window else { return }
        XCTAssertEqual(window.paceSecondsPerKilometer, 250, accuracy: 1e-6,
                       "pause time must not count toward record pace")
        let elapsedSpan = window.endElapsedSeconds - window.startElapsedSeconds
        XCTAssertGreaterThan(elapsedSpan, window.activeSeconds,
                             "elapsed span includes the pause; active time excludes it")
        XCTAssertEqual(window.activeSeconds, 1_250, accuracy: 1e-6,
                       "5 km at 250 s/km is 1,250 active seconds")
    }

    func testMileAndOneKilometerWindowsOverlapAndPickDifferentStarts() {
        // The bridge parity tests compare only the five segment kinds, so the
        // dedicated record tests alone must prove the overlapping windows
        // search independently. Three speed sections over 3 km — 260, 240,
        // and 270 s/km — make the fast block exactly 1 km: the 1 km record
        // sits inside it (start 1 km), while the mile must cover the whole
        // fast block plus both slow sides and starts earlier (400 m, where
        // the cheaper leading slow section wins). The two windows overlap
        // between 1.0 km and 2.009 km.
        let sections: [(end: Double, secondsPerMeter: Double)] = [
            (1_000, 0.26), (2_000, 0.24), (3_000, 0.27)
        ]
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var elapsed = 0.0
        for index in 0...30 {
            let distance = Double(index) * 100
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 1 + distance / 100_000,
                longitude: 1,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                routeSegmentIndex: 0
            ))
            if index < 30 {
                let speed = sections.first { distance < $0.end }!.secondsPerMeter
                elapsed += 100 * speed
            }
        }

        let records = detectRecords(points)
        let oneKm = records.window(for: .fastest1km)
        let mile = records.window(for: .fastest1mile)
        XCTAssertNotNil(oneKm)
        XCTAssertNotNil(mile)
        guard let oneKm, let mile else { return }

        // The 1 km record is the fast block itself: exactly 240 s/km.
        XCTAssertEqual(oneKm.startDistanceMeters, 1_000, accuracy: 1e-9)
        XCTAssertEqual(oneKm.paceSecondsPerKilometer, 240, accuracy: 1e-9)

        // The mile starts at 400 m: 600 m at 260, the full fast kilometre,
        // and 9.344 m at 270 = 398.52288 s over 1'609.344 m.
        XCTAssertEqual(mile.startDistanceMeters, 400, accuracy: 1e-9)
        XCTAssertEqual(
            mile.endDistanceMeters,
            400 + PersonalRecordCategory.fastest1mile.nominalWindowDistanceMeters!,
            accuracy: 1e-9
        )
        let expectedMilePace = 398.52288
            / PersonalRecordCategory.fastest1mile.nominalWindowDistanceMeters!
            * 1_000
        XCTAssertEqual(mile.paceSecondsPerKilometer, expectedMilePace, accuracy: 1e-6)

        // The windows overlap yet pick different starts.
        XCTAssertNotEqual(oneKm.startDistanceMeters, mile.startDistanceMeters)
        XCTAssertLessThan(mile.startDistanceMeters, oneKm.startDistanceMeters)
        XCTAssertLessThan(oneKm.startDistanceMeters, mile.endDistanceMeters)
        XCTAssertLessThan(oneKm.endDistanceMeters - 1e-9, 3_000)
    }

    func testSinglePointRouteProducesEmptyComputedRecords() {
        // Computed-with-nothing, not nil: the marker semantics distinguish
        // "attempted none" from "never computed".
        let records = detectRecords([
            RoutePoint(timestamp: Date(), latitude: 1, longitude: 1,
                       distanceFromStartMeters: 0, elapsedSeconds: 0)
        ])
        XCTAssertTrue(records.windows.isEmpty)
    }

    // MARK: - Analyzer stamping

    func testAnalyzerStampsRecordsAndKeepsFiveSegmentKinds() {
        var workout = RunWorkout(routePoints: makeRoute(totalDistance: 5_000))
        WorkoutAnalyzer().analyze(&workout)
        XCTAssertNotNil(workout.personalRecords,
                        "analysis pass must stamp the records marker")
        let categories = Set(workout.personalRecords?.windows.map(\.category) ?? [])
        XCTAssertEqual(categories, [.fastest400m, .fastest1km, .fastest1mile, .fastest5km])
        // The public segment list still exposes only the original five kinds.
        let segmentTypes = Set(workout.segments.map(\.type))
        XCTAssertTrue(segmentTypes.isSubset(of: [
            .fastest400m, .fastest1km, .slowest1km, .biggestClimb, .biggestDescent
        ]))
    }

    func testReanalyzePreservingRoutePointsKeepsRecords() {
        var workout = RunWorkout(routePoints: makeRoute(totalDistance: 5_000))
        WorkoutAnalyzer().reanalyzePreservingRoutePoints(&workout)
        XCTAssertNotNil(workout.personalRecords)
    }

    // MARK: - Codable tolerance

    func testSnapshotWithoutRecordsDecodesAsNil() throws {
        var workout = RunWorkout(routePoints: makeRoute(totalDistance: 5_000))
        WorkoutAnalyzer().analyze(&workout)
        let data = try JSONEncoder().encode(workout)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "personalRecords"))
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RunWorkout.self, from: legacyData)
        XCTAssertNil(decoded.personalRecords,
                     "legacy snapshots decode without records instead of failing")
    }

    func testRecordsRoundTripThroughCodable() throws {
        let records = detectRecords(makeRoute(totalDistance: 5_000))
        var workout = RunWorkout(routePoints: makeRoute(totalDistance: 5_000))
        workout.personalRecords = records
        let decoded = try JSONDecoder().decode(
            RunWorkout.self,
            from: JSONEncoder().encode(workout)
        )
        XCTAssertEqual(decoded.personalRecords, records)
    }

    // MARK: - Aggregation

    private func makeAggregationWorkout(
        id: UUID = UUID(),
        name: String,
        daysAgo: Int,
        distance: Double = 5_000,
        pace5k: Double? = nil,
        ascentCorrected: Double = 0,
        ascentRaw: Double? = nil,
        hasRecords: Bool = true
    ) -> RunWorkout {
        let date = Date(timeIntervalSince1970: 1_700_000_000 - Double(daysAgo) * 86_400)
        var windows: [PersonalRecordWindow] = []
        if let pace5k {
            windows.append(PersonalRecordWindow(
                category: .fastest5km,
                startDistanceMeters: 0,
                endDistanceMeters: 5_000,
                startElapsedSeconds: 0,
                endElapsedSeconds: pace5k * 5,
                activeSeconds: pace5k * 5,
                paceSecondsPerKilometer: pace5k,
                averageHeartRateBPM: 160,
                sourcePointRange: 0..<10
            ))
        }
        var workout = RunWorkout(
            id: id,
            metadata: WorkoutMetadata(name: name, startDate: date),
            source: .gpx,
            routePoints: makeRoute(totalDistance: distance, start: date),
            summary: RunSummary(
                totalDistanceMeters: distance,
                totalElapsedSeconds: 1_800,
                totalActiveSeconds: 1_800,
                elevationGainMeters: ascentCorrected,
                rawElevationGainMeters: ascentRaw
            )
        )
        workout.personalRecords =
            hasRecords ? WorkoutPersonalRecords(windows: windows) : nil
        return workout
    }

    func testAggregationPicksBestAndBuildsProgression() {
        // Oldest → newest: 300, 280 (new best), 290 (no improvement).
        let workouts = [
            makeAggregationWorkout(name: "A", daysAgo: 30, pace5k: 300),
            makeAggregationWorkout(name: "B", daysAgo: 20, pace5k: 280),
            makeAggregationWorkout(name: "C", daysAgo: 10, pace5k: 290)
        ]
        let snapshot = PersonalRecordsAggregator.aggregate(workouts: workouts)
        let row = snapshot.row(for: .fastest5km)
        XCTAssertEqual(row?.best?.workoutName, "B")
        XCTAssertEqual(row?.history.map(\.workoutName), ["A", "B"],
                       "only set-or-beat efforts appear in the progression")
        // Best is always the latest progression event.
        XCTAssertEqual(row?.best?.value, row?.history.last?.value)
        // Attempted-vs-not rows exist for every category.
        XCTAssertEqual(snapshot.rows.count, PersonalRecordCategory.allCases.count)
    }

    func testEqualEffortDoesNotReplaceStandingHolder() {
        let workouts = [
            makeAggregationWorkout(name: "First", daysAgo: 20, pace5k: 280),
            makeAggregationWorkout(name: "Equal", daysAgo: 10, pace5k: 280)
        ]
        let row = PersonalRecordsAggregator.aggregate(workouts: workouts).row(for: .fastest5km)
        XCTAssertEqual(row?.best?.workoutName, "First",
                       "an exactly equal effort never replaces the earlier holder")
        XCTAssertEqual(row?.history.count, 1)
    }

    func testLongestRunAndBiggestAscentUseSummariesWithRawFallback() {
        let workouts = [
            makeAggregationWorkout(
                name: "Short Hilly", daysAgo: 20, distance: 8_000,
                ascentCorrected: 0, ascentRaw: 300
            ),
            makeAggregationWorkout(
                name: "Long Flat", daysAgo: 10, distance: 15_000,
                ascentCorrected: 500, ascentRaw: nil
            )
        ]
        let snapshot = PersonalRecordsAggregator.aggregate(workouts: workouts)
        XCTAssertEqual(snapshot.row(for: .longestRun)?.best?.workoutName, "Long Flat")
        XCTAssertEqual(snapshot.row(for: .longestRun)?.best?.value, 15_000)
        XCTAssertEqual(snapshot.row(for: .biggestAscent)?.best?.workoutName, "Long Flat")
        XCTAssertEqual(snapshot.row(for: .biggestAscent)?.best?.value, 500)
        // The corrected-empty workout still contributes its raw ascent.
        XCTAssertEqual(snapshot.row(for: .biggestAscent)?.history.count, 2)
        // Whole-run categories carry no window.
        XCTAssertNil(snapshot.row(for: .longestRun)?.best?.window)
    }

    func testNeverAttemptedCategoryHasNoBestAndEmptyHistory() {
        let snapshot = PersonalRecordsAggregator.aggregate(
            workouts: [makeAggregationWorkout(name: "A", daysAgo: 1, pace5k: 300)]
        )
        let marathon = snapshot.row(for: .fastestMarathon)
        XCTAssertNil(marathon?.best)
        XCTAssertTrue(marathon?.history.isEmpty ?? false)
    }

    func testHistoryIsCappedToLastTenImprovements() {
        let workouts = (0..<12).map { index in
            makeAggregationWorkout(
                name: "Run \(index)",
                daysAgo: 40 - index,
                pace5k: 400 - Double(index) * 5
            )
        }
        let row = PersonalRecordsAggregator.aggregate(workouts: workouts).row(for: .fastest5km)
        XCTAssertEqual(row?.history.count, 10)
        XCTAssertEqual(row?.best?.workoutName, "Run 11",
                       "capping history never drops the current holder")
    }

    func testPendingBackfillCountTracksUncomputedSnapshots() {
        let workouts = [
            makeAggregationWorkout(name: "A", daysAgo: 1, pace5k: 300),
            makeAggregationWorkout(name: "B", daysAgo: 2, pace5k: nil, hasRecords: false),
            makeAggregationWorkout(name: "C", daysAgo: 3, pace5k: 320, hasRecords: false)
        ]
        let snapshot = PersonalRecordsAggregator.aggregate(workouts: workouts)
        XCTAssertEqual(snapshot.includedWorkoutCount, 3)
        XCTAssertEqual(snapshot.pendingBackfillWorkoutCount, 2)
        XCTAssertEqual(snapshot.currentHolders[.fastest5km]?.workoutName, "A")
    }

    // MARK: - Accessibility

    func testAccessibilitySummaryAnnouncesStandingRecords() {
        let snapshot = PersonalRecordsAggregator.aggregate(
            workouts: [makeAggregationWorkout(name: "A", daysAgo: 1, pace5k: 300)]
        )
        let summary = PersonalRecordsAccessibilitySummary(
            scopeDescription: "entire library",
            snapshot: snapshot
        )
        let spoken = summary.spokenSummary
        XCTAssertTrue(spoken.contains("Personal records."))
        XCTAssertTrue(spoken.contains("Fastest 5 km 5:00 per kilometre"))
        XCTAssertTrue(spoken.contains("Fastest Marathon not attempted."))
        XCTAssertTrue(spoken.contains("1 runs in scope."))
    }

    // MARK: - Backfill

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalRecordsTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func makeStoredLibrary(workoutCount: Int) async throws -> WorkoutLibraryStoreActor {
        let store = WorkoutLibraryStoreActor(
            store: FileWorkoutLibraryStore(rootURL: tempDir)
        )
        for index in 0..<workoutCount {
            var workout = RunWorkout(
                metadata: WorkoutMetadata(
                    name: "Backfill \(index)",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
                ),
                source: .gpx,
                routePoints: makeRoute(totalDistance: 5_000 + Double(index) * 100)
            )
            // Simulate a legacy snapshot: no analysis pass ever ran here.
            workout.personalRecords = nil
            try await store.addWorkout(workout, select: index == 0)
        }
        return store
    }

    func testBackfillComputesRecordsAndIsIdempotent() async throws {
        let store = try await makeStoredLibrary(workoutCount: 3)

        final class UpdateCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [WorkoutLibraryStoreActor.PersonalRecordsBackfillUpdate] = []
            func append(
                _ update: WorkoutLibraryStoreActor.PersonalRecordsBackfillUpdate
            ) {
                lock.lock()
                items.append(update)
                lock.unlock()
            }
            var all: [WorkoutLibraryStoreActor.PersonalRecordsBackfillUpdate] {
                lock.lock()
                defer { lock.unlock() }
                return items
            }
        }
        let collector = UpdateCollector()
        let first = await store.backfillPersonalRecords { update in
            collector.append(update)
        }
        XCTAssertEqual(first.computedCount, 3)
        XCTAssertEqual(first.skippedCount, 0)
        let updates = collector.all
        XCTAssertEqual(updates.count, 3)
        XCTAssertTrue(updates.allSatisfy { $0.computedWorkout != nil })

        // Saved snapshots now carry records.
        for update in updates {
            let workout = try XCTUnwrap(update.computedWorkout)
            XCTAssertFalse(
                workout.personalRecords?.windows.isEmpty ?? true,
                "5 km synthetic routes must gain at least the 400 m and 1 km windows"
            )
        }

        // Second pass is a pure skip: the nil marker is the idempotence key.
        let second = await store.backfillPersonalRecords()
        XCTAssertEqual(second.computedCount, 0)
        XCTAssertEqual(second.skippedCount, 3)
    }

    func testCancelledBackfillIsResumable() async throws {
        let store = try await makeStoredLibrary(workoutCount: 3)

        final class CancelBox: @unchecked Sendable {
            var cancel: (() -> Void)?
        }
        let box = CancelBox()
        let task = Task {
            await store.backfillPersonalRecords(policy: .runningDefault) { update in
                if update.completedCount >= 1 {
                    box.cancel?()
                }
            }
        }
        box.cancel = { task.cancel() }

        let partial = await task.value
        XCTAssertLessThan(partial.computedCount, 3,
                          "cancellation must stop the pass before completion")
        XCTAssertGreaterThan(partial.computedCount, 0,
                             "work completed before cancelling stays applied")
        XCTAssertEqual(partial.failedCount, 0,
                       "cancelling is not a failure: a run interrupted mid-detection "
                           + "keeps its unset marker for the next pass")
        XCTAssertEqual(partial.saveFailureCount, 0)

        // A later pass finishes the remainder.
        let resume = await store.backfillPersonalRecords()
        XCTAssertEqual(resume.computedCount, 3 - partial.computedCount)
        XCTAssertEqual(resume.skippedCount, partial.computedCount)
    }
}
