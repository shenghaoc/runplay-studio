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

    func testContinuousReplayWritesPeriodicCheckpointsBeforePause() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let store = RecordingAppSessionStore()
        let controller = AppSessionController(
            appState: appState,
            store: store,
            replayCheckpointInterval: 40_000_000
        )
        appState.sessionController = controller

        await controller.startIfNeeded()
        await controller.flush()
        let initialSaveCount = await store.saveCount

        appState.replayController.engine.play()
        for _ in 0..<24 {
            appState.replayController.advancePlayback(by: 1.0 / 30.0)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let checkpointCount = await store.saveCount - initialSaveCount
        XCTAssertGreaterThanOrEqual(checkpointCount, 3)
        // A loaded CI runner can stretch the loop across several checkpoint
        // intervals. The invariant is periodic progress without one write per
        // replay tick, not a wall-clock-specific count.
        XCTAssertLessThan(checkpointCount, 24)

        appState.replayController.pause()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(appState.replayController.isPlaying)
    }

    func testSnapshotBoundsSearchWithoutDroppingFiltersOrSort() {
        let appState = AppState(storeActor: nil, importService: nil)
        appState.workoutLibrary.searchText = String(repeating: "x", count: 501)
        appState.workoutLibrary.favoriteFilter = .favoritesOnly
        appState.workoutLibrary.sort = .distanceLongest

        let query = appState.makeSessionSnapshot().library.manualQuery

        XCTAssertEqual(query.searchText.unicodeScalars.count, 500)
        XCTAssertEqual(query.filter.favorite, .favoritesOnly)
        XCTAssertEqual(query.sort, .distanceLongest)
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

    func testApplySessionSnapshotPreservesRouteAwareProgressUntilAlignmentIsReady() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let primary = makeAlignmentWorkout(name: "Primary", elapsedScale: 1)
        let comparison = makeAlignmentWorkout(name: "Comparison", elapsedScale: 1.2)
        appState.workouts = [primary, comparison]
        appState.selectWorkout(primary, persistSelection: false)

        appState.applySessionSnapshot(AppSessionSnapshot(
            destination: .comparison,
            comparison: AppSessionComparisonState(
                peerWorkoutID: comparison.id,
                alignmentModeRaw: ComparisonAlignmentMode.routeAware.rawValue,
                alignedProgressMeters: 1_000
            )
        ))
        // SwiftUI's restored comparison picker may immediately write the
        // already-selected peer while the alignment is still loading.
        appState.setComparison(comparison)

        XCTAssertEqual(appState.workspaceMode, .comparison)
        XCTAssertEqual(appState.comparisonViewModel.alignmentMode, .routeAware)
        XCTAssertEqual(appState.comparisonViewModel.selectedAlignedProgressMeters, 1_000)
        XCTAssertEqual(
            appState.makeSessionSnapshot().comparison?.alignedProgressMeters,
            1_000
        )

        for _ in 0..<100 {
            if appState.comparisonViewModel.routeAlignmentLoadState == .ready {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(appState.comparisonViewModel.routeAlignmentLoadState, .ready)
        XCTAssertEqual(appState.comparisonViewModel.clampedAlignedProgressMeters, 1_000)

        appState.setComparison(comparison)

        XCTAssertEqual(appState.comparisonViewModel.routeAlignmentLoadState, .ready)
        XCTAssertEqual(appState.comparisonViewModel.clampedAlignedProgressMeters, 1_000)
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

    private func makeAlignmentWorkout(name: String, elapsedScale: Double) -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0...40).map { index in
            let offset = Double(index)
            return RoutePoint(
                timestamp: start.addingTimeInterval(offset * 10 * elapsedScale),
                latitude: 1.3 + offset * 0.0005,
                longitude: 103.8 + offset * 0.0005,
                distanceFromStartMeters: offset * 100,
                elapsedSeconds: offset * 10 * elapsedScale
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: start),
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: 4_000,
                totalElapsedSeconds: 400 * elapsedScale
            )
        )
    }
}
