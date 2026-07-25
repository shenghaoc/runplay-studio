import AppKit
import XCTest
@testable import RunPlayStudio

@MainActor
private final class RecordingTerminatingSession: AppSessionTerminating {
    private(set) var flushCount = 0

    func pauseReplayAndFlush() async {
        flushCount += 1
        await Task.yield()
    }
}

@MainActor
final class AppTerminationCoordinatorTests: XCTestCase {
    func testTerminationWaitsForSessionFlushBeforeReplying() async {
        let session = RecordingTerminatingSession()
        let coordinator = AppTerminationCoordinator()
        let replied = expectation(description: "AppKit termination reply")
        coordinator.sessionController = session
        coordinator.terminationReply = { _, shouldTerminate in
            XCTAssertTrue(shouldTerminate)
            replied.fulfill()
        }

        let reply = coordinator.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(session.flushCount, 1)
    }
}
