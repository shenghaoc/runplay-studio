import XCTest
import RunPlayCore
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

    func testDefaultAppStateLoadsDemoComparisonWorkouts() {
        let appState = AppState()

        XCTAssertGreaterThanOrEqual(appState.workouts.count, 2)
        XCTAssertEqual(appState.selectedWorkout?.displayName, "Morning Park Run")
        XCTAssertTrue(appState.workouts.contains { $0.displayName == "Morning Park Progression Run" })
        XCTAssertFalse(appState.availableForComparison.isEmpty)
    }

    // MARK: - Delete Tests

    func testDeleteWorkoutRemovesFromList() {
        let appState = AppState(loadSampleWorkout: false)
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")
        appState.workouts = [w1, w2]
        appState.selectWorkout(w1)

        appState.deleteWorkout(w1)

        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.workouts.first?.id, w2.id)
    }

    func testDeleteSelectedWorkoutSelectsNext() {
        let appState = AppState(loadSampleWorkout: false)
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")
        appState.workouts = [w1, w2]
        appState.selectWorkout(w1)

        appState.deleteWorkout(w1)

        XCTAssertEqual(appState.selectedWorkout?.id, w2.id)
    }

    func testDeleteComparisonWorkoutClearsComparison() {
        let appState = AppState(loadSampleWorkout: false)
        let primary = makeWorkout(name: "Primary")
        let comparison = makeWorkout(name: "Comparison")
        appState.workouts = [primary, comparison]
        appState.selectWorkout(primary)
        appState.setComparison(comparison)

        appState.deleteWorkout(comparison)

        XCTAssertNil(appState.comparisonWorkout)
        XCTAssertFalse(appState.isComparing)
    }

    func testDeleteLastWorkoutLeavesEmptyState() {
        let appState = AppState(loadSampleWorkout: false)
        let w1 = makeWorkout(name: "Only")
        appState.workouts = [w1]
        appState.selectWorkout(w1)

        appState.deleteWorkout(w1)

        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertNil(appState.selectedWorkout)
        XCTAssertTrue(appState.detectedSegments.isEmpty)
    }

    func testDeleteNonSelectedWorkoutDoesNotChangeSelection() {
        let appState = AppState(loadSampleWorkout: false)
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")
        appState.workouts = [w1, w2]
        appState.selectWorkout(w1)

        appState.deleteWorkout(w2)

        XCTAssertEqual(appState.selectedWorkout?.id, w1.id)
        XCTAssertEqual(appState.workouts.count, 1)
    }

    // MARK: - Delete + Comparison Combo

    func testDeleteSelectedWorkoutWhileComparingClearsComparison() {
        let appState = AppState(loadSampleWorkout: false)
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")
        appState.workouts = [w1, w2]
        appState.selectWorkout(w1)
        appState.setComparison(w2)

        appState.deleteWorkout(w1)

        XCTAssertEqual(appState.selectedWorkout?.id, w2.id)
        XCTAssertFalse(appState.isComparing)
        XCTAssertNil(appState.comparisonWorkout)
        XCTAssertNil(appState.selectedSegment)
    }

    func testDeleteSelectedWorkoutWhileComparingDoesNotCarryComparisonToReplacementSelection() {
        let appState = AppState(loadSampleWorkout: false)
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")
        let w3 = makeWorkout(name: "C")
        appState.workouts = [w1, w2, w3]
        appState.selectWorkout(w1)
        appState.setComparison(w3)
        appState.selectedComparisonDistanceMeters = 500

        appState.deleteWorkout(w1)

        XCTAssertEqual(appState.selectedWorkout?.id, w2.id)
        XCTAssertFalse(appState.isComparing)
        XCTAssertNil(appState.comparisonWorkout)
        XCTAssertNil(appState.comparisonPair)
        XCTAssertEqual(appState.selectedComparisonDistanceMeters, 0)
    }

    func testDeleteSelectedWorkoutCollisionWithComparison() {
        let appState = AppState(loadSampleWorkout: false)
        let w1 = makeWorkout(name: "A")
        let w2 = makeWorkout(name: "B")
        appState.workouts = [w1, w2]
        appState.selectWorkout(w1)
        appState.setComparison(w2)

        // Delete w1 — new selection is w2, which equals comparisonWorkout
        appState.deleteWorkout(w1)

        XCTAssertFalse(appState.isComparing)
        XCTAssertNil(appState.comparisonWorkout)
    }

    private func makeWorkout(name: String) -> RunWorkout {
        RunWorkout(metadata: WorkoutMetadata(name: name, activityType: "running"))
    }
}
