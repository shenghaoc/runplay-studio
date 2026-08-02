import os
import XCTest
@testable import RunPlayStudio
import RunPlayCore
@testable import RunPlayPlatform

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

    func testDurationChangeReusesMapPreparationAlreadyInFlight() async throws {
        let preparer = GatedCountingVideoMapPreparer()
        let workout = sampleWorkout()
        let vm = WorkoutVideoExportViewModel(
            workout: workout,
            initialConfiguration: WorkoutVideoExportConfiguration(
                duration: .thirtySeconds,
                appearance: .light,
                routeColorMode: .solid
            ),
            analysisContext: WorkoutAnalysisContext(workout: workout),
            exporter: WorkoutVideoExporter(mapPreparer: preparer),
            policy: WorkoutVideoExportPolicy(
                width: 320,
                height: 180,
                framesPerSecond: 10,
                averageBitRate: 400_000,
                maximumFrameCount: 600
            ),
            posterPolicy: WorkoutVideoExportPolicy(
                width: 160,
                height: 90,
                framesPerSecond: 10,
                averageBitRate: 200_000,
                maximumFrameCount: 600
            )
        )

        vm.onAppear()
        await preparer.waitUntilStarted()
        XCTAssertEqual(preparer.prepareCount, 1)

        var updated = vm.configuration
        updated.duration = .fifteenSeconds
        vm.configuration = updated
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(preparer.prepareCount, 1)

        await preparer.release()
        try await waitUntil(timeout: 5) { vm.canExport }
        XCTAssertEqual(preparer.prepareCount, 1)
        XCTAssertEqual(vm.configuration.duration, .fifteenSeconds)
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
        XCTAssertEqual(vm.phase, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testEligibilityOnMenuGate() {
        XCTAssertTrue(WorkoutVideoExportEligibility.canExportVideo(sampleWorkout()))
        XCTAssertFalse(WorkoutVideoExportEligibility.canExportVideo(RunWorkout(routePoints: [])))
    }

    func testExportFailureCanRetryAndCompletionProgressCannotRaceFilename() async throws {
        let attempts = AttemptCounter()
        let recorder = RecordingAccessibilityAnnouncer()
        let client = TestVideoExportClient { url, progress in
            let attempt = await attempts.next()
            if attempt == 1 {
                throw WorkoutVideoExportError.finalizationFailed(
                    "/private/tmp/runplay-video-secret.mp4"
                )
            }
            // A client that reports completion before returning must not make
            // the sheet observe completion before the result filename exists.
            await progress(WorkoutVideoExportProgress(
                phase: .completed,
                completedFrames: 150,
                totalFrames: 150
            ))
            return Self.fakeResult(url: url)
        }
        let vm = makeViewModel(
            workout: sampleWorkout(),
            exporter: client,
            announcementPolicy: AccessibilityAnnouncementPolicy(announcer: recorder)
        )
        vm.onAppear()
        try await waitUntil(timeout: 5) { vm.canExport }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-retry-\(UUID().uuidString).mp4")
        await vm.export(to: destination)
        XCTAssertEqual(vm.phase, .failed)
        XCTAssertTrue(vm.canExport)
        XCTAssertFalse(vm.errorMessage?.contains("/private/tmp") ?? true)

        await vm.export(to: destination)
        XCTAssertEqual(vm.phase, .completed)
        XCTAssertEqual(vm.lastExportedFilename, destination.lastPathComponent)
        XCTAssertEqual(
            recorder.messages.filter { $0.hasPrefix("Video exported ") }.count,
            1
        )
    }

    func testCancellationStaysBusyUntilExporterCleanupAcknowledges() async throws {
        let gate = ExportCleanupGate()
        let client = TestVideoExportClient { _, progress in
            await progress(WorkoutVideoExportProgress(
                phase: .encoding,
                completedFrames: 1,
                totalFrames: 150
            ))
            await gate.markStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // Hold the task until deterministic cleanup is released.
            }
            await gate.waitForCleanupRelease()
            throw WorkoutVideoExportError.cancelled
        }
        let vm = makeViewModel(workout: sampleWorkout(), exporter: client)
        vm.onAppear()
        try await waitUntil(timeout: 5) { vm.canExport }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-cancel-\(UUID().uuidString).mp4")
        let export = Task { await vm.export(to: destination) }
        await gate.waitUntilStarted()
        vm.cancelExport()

        XCTAssertTrue(vm.isExporting)
        XCTAssertTrue(vm.isCancelling)
        XCTAssertFalse(vm.canExport)
        XCTAssertEqual(vm.phase, .cancelling)

        await gate.releaseCleanup()
        await export.value
        XCTAssertFalse(vm.isExporting)
        XCTAssertFalse(vm.isCancelling)
        XCTAssertEqual(vm.phase, .cancelled)
        XCTAssertTrue(vm.canExport)
    }

    func testUnavailableInitialRouteColorNormalizesToSolidTruthfully() async throws {
        let sparse = sampleWorkout(includeHeartRate: false)
        let vm = WorkoutVideoExportViewModel(
            workout: sparse,
            initialConfiguration: WorkoutVideoExportConfiguration(
                duration: .fifteenSeconds,
                appearance: .light,
                routeColorMode: .heartRate
            ),
            analysisContext: WorkoutAnalysisContext(workout: sparse),
            exporter: TestVideoExportClient.succeeding
        )
        vm.onAppear()
        await vm.updateAvailabilityProbe()
        try await waitUntil(timeout: 5) { !vm.isPreparingPoster }

        XCTAssertEqual(vm.configuration.routeColorMode, .solid)
        XCTAssertTrue(vm.posterAccessibilityLabel.contains("Solid route color"))
        XCTAssertFalse(vm.isModeAvailable(.heartRate))
    }

    func testPosterFailureCanRetry() async throws {
        let client = TestVideoExportClient(posterFailuresBeforeSuccess: 1) { url, _ in
            Self.fakeResult(url: url)
        }
        let vm = makeViewModel(workout: sampleWorkout(), exporter: client)

        vm.onAppear()
        try await waitUntil(timeout: 5) { vm.canRetryPreview }

        XCTAssertEqual(vm.phase, .failed)
        XCTAssertNil(vm.posterImage)
        XCTAssertFalse(vm.canExport)

        vm.retryPreview()
        try await waitUntil(timeout: 5) { vm.canExport }

        XCTAssertEqual(vm.phase, .awaitingDestination)
        XCTAssertNotNil(vm.posterImage)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isPreviewFailure)
    }

    // MARK: - Helpers

    private func sampleWorkout(includeHeartRate: Bool = true) -> RunWorkout {
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
                    heartRateBPM: includeHeartRate ? 138 : nil
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

    private func makeViewModel(
        workout: RunWorkout,
        exporter: any WorkoutVideoExportClient,
        announcementPolicy: AccessibilityAnnouncementPolicy = AccessibilityAnnouncementPolicy()
    ) -> WorkoutVideoExportViewModel {
        WorkoutVideoExportViewModel(
            workout: workout,
            initialConfiguration: WorkoutVideoExportConfiguration(
                duration: .fifteenSeconds,
                appearance: .light,
                routeColorMode: .solid
            ),
            analysisContext: WorkoutAnalysisContext(workout: workout),
            exporter: exporter,
            announcementPolicy: announcementPolicy,
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
    }

    nonisolated private static func fakeResult(url: URL) -> WorkoutVideoExportResult {
        WorkoutVideoExportResult(
            url: url,
            filename: url.lastPathComponent,
            fileSizeBytes: 1,
            outputDurationSeconds: 15,
            frameCount: 150,
            width: 320,
            height: 180,
            framesPerSecond: 10
        )
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

private final class GatedCountingVideoMapPreparer: WorkoutVideoMapPreparing, @unchecked Sendable {
    private let countBox = OSAllocatedUnfairLock(initialState: 0)
    private let gate = MapPreparationGate()
    private let base = SyntheticWorkoutVideoMapPreparer()

    var prepareCount: Int {
        countBox.withLock { $0 }
    }

    func prepare(
        request: WorkoutVideoMapPreparationRequest
    ) async throws -> WorkoutVideoMapPreparation {
        countBox.withLock { $0 += 1 }
        await gate.markStarted()
        await gate.waitForRelease()
        try Task.checkCancellation()
        return try await base.prepare(request: request)
    }

    func waitUntilStarted() async {
        await gate.waitUntilStarted()
    }

    func release() async {
        await gate.release()
    }
}

private actor MapPreparationGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private struct TestVideoExportClient: WorkoutVideoExportClient, Sendable {
    typealias ExportOperation = @Sendable (
        URL,
        @Sendable (WorkoutVideoExportProgress) async -> Void
    ) async throws -> WorkoutVideoExportResult

    private let base = WorkoutVideoExporter(
        mapPreparer: SyntheticWorkoutVideoMapPreparer()
    )
    private let posterFailureCounter: PosterFailureCounter
    private let operation: ExportOperation

    init(
        posterFailuresBeforeSuccess: Int = 0,
        operation: @escaping ExportOperation
    ) {
        self.posterFailureCounter = PosterFailureCounter(
            failuresRemaining: posterFailuresBeforeSuccess
        )
        self.operation = operation
    }

    static let succeeding = TestVideoExportClient { url, _ in
        WorkoutVideoExportResult(
            url: url,
            filename: url.lastPathComponent,
            fileSizeBytes: 1,
            outputDurationSeconds: 15,
            frameCount: 150,
            width: 320,
            height: 180,
            framesPerSecond: 10
        )
    }

    func prepareMap(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        policy: WorkoutVideoExportPolicy,
        analysisContext: WorkoutAnalysisContext?,
        profileProbe: RouteMetricProfileProbe?
    ) async throws -> WorkoutVideoMapPreparation {
        try await base.prepareMap(
            workout: workout,
            configuration: configuration,
            policy: policy,
            analysisContext: analysisContext,
            profileProbe: profileProbe
        )
    }

    func renderPosterResult(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        mapPreparation: WorkoutVideoMapPreparation,
        policy: WorkoutVideoExportPolicy,
        analysisContext: WorkoutAnalysisContext?
    ) throws -> WorkoutVideoPoster {
        if posterFailureCounter.consumeFailure() {
            throw WorkoutVideoExportError.frameRenderingFailed("Poster test failure")
        }
        return try base.renderPosterResult(
            workout: workout,
            configuration: configuration,
            mapPreparation: mapPreparation,
            policy: policy,
            analysisContext: analysisContext
        )
    }

    func export(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy,
        mapPreparation: WorkoutVideoMapPreparation?,
        analysisContext: WorkoutAnalysisContext?,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void
    ) async throws -> WorkoutVideoExportResult {
        try await operation(destinationURL, progress)
    }
}

private final class PosterFailureCounter: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<Int>

    init(failuresRemaining: Int) {
        state = OSAllocatedUnfairLock(initialState: failuresRemaining)
    }

    func consumeFailure() -> Bool {
        state.withLock { remaining in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}

private actor AttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private actor ExportCleanupGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForCleanupRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            cleanupWaiters.append(continuation)
        }
    }

    func releaseCleanup() {
        released = true
        cleanupWaiters.forEach { $0.resume() }
        cleanupWaiters.removeAll()
    }
}
