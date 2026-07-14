import Foundation
import XCTest
@testable import RunPlayCore

final class MovementProfileTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Moving-only workout

    func testAllMovingWorkoutProducesNoStoppedTime() throws {
        let points = (0..<10).map { i in
            point(time: Double(i) * 10, distance: Double(i) * 30, lat: 1 + Double(i) * 0.001, lon: 1)
        }
        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline)

        XCTAssertEqual(profile.totalMovingSeconds, timeline.totalActiveSeconds, accuracy: 0.001)
        XCTAssertEqual(profile.totalStoppedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(profile.states.filter { $0 == .moving }.count, points.count - 1)
        XCTAssertEqual(profile.states.filter { $0 == .stopped }.count, 0)
    }

    // MARK: - Clear stop

    func testStationaryPointsProduceStop() throws {
        let policy = MovementDetectionPolicy.runningDefault
        // Moving for 5 intervals, then stationary for 10 seconds
        var points: [RoutePoint] = []
        // 5 moving points (1s apart, 111m displacement per step = clearly moving)
        for i in 0..<5 {
            points.append(point(time: Double(i), distance: Double(i) * 3, lat: 1 + Double(i) * 0.001, lon: 1))
        }
        // 10 stationary points (same location, same distance, 1 second apart)
        let lastDistance = points.last!.distanceFromStartMeters
        let lastLat = points.last!.latitude
        for i in 0..<10 {
            points.append(point(time: Double(5 + i), distance: lastDistance, lat: lastLat, lon: 1))
        }

        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline, policy: policy)

        XCTAssertGreaterThan(profile.totalStoppedSeconds, 0)
        XCTAssertGreaterThanOrEqual(profile.totalStoppedSeconds, policy.minimumStopDurationSeconds - 0.001)
        XCTAssertLessThan(profile.totalMovingSeconds, timeline.totalActiveSeconds)
        XCTAssertTrue(profile.diagnostics.analysedPointPairCount > 0)
    }

    // MARK: - Stop and resume

    func testStopFollowedByResume() throws {
        let policy = MovementDetectionPolicy.runningDefault
        var points: [RoutePoint] = []
        // Moving at ~111m displacement per step
        for i in 0..<5 {
            points.append(point(time: Double(i), distance: Double(i) * 3, lat: 1 + Double(i) * 0.001, lon: 1))
        }
        // Stopped (10s dwell at same position)
        let stoppedAt = points.last!
        for i in 0..<10 {
            points.append(point(
                time: Double(5 + i),
                distance: stoppedAt.distanceFromStartMeters,
                lat: stoppedAt.latitude,
                lon: stoppedAt.longitude
            ))
        }
        // Resume moving at ~111m displacement per step
        let resumeBase = points.last!
        let resumeLat = resumeBase.latitude
        let resumeDist = resumeBase.distanceFromStartMeters
        for i in 0..<5 {
            points.append(point(
                time: Double(15 + i),
                distance: resumeDist + Double(i + 1) * 3,
                lat: resumeLat + Double(i + 1) * 0.001,
                lon: 1
            ))
        }

        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline, policy: policy)

        XCTAssertGreaterThan(profile.totalStoppedSeconds, 0)
        XCTAssertGreaterThan(profile.totalMovingSeconds, 0)
        XCTAssertEqual(
            profile.totalMovingSeconds + profile.totalStoppedSeconds,
            timeline.totalActiveSeconds,
            accuracy: 0.001
        )
    }

    // MARK: - Short blips (hysteresis)

    func testShortBlipDoesNotTriggerFalseStop() throws {
        let policy = MovementDetectionPolicy.runningDefault
        // Single stationary point between moving points (< minimumStopDurationSeconds)
        var points: [RoutePoint] = []
        // Moving at ~111m displacement per step
        for i in 0..<5 {
            points.append(point(time: Double(i), distance: Double(i) * 3, lat: 1 + Double(i) * 0.001, lon: 1))
        }
        // One short stationary blip (1 second at same position)
        let last = points.last!
        points.append(point(time: 5, distance: last.distanceFromStartMeters, lat: last.latitude, lon: last.longitude))
        // Resume immediately
        for i in 0..<5 {
            points.append(point(
                time: Double(6 + i),
                distance: last.distanceFromStartMeters + Double(i + 1) * 3,
                lat: last.latitude + Double(i + 1) * 0.001,
                lon: 1
            ))
        }

        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline, policy: policy)

        // Should not trigger a stop (below minimumStopDurationSeconds)
        XCTAssertEqual(profile.totalStoppedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(profile.totalMovingSeconds, timeline.totalActiveSeconds, accuracy: 0.001)
    }

    // MARK: - Pause handling

    func testSegmentBoundariesArePausedNotStopped() throws {
        var points: [RoutePoint] = []
        // Segment 0: moving
        for i in 0..<5 {
            points.append(point(
                time: Double(i), distance: Double(i) * 3, lat: 1 + Double(i) * 0.001, lon: 1, segment: 0
            ))
        }
        // Segment 1 (gap): no points for 300 seconds, then resume at different location (not a stop)
        let last = points.last!
        points.append(point(
            time: 305, distance: last.distanceFromStartMeters, lat: last.latitude, lon: last.longitude, segment: 1
        ))
        for i in 1..<5 {
            points.append(point(
                time: Double(305 + i), distance: last.distanceFromStartMeters + Double(i) * 3,
                lat: last.latitude + Double(i) * 0.001, lon: 1, segment: 1
            ))
        }

        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline)

        // Segment boundary should be .paused, not .stopped
        let pausedCount = profile.states.filter { $0 == .paused }.count
        XCTAssertGreaterThanOrEqual(pausedCount, 1)
        // Active time should be much less than elapsed (gap excluded)
        XCTAssertLessThan(timeline.totalActiveSeconds, timeline.totalElapsedSeconds)
        // Stopped time should be zero (no intra-segment stops)
        XCTAssertEqual(profile.totalStoppedSeconds, 0, accuracy: 0.001)
        // Moving = active = all intra-segment time
        XCTAssertEqual(profile.totalMovingSeconds, timeline.totalActiveSeconds, accuracy: 0.001)
    }

    // MARK: - Empty / single point

    func testEmptyRouteReturnsEmptyProfile() throws {
        let timeline = WorkoutTimeline(routePoints: [])
        let profile = try MovementProfile(routePoints: [], timeline: timeline)

        XCTAssertEqual(profile.totalMovingSeconds, 0)
        XCTAssertEqual(profile.totalStoppedSeconds, 0)
        XCTAssertTrue(profile.states.isEmpty)
        XCTAssertTrue(profile.diagnostics.usedConservativeFallback)
    }

    func testSinglePointReturnsEmptyProfile() throws {
        let points = [point(time: 0, distance: 0, lat: 1, lon: 1)]
        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline)

        XCTAssertEqual(profile.totalMovingSeconds, 0)
        XCTAssertEqual(profile.totalStoppedSeconds, 0)
        XCTAssertTrue(profile.states.isEmpty)
    }

    // MARK: - Cumulative arrays

    func testCumulativeArraysAreMonotonic() throws {
        var points: [RoutePoint] = []
        for i in 0..<10 {
            points.append(point(time: Double(i), distance: Double(i) * 3, lat: 1 + Double(i) * 0.001, lon: 1))
        }
        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline)

        // Moving cumulative should be monotonically non-decreasing
        for i in 1..<profile.movingSecondsByPoint.count {
            XCTAssertGreaterThanOrEqual(
                profile.movingSecondsByPoint[i],
                profile.movingSecondsByPoint[i - 1]
            )
        }
        // Stopped cumulative should be monotonically non-decreasing
        for i in 1..<profile.stoppedSecondsByPoint.count {
            XCTAssertGreaterThanOrEqual(
                profile.stoppedSecondsByPoint[i],
                profile.stoppedSecondsByPoint[i - 1]
            )
        }
        // Final cumulative should equal total
        XCTAssertEqual(
            profile.movingSecondsByPoint.last ?? 0,
            profile.totalMovingSeconds,
            accuracy: 0.001
        )
    }

    // MARK: - Distance range queries

    func testMovingSecondsInDistanceRange() throws {
        var points: [RoutePoint] = []
        for i in 0..<10 {
            points.append(point(time: Double(i), distance: Double(i) * 10, lat: 1 + Double(i) * 0.001, lon: 1))
        }
        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline)

        let midMoving = profile.movingSeconds(from: 0, to: 50, timeline: timeline)
        XCTAssertNotNil(midMoving)
        XCTAssertGreaterThan(midMoving!, 0)
        XCTAssertLessThan(midMoving!, profile.totalMovingSeconds)
    }

    // MARK: - Diagnostics

    func testDiagnosticsArePopulated() throws {
        var points: [RoutePoint] = []
        // Use 5s intervals so they fall in the reliable window (2-30s)
        for i in 0..<20 {
            points.append(point(time: Double(i) * 5, distance: Double(i) * 15, lat: 1 + Double(i) * 0.001, lon: 1))
        }
        let timeline = WorkoutTimeline(routePoints: points)
        let profile = try MovementProfile(routePoints: points, timeline: timeline)

        XCTAssertEqual(profile.diagnostics.analysedPointPairCount, points.count - 1)
        XCTAssertEqual(profile.diagnostics.policyVersion, MovementDetectionPolicy.currentVersion)
        XCTAssertGreaterThan(profile.diagnostics.reliableIntervalCount, 0)
    }

    // MARK: - Helpers

    private func point(
        time: Double, distance: Double, lat: Double, lon: Double, segment: Int = 0
    ) -> RoutePoint {
        RoutePoint(
            timestamp: start.addingTimeInterval(time),
            latitude: lat,
            longitude: lon,
            altitudeMeters: 10,
            distanceFromStartMeters: distance,
            elapsedSeconds: time,
            heartRateBPM: 120,
            routeSegmentIndex: segment
        )
    }
}
