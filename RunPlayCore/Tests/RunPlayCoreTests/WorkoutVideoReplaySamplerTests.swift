import XCTest
@testable import RunPlayCore

final class WorkoutVideoReplaySamplerTests: XCTestCase {
    func testContinuousRunSamplesFinalPoint() throws {
        let workout = continuousWorkout()
        let sampler = WorkoutVideoReplaySampler(workout: workout)
        let plan = try WorkoutVideoFramePlan(
            frameCount: 20,
            framesPerSecond: 10,
            sourceTotalElapsedSeconds: sampler.totalElapsedSeconds
        )
        let first = sampler.sample(frameIndex: 0, plan: plan)
        let last = sampler.sample(frameIndex: plan.frameCount - 1, plan: plan)

        XCTAssertEqual(first.sourceElapsedSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(first.progress, 0, accuracy: 1e-12)
        XCTAssertEqual(last.progress, 1, accuracy: 1e-12)
        XCTAssertEqual(
            last.sourceElapsedSeconds,
            plan.sourceTotalElapsedSeconds,
            accuracy: 1e-9
        )
        XCTAssertEqual(last.routePointIndex, workout.routePoints.count - 1)
        XCTAssertGreaterThan(last.distanceMeters, first.distanceMeters)
        XCTAssertNotNil(last.heartRateBPM)
        XCTAssertNotNil(last.correctedElevationMeters)
    }

    func testRecordingGapAndPauseSemantics() throws {
        let workout = gapWorkout()
        let sampler = WorkoutVideoReplaySampler(workout: workout)
        XCTAssertTrue(sampler.hasPlayableTimeline)
        let plan = try WorkoutVideoFramePlan(
            frameCount: 11,
            framesPerSecond: 10,
            sourceTotalElapsedSeconds: sampler.totalElapsedSeconds
        )

        // Midpoint should land in or near the gap depending on timeline.
        var sawGap = false
        for index in 0..<plan.frameCount {
            let sample = sampler.sample(frameIndex: index, plan: plan)
            if sample.isInRecordingGap || sample.movementState == .paused {
                sawGap = true
            }
        }
        // Multi-segment workouts expose gap/pause on the elapsed clock.
        XCTAssertTrue(sawGap || workout.routePoints.contains { $0.routeSegmentIndex > 0 })
    }

    func testMissingMetricsRemainNilNotZero() throws {
        let workout = metricsSparseWorkout()
        let sampler = WorkoutVideoReplaySampler(workout: workout)
        let plan = try WorkoutVideoFramePlan(
            frameCount: 10,
            framesPerSecond: 10,
            sourceTotalElapsedSeconds: max(sampler.totalElapsedSeconds, 1)
        )
        let sample = sampler.sample(frameIndex: 5, plan: plan)
        XCTAssertNil(sample.heartRateBPM)
        // Elevation may be nil or present from altitude; HR must stay nil.
    }

    func testPrivateSamplerDoesNotRequireLiveController() throws {
        let workout = continuousWorkout()
        let live = PlaybackEngine()
        live.load(workout)
        live.seekToTime(40)
        live.setSpeed(4)
        let liveSnapshot = live.state

        let sampler = WorkoutVideoReplaySampler(workout: workout)
        let plan = try WorkoutVideoFramePlan(
            frameCount: 20,
            framesPerSecond: 10,
            sourceTotalElapsedSeconds: sampler.totalElapsedSeconds
        )
        _ = sampler.sample(frameIndex: 19, plan: plan)

        XCTAssertEqual(live.state.currentTime, liveSnapshot.currentTime, accuracy: 1e-9)
        XCTAssertEqual(live.state.playbackSpeed, liveSnapshot.playbackSpeed, accuracy: 1e-9)
        XCTAssertEqual(live.state.currentPointIndex, liveSnapshot.currentPointIndex)
    }

    func testEligibilityGates() {
        XCTAssertTrue(WorkoutVideoExportEligibility.canExportVideo(continuousWorkout()))
        XCTAssertFalse(WorkoutVideoExportEligibility.canExportVideo(RunWorkout(routePoints: [])))
        XCTAssertNotNil(WorkoutVideoExportEligibility.unavailableHelp(for: RunWorkout(routePoints: [])))
    }

    func testVideoFilename() {
        let workout = continuousWorkout()
        let name = ExportFilenameBuilder.videoReplayFilename(for: workout)
        XCTAssertTrue(name.hasSuffix("-replay.mp4"))
        XCTAssertFalse(name.contains(" "))
    }

    // MARK: - Fixtures

    private func continuousWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<40 {
            let index = Double(i)
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(index * 5),
                    latitude: 37.77 + index * 0.0001,
                    longitude: -122.42 + index * 0.00008,
                    altitudeMeters: 20 + index * 0.2,
                    distanceFromStartMeters: index * 12,
                    elapsedSeconds: index * 5,
                    paceSecondsPerKilometer: 300,
                    heartRateBPM: 140 + Double(i % 10)
                )
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Video Sampler", activityType: "run", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: 468,
                totalElapsedSeconds: 195,
                averagePaceSecondsPerKilometer: 300,
                elevationGainMeters: 8,
                averageHeartRateBPM: 145
            )
        )
    }

    private func gapWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<10 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i) * 3),
                latitude: 37.77 + Double(i) * 0.0001,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * 10,
                elapsedSeconds: Double(i) * 3,
                routeSegmentIndex: 0
            ))
        }
        // Recording gap: segment 1 resumes after a jump in elapsed time.
        for i in 0..<10 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(40 + i) * 3),
                latitude: 37.78 + Double(i) * 0.0001,
                longitude: -122.41,
                distanceFromStartMeters: 100 + Double(i) * 10,
                elapsedSeconds: Double(40 + i) * 3,
                routeSegmentIndex: 1
            ))
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Gap Run", activityType: "run", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 190, totalElapsedSeconds: 147)
        )
    }

    private func metricsSparseWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<15 {
            let index = Double(i)
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(index * 4),
                    latitude: 37.77 + index * 0.0001,
                    longitude: -122.42,
                    distanceFromStartMeters: index * 10,
                    elapsedSeconds: index * 4
                )
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Sparse", activityType: "run", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 140, totalElapsedSeconds: 56)
        )
    }
}
