import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class AccessibilityAnnouncementTests: XCTestCase {

    func testDeliberateEventsProduceMessages() {
        let recorder = RecordingAccessibilityAnnouncer()
        let policy = AccessibilityAnnouncementPolicy(announcer: recorder)

        policy.handle(.replayPlayed)
        policy.handle(.replayPaused)
        policy.handle(.replayRestarted)
        policy.handle(.replayReachedEnd)
        policy.handle(.speedChanged(label: "2×"))
        policy.handle(.queryResultPublished(count: 3))
        policy.handle(.importCompleted(name: "fixture.gpx"))
        policy.handle(.heatmapReady(runCount: 5))

        XCTAssertEqual(recorder.messages.count, 8)
        XCTAssertEqual(recorder.messages[0], "Replay playing.")
        XCTAssertEqual(recorder.messages[1], "Replay paused.")
        XCTAssertTrue(recorder.messages.contains("3 runs."))
        XCTAssertTrue(recorder.messages.contains("Imported fixture.gpx."))
    }

    func testQueryResultAnnouncesOncePerDistinctCount() {
        let recorder = RecordingAccessibilityAnnouncer()
        let policy = AccessibilityAnnouncementPolicy(announcer: recorder)

        policy.handle(.queryResultPublished(count: 2))
        policy.handle(.queryResultPublished(count: 2))
        policy.handle(.queryResultPublished(count: 0))
        policy.handle(.queryResultPublished(count: 0))

        XCTAssertEqual(recorder.messages, [
            "2 runs.",
            "No runs match the current search or filters."
        ])
    }

    func testLibraryLoadSuppressesImmediateDuplicateQueryCount() {
        let recorder = RecordingAccessibilityAnnouncer()
        let policy = AccessibilityAnnouncementPolicy(announcer: recorder)

        policy.handle(.libraryLoaded(count: 2))
        policy.handle(.queryResultPublished(count: 2))
        policy.handle(.queryResultPublished(count: 1))

        XCTAssertEqual(recorder.messages, [
            "Library loaded. 2 runs.",
            "1 run.",
        ])
    }

    func testAppStateComparisonTransitionsUseRetainedPolicy() {
        let recorder = RecordingAccessibilityAnnouncer()
        let appState = AppState(accessibilityAnnouncer: recorder)
        let primary = RunWorkout(metadata: WorkoutMetadata(name: "Primary"))
        let comparison = RunWorkout(metadata: WorkoutMetadata(name: "Comparison"))
        appState.workouts = [primary, comparison]
        appState.selectedWorkout = primary

        appState.setComparison(comparison)
        appState.clearComparison()

        XCTAssertEqual(recorder.messages, [
            "Entered comparison.",
            "Ended comparison.",
        ])
    }

    func testWorkoutLibraryPublishesQueryResultAnnouncement() async {
        let recorder = RecordingAccessibilityAnnouncer()
        let policy = AccessibilityAnnouncementPolicy(announcer: recorder)
        let viewModel = WorkoutLibraryViewModel(announcementPolicy: policy)
        let workout = RunWorkout(metadata: WorkoutMetadata(name: "Synthetic"))

        viewModel.replaceLibrary(workouts: [workout], favoriteIDs: [])
        for _ in 0..<100 where viewModel.loadState != .ready {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.resultIDs, [workout.id])
        XCTAssertTrue(recorder.messages.contains("1 run."))
    }

    func testReplayTickAndProgressNeverAnnounce() {
        XCTAssertFalse(AccessibilityAnnouncementPolicy.shouldAnnounceReplayTick())
        XCTAssertFalse(AccessibilityAnnouncementPolicy.shouldAnnounceProgressPercent())
    }

    func testEmptyMessageIsIgnored() {
        let recorder = RecordingAccessibilityAnnouncer()
        recorder.announce("   ")
        XCTAssertTrue(recorder.messages.isEmpty)
    }

    func testCancellationAndFailureMessages() {
        XCTAssertEqual(
            AccessibilityAnnouncementEvent.importCancelled.message,
            "Import cancelled."
        )
        XCTAssertTrue(
            AccessibilityAnnouncementEvent.importFailed(message: "bad zip").message
                .contains("bad zip")
        )
        XCTAssertTrue(
            AccessibilityAnnouncementEvent.exportFailed(message: "disk full").message
                .contains("disk full")
        )
        XCTAssertEqual(
            AccessibilityAnnouncementEvent.exportCompleted(name: "summary.png").message,
            "Exported summary.png."
        )
    }
}
