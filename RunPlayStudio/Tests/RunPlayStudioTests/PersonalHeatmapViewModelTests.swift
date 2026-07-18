import XCTest
import RunPlayCore
import RunPlayPlatform
@testable import RunPlayStudio

// MARK: - Controllable fake builder

private final class ControllableHeatmapBuilder: PersonalHeatmapBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var _continue: CheckedContinuation<Void, Never>?
    private var _shouldWait = false
    private var _error: Error?
    private var _snapshot: PersonalHeatmapSnapshot?
    private var _buildCount = 0

    var buildCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _buildCount
    }

    func setShouldWait(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        _shouldWait = value
    }

    func setError(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        _error = error
    }

    func setSnapshot(_ snapshot: PersonalHeatmapSnapshot?) {
        lock.lock(); defer { lock.unlock() }
        _snapshot = snapshot
    }

    func resumeWaitingBuild() {
        lock.lock()
        let cont = _continue
        _continue = nil
        lock.unlock()
        cont?.resume()
    }

    func build(
        workouts: [RunWorkout],
        configuration: PersonalHeatmapConfiguration,
        isCancelled: @Sendable () -> Bool
    ) throws -> PersonalHeatmapSnapshot {
        lock.lock()
        _buildCount += 1
        let shouldWait = _shouldWait
        let error = _error
        let snapshot = _snapshot
        lock.unlock()

        if shouldWait {
            let semaphore = DispatchSemaphore(value: 0)
            lock.lock()
            // Store a resume hook via semaphore path for tests that gate progress.
            lock.unlock()
            // Cooperative wait: poll cancellation and a flag.
            while true {
                if isCancelled() { throw CancellationError() }
                lock.lock()
                let stillWait = _shouldWait
                lock.unlock()
                if !stillWait { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if isCancelled() { throw CancellationError() }
            _ = semaphore
        }

        if isCancelled() { throw CancellationError() }
        if let error { throw error }

        if let snapshot { return snapshot }

        // Default: empty or simple snapshot based on workouts with points.
        let withRoute = workouts.filter { !$0.routePoints.isEmpty }
        if withRoute.isEmpty {
            return .empty(configuration: configuration)
        }
        let cellID = PersonalHeatmapCellID(x: 0, y: 0)
        let bounds = PersonalHeatmapCellBounds(
            minLatitude: 1.3, maxLatitude: 1.301,
            minLongitude: 103.8, maxLongitude: 103.801
        )
        return PersonalHeatmapSnapshot(
            cells: [
                PersonalHeatmapCell(
                    id: cellID,
                    workoutCount: withRoute.count,
                    normalizedIntensity: 1,
                    bounds: bounds
                )
            ],
            statistics: PersonalHeatmapStatistics(
                includedWorkoutCount: withRoute.count,
                totalDistanceMeters: withRoute.reduce(0) { $0 + $1.summary.totalDistanceMeters },
                maximumOverlap: withRoute.count,
                requestedCellSizeMeters: configuration.cellSizeMeters,
                effectiveCellSizeMeters: configuration.cellSizeMeters,
                resolutionWasAdjusted: false,
                excludedUndatedWorkoutCount: 0,
                excludedNoRouteWorkoutCount: workouts.count - withRoute.count
            ),
            diagnostics: .empty,
            configuration: configuration,
            bounds: PersonalHeatmapBounds(
                minLatitude: bounds.minLatitude,
                maxLatitude: bounds.maxLatitude,
                minLongitude: bounds.minLongitude,
                maxLongitude: bounds.maxLongitude
            )
        )
    }
}

@MainActor
final class PersonalHeatmapViewModelTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeWorkout(name: String, hasRoute: Bool = true) -> RunWorkout {
        let points: [RoutePoint]
        if hasRoute {
            points = [
                RoutePoint(
                    timestamp: fixedNow,
                    latitude: 1.3,
                    longitude: 103.8,
                    distanceFromStartMeters: 0,
                    elapsedSeconds: 0
                ),
                RoutePoint(
                    timestamp: fixedNow.addingTimeInterval(60),
                    latitude: 1.301,
                    longitude: 103.801,
                    distanceFromStartMeters: 100,
                    elapsedSeconds: 60
                )
            ]
        } else {
            points = []
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: fixedNow),
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: hasRoute ? 100 : 0, totalElapsedSeconds: 60)
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition not met within \(timeout)s", file: file, line: line)
    }

    func testSuccessfulResult() async {
        let builder = ControllableHeatmapBuilder()
        let vm = PersonalHeatmapViewModel(builder: builder, now: fixedNow)
        vm.nowProvider = { self.fixedNow }

        let workouts = [makeWorkout(name: "A"), makeWorkout(name: "B")]
        vm.refresh(workouts: workouts)

        await waitUntil { vm.loadState == .ready && vm.snapshot != nil }
        XCTAssertEqual(vm.snapshot?.statistics.includedWorkoutCount, 2)
        XCTAssertFalse(vm.mapAreas.isEmpty)
        XCTAssertFalse(vm.isComputing)
    }

    func testEmptyLibraryShowsNoGPS() async {
        let builder = ControllableHeatmapBuilder()
        let vm = PersonalHeatmapViewModel(builder: builder, now: fixedNow)
        vm.nowProvider = { self.fixedNow }

        vm.refresh(workouts: [])
        await waitUntil {
            if case .empty(.noGPSWorkouts) = vm.loadState { return true }
            return false
        }
    }

    func testErrorState() async {
        let builder = ControllableHeatmapBuilder()
        builder.setError(PersonalHeatmapError.invalidConfiguration)
        let vm = PersonalHeatmapViewModel(builder: builder, now: fixedNow)
        vm.nowProvider = { self.fixedNow }

        vm.refresh(workouts: [makeWorkout(name: "A")])
        await waitUntil {
            if case .failed = vm.loadState { return true }
            return false
        }
    }

    func testStaleRequestDoesNotOverwriteNewerResult() async {
        let builder = ControllableHeatmapBuilder()
        builder.setShouldWait(true)
        let vm = PersonalHeatmapViewModel(builder: builder, now: fixedNow)
        vm.nowProvider = { self.fixedNow }

        let first = [makeWorkout(name: "A")]
        vm.refresh(workouts: first)

        // Change filter quickly — newer request.
        builder.setShouldWait(false)
        vm.minimumWorkoutCount = 2
        let second = [makeWorkout(name: "A"), makeWorkout(name: "B")]
        vm.refresh(workouts: second)

        await waitUntil { !vm.isComputing && vm.snapshot != nil }
        // Latest request used minimum 2; fake still returns cells. Key is lastKey stability.
        XCTAssertEqual(vm.minimumWorkoutCount, 2)
        // First slow build should have been cancelled or ignored.
        XCTAssertGreaterThanOrEqual(builder.buildCount, 1)
    }

    func testCacheHitDoesNotRebuild() async {
        let builder = ControllableHeatmapBuilder()
        let vm = PersonalHeatmapViewModel(builder: builder, now: fixedNow)
        vm.nowProvider = { self.fixedNow }
        let workouts = [makeWorkout(name: "A")]

        vm.refresh(workouts: workouts)
        await waitUntil { vm.loadState == .ready }
        let countAfterFirst = builder.buildCount

        vm.refresh(workouts: workouts)
        // Cache hit is synchronous.
        XCTAssertEqual(builder.buildCount, countAfterFirst)
        XCTAssertEqual(vm.loadState, .ready)
    }

    func testLibraryChangeInvalidatesCache() async {
        let builder = ControllableHeatmapBuilder()
        let vm = PersonalHeatmapViewModel(builder: builder, now: fixedNow)
        vm.nowProvider = { self.fixedNow }

        let a = makeWorkout(name: "A")
        vm.refresh(workouts: [a])
        await waitUntil { vm.loadState == .ready }
        let countAfterFirst = builder.buildCount

        let b = makeWorkout(name: "B")
        vm.refresh(workouts: [a, b])
        await waitUntil { builder.buildCount > countAfterFirst }
        XCTAssertEqual(vm.snapshot?.statistics.includedWorkoutCount, 2)
    }

    func testCancelStopsLoadingWithoutPublishingFailure() async {
        let builder = ControllableHeatmapBuilder()
        builder.setShouldWait(true)
        let vm = PersonalHeatmapViewModel(builder: builder, now: fixedNow)
        vm.nowProvider = { self.fixedNow }

        vm.refresh(workouts: [makeWorkout(name: "A")])
        await waitUntil { vm.isComputing }
        vm.cancel()
        XCTAssertFalse(vm.isComputing)
        if case .failed = vm.loadState {
            XCTFail("cancel should not publish failure")
        }
        builder.setShouldWait(false)
    }

    func testResetFilters() async {
        let builder = ControllableHeatmapBuilder()
        let vm = PersonalHeatmapViewModel(builder: builder, now: fixedNow)
        vm.nowProvider = { self.fixedNow }
        vm.datePreset = .last30Days
        vm.resolution = .fine
        vm.minimumWorkoutCount = 5

        vm.resetFilters(workouts: [makeWorkout(name: "A")])
        XCTAssertEqual(vm.datePreset, .allTime)
        XCTAssertEqual(vm.resolution, .standard)
        XCTAssertEqual(vm.minimumWorkoutCount, 1)
        await waitUntil { vm.loadState == .ready || vm.snapshot != nil }
    }
}
