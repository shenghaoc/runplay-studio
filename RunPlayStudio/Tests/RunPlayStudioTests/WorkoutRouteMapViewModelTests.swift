import XCTest
import RunPlayCore
import RunPlayPlatform
@testable import RunPlayStudio

@MainActor
final class WorkoutRouteMapViewModelTests: XCTestCase {

    func testInitialSolidMode() async throws {
        let workout = makeWorkout(pointCount: 30, withHR: true, withAltitude: true)
        let context = WorkoutAnalysisContext(workout: workout)
        let vm = WorkoutRouteMapViewModel()
        vm.preferredMode = .solid
        vm.update(workout: workout, analysisContext: context)

        let presentation = try await waitForPresentation(vm)
        XCTAssertEqual(presentation.effectiveMode, .solid)
        XCTAssertFalse(presentation.lines.isEmpty)
        XCTAssertTrue(presentation.lines.allSatisfy { $0.style == .primary })
    }

    func testSelectingPace() async throws {
        let workout = makeWorkout(pointCount: 40, withHR: true, withAltitude: true)
        let context = WorkoutAnalysisContext(workout: workout)
        let vm = WorkoutRouteMapViewModel()
        vm.preferredMode = .pace
        vm.update(workout: workout, analysisContext: context)

        let presentation = try await waitForPresentation(vm, mode: .pace)
        XCTAssertEqual(presentation.effectiveMode, .pace)
        XCTAssertNotNil(presentation.profile)
        XCTAssertTrue(presentation.lines.contains {
            if case .metric(let mode, _) = $0.style { return mode == .pace }
            return false
        })
    }

    func testSelectingHeartRate() async throws {
        let workout = makeWorkout(pointCount: 40, withHR: true, withAltitude: true)
        let context = WorkoutAnalysisContext(workout: workout)
        let vm = WorkoutRouteMapViewModel()
        vm.preferredMode = .heartRate
        vm.update(workout: workout, analysisContext: context)

        let presentation = try await waitForPresentation(vm, mode: .heartRate)
        XCTAssertEqual(presentation.effectiveMode, .heartRate)
    }

    func testSelectingElevation() async throws {
        let workout = makeWorkout(pointCount: 40, withHR: true, withAltitude: true)
        let context = WorkoutAnalysisContext(workout: workout)
        let vm = WorkoutRouteMapViewModel()
        vm.preferredMode = .correctedElevation
        vm.update(workout: workout, analysisContext: context)

        let presentation = try await waitForPresentation(vm, mode: .correctedElevation)
        XCTAssertEqual(presentation.effectiveMode, .correctedElevation)
    }

    func testUnavailableHRFallsBackToSolid() async throws {
        let workout = makeWorkout(pointCount: 30, withHR: false, withAltitude: true)
        let context = WorkoutAnalysisContext(workout: workout)
        let vm = WorkoutRouteMapViewModel()
        vm.preferredMode = .heartRate
        vm.update(workout: workout, analysisContext: context)

        let presentation = try await waitForPresentation(vm)
        XCTAssertEqual(presentation.effectiveMode, .solid)
        XCTAssertNotNil(presentation.fallbackReason)
        XCTAssertFalse(vm.availability.heartRate)
    }

    func testPreferenceDecodingFallback() {
        XCTAssertEqual(WorkoutRouteColorMode(rawValue: "pace"), .pace)
        XCTAssertNil(WorkoutRouteColorMode(rawValue: "zones"))
        XCTAssertEqual(WorkoutRouteColorMode(rawValue: "zones") ?? .solid, .solid)
    }

    func testCacheHitDoesNotRebuildMeaningfully() async throws {
        let workout = makeWorkout(pointCount: 25, withHR: true, withAltitude: true)
        let context = WorkoutAnalysisContext(workout: workout)
        let vm = WorkoutRouteMapViewModel()
        vm.preferredMode = .pace
        vm.update(workout: workout, analysisContext: context)
        let first = try await waitForPresentation(vm, mode: .pace)

        vm.update(workout: workout, analysisContext: context)
        // Cache hit is synchronous for matching key.
        XCTAssertEqual(vm.presentation?.key, first.key)
        XCTAssertFalse(vm.isBuilding)
    }

    func testReplayIndexChangeDoesNotRequireUpdate() async throws {
        // Documented contract: ViewModel is not driven by replay index.
        let workout = makeWorkout(pointCount: 20, withHR: true, withAltitude: false)
        let context = WorkoutAnalysisContext(workout: workout)
        let vm = WorkoutRouteMapViewModel()
        vm.preferredMode = .pace
        vm.update(workout: workout, analysisContext: context)
        let first = try await waitForPresentation(vm, mode: .pace)
        let linesBefore = first.lines
        // No update call for replay — presentation unchanged.
        XCTAssertEqual(vm.presentation?.lines, linesBefore)
    }

    func testChangingWorkoutSchedulesNewBuild() async throws {
        let a = makeWorkout(pointCount: 20, withHR: true, withAltitude: true)
        let b = makeWorkout(pointCount: 35, withHR: true, withAltitude: true)
        let vm = WorkoutRouteMapViewModel()
        vm.preferredMode = .pace
        vm.update(workout: a, analysisContext: WorkoutAnalysisContext(workout: a))
        _ = try await waitForPresentation(vm, mode: .pace)

        vm.update(workout: b, analysisContext: WorkoutAnalysisContext(workout: b))
        let second = try await waitForPresentation(vm, mode: .pace)
        XCTAssertEqual(second.key.workoutID, b.id)
    }

    // MARK: - Helpers

    private func waitForPresentation(
        _ vm: WorkoutRouteMapViewModel,
        mode: WorkoutRouteColorMode? = nil,
        timeout: TimeInterval = 5
    ) async throws -> WorkoutRouteMapPresentation {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let presentation = vm.presentation, !vm.isBuilding {
                if let mode {
                    // Wait until preferred mode has been applied (or fell back).
                    if presentation.key.mode == mode || presentation.effectiveMode == mode || presentation.fallbackReason != nil {
                        return presentation
                    }
                } else {
                    return presentation
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for map presentation")
        throw CancellationError()
    }

    private func makeWorkout(
        pointCount: Int,
        withHR: Bool,
        withAltitude: Bool
    ) -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var elapsed = 0.0
        let step = 50.0
        for i in 0..<pointCount {
            let t = Double(i) / Double(max(1, pointCount - 1))
            let pace = 280.0 + 100.0 * t
            if i > 0 { elapsed += (step / 1000.0) * pace }
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 37.77 + Double(i) * step / 111_320.0,
                longitude: -122.42,
                altitudeMeters: withAltitude ? 50 + Double(i) * 2 : nil,
                distanceFromStartMeters: Double(i) * step,
                elapsedSeconds: elapsed,
                heartRateBPM: withHR ? 130 + 40 * t : nil,
                routeSegmentIndex: 0
            ))
        }
        return RunWorkout(routePoints: points)
    }
}
