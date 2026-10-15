import XCTest
@testable import RunPlayCore

final class ReplayStateTests: XCTestCase {

    func testInitClampsInvalidPlaybackValues() {
        let state = ReplayState(
            currentTime: -10,
            currentDistance: Double.nan,
            currentPointIndex: -4,
            playbackSpeed: 0,
            totalDuration: 300,
            totalDistance: 5_000
        )

        XCTAssertEqual(state.currentTime, 0)
        XCTAssertEqual(state.currentDistance, 0)
        XCTAssertEqual(state.currentPointIndex, 0)
        XCTAssertEqual(state.playbackSpeed, 1.0)
        XCTAssertEqual(state.progress, 0)
        XCTAssertEqual(state.distanceProgress, 0)
    }

    func testInitClampsPositionToKnownTotals() {
        let state = ReplayState(
            currentTime: 400,
            currentDistance: 6_000,
            currentPointIndex: 3,
            playbackSpeed: 2,
            totalDuration: 300,
            totalDistance: 5_000
        )

        XCTAssertEqual(state.currentTime, 300)
        XCTAssertEqual(state.currentDistance, 5_000)
        XCTAssertEqual(state.currentPointIndex, 3)
        XCTAssertEqual(state.playbackSpeed, 2)
        XCTAssertEqual(state.progress, 1)
        XCTAssertEqual(state.distanceProgress, 1)
    }

    func testFormattedSpeedLabelsEverySpeedOption() {
        let speeds = PlaybackEngine.speedOptions

        // `%.1f` alone labelled 0.25 "0.2×".
        XCTAssertEqual(
            speeds.map { ReplayState.formattedSpeed($0) },
            ["0.25×", "0.5×", "1×", "2.0×", "4.0×", "8.0×"]
        )
        // The speed pop-up's value and the speed-change announcement read the
        // state's label.
        XCTAssertEqual(
            speeds.map { ReplayState(playbackSpeed: $0).formattedSpeed },
            ["0.25×", "0.5×", "1×", "2.0×", "4.0×", "8.0×"]
        )
    }

    func testFormattedSpeedMultiplierForEverySpeedOption() {
        // The speed pills' help text ("Replay at 0.25 speed") uses it.
        XCTAssertEqual(
            PlaybackEngine.speedOptions.map { ReplayState.formattedSpeedMultiplier($0) },
            ["0.25", "0.5", "1", "2.0", "4.0", "8.0"]
        )
    }
}
