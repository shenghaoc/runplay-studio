import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class ComparisonViewModelTests: XCTestCase {

    func testInitialModeIsDistance() {
        let vm = ComparisonViewModel()
        XCTAssertEqual(vm.alignmentMode, .distance)
        XCTAssertEqual(vm.routeAlignmentLoadState, .idle)
    }

    func testSwitchToRouteAwareLoadsAlignment() async {
        let primary = makeWorkout(distanceMeters: 3_000)
        let comparison = makeWorkout(distanceMeters: 3_000)
        let pair = ComparisonPair(primary: primary, comparison: comparison)
        let vm = ComparisonViewModel()
        vm.setAlignmentMode(
            .routeAware,
            pair: pair,
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison)
        )
        await waitUntil(timeout: 5) {
            if case .ready = vm.routeAlignmentLoadState { return true }
            if case .unavailable = vm.routeAlignmentLoadState { return true }
            if case .failed = vm.routeAlignmentLoadState { return true }
            return false
        }
        XCTAssertEqual(vm.alignmentMode, .routeAware)
        XCTAssertNotEqual(vm.routeAlignmentLoadState, .loading)
        XCTAssertNotEqual(vm.routeAlignmentLoadState, .idle)
    }

    func testCacheHitAvoidsReload() async {
        let primary = makeWorkout(distanceMeters: 2_500)
        let comparison = makeWorkout(distanceMeters: 2_500)
        let pair = ComparisonPair(primary: primary, comparison: comparison)
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)
        let vm = ComparisonViewModel()
        vm.setAlignmentMode(
            .routeAware,
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        await waitUntil(timeout: 5) {
            vm.routeAlignmentLoadState == .ready || {
                if case .unavailable = vm.routeAlignmentLoadState { return true }
                return false
            }()
        }
        let firstSnapshot = vm.routeAlignmentSnapshot
        // Second ensure should hit cache and stay ready without loading flicker.
        vm.ensureRouteAlignment(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        XCTAssertNotEqual(vm.routeAlignmentLoadState, .loading)
        XCTAssertEqual(
            vm.routeAlignmentSnapshot?.totalAlignedDistanceMeters,
            firstSnapshot?.totalAlignedDistanceMeters
        )
    }

    func testPairChangeClearsPreviousAlignment() async {
        let a = makeWorkout(distanceMeters: 2_500)
        let b = makeWorkout(distanceMeters: 2_500)
        let c = makeWorkout(distanceMeters: 2_800)
        let vm = ComparisonViewModel()
        vm.restoreAlignmentMode(.routeAware)
        vm.pairDidChange(
            pair: ComparisonPair(primary: a, comparison: b),
            primaryContext: WorkoutAnalysisContext(workout: a),
            comparisonContext: WorkoutAnalysisContext(workout: b)
        )
        await waitUntil(timeout: 5) {
            vm.routeAlignmentSnapshot != nil || {
                if case .unavailable = vm.routeAlignmentLoadState { return true }
                return false
            }()
        }
        vm.pairDidChange(
            pair: ComparisonPair(primary: a, comparison: c),
            primaryContext: WorkoutAnalysisContext(workout: a),
            comparisonContext: WorkoutAnalysisContext(workout: c)
        )
        // Immediately after pair change, previous ready snapshot must not linger as stale ready.
        // Loading or idle/unavailable for the new pair is acceptable.
        if case .ready = vm.routeAlignmentLoadState {
            // Ready is only OK if it already finished for the new pair (cache miss usually loads).
            XCTAssertEqual(vm.routeAlignmentSnapshot?.diagnostics.comparisonRouteDistanceMeters ?? 0, 2_800, accuracy: 50)
        }
    }

    func testSliderMovementDoesNotChangeLoadState() async {
        let primary = makeWorkout(distanceMeters: 3_000)
        let comparison = makeWorkout(distanceMeters: 3_000)
        let pair = ComparisonPair(primary: primary, comparison: comparison)
        let vm = ComparisonViewModel()
        vm.setAlignmentMode(
            .routeAware,
            pair: pair,
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison)
        )
        await waitUntil(timeout: 5) {
            vm.routeAlignmentLoadState == .ready
        }
        XCTAssertEqual(vm.routeAlignmentLoadState, .ready, "precondition: alignment ready before slider stress")
        let before = vm.routeAlignmentLoadState
        for i in 0..<100 {
            vm.selectedAlignedProgressMeters = Double(i) * 10
            vm.clampAlignedProgress()
        }
        XCTAssertEqual(vm.routeAlignmentLoadState, before)
    }

    func testUseDistanceAlignmentSwitchesMode() {
        let vm = ComparisonViewModel()
        vm.restoreAlignmentMode(.routeAware)
        vm.useDistanceAlignment()
        XCTAssertEqual(vm.alignmentMode, .distance)
    }

    func testAlignedProgressClamping() {
        let vm = ComparisonViewModel()
        vm.selectedAlignedProgressMeters = -10
        vm.clampAlignedProgress()
        XCTAssertEqual(vm.selectedAlignedProgressMeters, 0)
        vm.selectedAlignedProgressMeters = .nan
        vm.clampAlignedProgress()
        XCTAssertEqual(vm.selectedAlignedProgressMeters, 0)
    }

    func testLoadingSliderReconciliationDoesNotOverwriteRestoredProgress() {
        let vm = ComparisonViewModel()
        vm.selectedAlignedProgressMeters = 1_000

        vm.setAlignedProgressFromUser(0)

        XCTAssertEqual(vm.selectedAlignedProgressMeters, 1_000)
    }

    func testAppStateDistanceModeParity() {
        let appState = AppState(storeActor: nil, importService: nil)
        let primary = makeWorkout(distanceMeters: 5_000)
        let comparison = makeWorkout(distanceMeters: 4_000)
        appState.workouts = [primary, comparison]
        appState.selectWorkout(primary)
        appState.setComparison(comparison)
        appState.selectedComparisonDistanceMeters = 2_500
        XCTAssertEqual(appState.comparisonViewModel.alignmentMode, .distance)
        XCTAssertEqual(appState.clampedComparisonDistanceMeters, 2_500, accuracy: 0.01)
        XCTAssertEqual(appState.comparisonDistanceMetrics.selectedDistanceMeters, 2_500, accuracy: 0.01)
        XCTAssertFalse(appState.comparisonMetrics.isEmpty)
    }

    // MARK: - Helpers

    private func makeWorkout(distanceMeters: Double) -> RunWorkout {
        let start = Date()
        var points: [RoutePoint] = []
        var d = 0.0
        while d <= distanceMeters {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: 37.7749 + d / 111_000,
                longitude: -122.4194,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + 25)
        }
        return RunWorkout(routePoints: points)
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
