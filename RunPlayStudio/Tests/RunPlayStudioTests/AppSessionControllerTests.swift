import XCTest
import RunPlayCore
@testable import RunPlayStudio

private actor RecordingAppSessionStore: AppSessionStoring {
    var storedSnapshot: AppSessionSnapshot?
    var saveCount = 0

    init(snapshot: AppSessionSnapshot? = nil) {
        self.storedSnapshot = snapshot
    }

    func load() async -> AppSessionSnapshot? {
        storedSnapshot
    }

    func save(_ snapshot: AppSessionSnapshot) async throws {
        storedSnapshot = snapshot
        saveCount += 1
    }

    func clear() async throws {
        storedSnapshot = nil
    }
}

@MainActor
final class AppSessionControllerTests: XCTestCase {
    func testWritesAreSuppressedBeforeRestorationIsActive() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let store = RecordingAppSessionStore()
        let controller = AppSessionController(appState: appState, store: store)
        appState.sessionController = controller

        controller.requestSave()
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(controller.phase, .notStarted)
        let countBefore = await store.saveCount
        XCTAssertEqual(countBefore, 0)
    }

    func testStartupActivatesAndFlushesALogicalSnapshot() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let store = RecordingAppSessionStore()
        let controller = AppSessionController(appState: appState, store: store)
        appState.sessionController = controller

        await controller.startIfNeeded()
        XCTAssertEqual(controller.phase, .active)
        XCTAssertNotNil(appState.selectedWorkout)

        appState.workoutDetailTabRaw = "Charts"
        appState.workoutMapDisplayModeRaw = "3D"
        appState.showWorkoutLibrary()
        appState.workoutLibrary.searchText = "park"
        await controller.flush()

        let saved = await store.storedSnapshot
        XCTAssertEqual(saved?.workout.tabRaw, "Charts")
        XCTAssertEqual(saved?.workout.mapDisplayModeRaw, "3D")
        XCTAssertEqual(saved?.destination, .allRuns)
        XCTAssertEqual(saved?.library.manualQuery.searchText, "park")
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1)
    }

    func testStartupAppliesPersistedDestinationAfterLibraryLoad() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let store = RecordingAppSessionStore(
            snapshot: AppSessionSnapshot(
                destination: .allRuns,
                workout: AppSessionWorkoutState(tabRaw: "Charts", mapDisplayModeRaw: "3D")
            )
        )
        let controller = AppSessionController(appState: appState, store: store)
        appState.sessionController = controller

        await controller.startIfNeeded()

        XCTAssertEqual(controller.phase, .active)
        XCTAssertEqual(appState.workspaceMode, .workoutLibrary)
        XCTAssertEqual(appState.workoutDetailTabRaw, "Charts")
        XCTAssertEqual(appState.workoutMapDisplayModeRaw, "3D")
    }

    func testDebouncedSavePersistsAChangeAfterStartup() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let store = RecordingAppSessionStore()
        let controller = AppSessionController(appState: appState, store: store)
        appState.sessionController = controller

        await controller.startIfNeeded()
        appState.workoutDetailTabRaw = "Charts"

        try? await Task.sleep(nanoseconds: 400_000_000)

        let saved = await store.storedSnapshot
        let saveCount = await store.saveCount
        XCTAssertEqual(saved?.workout.tabRaw, "Charts")
        XCTAssertEqual(saveCount, 1)
    }

    func testReplayTicksAreCoalescedAndPauseFlushesImmediately() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let store = RecordingAppSessionStore()
        let controller = AppSessionController(appState: appState, store: store)
        appState.sessionController = controller

        await controller.startIfNeeded()
        await controller.flush()
        let initialSaveCount = await store.saveCount

        appState.replayController.engine.play()
        for _ in 0..<30 {
            appState.replayController.advancePlayback(by: 1.0 / 30.0)
        }
        appState.replayController.pause()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let finalSaveCount = await store.saveCount
        XCTAssertGreaterThan(finalSaveCount, initialSaveCount)
        XCTAssertLessThanOrEqual(finalSaveCount - initialSaveCount, 2)
        XCTAssertFalse(appState.replayController.isPlaying)
    }

    func testApplySessionSnapshotRestoresFiltersAndAlwaysPausesReplay() {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout()
        appState.workouts = [workout]
        appState.selectWorkout(workout, persistSelection: false)

        let snapshot = AppSessionSnapshot(
            destination: .personalHeatmap,
            sidebarVisibilityRaw: "detailOnly",
            workout: AppSessionWorkoutState(tabRaw: "Splits", mapDisplayModeRaw: "3D"),
            heatmap: AppSessionHeatmapState(
                datePresetRaw: "last90Days",
                resolutionRaw: "fine",
                minimumWorkoutCount: 3
            ),
            replay: AppSessionReplayState(
                workoutID: workout.id,
                elapsedSeconds: 40,
                playbackSpeed: 2
            )
        )

        appState.applySessionSnapshot(snapshot)

        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)
        XCTAssertEqual(appState.sidebarVisibilityRaw, "detailOnly")
        XCTAssertEqual(appState.workoutDetailTabRaw, "Splits")
        XCTAssertEqual(appState.workoutMapDisplayModeRaw, "3D")
        XCTAssertEqual(appState.personalHeatmap.datePreset, .last90Days)
        XCTAssertEqual(appState.personalHeatmap.resolution, .fine)
        XCTAssertEqual(appState.personalHeatmap.minimumWorkoutCount, 3)
        XCTAssertEqual(appState.replayController.state.currentTime, 40, accuracy: 1)
        XCTAssertFalse(appState.replayController.isPlaying)
        XCTAssertEqual(appState.replayController.state.playbackState, .paused)
    }

    private func makeWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for index in 0...4 {
            let offset = Double(index)
            let timestamp = start.addingTimeInterval(offset * 10)
            let latitude = 1.3 + offset * 0.001
            let longitude = 103.8 + offset * 0.001
            let distance = offset * 100
            let elapsed = offset * 10
            points.append(RoutePoint(
                timestamp: timestamp,
                latitude: latitude,
                longitude: longitude,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed
            ))
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Session Test", startDate: start),
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 400, totalElapsedSeconds: 40)
        )
    }
}
