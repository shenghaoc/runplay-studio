import XCTest
import RunPlayCore
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

    // MARK: - Playback Tick (advancePlayback)

    func testAdvancePlaybackAdvancesTime() {
        controller.play()
        let before = controller.state.currentTime

        controller.advancePlayback(by: 1.0 / 30.0)

        XCTAssertGreaterThan(controller.state.currentTime, before)
    }

    func testAdvancePlaybackAdvancesDistanceAndIndex() {
        controller.play()
        controller.advancePlayback(by: 50.0) // jump 50 seconds

        XCTAssertGreaterThan(controller.state.currentDistance, 0)
        XCTAssertGreaterThan(controller.state.currentPointIndex, 0)
    }

    func testAdvancePlaybackRespectsSpeedMultiplier() {
        controller.setSpeed(4.0)
        controller.play()

        controller.advancePlayback(by: 1.0) // 1 second wall-clock
        let at4x = controller.state.currentTime

        controller.stop()
        controller.setSpeed(1.0)
        controller.play()
        controller.advancePlayback(by: 1.0)
        let at1x = controller.state.currentTime

        // 4x speed should advance 4x as far in the same wall-clock interval
        XCTAssertEqual(at4x, at1x * 4.0, accuracy: 0.01)
    }

    func testAdvancePlaybackReachingEndLandsOnFinalPoint() {
        controller.play()
        // Advance well past the end
        controller.advancePlayback(by: controller.state.totalDuration + 100)

        let lastRoutePoint = workout.routePoints.last!
        XCTAssertEqual(controller.state.currentTime, controller.state.totalDuration, accuracy: 0.01)
        XCTAssertEqual(controller.state.currentPointIndex, workout.routePoints.count - 1)
        XCTAssertEqual(
            controller.state.currentDistance,
            lastRoutePoint.distanceFromStartMeters,
            accuracy: 0.01
        )
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.state.playbackState, .paused)
    }

    func testAdvancePlaybackDoesNothingWhenPaused() {
        controller.play()
        controller.advancePlayback(by: 5.0)
        let afterTick = controller.state.currentTime

        controller.pause()
        controller.advancePlayback(by: 5.0)

        // Should not have advanced while paused
        XCTAssertEqual(controller.state.currentTime, afterTick)
    }

    func testMultipleTicksAdvanceMonotonically() {
        controller.play()
        var previousTime = controller.state.currentTime
        var previousIndex = controller.state.currentPointIndex

        for _ in 0..<100 {
            controller.advancePlayback(by: 1.0) // 1 second per tick
            XCTAssertGreaterThanOrEqual(controller.state.currentTime, previousTime)
            XCTAssertGreaterThanOrEqual(controller.state.currentPointIndex, previousIndex)
            previousTime = controller.state.currentTime
            previousIndex = controller.state.currentPointIndex
        }

        // After 100 ticks at 1s each we should have moved significantly
        XCTAssertGreaterThan(controller.state.currentPointIndex, 0)
    }

    // MARK: - Marker Mapping Logic

    func testMarkerMappingFindsSourceIndexDirectly() {
        // Simulate projected scene points with sourceIndex gaps
        let routePoints = (0..<20).map { i in
            RoutePoint(
                timestamp: Date().addingTimeInterval(Double(i) * 5),
                latitude: 37.0 + Double(i) * 0.001,
                longitude: -122.0,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 5
            )
        }
        let workout = RunWorkout(routePoints: routePoints)

        // Project — all points valid, so sourceIndex should be 1:1
        let projection = RouteProjectionService()
        let scenePoints = projection.project(routePoints)

        // Look up scene point for route index 10
        let targetIndex = 10
        let match = scenePoints.first(where: { $0.sourceIndex == targetIndex })
        XCTAssertNotNil(match, "Direct sourceIndex match should succeed for valid coordinates")
        XCTAssertEqual(match!.sourceIndex, targetIndex)
    }

    func testMarkerMappingFallsBackToNearestDistance() {
        // Simulate scene points where some route indices are missing
        // (e.g., invalid coordinates were filtered out by projection)
        let scenePoints: [RouteScenePoint] = [
            RouteScenePoint(xMeters: 0, yMeters: 0, zMeters: 0,
                            sourceIndex: 0, distanceFromStartMeters: 0,
                            elapsedSeconds: 0),
            RouteScenePoint(xMeters: 100, yMeters: 0, zMeters: 0,
                            sourceIndex: 2, distanceFromStartMeters: 200,
                            elapsedSeconds: 10),
            RouteScenePoint(xMeters: 300, yMeters: 0, zMeters: 0,
                            sourceIndex: 4, distanceFromStartMeters: 400,
                            elapsedSeconds: 20),
            RouteScenePoint(xMeters: 500, yMeters: 0, zMeters: 0,
                            sourceIndex: 6, distanceFromStartMeters: 600,
                            elapsedSeconds: 30),
        ]

        // Route index 3 doesn't exist in scenePoints (sourceIndex 3 is missing).
        // The fallback should find the nearest by distanceFromStartMeters.
        let routeIndex = 3
        let routePoints = (0..<7).map { i in
            RoutePoint(
                timestamp: Date(),
                latitude: 37.0,
                longitude: -122.0,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 5
            )
        }

        // Direct match should fail
        let directMatch = scenePoints.first(where: { $0.sourceIndex == routeIndex })
        XCTAssertNil(directMatch, "sourceIndex 3 should be missing from scene points")

        // Fallback: binary search by distance
        let targetDistance = routePoints[routeIndex].distanceFromStartMeters // 300m
        var low = 0
        var high = scenePoints.count - 1
        while low < high {
            let mid = (low + high) / 2
            if scenePoints[mid].distanceFromStartMeters < targetDistance {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var bestIndex = low
        if low > 0 {
            let prevDiff = abs(scenePoints[low - 1].distanceFromStartMeters - targetDistance)
            let currDiff = abs(scenePoints[low].distanceFromStartMeters - targetDistance)
            if prevDiff < currDiff {
                bestIndex = low - 1
            }
        }

        // 300m target: closest scene point is sourceIndex 4 at 400m (100m away)
        // vs sourceIndex 2 at 200m (100m away) — equal distance, binary search
        // returns index 2 (the upper bound), so currDiff wins the tie.
        let chosen = scenePoints[bestIndex]
        XCTAssertTrue(chosen.sourceIndex == 2 || chosen.sourceIndex == 4,
                      "Fallback should pick nearest by distance")
        XCTAssertEqual(chosen.distanceFromStartMeters, 400, accuracy: 0.01)
    }

    // MARK: - Non-finite Input Guards

    func testSeekToTimeNaNIsIgnored() {
        controller.seekToTime(500)
        let before = controller.state.currentTime
        controller.seekToTime(.nan)
        XCTAssertEqual(controller.state.currentTime, before)
    }

    func testSeekToTimeInfinityIsIgnored() {
        controller.seekToTime(500)
        let before = controller.state.currentTime
        controller.seekToTime(.infinity)
        XCTAssertEqual(controller.state.currentTime, before)
    }

    func testSeekToDistanceNaNIsIgnored() {
        controller.seekToDistance(500)
        let before = controller.state.currentDistance
        controller.seekToDistance(.nan)
        XCTAssertEqual(controller.state.currentDistance, before)
    }

    func testSeekToDistanceInfinityIsIgnored() {
        controller.seekToDistance(500)
        let before = controller.state.currentDistance
        controller.seekToDistance(.infinity)
        XCTAssertEqual(controller.state.currentDistance, before)
    }

    func testSeekToProgressNaNIsIgnored() {
        controller.seekToProgress(0.5)
        let before = controller.state.currentTime
        controller.seekToProgress(.nan)
        XCTAssertEqual(controller.state.currentTime, before)
    }

    func testSeekToProgressInfinityIsIgnored() {
        controller.seekToProgress(0.5)
        let before = controller.state.currentTime
        controller.seekToProgress(.infinity)
        XCTAssertEqual(controller.state.currentTime, before)
    }

    func testSetSpeedNaNIsIgnored() {
        controller.setSpeed(2.0)
        let before = controller.state.playbackSpeed
        controller.setSpeed(.nan)
        XCTAssertEqual(controller.state.playbackSpeed, before)
    }

    func testSetSpeedInfinityIsIgnored() {
        controller.setSpeed(2.0)
        let before = controller.state.playbackSpeed
        controller.setSpeed(.infinity)
        XCTAssertEqual(controller.state.playbackSpeed, before)
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
