import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// Records workspace wiring: transitions, scoping, navigation, and session
/// restoration. All fixtures are synthetic.
@MainActor
final class PersonalRecordsWorkspaceTests: XCTestCase {

    private func makeWorkout(
        name: String,
        id: UUID = UUID(),
        daysAgo: Int,
        distanceMeters: Double = 5_000,
        pace5k: Double? = nil
    ) -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000 - Double(daysAgo) * 86_400)
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
                averageHeartRateBPM: 165,
                sourcePointRange: 0..<2
            ))
        }
        var workout = RunWorkout(
            id: id,
            metadata: WorkoutMetadata(name: name, activityType: "running", startDate: start),
            routePoints: [
                RoutePoint(
                    timestamp: start,
                    latitude: 1.3,
                    longitude: 103.8,
                    elapsedSeconds: 0
                ),
                RoutePoint(
                    timestamp: start.addingTimeInterval(1_500),
                    latitude: 1.31,
                    longitude: 103.9,
                    distanceFromStartMeters: distanceMeters,
                    elapsedSeconds: 1_500
                )
            ],
            summary: RunSummary(
                totalDistanceMeters: distanceMeters,
                totalElapsedSeconds: 1_560,
                totalActiveSeconds: 1_500
            )
        )
        workout.personalRecords = WorkoutPersonalRecords(windows: windows)
        return workout
    }

    /// Polls until the async records build publishes, bounded in time.
    private func waitForReady(
        _ viewModel: PersonalRecordsViewModel,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ready = viewModel.loadState { return true }
            if case .empty = viewModel.loadState { return true }
            if case .failed = viewModel.loadState { return false }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: - Workspace transitions

    func testEnteringRecordsSetsWorkspaceModeAndKeepsSelection() {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout(name: "A", daysAgo: 3)
        appState.workouts = [workout]
        appState.selectWorkout(workout)

        appState.showPersonalRecords()

        XCTAssertEqual(appState.workspaceMode, .personalRecords)
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
        XCTAssertEqual(appState.sidebarSelection, .personalRecords)
    }

    func testSelectingWorkoutExitsRecords() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A", daysAgo: 3)
        let b = makeWorkout(name: "B", daysAgo: 5)
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showPersonalRecords()

        appState.selectWorkout(b)

        XCTAssertEqual(appState.workspaceMode, .workout)
    }

    func testShowRecordsPreselectsActiveSmartCollectionScope() {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout(name: "A", daysAgo: 3)
        appState.workouts = [workout]
        let collection = WorkoutSmartCollection(name: "Races", query: WorkoutLibrarySavedQuery())
        appState.smartCollections = [collection]
        appState.showSmartCollection(id: collection.id)

        appState.showPersonalRecords()

        XCTAssertEqual(
            appState.personalRecords.scope,
            .smartCollection(collection.id),
            "first Records open preselects the active All Runs collection"
        )

        // An explicit user selection is never overwritten on re-entry.
        appState.personalRecords.scope = .entireLibrary
        appState.showPersonalRecords()
        XCTAssertEqual(appState.personalRecords.scope, .entireLibrary)
    }

    // MARK: - Record navigation

    func testOpenPersonalRecordSelectsWorkoutSeeksAndHighlights() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout(name: "Holder", daysAgo: 1, pace5k: 280)
        appState.workouts = [workout]
        appState.showPersonalRecords()
        _ = await waitForReady(appState.personalRecords)

        let effort = PersonalRecordsAggregator
            .aggregate(workouts: [workout])
            .currentHolders[.fastest5km]
        XCTAssertNotNil(effort)
        guard let effort else { return }

        appState.openPersonalRecord(effort)

        XCTAssertEqual(appState.workspaceMode, .workout)
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
        XCTAssertEqual(appState.highlightedWorkoutRange?.workoutID, workout.id)
        XCTAssertEqual(appState.highlightedWorkoutRange?.startDistanceMeters, 0)
        XCTAssertEqual(appState.workoutDetailTabRaw, "Overview")
        // Sought to the window start (window starts at distance 0).
        XCTAssertEqual(appState.replayController.state.currentDistance, 0, accuracy: 1e-6)

        // Selecting a different workout clears the highlight.
        let other = makeWorkout(name: "Other", daysAgo: 10)
        appState.workouts.append(other)
        appState.selectWorkout(other)
        XCTAssertNil(appState.highlightedWorkoutRange)
    }

    func testOpenWholeRunRecordSelectsWorkoutWithoutRange() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout(name: "Longest", daysAgo: 1, distanceMeters: 12_000)
        appState.workouts = [workout]
        appState.showPersonalRecords()
        _ = await waitForReady(appState.personalRecords)

        guard let effort = PersonalRecordsAggregator
            .aggregate(workouts: [workout])
            .currentHolders[.longestRun] else {
            return XCTFail("longest-run holder missing")
        }

        appState.openPersonalRecord(effort)

        XCTAssertEqual(appState.workspaceMode, .workout)
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
        XCTAssertNil(appState.highlightedWorkoutRange,
                     "whole-run records open without a window highlight")
    }

    // MARK: - Scoped aggregation through the view model

    func testScopeRespectsCurrentAllRunsQuery() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let inFilter = makeWorkout(name: "Race", id: UUID(), daysAgo: 2, pace5k: 300)
        let outOfFilter = makeWorkout(name: "Training", id: UUID(), daysAgo: 1, pace5k: 250)
        appState.workouts = [inFilter, outOfFilter]
        appState.showWorkoutLibrary()
        appState.workoutLibrary.searchText = "Race"

        appState.showPersonalRecords()
        appState.personalRecords.scope = .currentLibraryFilter
        appState.refreshPersonalRecords()
        let ready = await waitForReady(appState.personalRecords)
        XCTAssertTrue(ready)

        let row = appState.personalRecords.snapshot?.row(for: .fastest5km)
        XCTAssertEqual(row?.best?.workoutName, "Race",
                       "the scoped table only ranks workouts matching the All Runs query")
        XCTAssertEqual(row?.best?.value ?? 0, 300, accuracy: 1e-9)
    }

    // MARK: - Session

    func testSessionRoundTripsRecordsDestinationAndScope() {
        let appState = AppState(storeActor: nil, importService: nil)
        let collection = WorkoutSmartCollection(name: "Races", query: WorkoutLibrarySavedQuery())
        appState.smartCollections = [collection]
        appState.personalRecords.scope = .smartCollection(collection.id)
        appState.showPersonalRecords()

        let snapshot = appState.makeSessionSnapshot()
        XCTAssertEqual(snapshot.destination, .personalRecords)
        XCTAssertEqual(snapshot.personalRecords.scopeKindRaw, "smartCollection")
        XCTAssertEqual(snapshot.personalRecords.scopeSmartCollectionID, collection.id)

        // Restoring into a fresh state with the collection present keeps the
        // scope; the workspace reopens Records.
        let restored = AppState(storeActor: nil, importService: nil)
        restored.smartCollections = [collection]
        restored.workouts = [makeWorkout(name: "A", daysAgo: 1, pace5k: 300)]
        restored.applySessionSnapshot(snapshot)
        XCTAssertEqual(restored.workspaceMode, .personalRecords)
        XCTAssertEqual(restored.personalRecords.scope, .smartCollection(collection.id))
    }

    func testSessionValidatorDropsMissingRecordsScopeCollection() {
        let snapshot = AppSessionSnapshot(
            destination: .personalRecords,
            personalRecords: AppSessionPersonalRecordsState(
                scopeKindRaw: "smartCollection",
                scopeSmartCollectionID: UUID()
            )
        )
        let result = AppSessionValidator.validate(
            snapshot,
            context: AppSessionValidationContext()
        )
        XCTAssertEqual(result.snapshot.destination, .personalRecords)
        XCTAssertEqual(
            result.snapshot.personalRecords.scopeKindRaw,
            "entireLibrary",
            "a dangling records scope collection degrades to the entire library"
        )
        XCTAssertTrue(result.usedFallback)
    }

    // MARK: - Commands

    func testWorkspaceCommandOpensRecords() {
        let appState = AppState(storeActor: nil, importService: nil)
        appState.workouts = [makeWorkout(name: "A", daysAgo: 1)]
        appState.handleWorkspaceCommand(.showPersonalRecords)
        XCTAssertEqual(appState.workspaceMode, .personalRecords)
    }

    func testCommandRegistryCarriesRecordsDefinition() {
        let definition = CommandRegistry.definition(for: .showPersonalRecords)
        XCTAssertEqual(definition.menuTitle, "Records")
        XCTAssertEqual(definition.keyEquivalent, "P")
    }
}

