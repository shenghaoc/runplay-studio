import AppKit
import XCTest
@testable import RunPlayStudio
import RunPlayCore
import RunPlayPlatform

@MainActor
final class PNGSummaryExportViewModelTests: XCTestCase {
    func testInitialConfigurationRespectsNoRoute() async {
        let workout = noGPSWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: FailingMapSnapshotter()
        )
        XCTAssertFalse(vm.hasUsableRoute)
        XCTAssertFalse(vm.configuration.includeMap)
    }

    func testMetricsOnlyPreviewSucceeds() async throws {
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: false,
                appearance: .dark,
                routeColorMode: .solid
            ),
            mapSnapshotter: FailingMapSnapshotter()
        )
        vm.onAppear()
        await waitForReady(vm)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertNotNil(vm.previewData)
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: try XCTUnwrap(vm.previewData)))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
    }

    func testMapInclusivePreviewUsesFakeSnapshotter() async throws {
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: BlankMapSnapshotter()
        )
        vm.onAppear()
        await waitForReady(vm)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertNotNil(vm.previewData)
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: try XCTUnwrap(vm.previewData)))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
    }

    func testMapFailureExposesRetryAndExportWithoutMap() async {
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: FailingMapSnapshotter()
        )
        vm.onAppear()
        await waitForPhase(vm) { $0.phase == .failed || $0.mapFailureMessage != nil }
        XCTAssertNotNil(vm.mapFailureMessage)

        vm.exportWithoutMap()
        await waitForReady(vm)
        XCTAssertFalse(vm.configuration.includeMap)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertNotNil(vm.previewData)
    }

    func testRetryAfterMapFailure() async {
        let counter = SnapshotCallCounter()
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: CountingFailThenSucceedSnapshotter(counter: counter)
        )
        vm.onAppear()
        await waitForPhase(vm) { $0.mapFailureMessage != nil }
        XCTAssertEqual(counter.calls, 1)
        vm.retry()
        await waitForReady(vm)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertGreaterThanOrEqual(counter.calls, 2)
    }

    func testRapidConfigurationChangesOnlyLatestPublishes() async {
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: false,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: BlankMapSnapshotter()
        )
        vm.onAppear()
        await waitForReady(vm)
        vm.configuration.appearance = .dark
        vm.configuration.appearance = .light
        vm.configuration.appearance = .dark
        await waitForReady(vm)
        XCTAssertEqual(vm.configuration.appearance, .dark)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertNotNil(vm.previewData)
    }

    func testCancellationDoesNotSurfaceAsError() async {
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: SlowMapSnapshotter()
        )
        vm.onAppear()
        // Let generation start then cancel.
        try? await Task.sleep(nanoseconds: 20_000_000)
        vm.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNotEqual(vm.phase, .failed)
    }

    func testCancelPropagatesIntoDetachedRoutePreparation() async {
        let recorder = CancellationProbeRecorder()
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: BlankMapSnapshotter(),
            profileBuilder: CancellationObservingProfileBuilder(recorder: recorder)
        )

        vm.onAppear()
        let started = await waitForCondition { recorder.started }
        XCTAssertTrue(started)

        vm.cancel()
        let observedCancellation = await waitForCondition { recorder.observedCancellation }
        XCTAssertTrue(observedCancellation)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNotEqual(vm.phase, .failed)
    }

    func testAvailabilityProbeCancellationPropagatesIntoDetachedTask() async {
        let recorder = CancellationProbeRecorder()
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: BlankMapSnapshotter(),
            profileBuilder: CancellationObservingProfileBuilder(recorder: recorder)
        )

        let probeTask = Task { await vm.updateAvailabilityProbe() }
        let started = await waitForCondition { recorder.started }
        XCTAssertTrue(started)

        probeTask.cancel()
        await probeTask.value
        let observedCancellation = await waitForCondition { recorder.observedCancellation }
        XCTAssertTrue(observedCancellation)
    }

    func testSaveReusesReadyPreview() async throws {
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: false,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: BlankMapSnapshotter()
        )
        vm.onAppear()
        await waitForReady(vm)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runplay-png-export-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await vm.save(to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: data))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
        XCTAssertEqual(vm.phase, .ready)
    }

    func testPreviewAccessibilityLabelIncludesKeyOptions() async {
        let workout = sampleRouteWorkout()
        let vm = PNGSummaryExportViewModel(
            workout: workout,
            segments: [],
            initialConfiguration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .dark,
                routeColorMode: .pace
            ),
            mapSnapshotter: BlankMapSnapshotter()
        )
        let label = vm.previewAccessibilityLabel()
        XCTAssertTrue(label.contains("Dark") || label.lowercased().contains("dark"))
        XCTAssertTrue(label.lowercased().contains("map") || label.lowercased().contains("pace"))
    }

    // MARK: - Helpers

    private func waitForReady(_ vm: PNGSummaryExportViewModel, timeout: TimeInterval = 5) async {
        await waitForPhase(vm, timeout: timeout) { $0.phase == .ready && $0.previewData != nil }
    }

    private func waitForPhase(
        _ vm: PNGSummaryExportViewModel,
        timeout: TimeInterval = 5,
        predicate: @escaping (PNGSummaryExportViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(vm) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for view model phase (last=\(vm.phase), error=\(vm.errorMessage ?? "nil"), map=\(vm.mapFailureMessage ?? "nil"))")
    }

    private func waitForCondition(
        timeout: TimeInterval = 2,
        predicate: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private func sampleRouteWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        points.reserveCapacity(40)
        for i in 0..<40 {
            let index = Double(i)
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(index * 3),
                    latitude: 37.77 + index * 0.00015,
                    longitude: -122.42 + index * 0.00012,
                    altitudeMeters: 20 + index * 0.2,
                    distanceFromStartMeters: index * 12,
                    elapsedSeconds: index * 3,
                    heartRateBPM: 140 + Double(i % 10)
                )
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "VM Test Run", activityType: "run", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: 480,
                totalElapsedSeconds: 120,
                averagePaceSecondsPerKilometer: 250,
                elevationGainMeters: 8,
                averageHeartRateBPM: 145,
                maxHeartRateBPM: 160
            )
        )
    }

    private func noGPSWorkout() -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(name: "No GPS", activityType: "run"),
            source: .json,
            routePoints: [],
            summary: RunSummary(totalDistanceMeters: 0, totalElapsedSeconds: 0)
        )
    }
}

