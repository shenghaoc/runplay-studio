import Foundation
import XCTest
@testable import RunPlayCore

final class PlaybackEngineTests: XCTestCase {
    func testPausedWorkoutUsesElapsedDurationAndHoldsRouteState() {
        let engine = PlaybackEngine()
        engine.load(pausedWorkout())

        XCTAssertEqual(engine.state.totalDuration, 3_300, accuracy: 0.001)

        engine.seekToTime(1_500)
        XCTAssertEqual(engine.state.currentPointIndex, 1)
        XCTAssertEqual(engine.state.currentDistance, 600, accuracy: 0.001)
        XCTAssertEqual(engine.selectedMetrics.elapsedSeconds ?? -1, 1_500, accuracy: 0.001)
        XCTAssertEqual(engine.selectedMetrics.activeSeconds ?? -1, 180, accuracy: 0.001)
        XCTAssertTrue(engine.selectedMetrics.isInRecordingGap)

        engine.seekToTime(3_180)
        XCTAssertEqual(engine.state.currentPointIndex, 2)
        XCTAssertEqual(engine.state.currentDistance, 600, accuracy: 0.001)
        XCTAssertEqual(engine.selectedMetrics.activeSeconds ?? -1, 180, accuracy: 0.001)
        XCTAssertFalse(engine.selectedMetrics.isInRecordingGap)
    }

    func testSteppingCrossesPauseUsingOnlyRealPoints() {
        let engine = PlaybackEngine()
        engine.load(pausedWorkout())
        engine.seekToTime(180)

        engine.stepForward()
        XCTAssertEqual(engine.state.currentPointIndex, 2)
        XCTAssertEqual(engine.state.currentTime, 3_180, accuracy: 0.001)
        XCTAssertEqual(engine.selectedMetrics.activeSeconds ?? -1, 180, accuracy: 0.001)

        engine.stepBackward()
        XCTAssertEqual(engine.state.currentPointIndex, 1)
        XCTAssertEqual(engine.state.currentTime, 180, accuracy: 0.001)
    }

