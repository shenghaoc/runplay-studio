import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class PersonalHeatmapNavigationTests: XCTestCase {

    private func makeWorkout(name: String, distanceMeters: Double = 1_000) -> RunWorkout {
        let points = [
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
                distanceFromStartMeters: distanceMeters,
                elapsedSeconds: distanceMeters / 3
            )
        ]
        return RunWorkout(
            metadata: WorkoutMetadata(name: name, activityType: "running"),
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: distanceMeters, totalElapsedSeconds: distanceMeters / 3)
        )
    }

    func testEnteringHeatmapSetsWorkspaceMode() {
        let appState = AppState(storeActor: nil, importService: nil)
        let w = makeWorkout(name: "A")
        appState.workouts = [w]
        appState.selectWorkout(w)

        appState.showPersonalHeatmap()

        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)
        XCTAssertFalse(appState.isComparing)
        XCTAssertEqual(appState.selectedWorkout?.id, w.id)
    }

    func testSelectingWorkoutExitsHeatmap() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showPersonalHeatmap()
        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)

        appState.selectWorkout(b)

        XCTAssertEqual(appState.workspaceMode, .workout)
        XCTAssertEqual(appState.selectedWorkout?.id, b.id)
    }

    func testEnteringComparisonExitsHeatmap() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showPersonalHeatmap()

        appState.setComparison(b)

        XCTAssertEqual(appState.workspaceMode, .comparison)
        XCTAssertTrue(appState.isComparing)
        XCTAssertNotEqual(appState.workspaceMode, .personalHeatmap)
    }

    func testLeavingComparisonReturnsToWorkout() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.setComparison(b)

        appState.clearComparison()

        XCTAssertEqual(appState.workspaceMode, .workout)
        XCTAssertFalse(appState.isComparing)
        XCTAssertEqual(appState.selectedWorkout?.id, a.id)
    }

    func testNoInvalidWorkspaceCombinations() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.setComparison(b)
        XCTAssertTrue(appState.isComparing)

        appState.showPersonalHeatmap()
        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)
        XCTAssertFalse(appState.isComparing)
        XCTAssertNil(appState.comparisonWorkout)
    }

    func testSelectedWorkoutRemainsWhileHeatmapVisible() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)
        appState.showPersonalHeatmap()

        XCTAssertEqual(appState.selectedWorkout?.id, a.id)
        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)
    }

    func testDeletionWhileHeatmapVisibleStaysOnHeatmap() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showPersonalHeatmap()

        await appState.deleteWorkout(a)

        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.selectedWorkout?.id, b.id)
    }

    func testShowWorkoutWorkspaceLeavesHeatmap() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)
        appState.showPersonalHeatmap()

        appState.showWorkoutWorkspace()

        XCTAssertEqual(appState.workspaceMode, .workout)
    }

    func testHeatmapAndComparisonAreMutuallyExclusiveViaEmptyComparison() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)
        appState.showPersonalHeatmap()

        appState.enterEmptyComparisonMode()

        XCTAssertEqual(appState.workspaceMode, .comparison)
        XCTAssertTrue(appState.isComparing)
    }

    func testSidebarSelectionReflectsHeatmapWorkspace() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)
        XCTAssertEqual(appState.sidebarSelection, .workout(a.id))

        appState.showPersonalHeatmap()
        XCTAssertEqual(appState.sidebarSelection, .personalHeatmap)

        appState.applySidebarSelection(.workout(a.id))
        XCTAssertEqual(appState.workspaceMode, .workout)
        XCTAssertEqual(appState.selectedWorkout?.id, a.id)
        XCTAssertEqual(appState.sidebarSelection, .workout(a.id))
    }

    func testApplySidebarSelectionOpensHeatmapWithoutClearingSelectedWorkout() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A")
        appState.workouts = [a]
        appState.selectWorkout(a)

        appState.applySidebarSelection(.personalHeatmap)

        XCTAssertEqual(appState.workspaceMode, .personalHeatmap)
        XCTAssertEqual(appState.selectedWorkout?.id, a.id)
        XCTAssertEqual(appState.sidebarSelection, .personalHeatmap)
    }
}
