import XCTest
@testable import RunPlayCore

final class TrainingLoadBackfillTests: XCTestCase {

    private var tempDir: URL!
    private var store: FileWorkoutLibraryStore!
    private var actor: WorkoutLibraryStoreActor!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrainingLoadBackfillTests-\(UUID().uuidString)")
        store = FileWorkoutLibraryStore(rootURL: tempDir)
        actor = WorkoutLibraryStoreActor(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// A workout with 30 minutes of usable heart rate at reserve 0.5 under
    /// the reference profile (resting 50, maximum 150).
    private func makeWorkout(
        id: UUID = UUID(),
        withHeartRate: Bool = true,
        start: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> RunWorkout {
        var points: [RoutePoint] = []
        for index in 0...60 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(index) * 30),
                latitude: 37,
                longitude: -122,
                altitudeMeters: 100,
                distanceFromStartMeters: 90 * Double(index),
                elapsedSeconds: Double(index) * 30,
                heartRateBPM: withHeartRate ? 100 : nil
            ))
        }
        return RunWorkout(
            id: id,
            metadata: WorkoutMetadata(name: "Run", startDate: start),
            source: .gpx,
            routePoints: points,
            splits: [],
            summary: RunSummary(
                totalDistanceMeters: 5_400,
                totalElapsedSeconds: 1_800,
                averageSpeedMetersPerSecond: 3
            )
        )
    }

    private let profile = AthleteProfile(restingHeartRateBPM: 50, maximumHeartRateBPM: 150)

    /// Seed workouts through the synchronous store, matching the existing
    /// store-actor test convention.
    private func seed(_ workouts: [RunWorkout]) throws {
        for workout in workouts {
            try store.saveWorkout(workout)
        }
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: workouts.map(\.id),
            selectedWorkoutID: workouts.first?.id
        ))
    }

    /// Locked recorder so the `@Sendable` progress closure can count updates
    /// without mutating captured state.
    private final class UpdateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var countStorage = 0

        func append(_ update: WorkoutLibraryStoreActor.TrainingLoadBackfillUpdate) {
            lock.lock()
            defer { lock.unlock() }
            countStorage += 1
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return countStorage
        }
    }

    // MARK: - Backfill passes

    func testBackfillFillsMissingAndSkipsCurrent() async throws {
        let missing = makeWorkout(id: UUID())
        var current = makeWorkout(id: UUID())
        current.trainingLoad = try TrainingLoadCalculator.compute(
            heartRateSamples: current.heartRateSamples,
            activeSeconds: current.summary.totalActiveSeconds,
            averageSpeedMetersPerSecond: 3,
            profile: profile,
            referenceYear: 2026
        )
        try seed([current, missing])

        let recorder = UpdateRecorder()
        let result = await actor.backfillTrainingLoad(profile: profile, referenceYear: 2026) { update in
            recorder.append(update)
        }

        XCTAssertEqual(result.computedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.saveFailureCount, 0)
        XCTAssertEqual(recorder.count, 2)

        let reloaded = try store.loadWorkout(id: missing.id)
        XCTAssertEqual(reloaded.trainingLoad?.kind, .measured)
        XCTAssertEqual(reloaded.trainingLoad?.banisterTRIMP ?? 0, 30 * 0.5 * 0.64 * exp(0.96), accuracy: 1e-9)
    }

    func testSecondPassIsIdempotent() async throws {
        let workout = makeWorkout()
        try seed([workout])

        let first = await actor.backfillTrainingLoad(profile: profile, referenceYear: 2026)
        XCTAssertEqual(first.computedCount, 1)
        XCTAssertEqual(first.skippedCount, 0)

        let second = await actor.backfillTrainingLoad(profile: profile, referenceYear: 2026)
        XCTAssertEqual(second.computedCount, 0)
        XCTAssertEqual(second.skippedCount, 1)
    }

    /// A profile change makes previously current loads stale; the same pass
    /// corrects them. One rule covers never-computed and stale snapshots.
    func testProfileChangeMakesLoadsStaleAndRecomputeCorrects() async throws {
        let workout = makeWorkout()
        try seed([workout])
        _ = await actor.backfillTrainingLoad(profile: profile, referenceYear: 2026)

        let changedProfile = AthleteProfile(restingHeartRateBPM: 55, maximumHeartRateBPM: 150)
        let stalePass = await actor.backfillTrainingLoad(profile: changedProfile, referenceYear: 2026)
        XCTAssertEqual(stalePass.computedCount, 1)
        XCTAssertEqual(stalePass.skippedCount, 0)

        let reloaded = try store.loadWorkout(id: workout.id)
        XCTAssertEqual(reloaded.trainingLoad?.profile, changedProfile)

        let freshPass = await actor.backfillTrainingLoad(profile: changedProfile, referenceYear: 2026)
        XCTAssertEqual(freshPass.computedCount, 0)
        XCTAssertEqual(freshPass.skippedCount, 1)
    }

    func testHeartRatelessRunBackfillsAsEstimated() async throws {
        let workout = makeWorkout(withHeartRate: false)
        try seed([workout])

        let result = await actor.backfillTrainingLoad(profile: profile, referenceYear: 2026)
        XCTAssertEqual(result.computedCount, 1)

        let reloaded = try store.loadWorkout(id: workout.id)
        XCTAssertEqual(reloaded.trainingLoad?.kind, .estimated)
        XCTAssertEqual(reloaded.trainingLoad?.estimateBasis, .paceDuration)
        // Summary carries 5,400 m over 1,800 s → 3 m/s → 10.8 km/h band.
        XCTAssertEqual(reloaded.trainingLoad?.assumedHeartRateReserve, 0.60)
    }

    /// Cancellation ends the pass without counting a failure: completed
    /// snapshots stay saved and the pass resumes on the next run.
    func testCancellationKeepsCompletedWorkAndResumes() async throws {
        try seed((0..<4).map { _ in makeWorkout(id: UUID()) })

        // Locals so the sending Task closure captures values, not the test case.
        let storeActor = actor!
        let currentProfile = profile
        let cancellable = Task<WorkoutLibraryStoreActor.TrainingLoadBackfillResult, Never> {
            await storeActor.backfillTrainingLoad(profile: currentProfile, referenceYear: 2026)
        }
        cancellable.cancel()
        let result = await cancellable.value

        // Whatever ran before cancellation is saved; nothing failed.
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertLessThanOrEqual(result.computedCount + result.skippedCount, 4)

        let resumed = await actor.backfillTrainingLoad(profile: profile, referenceYear: 2026)
        XCTAssertEqual(resumed.computedCount + resumed.skippedCount, 4)
        XCTAssertEqual(resumed.failedCount, 0)
    }

    func testEmptyLibraryPassesCleanly() async {
        let result = await actor.backfillTrainingLoad(profile: profile, referenceYear: 2026)
        XCTAssertEqual(result.computedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
    }
}
