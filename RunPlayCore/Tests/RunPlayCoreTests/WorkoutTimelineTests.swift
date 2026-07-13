import Foundation
import XCTest
@testable import RunPlayCore

final class WorkoutTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoPauseUsesSameElapsedAndActiveClock() {
        let timeline = WorkoutTimeline(routePoints: [
            point(time: 0, distance: 0),
            point(time: 10, distance: 100),
            point(time: 20, distance: 200)
        ])

        XCTAssertEqual(timeline.totalElapsedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(timeline.totalActiveSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(timeline.totalPausedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.activeElapsedSecondsByPoint, [0, 10, 20])
    }

    func testOnePauseExcludesOnlyCrossSegmentDelta() {
        let timeline = WorkoutTimeline(routePoints: pausedRoute())

        XCTAssertEqual(timeline.totalElapsedSeconds, 3_300, accuracy: 0.001)
        XCTAssertEqual(timeline.totalActiveSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(timeline.totalPausedSeconds, 3_000, accuracy: 0.001)
        XCTAssertEqual(timeline.activeElapsedSecondsByPoint, [0, 180, 180, 300])
    }

    func testMultiplePausesAccumulateActiveIntervals() {
        let timeline = WorkoutTimeline(routePoints: [
            point(time: 0, distance: 0, segment: 0),
            point(time: 10, distance: 100, segment: 0),
            point(time: 40, distance: 100, segment: 1),
            point(time: 50, distance: 200, segment: 1),
            point(time: 100, distance: 200, segment: 2),
            point(time: 110, distance: 300, segment: 2)
        ])

        XCTAssertEqual(timeline.totalElapsedSeconds, 110, accuracy: 0.001)
        XCTAssertEqual(timeline.totalActiveSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(timeline.totalPausedSeconds, 80, accuracy: 0.001)
    }

    func testZeroDurationSegmentBoundaryDoesNotCreatePauseTime() {
        let timeline = WorkoutTimeline(routePoints: [
            point(time: 0, distance: 0, segment: 0),
            point(time: 10, distance: 100, segment: 0),
            point(time: 10, distance: 100, segment: 1),
            point(time: 20, distance: 200, segment: 1)
        ])

        XCTAssertEqual(timeline.totalElapsedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(timeline.totalActiveSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(timeline.totalPausedSeconds, 0, accuracy: 0.001)
    }

    func testInvalidTimestampDeltaDoesNotFabricateActiveTime() {
        let invalidTimestamp = Date(timeIntervalSinceReferenceDate: .nan)
        let timeline = WorkoutTimeline(routePoints: [
            point(time: 0, distance: 0),
            RoutePoint(
                timestamp: invalidTimestamp,
                latitude: 1,
                longitude: 1,
                distanceFromStartMeters: 100,
                elapsedSeconds: 10
            ),
            point(time: 20, distance: 200)
        ])

        XCTAssertEqual(timeline.totalElapsedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(timeline.totalActiveSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.totalPausedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(
            timeline.replaySample(atElapsedTime: 10)?.activeSeconds ?? -1,
            0,
            accuracy: 0.001
        )
        XCTAssertTrue(timeline.totalPausedSeconds.isFinite)
    }

    func testDuplicateTimestampAddsNoActiveTime() {
        let timeline = WorkoutTimeline(routePoints: [
            point(time: 0, distance: 0),
            point(time: 0, distance: 10),
            point(time: 10, distance: 100)
        ])

        XCTAssertEqual(timeline.totalElapsedSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(timeline.totalActiveSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(timeline.replayPointIndex(atElapsedTime: -1), 0)
        XCTAssertEqual(timeline.replaySample(atElapsedTime: -1)?.pointIndex, 0)
        XCTAssertEqual(timeline.replayPointIndex(atElapsedTime: 0), 1)
    }

    func testEmptyAndOnePointRoutesAreSafe() {
        let empty = WorkoutTimeline(routePoints: [])
        XCTAssertEqual(empty.totalElapsedSeconds, 0)
        XCTAssertEqual(empty.totalActiveSeconds, 0)
        XCTAssertNil(empty.replaySample(atElapsedTime: 10))

        let single = WorkoutTimeline(routePoints: [point(time: 0, distance: 42)])
        XCTAssertEqual(single.totalElapsedSeconds, 0)
        XCTAssertEqual(single.totalActiveSeconds, 0)
        XCTAssertEqual(single.replaySample(atElapsedTime: 10)?.pointIndex, 0)
        XCTAssertEqual(single.distanceSample(at: 42, boundary: .rangeEnd)?.distanceMeters, 42)
    }

    func testDistanceSamplingExposesBothClocksAcrossPause() throws {
        let timeline = WorkoutTimeline(routePoints: pausedRoute())
        let sample = try XCTUnwrap(timeline.distanceSample(at: 800, boundary: .rangeEnd))

        XCTAssertEqual(sample.elapsedSeconds, 3_240, accuracy: 0.001)
        XCTAssertEqual(sample.activeSeconds, 240, accuracy: 0.001)

        let range = try XCTUnwrap(timeline.distanceRange(from: 0, to: 1_000))
        XCTAssertEqual(range.elapsedSeconds, 3_300, accuracy: 0.001)
        XCTAssertEqual(range.activeSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(range.pausedSeconds, 3_000, accuracy: 0.001)
    }

    func testDuplicateDistanceBoundaryUsesStopForEndAndResumeForStart() throws {
        let timeline = WorkoutTimeline(routePoints: pausedRoute())
        let end = try XCTUnwrap(timeline.distanceSample(at: 600, boundary: .rangeEnd))
        let start = try XCTUnwrap(timeline.distanceSample(at: 600, boundary: .rangeStart))

        XCTAssertEqual(end.pointIndex, 1)
        XCTAssertEqual(end.elapsedSeconds, 180, accuracy: 0.001)
        XCTAssertEqual(start.pointIndex, 2)
        XCTAssertEqual(start.elapsedSeconds, 3_180, accuracy: 0.001)
        XCTAssertEqual(end.activeSeconds, start.activeSeconds, accuracy: 0.001)
    }

    func testSameSegmentDistancePlateauIsNotDoubleCountedAcrossRanges() throws {
        let timeline = WorkoutTimeline(routePoints: [
            point(time: 0, distance: 0),
            point(time: 300, distance: 1_000),
            point(time: 400, distance: 1_000),
            point(time: 700, distance: 2_000)
        ])

        let first = try XCTUnwrap(timeline.distanceRange(from: 0, to: 1_000))
        let second = try XCTUnwrap(timeline.distanceRange(from: 1_000, to: 2_000))

        XCTAssertEqual(first.activeSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(second.activeSeconds, 400, accuracy: 0.001)
        XCTAssertEqual(first.activeSeconds + second.activeSeconds, timeline.totalActiveSeconds, accuracy: 0.001)
        XCTAssertEqual(first.elapsedSeconds + second.elapsedSeconds, timeline.totalElapsedSeconds, accuracy: 0.001)
    }

    func testTerminalSameSegmentDistancePlateauUsesFinalTimerSample() throws {
        let timeline = WorkoutTimeline(routePoints: [
            point(time: 0, distance: 0),
            point(time: 300, distance: 1_000),
            point(time: 400, distance: 1_000)
        ])

        let sample = try XCTUnwrap(timeline.distanceSample(at: 1_000, boundary: .rangeEnd))
        let range = try XCTUnwrap(timeline.distanceRange(from: 0, to: 1_000))

        XCTAssertEqual(sample.pointIndex, 2)
        XCTAssertEqual(sample.elapsedSeconds, timeline.totalElapsedSeconds, accuracy: 0.001)
        XCTAssertEqual(sample.activeSeconds, timeline.totalActiveSeconds, accuracy: 0.001)
        XCTAssertEqual(range.elapsedSeconds, 400, accuracy: 0.001)
        XCTAssertEqual(range.activeSeconds, 400, accuracy: 0.001)
    }

    func testReplayHoldsDuringGapAndJumpsAtExactResumeTime() throws {
        let timeline = WorkoutTimeline(routePoints: pausedRoute())
        let duringPause = try XCTUnwrap(timeline.replaySample(atElapsedTime: 1_500))

        XCTAssertEqual(duringPause.pointIndex, 1)
        XCTAssertEqual(duringPause.distanceMeters, 600, accuracy: 0.001)
        XCTAssertEqual(duringPause.elapsedSeconds, 1_500, accuracy: 0.001)
        XCTAssertEqual(duringPause.activeSeconds, 180, accuracy: 0.001)
        XCTAssertTrue(duringPause.isInRecordingGap)

        let resume = try XCTUnwrap(timeline.replaySample(atElapsedTime: 3_180))
        XCTAssertEqual(resume.pointIndex, 2)
        XCTAssertEqual(resume.activeSeconds, 180, accuracy: 0.001)
        XCTAssertFalse(resume.isInRecordingGap)
    }

    private func pausedRoute() -> [RoutePoint] {
        [
            point(time: 0, distance: 0, segment: 0),
            point(time: 180, distance: 600, segment: 0),
            point(time: 3_180, distance: 600, segment: 1),
            point(time: 3_300, distance: 1_000, segment: 1)
        ]
    }

    private func point(time: Double, distance: Double, segment: Int = 0) -> RoutePoint {
        RoutePoint(
            timestamp: start.addingTimeInterval(time),
            latitude: 1 + (distance / 100_000),
            longitude: 1,
            altitudeMeters: 10 + (distance / 100),
            distanceFromStartMeters: distance,
            elapsedSeconds: time,
            heartRateBPM: 120 + (distance / 100),
            routeSegmentIndex: segment
        )
    }
}
