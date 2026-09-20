import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class AthleteProfileSettingsTests: XCTestCase {

    private func makeWorkout(
        start: Date,
        trainingLoad: TrainingLoadSnapshot?
    ) -> RunWorkout {
        RunWorkout(
            id: UUID(),
            metadata: WorkoutMetadata(name: "Run", activityType: "running", startDate: start),
            routePoints: [
                RoutePoint(
                    timestamp: start,
                    latitude: 1.3,
                    longitude: 103.8,
                    elapsedSeconds: 0
                ),
                RoutePoint(
                    timestamp: start.addingTimeInterval(1_800),
                    latitude: 1.31,
                    longitude: 103.9,
                    distanceFromStartMeters: 5_000,
                    elapsedSeconds: 1_800
                )
            ],
            summary: RunSummary(
                totalDistanceMeters: 5_000,
                totalElapsedSeconds: 1_800,
                totalActiveSeconds: 1_800,
                averageSpeedMetersPerSecond: 2.8
            ),
            trainingLoad: trainingLoad,
            analysisVersion: RunWorkout.currentAnalysisVersion
        )
    }

    func testUpdateAthleteProfilePersistsThroughStore() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileSettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let profileStore = FileAthleteProfileStore(rootURL: tempDir)
        let appState = AppState(storeActor: nil, profileStore: profileStore)

        XCTAssertEqual(appState.athleteProfile, AthleteProfile())

        let profile = AthleteProfile(
            birthYear: 1990,
            restingHeartRateBPM: 52,
            maximumHeartRateBPM: 194,
            trimpCoefficientProfile: .standardFemale
        )
        appState.updateAthleteProfile(profile)
        XCTAssertEqual(appState.athleteProfile, profile)
        XCTAssertEqual(profileStore.loadOrDefault(), profile)
    }

    func testStaleCountFollowsProfileRule() {
        let appState = AppState(storeActor: nil)
        let current = AthleteProfile(restingHeartRateBPM: 50)
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        appState.workouts = [
            makeWorkout(
                start: start,
                trainingLoad: TrainingLoadSnapshot(
                    kind: .measured,
                    banisterTRIMP: 50,
                    zoneSeconds: [0, 50, 0, 0, 0],
                    meanHeartRateBPM: 140,
                    validHeartRateSeconds: 1_800,
                    coveredActiveSeconds: 1_800,
                    profile: current
                )
            ),
            makeWorkout(start: start.addingTimeInterval(86_400), trainingLoad: nil),
        ]

        appState.updateAthleteProfile(current)
        // The never-computed snapshot counts; the matching one does not.
        XCTAssertEqual(appState.staleTrainingLoadCount, 1)

        let changed = AthleteProfile(restingHeartRateBPM: 55)
        appState.updateAthleteProfile(changed)
        // Both are stale now: one missing, one computed under the old rule.
        XCTAssertEqual(appState.staleTrainingLoadCount, 2)
    }

    func testRecomputePassRefreshesSnapshotsUnderCurrentProfile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileSettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = FileWorkoutLibraryStore(rootURL: tempDir)
        let storeActor = WorkoutLibraryStoreActor(store: store)

        let workout = makeWorkout(
            start: Date(timeIntervalSince1970: 1_767_225_600),
            trainingLoad: nil
        )
        try store.saveWorkout(workout)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [workout.id],
            selectedWorkoutID: workout.id
        ))

        let appState = AppState(storeActor: storeActor)
        appState.workouts = [workout]
        appState.hasPersistedLibrary = true

        XCTAssertEqual(appState.trainingLoadRecomputeState, .idle)
        appState.recomputeTrainingLoads()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .idle = appState.trainingLoadRecomputeState { break }
            if case .failed = appState.trainingLoadRecomputeState { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        guard case .idle = appState.trainingLoadRecomputeState else {
            return XCTFail("recompute did not finish cleanly")
        }
        XCTAssertNotNil(appState.workouts.first?.trainingLoad)
        XCTAssertEqual(appState.staleTrainingLoadCount, 0)
    }
}
