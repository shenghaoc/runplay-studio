import XCTest
@testable import RunPlayCore

final class ComparisonVideoAlignmentResolverTests: XCTestCase {
    func testDistanceModeNeverRunsAligner() throws {
        let aligner = CountingAligner()
        let resolver = ComparisonVideoAlignmentResolver(aligner: aligner)
        let primary = makeWorkout(distanceMeters: 1_500)
        let comparison = makeWorkout(distanceMeters: 1_500, latOffset: 0.0001)
        let resolution = try resolver.resolve(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison),
            desiredMode: .distance,
            seed: nil
        )
        XCTAssertEqual(aligner.alignCount, 0)
        if case .distanceOnly = resolution {
            // expected
        } else {
            XCTFail("Expected distanceOnly")
        }
    }

    func testValidSeedReuse() throws {
        let primary = makeWorkout(distanceMeters: 2_000)
        let comparison = makeWorkout(distanceMeters: 2_000, latOffset: 0.00005)
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)
        let realAligner = ConstrainedDynamicTimeWarpingAligner()
        let snapshot = try realAligner.align(
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        guard snapshot.availability.isAvailable else {
            throw XCTSkip("Could not produce available seed snapshot")
        }

        let seed = ComparisonVideoAlignmentSeed(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            snapshot: snapshot
        )
        let counting = CountingAligner()
        let resolver = ComparisonVideoAlignmentResolver(aligner: counting)
        let resolution = try resolver.resolve(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            desiredMode: .routeAware,
            seed: seed
        )
        XCTAssertEqual(counting.alignCount, 0)
        if case .routeAware(let resolved) = resolution {
            XCTAssertEqual(resolved.totalAlignedDistanceMeters, snapshot.totalAlignedDistanceMeters, accuracy: 1e-6)
        } else {
            XCTFail("Expected routeAware from seed")
        }
    }

    func testWrongPairRejectsSeedAndRecalculates() throws {
        let primary = makeWorkout(distanceMeters: 2_000)
        let comparison = makeWorkout(distanceMeters: 2_000, latOffset: 0.00005)
        let other = makeWorkout(distanceMeters: 2_000, latOffset: 0.0002)
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)
        let otherContext = WorkoutAnalysisContext(workout: other)
        let realAligner = ConstrainedDynamicTimeWarpingAligner()
        let snapshot = try realAligner.align(
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        let seed = ComparisonVideoAlignmentSeed(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            snapshot: snapshot
        )
        let counting = CountingAligner(delegate: realAligner)
        let resolver = ComparisonVideoAlignmentResolver(aligner: counting)
        _ = try resolver.resolve(
            pair: ComparisonPair(primary: primary, comparison: other),
            primaryContext: primaryContext,
            comparisonContext: otherContext,
            desiredMode: .routeAware,
            seed: seed
        )
        XCTAssertEqual(counting.alignCount, 1)
    }

    func testCancellationThrows() {
        let primary = makeWorkout(distanceMeters: 1_000)
        let comparison = makeWorkout(distanceMeters: 1_000, latOffset: 0.0001)
        let resolver = ComparisonVideoAlignmentResolver()
        XCTAssertThrowsError(
            try resolver.resolve(
                pair: ComparisonPair(primary: primary, comparison: comparison),
                primaryContext: WorkoutAnalysisContext(workout: primary),
                comparisonContext: WorkoutAnalysisContext(workout: comparison),
                desiredMode: .routeAware,
                seed: nil,
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue((error as? ComparisonVideoExportError)?.isCancellation == true)
        }
    }

    // MARK: - Helpers

    private final class CountingAligner: RouteComparisonAligning, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let delegate: any RouteComparisonAligning

        var alignCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        init(delegate: any RouteComparisonAligning = ConstrainedDynamicTimeWarpingAligner()) {
            self.delegate = delegate
        }

        func align(
            primary: RunWorkout,
            comparison: RunWorkout,
            primaryContext: WorkoutAnalysisContext,
            comparisonContext: WorkoutAnalysisContext,
            policy: RouteAlignmentPolicy,
            isCancelled: @Sendable () -> Bool
        ) throws -> RouteAlignmentSnapshot {
            lock.lock()
            count += 1
            lock.unlock()
            return try delegate.align(
                primary: primary,
                comparison: comparison,
                primaryContext: primaryContext,
                comparisonContext: comparisonContext,
                policy: policy,
                isCancelled: isCancelled
            )
        }
    }

    private func makeWorkout(distanceMeters: Double, latOffset: Double = 0) -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var d = 0.0
        while d <= distanceMeters {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: 37.7749 + latOffset + d / 111_000,
                longitude: -122.4194,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + 25)
        }
        return RunWorkout(routePoints: points)
    }
}