// MARK: - Fake snapshotters

private final class SnapshotCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    func increment() {
        lock.lock(); _calls += 1; lock.unlock()
    }
}

private struct FailingMapSnapshotter: WorkoutMapSnapshotting {
    func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        throw WorkoutMapSnapshotError.snapshotFailed("Simulated offline map failure")
    }
}

private struct BlankMapSnapshotter: WorkoutMapSnapshotting {
    func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        let width = Int(request.size.width)
        let height = Int(request.size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.systemGray.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let basemap = context.makeImage()!
        let converter = LinearMapCoordinateConverter(routes: request.routes, size: request.size)
        return try MapSnapshotOverlayComposer.compose(
            basemap: basemap,
            routes: request.routes,
            markers: request.markers,
            converter: converter,
            lineWidth: request.lineWidth
        )
    }
}

private struct CountingFailThenSucceedSnapshotter: WorkoutMapSnapshotting {
    let counter: SnapshotCallCounter
    private let success = BlankMapSnapshotter()

    func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        counter.increment()
        if counter.calls == 1 {
            throw WorkoutMapSnapshotError.snapshotFailed("first failure")
        }
        return try await success.makeSnapshot(request: request)
    }
}

private struct SlowMapSnapshotter: WorkoutMapSnapshotting {
    func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        try await Task.sleep(nanoseconds: 500_000_000)
        try Task.checkCancellation()
        return try await BlankMapSnapshotter().makeSnapshot(request: request)
    }
}

private final class CancellationProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _observedCancellation = false

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _started
    }

    var observedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _observedCancellation
    }

    func markStarted() {
        lock.lock()
        _started = true
        lock.unlock()
    }

    func markObservedCancellation() {
        lock.lock()
        _observedCancellation = true
        lock.unlock()
    }
}

private struct CancellationObservingProfileBuilder: RouteMetricProfileBuilding {
    let recorder: CancellationProbeRecorder
    private let base = RouteMetricProfileBuilder()

    func build(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfile {
        try base.build(
            routePoints: routePoints,
            context: context,
            mode: mode,
            policy: policy,
            isCancelled: isCancelled
        )
    }

    func probe(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfileProbe {
        recorder.markStarted()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if isCancelled() {
                recorder.markObservedCancellation()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw CancellationProbeTestError.timedOut
    }
}

private enum CancellationProbeTestError: Error {
    case timedOut
}