    func testEndStateSelectsFinalPointAndStopsPlayback() {
        let engine = PlaybackEngine()
        let workout = pausedWorkout()
        engine.load(workout)
        engine.play()

        engine.advancePlayback(by: 4_000)

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.state.currentTime, 3_300, accuracy: 0.001)
        XCTAssertEqual(engine.state.currentPointIndex, workout.routePoints.count - 1)
        XCTAssertEqual(engine.state.currentDistance, 1_000, accuracy: 0.001)
    }

    func testLoadStopAndEndRestartUseLatestPointAtDuplicateZeroTimestamp() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let workout = RunWorkout(routePoints: [
            point(start: start, time: 0, distance: 0, segment: 0),
            point(start: start, time: 0, distance: 10, segment: 0),
            point(start: start, time: 10, distance: 100, segment: 0)
        ])
        let engine = PlaybackEngine()

        engine.load(workout)
        XCTAssertEqual(engine.state.currentPointIndex, 1)
        XCTAssertEqual(engine.state.currentDistance, 10, accuracy: 0.001)
        XCTAssertTrue(engine.canStepBackward)
        XCTAssertTrue(engine.canStepForward)

        engine.seekToTime(10)
        engine.stop()
        XCTAssertEqual(engine.state.currentPointIndex, 1)

        engine.seekToTime(10)
        engine.play()
        XCTAssertEqual(engine.state.currentPointIndex, 1)
        XCTAssertEqual(engine.state.currentTime, 0, accuracy: 0.001)
    }

    func testDuplicateFinalTimestampKeepsForwardStepAvailableByIndex() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let workout = RunWorkout(routePoints: [
            point(start: start, time: 0, distance: 0, segment: 0),
            point(start: start, time: 10, distance: 90, segment: 0),
            point(start: start, time: 10, distance: 100, segment: 0)
        ])
        let engine = PlaybackEngine()
        engine.load(workout)
        engine.seekToTime(10)

        XCTAssertFalse(engine.canStepForward)
        engine.stepBackward()
        XCTAssertEqual(engine.state.currentPointIndex, 1)
        XCTAssertEqual(engine.state.currentTime, engine.state.totalDuration, accuracy: 0.001)
        XCTAssertTrue(engine.canStepForward)
    }

    func testSplitAtPauseBoundaryStaysPriorUntilExactResume() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var workout = RunWorkout(routePoints: [
            point(start: start, time: 0, distance: 0, segment: 0),
            point(start: start, time: 300, distance: 1_000, segment: 0),
            point(start: start, time: 3_300, distance: 1_000, segment: 1),
            point(start: start, time: 3_600, distance: 2_000, segment: 1)
        ])
        WorkoutAnalyzer().analyze(&workout)
        let engine = PlaybackEngine()
        engine.load(workout)

        engine.seekToTime(300)
        XCTAssertEqual(engine.selectedMetrics.splitIndex, 0)

        engine.seekToTime(1_500)
        XCTAssertEqual(engine.selectedMetrics.splitIndex, 0)

        engine.seekToTime(3_300)
        XCTAssertEqual(engine.selectedMetrics.splitIndex, 1)
    }

    func testRecordedLapOwnershipAdvancesAtSharedBoundaryAndHoldsAtFinish() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let laps = [
            recordedLap(index: 1, startTime: 0, endTime: 10, startDistance: 0, endDistance: 100),
            recordedLap(index: 2, startTime: 10, endTime: 20, startDistance: 100, endDistance: 200)
        ]
        let workout = RunWorkout(
            routePoints: [
                point(start: start, time: 0, distance: 0, segment: 0),
                point(start: start, time: 10, distance: 100, segment: 0),
                point(start: start, time: 20, distance: 200, segment: 0)
            ],
            recordedLaps: laps
        )
        let engine = PlaybackEngine()
        engine.load(workout)

        engine.seekToTime(9.999)
        XCTAssertEqual(engine.selectedMetrics.recordedLapIndex, 0)

        engine.seekToTime(10)
        XCTAssertEqual(engine.selectedMetrics.recordedLapIndex, 1)

        engine.seekToTime(20)
        XCTAssertEqual(engine.selectedMetrics.recordedLapIndex, 1)
    }

    func testZeroDurationRecordedLapOwnsOnlyItsExactBoundary() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let laps = [
            recordedLap(index: 1, startTime: 0, endTime: 10, startDistance: 0, endDistance: 100),
            recordedLap(index: 2, startTime: 10, endTime: 10, startDistance: 100, endDistance: 100),
            recordedLap(index: 3, startTime: 10, endTime: 20, startDistance: 100, endDistance: 200)
        ]
        let workout = RunWorkout(
            routePoints: [
                point(start: start, time: 0, distance: 0, segment: 0),
                point(start: start, time: 10, distance: 100, segment: 0),
                point(start: start, time: 20, distance: 200, segment: 0)
            ],
            recordedLaps: laps
        )
        let engine = PlaybackEngine()
        engine.load(workout)

        engine.seekToTime(10)
        XCTAssertEqual(engine.selectedMetrics.recordedLapIndex, 1)

        engine.seekToTime(10.001)
        XCTAssertEqual(engine.selectedMetrics.recordedLapIndex, 2)
    }

    func testEmptyAndOnePointWorkoutsRemainSafe() {
        let engine = PlaybackEngine()
        engine.load(RunWorkout(routePoints: []))
        engine.seekToTime(10)
        engine.stepForward()
        XCTAssertNil(engine.currentRoutePoint)

        let point = RoutePoint(
            timestamp: Date(timeIntervalSince1970: 100),
            latitude: 1,
            longitude: 1,
            distanceFromStartMeters: 0,
            elapsedSeconds: 0
        )
        engine.load(RunWorkout(routePoints: [point]))
        engine.stepForward()
        engine.stepBackward()
        XCTAssertEqual(engine.state.currentPointIndex, 0)
        XCTAssertEqual(engine.state.totalDuration, 0)
    }

    private func pausedWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            point(start: start, time: 0, distance: 0, segment: 0),
            point(start: start, time: 180, distance: 600, segment: 0),
            point(start: start, time: 3_180, distance: 600, segment: 1),
            point(start: start, time: 3_300, distance: 1_000, segment: 1)
        ]
        return RunWorkout(routePoints: points)
    }

    private func point(start: Date, time: Double, distance: Double, segment: Int) -> RoutePoint {
        RoutePoint(
            timestamp: start.addingTimeInterval(time),
            latitude: 1 + (distance / 100_000),
            longitude: 1,
            distanceFromStartMeters: distance,
            elapsedSeconds: time,
            paceSecondsPerKilometer: 300,
            routeSegmentIndex: segment
        )
    }

    private func recordedLap(
        index: Int,
        startTime: Double,
        endTime: Double,
        startDistance: Double,
        endDistance: Double
    ) -> RecordedLap {
        RecordedLap(
            lapIndex: index,
            source: .fit,
            trigger: .manual,
            startElapsedSeconds: startTime,
            endElapsedSeconds: endTime,
            startDistanceMeters: startDistance,
            endDistanceMeters: endDistance,
            elapsedSeconds: endTime - startTime,
            activeSeconds: endTime - startTime,
            movingSeconds: endTime - startTime
        )
    }
}
