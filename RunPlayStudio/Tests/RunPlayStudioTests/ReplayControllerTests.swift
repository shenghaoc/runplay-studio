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

    func testSelectedMetricsAtStart() {
        let metrics = controller.selectedMetrics
        XCTAssertNotNil(metrics.elapsedSeconds)
        XCTAssertEqual(metrics.elapsedSeconds!, 0, accuracy: 0.1)
        XCTAssertNotNil(metrics.distanceMeters)
        XCTAssertEqual(metrics.distanceMeters!, 0, accuracy: 0.1)
    }

    func testSelectedMetricsAfterSeek() {
        controller.seekToTime(500)
        let metrics = controller.selectedMetrics
        XCTAssertNotNil(metrics.elapsedSeconds)
        // Should be close to 500 seconds (within a few seconds due to discrete points)
        XCTAssertEqual(metrics.elapsedSeconds!, 500, accuracy: 30)
        XCTAssertNotNil(metrics.distanceMeters)
        XCTAssertGreaterThan(metrics.distanceMeters!, 0)
    }

    func testSelectedMetricsFormatting() {
        controller.seekToTime(300) // 5 minutes
        let metrics = controller.selectedMetrics
        // Should be formatted as MM:SS (may not be exactly 5:00 due to discrete points)
        XCTAssertTrue(metrics.formattedElapsed.contains(":"))
        XCTAssertTrue(metrics.formattedDistance.contains("km"))
        XCTAssertTrue(metrics.formattedPace.contains("/km"))
    }

    func testSelectedMetricsHandlesMissingData() {
        // Workout without HR data
        let noHRWorkout = createSampleWorkout()
        controller.load(noHRWorkout)
        controller.seekToTime(500)

        let metrics = controller.selectedMetrics
        // Should not crash, HR should be nil
        XCTAssertNil(metrics.heartRateBPM)
    }

    func testSelectedIndexClampsAtEnd() {
        controller.seekToTime(controller.state.totalDuration + 1000)
        let metrics = controller.selectedMetrics
        XCTAssertNotNil(metrics.elapsedSeconds)
        // Should be clamped to last point
        XCTAssertLessThanOrEqual(metrics.elapsedSeconds!, controller.state.totalDuration + 1)
    }

    func testSelectedIndexClampsAtStart() {
        controller.seekToTime(-100)
        let metrics = controller.selectedMetrics
        XCTAssertNotNil(metrics.elapsedSeconds)
        XCTAssertEqual(metrics.elapsedSeconds!, 0, accuracy: 1)
    }

    func testRepeatedTimestampsDoNotCrash() {
        // Create workout with repeated timestamps
        let points = (0..<10).map { i in
            RoutePoint(
                timestamp: Date(),
                latitude: 37.7749 + Double(i) * 0.001,
                longitude: -122.4194,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: 0 // All same time
            )
        }
        let repeatedWorkout = RunWorkout(routePoints: points)
        controller.load(repeatedWorkout)
        controller.seekToTime(0)

        let metrics = controller.selectedMetrics
        XCTAssertNotNil(metrics.elapsedSeconds)
        // Should not crash
    }

    func testShortRouteDoesNotCrash() {
        let points = [
            RoutePoint(timestamp: Date(), latitude: 37.7749, longitude: -122.4194, altitudeMeters: 10, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: Date(), latitude: 37.7750, longitude: -122.4193, altitudeMeters: 15, distanceFromStartMeters: 100, elapsedSeconds: 30)
        ]
        let shortWorkout = RunWorkout(routePoints: points)
        controller.load(shortWorkout)

        // Should not crash on any seek
        controller.seekToTime(0)
        controller.seekToTime(15)
        controller.seekToTime(30)
        controller.seekToTime(100) // Beyond end

        let metrics = controller.selectedMetrics
        XCTAssertNotNil(metrics.elapsedSeconds)
    }

    func testSelectedMetricsNoNaN() {
        controller.seekToTime(500)
        let metrics = controller.selectedMetrics

        if let elapsed = metrics.elapsedSeconds {
            XCTAssertTrue(elapsed.isFinite)
            XCTAssertFalse(elapsed.isNaN)
        }
        if let distance = metrics.distanceMeters {
            XCTAssertTrue(distance.isFinite)
            XCTAssertFalse(distance.isNaN)
        }
        if let pace = metrics.paceSecondsPerKilometer {
            XCTAssertTrue(pace.isFinite)
            XCTAssertFalse(pace.isNaN)
        }
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
