import XCTest
@testable import RunPlayStudio

@MainActor
final class AccessibilityAnnouncementTests: XCTestCase {

    func testDeliberateEventsProduceMessages() {
        let recorder = RecordingAccessibilityAnnouncer()
        var policy = AccessibilityAnnouncementPolicy(announcer: recorder)

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
        var policy = AccessibilityAnnouncementPolicy(announcer: recorder)

        policy.handle(.queryResultPublished(count: 2))
        policy.handle(.queryResultPublished(count: 2))
        policy.handle(.queryResultPublished(count: 0))
        policy.handle(.queryResultPublished(count: 0))

        XCTAssertEqual(recorder.messages, [
            "2 runs.",
            "No runs match the current search or filters."
        ])
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
    }
}
