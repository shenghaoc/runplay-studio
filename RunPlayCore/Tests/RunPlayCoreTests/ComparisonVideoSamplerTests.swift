import XCTest
@testable import RunPlayCore

final class ComparisonVideoSamplerTests: XCTestCase {
    func testDistanceEqualLengthRoutes() throws {
        let primary = makeWorkout(distanceMeters: 2_000, paceSecondsPerKm: 300)
        let comparison = makeWorkout(distanceMeters: 2_000, paceSecondsPerKm: 330, latOffset: 0.0001)
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)
        let pair = ComparisonPair(primary: primary, comparison: comparison)
        let sampler = ComparisonVideoSampler(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            alignmentMode: .distance
        )
        let plan = try ComparisonVideoFramePlan.make(
            duration: .fifteenSeconds,
            policy: .unitTest,
            domainLength: sampler.domainLengthMeters,
            domain: .commonDistance
        )

        let first = sampler.sample(frameIndex: 0, plan: plan)
        XCTAssertEqual(first.domainPositionMeters, 0, accuracy: 1e-6)
        XCTAssertEqual(first.primaryDistanceMeters, 0, accuracy: 1e-3)
        XCTAssertEqual(first.comparisonDistanceMeters, 0, accuracy: 1e-3)

        let last = sampler.sample(frameIndex: plan.frameCount - 1, plan: plan)
        XCTAssertEqual(last.domainPositionMeters, 2_000, accuracy: 1e-6)
        XCTAssertEqual(last.primaryDistanceMeters, 2_000, accuracy: 1)
        XCTAssertEqual(last.comparisonDistanceMeters, 2_000, accuracy: 1)
        XCTAssertNotNil(last.primaryElapsedSeconds)
        XCTAssertNotNil(last.comparisonElapsedSeconds)
    }

    func testDistanceUnequalRoutesClampToCommon() throws {
        let primary = makeWorkout(distanceMeters: 5_000, paceSecondsPerKm: 300)
        let comparison = makeWorkout(distanceMeters: 3_000, paceSecondsPerKm: 300, latOffset: 0.0001)
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)
        let sampler = ComparisonVideoSampler(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            alignmentMode: .distance
        )
        XCTAssertEqual(sampler.domainLengthMeters, 3_000, accuracy: 1)
        let plan = try ComparisonVideoFramePlan(
            frameCount: 11,
            framesPerSecond: 10,
            domainLength: sampler.domainLengthMeters,
            domain: .commonDistance
        )
        let last = sampler.sample(frameIndex: 10, plan: plan)
        XCTAssertEqual(last.domainPositionMeters, 3_000, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(last.primaryDistanceMeters, 3_000 + 1)
    }

    func testDistanceActivePaceDelta() throws {
        let primary = makeWorkout(distanceMeters: 2_000, paceSecondsPerKm: 300)
        let comparison = makeWorkout(distanceMeters: 2_000, paceSecondsPerKm: 360, latOffset: 0.0001)
        let sampler = ComparisonVideoSampler(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison),
            alignmentMode: .distance
        )
        let plan = try ComparisonVideoFramePlan(
            frameCount: 11,
            framesPerSecond: 10,
            domainLength: sampler.domainLengthMeters,
            domain: .commonDistance
        )
        let mid = sampler.sample(frameIndex: 5, plan: plan)
        XCTAssertNotNil(mid.primaryActivePaceSecondsPerKm)
        XCTAssertNotNil(mid.comparisonActivePaceSecondsPerKm)
        if let delta = mid.activePaceDeltaSecondsPerKm {
            // Primary faster → negative pace delta.
            XCTAssertLessThan(delta, 0)
        }
    }

    func testRouteAwareUsesMappedDistances() throws {
        let primary = makeWorkout(distanceMeters: 2_000, paceSecondsPerKm: 300)
        let comparison = makeWorkout(distanceMeters: 2_000, paceSecondsPerKm: 300, latOffset: 0.00005)
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)
        let aligner = ConstrainedDynamicTimeWarpingAligner()
        let snapshot = try aligner.align(
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        guard snapshot.availability.isAvailable, snapshot.totalAlignedDistanceMeters > 0 else {
            throw XCTSkip("Synthetic pair did not produce Route-Aware alignment")
        }

        let sampler = ComparisonVideoSampler(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            alignmentMode: .routeAware,
            snapshot: snapshot
        )
        let plan = try ComparisonVideoFramePlan(
            frameCount: 11,
            framesPerSecond: 10,
            domainLength: sampler.domainLengthMeters,
            domain: .alignedProgress
        )
        let first = sampler.sample(frameIndex: 0, plan: plan)
        let last = sampler.sample(frameIndex: 10, plan: plan)
        XCTAssertEqual(first.alignmentMode, .routeAware)
        XCTAssertNotNil(first.alignmentBlockIndex)
        XCTAssertEqual(
            last.domainPositionMeters,
            snapshot.totalAlignedDistanceMeters,
            accuracy: 1
        )
        XCTAssertNotNil(last.spatialSeparationMeters)
    }

    func testFilenameBuilder() {
        let primary = makeWorkout(distanceMeters: 1_000, paceSecondsPerKm: 300)
        let comparison = makeWorkout(distanceMeters: 1_000, paceSecondsPerKm: 300, latOffset: 0.0001)
        let name = ExportFilenameBuilder.comparisonVideoReplayFilename(
            primary: primary,
            comparison: comparison
        )
        XCTAssertTrue(name.hasSuffix("-comparison-replay.mp4"))
        XCTAssertTrue(name.contains("-vs-"))
        XCTAssertFalse(name.contains(primary.id.uuidString))
    }

    // MARK: - Fixtures

    private func makeWorkout(
        distanceMeters: Double,
        paceSecondsPerKm: Double,
        latOffset: Double = 0
    ) -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var d = 0.0
        let step = 20.0
        let speed = 1000.0 / paceSecondsPerKm
        while d <= distanceMeters {
            let elapsed = d / speed
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 37.7749 + latOffset + d / 111_000,
                longitude: -122.4194,
                distanceFromStartMeters: d,
                elapsedSeconds: elapsed,
                paceSecondsPerKilometer: paceSecondsPerKm,
                routeSegmentIndex: 0
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + step)
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Synthetic \(Int(distanceMeters))m"),
            routePoints: points
        )
    }
}
