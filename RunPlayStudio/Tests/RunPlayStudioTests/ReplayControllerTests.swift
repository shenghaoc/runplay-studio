import XCTest
@testable import RunPlayStudio

final class ReplayControllerTests: XCTestCase {

    var controller: ReplayController!
    var workout: RunWorkout!

    override func setUp() {
        super.setUp()
        controller = ReplayController()
        workout = createSampleWorkout()
        controller.load(workout)
    }

    func testInitialState() {
        XCTAssertEqual(controller.state.playbackState, .stopped)
        XCTAssertEqual(controller.state.currentTime, 0)
        XCTAssertEqual(controller.state.currentDistance, 0)
        XCTAssertEqual(controller.state.currentPointIndex, 0)
        XCTAssertEqual(controller.state.playbackSpeed, 1.0)
    }

    func testLoadSetsTotalDuration() {
        XCTAssertGreaterThan(controller.state.totalDuration, 0)
        XCTAssertGreaterThan(controller.state.totalDistance, 0)
    }

    func testSeekToTime() {
        let halfTime = controller.state.totalDuration / 2
        controller.seekToTime(halfTime)

        XCTAssertEqual(controller.state.currentTime, halfTime, accuracy: 1)
        XCTAssertGreaterThan(controller.state.currentPointIndex, 0)
        XCTAssertGreaterThan(controller.state.currentDistance, 0)
    }

    func testSeekToProgress() {
        controller.seekToProgress(0.5)
        let expectedTime = controller.state.totalDuration * 0.5
        XCTAssertEqual(controller.state.currentTime, expectedTime, accuracy: 1)
    }

    func testSeekToProgressClamped() {
        controller.seekToProgress(1.5) // Beyond end
        XCTAssertEqual(controller.state.currentTime, controller.state.totalDuration, accuracy: 1)

        controller.seekToProgress(-0.5) // Before start
        XCTAssertEqual(controller.state.currentTime, 0)
    }

    func testSeekToDistance() {
        let halfDist = controller.state.totalDistance / 2
        controller.seekToDistance(halfDist)

        XCTAssertEqual(controller.state.currentDistance, halfDist, accuracy: 10)
    }

    func testPlayPauseToggle() {
        XCTAssertFalse(controller.isPlaying)

        controller.togglePlayPause()
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.state.playbackState, .playing)

        controller.togglePlayPause()
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.state.playbackState, .paused)
    }

    func testStopResetsState() {
        controller.seekToTime(controller.state.totalDuration / 2)
        controller.stop()

        XCTAssertEqual(controller.state.currentTime, 0)
        XCTAssertEqual(controller.state.currentDistance, 0)
        XCTAssertEqual(controller.state.currentPointIndex, 0)
        XCTAssertEqual(controller.state.playbackState, .stopped)
    }

    func testSetSpeed() {
        controller.setSpeed(2.0)
        XCTAssertEqual(controller.state.playbackSpeed, 2.0)

        controller.setSpeed(0.5)
        XCTAssertEqual(controller.state.playbackSpeed, 0.5)
    }

    func testSpeedClamping() {
        controller.setSpeed(0.01) // Below minimum
        XCTAssertEqual(controller.state.playbackSpeed, 0.1)

        controller.setSpeed(100) // Above maximum
        XCTAssertEqual(controller.state.playbackSpeed, 16.0)
    }

    func testStepForward() {
        let initialIndex = controller.state.currentPointIndex
        controller.stepForward()
        XCTAssertGreaterThanOrEqual(controller.state.currentPointIndex, initialIndex)
    }

    func testStepBackward() {
        controller.seekToTime(controller.state.totalDuration / 2)
        let midIndex = controller.state.currentPointIndex
        controller.stepBackward()
        XCTAssertLessThanOrEqual(controller.state.currentPointIndex, midIndex)
    }

    func testCurrentRoutePoint() {
        XCTAssertNotNil(controller.currentRoutePoint)
        XCTAssertEqual(controller.currentRoutePoint?.id, workout.routePoints[0].id)
    }

    // MARK: - Helpers

    private func createSampleWorkout() -> RunWorkout {
        let points = (0..<50).map { i -> RoutePoint in
            let fraction = Double(i) / 49.0
            return RoutePoint(
                timestamp: Date().addingTimeInterval(fraction * 1000),
                latitude: 37.7749 + fraction * 0.01,
                longitude: -122.4194 + fraction * 0.01,
                altitudeMeters: 10 + fraction * 20,
                distanceFromStartMeters: fraction * 5000,
                elapsedSeconds: fraction * 1000
            )
        }
        return RunWorkout(routePoints: points)
    }
}