final class PersonalRecordsBackfillMessageTests: XCTestCase {

    private func result(
        computed: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        saveFailures: Int = 0
    ) -> WorkoutLibraryStoreActor.PersonalRecordsBackfillResult {
        WorkoutLibraryStoreActor.PersonalRecordsBackfillResult(
            computedCount: computed,
            skippedCount: skipped,
            failedCount: failed,
            saveFailureCount: saveFailures
        )
    }

    @MainActor
    func testCancelledPassReportsNoFailureBanner() {
        // A user-cancelled pass computes fewer runs than the library holds
        // but nothing failed, so the banner must stay silent.
        XCTAssertNil(AppState.personalRecordsBackfillFailureMessage(
            result(computed: 4, skipped: 1)
        ))
    }

    @MainActor
    func testFailureBannerAgreesWithCountAndRetryPath() {
        let analysisOnly = AppState.personalRecordsBackfillFailureMessage(
            result(computed: 2, failed: 1)
        )
        XCTAssertEqual(
            analysisOnly,
            "1 run could not be analyzed; it will be retried the next time you open Records."
        )

        let saveOnly = AppState.personalRecordsBackfillFailureMessage(
            result(computed: 2, saveFailures: 2)
        )
        XCTAssertEqual(
            saveOnly,
            "2 runs were analyzed but could not be saved; they will be recomputed on the next launch."
        )

        let both = AppState.personalRecordsBackfillFailureMessage(
            result(failed: 2, saveFailures: 1)
        )
        XCTAssertEqual(
            both,
            "2 runs could not be analyzed; they will be retried the next time you open Records. "
                + "1 run was analyzed but could not be saved; it will be recomputed on the next launch."
        )
    }
}
