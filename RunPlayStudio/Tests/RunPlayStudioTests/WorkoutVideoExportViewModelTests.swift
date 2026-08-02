import os
import XCTest
@testable import RunPlayStudio
import RunPlayCore
import RunPlayPlatform

@MainActor
final class WorkoutVideoExportViewModelTests: XCTestCase {
    func testInitialConfigurationAndFilename() {
        let workout = sampleWorkout()
        let vm = WorkoutVideoExportViewModel(
            workout: workout,
            initialConfiguration: WorkoutVideoExportConfiguration(
                duration: .thirtySeconds,
                appearance: .dark,
                routeColorMode: .solid
            ),
            exporter: WorkoutVideoExporter(mapPreparer: SyntheticWorkoutVideoMapPreparer())
        )
        XCTAssertEqual(vm.configuration.duration, .thirtySeconds)
        XCTAssertEqual(vm.configuration.appearance, .dark)
        XCTAssertTrue(vm.defaultFilename().hasSuffix("-replay.mp4"))
    }

    func testDurationChangeDoesNotDropCachedMapAfterPrepare() async throws {
        let exporter = WorkoutVideoExporter(mapPreparer: CountingVideoMapPreparer())
        let counting = exporter // preparer is inside
        _ = counting

        let preparer = CountingVideoMapPreparer()
        let smallPolicy = WorkoutVideoExportPolicy(
            width: 320,
            height: 180,
            framesPerSecond: 10,
            averageBitRate: 400_000,
            maximumFrameCount: 900
        )
        let posterPolicy = WorkoutVideoExportPolicy(
            width: 160,
            height: 90,
            framesPerSecond: 10,
            averageBitRate: 200_000,
            maximumFrameCount: 900
        )
        let vm = WorkoutVideoExportViewModel(
            workout: sampleWorkout(),
            initialConfiguration: WorkoutVideoExportConfiguration(
                duration: .thirtySeconds,
                appearance: .light,
                routeColorMode: .solid
            ),
            exporter: WorkoutVideoExporter(mapPreparer: preparer),
            policy: smallPolicy,
            posterPolicy: posterPolicy
        )

        vm.onAppear()
        try await waitUntil(timeout: 5) { vm.posterImage != nil || vm.mapFailureMessage != nil }
        XCTAssertNotNil(vm.posterImage, "Poster should be ready before duration change")
        let preparesAfterFirst = preparer.prepareCount
        XCTAssertGreaterThanOrEqual(preparesAfterFirst, 1)

        // Assign whole configuration so Observable didSet fires reliably.
        var updated = vm.configuration
        updated.duration = .fifteenSeconds
        vm.configuration = updated
        try await waitUntil(timeout: 5) { !vm.isPreparingPoster }
        XCTAssertEqual(preparer.prepareCount, preparesAfterFirst)
        XCTAssertNotNil(vm.posterImage)
    }

    func testAppearanceChangeRequestsNewMap() async throws {
        let preparer = CountingVideoMapPreparer()
        let vm = WorkoutVideoExportViewModel(
            workout: sampleWorkout(),
            initialConfiguration: WorkoutVideoExportConfiguration(
                duration: .fifteenSeconds,
                appearance: .light,
                routeColorMode: .solid
            ),
            exporter: WorkoutVideoExporter(mapPreparer: preparer),
            policy: WorkoutVideoExportPolicy(
                width: 320,
                height: 180,
                framesPerSecond: 10,
                averageBitRate: 400_000,
                maximumFrameCount: 200
            ),
            posterPolicy: WorkoutVideoExportPolicy(
                width: 160,
                height: 90,
                framesPerSecond: 10,
                averageBitRate: 200_000,
                maximumFrameCount: 200
            )
        )
        vm.onAppear()
        try await waitUntil(timeout: 5) { vm.posterImage != nil || vm.phase == .failed }
        let first = preparer.prepareCount
        var updated = vm.configuration
        updated.appearance = .dark
        vm.configuration = updated
        try await waitUntil(timeout: 5) {
            preparer.prepareCount > first || vm.mapFailureMessage != nil
        }
        XCTAssertGreaterThan(preparer.prepareCount, first)
    }

    func testExportDoesNotMutateLiveReplayController() async throws {
        let workout = sampleWorkout()
        let live = ReplayController()
        live.load(workout)
        live.seekToTime(20)
        live.setSpeed(2)
        let before = live.state

        let preparer = SyntheticWorkoutVideoMapPreparer()
        let vm = WorkoutVideoExportViewModel(
            workout: workout,
            initialConfiguration: WorkoutVideoExportConfiguration(
                duration: .fifteenSeconds,
                appearance: .light,
                routeColorMode: .solid
            ),
            exporter: WorkoutVideoExporter(mapPreparer: preparer),
            policy: WorkoutVideoExportPolicy(
                width: 320,
                height: 180,
                framesPerSecond: 10,
                averageBitRate: 400_000,
                maximumFrameCount: 200
            ),
            posterPolicy: WorkoutVideoExportPolicy(
                width: 160,
                height: 90,
                framesPerSecond: 10,
                averageBitRate: 200_000,
                maximumFrameCount: 200
            )
        )
        vm.onAppear()
        try await waitUntil(timeout: 5) { vm.posterImage != nil }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        await vm.export(to: destination)

        XCTAssertEqual(live.state.currentTime, before.currentTime, accuracy: 1e-9)
        XCTAssertEqual(live.state.playbackSpeed, before.playbackSpeed, accuracy: 1e-9)
        XCTAssertEqual(live.state.currentPointIndex, before.currentPointIndex)
        if vm.phase == .completed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testEligibilityOnMenuGate() {
        XCTAssertTrue(WorkoutVideoExportEligibility.canExportVideo(sampleWorkout()))
        XCTAssertFalse(WorkoutVideoExportEligibility.canExportVideo(RunWorkout(routePoints: [])))
    }

    // MARK: - Helpers

    private func sampleWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<25 {
            let index = Double(i)
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(index * 4),
                    latitude: 37.77 + index * 0.0001,
                    longitude: -122.42 + index * 0.00008,
                    altitudeMeters: 12 + index,
                    distanceFromStartMeters: index * 12,
                    elapsedSeconds: index * 4,
                    paceSecondsPerKilometer: 300,
                    heartRateBPM: 138
                )
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "VM Video", activityType: "run", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 288, totalElapsedSeconds: 96)
        )
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

/// Counts MapKit/map preparation calls for duration-vs-appearance tests.
private final class CountingVideoMapPreparer: WorkoutVideoMapPreparing, @unchecked Sendable {
    private let countBox = OSAllocatedUnfairLock(initialState: 0)
    private let base = SyntheticWorkoutVideoMapPreparer()

    var prepareCount: Int {
        countBox.withLock { $0 }
    }

    func prepare(
        request: WorkoutVideoMapPreparationRequest
    ) async throws -> WorkoutVideoMapPreparation {
        countBox.withLock { $0 += 1 }
        return try await base.prepare(request: request)
    }
}
