import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class WorkoutLibraryNavigationTests: XCTestCase {

    private func makeWorkout(name: String, start: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: start),
            source: .gpx,
            routePoints: [
                RoutePoint(
                    timestamp: start ?? Date(timeIntervalSince1970: 1_700_000_000),
                    latitude: 1.3,
                    longitude: 103.8,
                    distanceFromStartMeters: 0,
                    elapsedSeconds: 0
                ),
                RoutePoint(
                    timestamp: (start ?? Date(timeIntervalSince1970: 1_700_000_000)).addingTimeInterval(100),
                    latitude: 1.31,
                    longitude: 103.9,
                    distanceFromStartMeters: 1_000,
                    elapsedSeconds: 100
                )
            ],
            summary: RunSummary(totalDistanceMeters: 1_000, totalElapsedSeconds: 100)
        )
    }

    func testEnteringAllRunsSetsWorkspaceWithoutClearingSelection() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)

        appState.showWorkoutLibrary()

        XCTAssertEqual(appState.workspaceMode, .workoutLibrary)
        XCTAssertEqual(appState.selectedWorkout?.id, a.id)
        XCTAssertEqual(appState.sidebarSelection, .allRuns)
    }

    func testSelectingWorkoutFromAllRunsOpensWorkoutWorkspace() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showWorkoutLibrary()

        appState.openWorkoutFromLibrary(b)

        XCTAssertEqual(appState.workspaceMode, .workout)
        XCTAssertEqual(appState.selectedWorkout?.id, b.id)
    }

    func testEnteringComparisonExitsAllRuns() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showWorkoutLibrary()

        appState.setComparison(b)

        XCTAssertEqual(appState.workspaceMode, .comparison)
        XCTAssertNotEqual(appState.workspaceMode, .workoutLibrary)
    }

    func testEnteringHeatmapExitsAllRuns() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)
        appState.showWorkoutLibrary()

        appState.showPersonalHeatmap()

        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)
    }

    func testDeletionWhileAllRunsVisibleKeepsAllRuns() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showWorkoutLibrary()

        await appState.deleteWorkout(a)

        XCTAssertEqual(appState.workspaceMode, .workoutLibrary)
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.selectedWorkout?.id, b.id)
    }

    func testApplySidebarSelectionAllRuns() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)

        appState.applySidebarSelection(.allRuns)

        XCTAssertEqual(appState.workspaceMode, .workoutLibrary)
        XCTAssertEqual(appState.selectedWorkout?.id, a.id)
    }

    func testWorkspaceMenuCommandOpensAllRuns() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)

        appState.handleWorkspaceCommand(.showAllRuns)

        XCTAssertEqual(appState.workspaceMode, .workoutLibrary)
        XCTAssertEqual(appState.selectedWorkout?.id, a.id)
    }

    func testDemoFavoriteDisabledWithoutPersistedLibrary() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "Demo")
        appState.workouts = [a]
        XCTAssertFalse(appState.canFavorite(a))
        XCTAssertFalse(appState.canEditLibraryMetadata(a))
        let ok = await appState.setFavorite(true, workoutID: a.id)
        XCTAssertFalse(ok)
        XCTAssertTrue(appState.favoriteWorkoutIDs.isEmpty)
    }



    func testAllRunsFiltersDoNotAffectHeatmapInputs() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.workoutLibrary.replaceLibrary(workouts: [a, b], favoriteIDs: [])
        appState.workoutLibrary.searchText = "A"
        appState.workoutLibrary.favoriteFilter = .favoritesOnly

        appState.showPersonalHeatmap()

        // Heatmap still receives full library, not All Runs filter subset.
        XCTAssertEqual(appState.workouts.count, 2)
        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)
        XCTAssertEqual(appState.workoutLibrary.searchText, "A")
    }
}

@MainActor
final class WorkoutLibraryPersistenceIntegrationTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryPersist-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeImportableWorkout(name: String) -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: Date(timeIntervalSince1970: 1_700_000_000)),
            source: .json,
            routePoints: [
                RoutePoint(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    latitude: 1.3,
                    longitude: 103.8,
                    distanceFromStartMeters: 0,
                    elapsedSeconds: 0
                ),
                RoutePoint(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                    latitude: 1.31,
                    longitude: 103.9,
                    distanceFromStartMeters: 1_000,
                    elapsedSeconds: 100
                )
            ],
            summary: RunSummary(totalDistanceMeters: 1_000, totalElapsedSeconds: 100)
        )
    }

    func testFirstImportReplacesDemosAndEnablesFavoriteOnlyForLibraryID() async throws {
        let store = FileWorkoutLibraryStore(rootURL: tempDir)
        let actor = WorkoutLibraryStoreActor(store: store)
        let appState = AppState(storeActor: actor, importService: WorkoutImportService())
        await appState.start()

        // Empty store → demos.
        XCTAssertFalse(appState.hasPersistedLibrary)
        XCTAssertTrue(appState.libraryWorkoutIDs.isEmpty)
        let demoIDs = Set(appState.workouts.map(\.id))
        XCTAssertFalse(demoIDs.isEmpty)
        for demo in appState.workouts {
            XCTAssertFalse(appState.canFavorite(demo))
            XCTAssertFalse(appState.canEditLibraryMetadata(demo))
        }

        let toImport = makeImportableWorkout(name: "Imported")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("import.json")
        try encoder.encode(toImport).write(to: url)

        await appState.importWorkout(from: url)

        XCTAssertTrue(appState.hasPersistedLibrary)
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.libraryWorkoutIDs.count, 1)
        XCTAssertTrue(demoIDs.isDisjoint(with: appState.libraryWorkoutIDs))
        let imported = try XCTUnwrap(appState.workouts.first)
        XCTAssertTrue(appState.canFavorite(imported))
        XCTAssertTrue(appState.canEditLibraryMetadata(imported))

        let favOK = await appState.setFavorite(true, workoutID: imported.id)
        XCTAssertTrue(favOK)
        XCTAssertTrue(appState.favoriteWorkoutIDs.contains(imported.id))
    }
}
