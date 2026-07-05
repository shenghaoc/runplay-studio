import XCTest
@testable import RunPlayStudio

@MainActor
final class AppStateComparisonTests: XCTestCase {

    func testSetComparisonRejectsSelectedWorkout() {
        let appState = AppState(loadSampleWorkout: false)
        let workout = makeWorkout(name: "Primary")
        appState.workouts = [workout]
        appState.selectWorkout(workout)

        appState.setComparison(workout)

        XCTAssertNil(appState.comparisonWorkout)
        XCTAssertNil(appState.comparisonPair)
        XCTAssertFalse(appState.isComparing)
        XCTAssertEqual(appState.comparisonSelectionMessage, "Choose a different run to compare.")
    }

    func testAvailableForComparisonExcludesSelectedWorkout() {
        let appState = AppState(loadSampleWorkout: false)
        let primary = makeWorkout(name: "Primary")
        let comparison = makeWorkout(name: "Comparison")
        appState.workouts = [primary, comparison]
        appState.selectWorkout(primary)

        XCTAssertEqual(appState.availableForComparison.map(\.id), [comparison.id])
    }

    func testComparisonPairRejectsSameWorkoutEvenIfStateIsMutatedDirectly() {
        let appState = AppState(loadSampleWorkout: false)
        let workout = makeWorkout(name: "Primary")
        appState.workouts = [workout]
        appState.selectedWorkout = workout
        appState.comparisonWorkout = workout

        XCTAssertNil(appState.comparisonPair)
    }

    func testSetComparisonAcceptsDifferentWorkout() {
        let appState = AppState(loadSampleWorkout: false)
        let primary = makeWorkout(name: "Primary")
        let comparison = makeWorkout(name: "Comparison")
        appState.workouts = [primary, comparison]
        appState.selectWorkout(primary)

        appState.setComparison(comparison)

        XCTAssertEqual(appState.comparisonWorkout?.id, comparison.id)
        XCTAssertNotNil(appState.comparisonPair)
        XCTAssertTrue(appState.isComparing)
        XCTAssertNil(appState.comparisonSelectionMessage)
    }

    private func makeWorkout(name: String) -> RunWorkout {
        RunWorkout(metadata: WorkoutMetadata(name: name, activityType: "running"))
    }
}
