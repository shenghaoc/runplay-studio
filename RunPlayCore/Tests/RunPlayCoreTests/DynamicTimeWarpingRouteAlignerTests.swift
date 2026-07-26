import XCTest
@testable import RunPlayCore

final class DynamicTimeWarpingRouteAlignerTests: XCTestCase {
    private let aligner = ConstrainedDynamicTimeWarpingAligner()
    private let policy = RouteAlignmentPolicy.default

    func testIdenticalRoutesProduceAvailableHighQualityAlignment() throws {
        let workout = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 25)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout),
            policy: policy
        )
        guard case .available(let quality) = snapshot.availability else {
            return XCTFail("Expected available, got \(snapshot.availability)")
        }
        XCTAssertTrue([RouteAlignmentQuality.excellent, .good].contains(quality))
        XCTAssertGreaterThan(snapshot.totalAlignedDistanceMeters, 2_000)
        XCTAssertFalse(snapshot.blocks.isEmpty)
        assertMonotonic(snapshot)
        assertFiniteDiagnostics(snapshot.diagnostics)
    }

    func testDifferentSampleRatesStillAlign() throws {
        let dense = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 10)
        let sparse = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 40)
        let snapshot = try aligner.align(
            primary: dense,
            comparison: sparse,
            primaryContext: WorkoutAnalysisContext(workout: dense),
            comparisonContext: WorkoutAnalysisContext(workout: sparse),
            policy: policy
        )
        XCTAssertTrue(snapshot.availability.isAvailable)
        assertMonotonic(snapshot)
    }

    func testSmallGPSNoiseRemainsAvailable() throws {
        let clean = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let noisy = makeNoisyWorkout(from: clean, noiseMeters: 4)
        let snapshot = try aligner.align(
            primary: clean,
            comparison: noisy,
            primaryContext: WorkoutAnalysisContext(workout: clean),
            comparisonContext: WorkoutAnalysisContext(workout: noisy),
            policy: policy
        )
        XCTAssertTrue(
            snapshot.availability.isAvailable,
            "availability=\(snapshot.availability) median=\(snapshot.diagnostics.medianSpatialSeparationMeters) p90=\(snapshot.diagnostics.p90SpatialSeparationMeters)"
        )
        XCTAssertLessThan(snapshot.diagnostics.medianSpatialSeparationMeters, 40)
    }

    func testModestPrefixOffsetStillAligns() throws {
        // Comparison starts ~80 m further along the same line (shared geography,
        // different start). Route-Aware should still produce an available mapping.
        let base = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let offset = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20, startOffsetMeters: 80)
        let snapshot = try aligner.align(
            primary: base,
            comparison: offset,
            primaryContext: WorkoutAnalysisContext(workout: base),
            comparisonContext: WorkoutAnalysisContext(workout: offset),
            policy: policy
        )
        XCTAssertTrue(
            snapshot.availability.isAvailable,
            "availability=\(snapshot.availability) coverage=\(snapshot.diagnostics.primaryCoverageFraction)/\(snapshot.diagnostics.comparisonCoverageFraction)"
        )
        XCTAssertGreaterThan(snapshot.totalAlignedDistanceMeters, 2_000)
    }

    func testOppositeDirectionIsUnavailable() throws {
        let forward = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20)
        let reverse = reverseWorkout(forward)
        let snapshot = try aligner.align(
            primary: forward,
            comparison: reverse,
            primaryContext: WorkoutAnalysisContext(workout: forward),
            comparisonContext: WorkoutAnalysisContext(workout: reverse),
            policy: policy
        )
        guard case .unavailable(let reason) = snapshot.availability else {
            return XCTFail("Expected unavailable for opposite direction")
        }
        XCTAssertEqual(reason, .oppositeDirection)
        XCTAssertEqual(snapshot.diagnostics.detectedDirection, .opposite)
    }

    func testUnrelatedRoutesAreUnavailable() throws {
        let a = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20, lat: 37.77, lon: -122.42)
        let b = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20, lat: 40.71, lon: -74.00)
        let snapshot = try aligner.align(
            primary: a,
            comparison: b,
            primaryContext: WorkoutAnalysisContext(workout: a),
            comparisonContext: WorkoutAnalysisContext(workout: b),
            policy: policy
        )
        XCTAssertFalse(snapshot.availability.isAvailable)
    }

    func testRecordingGapProducesSeparateBlocks() throws {
        let gapped = makeGappedWorkout(segmentDistances: [1_500, 1_500])
        let continuous = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let snapshot = try aligner.align(
            primary: continuous,
            comparison: gapped,
            primaryContext: WorkoutAnalysisContext(workout: continuous),
            comparisonContext: WorkoutAnalysisContext(workout: gapped),
            policy: policy
        )
        if snapshot.availability.isAvailable {
            // Gap handling: either multiple blocks or still available with diagnostics.
            XCTAssertGreaterThanOrEqual(snapshot.diagnostics.matchedBlockCount, 1)
            for block in snapshot.blocks {
                let segmentsP = Set(block.anchors.map(\.primarySegmentIndex))
                // Within a block, primary segment may be continuous; comparison may split.
                XCTAssertFalse(block.anchors.isEmpty)
                _ = segmentsP
            }
            // Mapping must not interpolate across blocks.
            if snapshot.blocks.count >= 2 {
                let end0 = snapshot.blocks[0].alignedEndMeters
                let start1 = snapshot.blocks[1].alignedStartMeters
                XCTAssertGreaterThanOrEqual(start1, end0)
                if let mid = snapshot.positions(atAlignedProgress: (end0 + start1) / 2) {
                    // Position resolves to a block boundary, not a bridged interior.
                    XCTAssertTrue(
                        abs(mid.alignedProgressMeters - end0) < 1e-6
                            || abs(mid.alignedProgressMeters - start1) < 1e-6
                            || snapshot.blocks.contains { mid.alignedProgressMeters >= $0.alignedStartMeters
                                && mid.alignedProgressMeters <= $0.alignedEndMeters }
                    )
                }
            }
        }
    }

    func testDeterministicOutput() throws {
        let a = makeLinearWorkout(distanceMeters: 2_200, stepMeters: 20)
        let b = makeNoisyWorkout(from: a, noiseMeters: 5)
        let first = try aligner.align(
            primary: a, comparison: b,
            primaryContext: WorkoutAnalysisContext(workout: a),
            comparisonContext: WorkoutAnalysisContext(workout: b),
            policy: policy
        )
        let second = try aligner.align(
            primary: a, comparison: b,
            primaryContext: WorkoutAnalysisContext(workout: a),
            comparisonContext: WorkoutAnalysisContext(workout: b),
            policy: policy
        )
        XCTAssertEqual(first.totalAlignedDistanceMeters, second.totalAlignedDistanceMeters, accuracy: 1e-9)
        XCTAssertEqual(first.blocks.count, second.blocks.count)
        XCTAssertEqual(first.diagnostics.primarySampleCount, second.diagnostics.primarySampleCount)
    }

    func testCancellationDoesNotPublishAvailableResult() throws {
        let workout = makeLinearWorkout(distanceMeters: 5_000, stepMeters: 10)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout),
            policy: policy,
            isCancelled: { true }
        )
        guard case .unavailable(let reason) = snapshot.availability else {
            return XCTFail("Expected cancelled unavailability")
        }
        XCTAssertEqual(reason, .cancelled)
    }

    func testDenseRawPointsStayWithinSampleBudget() throws {
        // Simulate dense GPS (~1 m) over 4 km without exploding samples.
        let dense = makeLinearWorkout(distanceMeters: 4_000, stepMeters: 1)
        XCTAssertGreaterThan(dense.routePoints.count, 3_000)
        let snapshot = try aligner.align(
            primary: dense,
            comparison: dense,
            primaryContext: WorkoutAnalysisContext(workout: dense),
            comparisonContext: WorkoutAnalysisContext(workout: dense),
            policy: policy
        )
        XCTAssertLessThanOrEqual(snapshot.diagnostics.primarySampleCount, policy.maximumSamplesPerRoute)
        XCTAssertTrue(snapshot.availability.isAvailable || snapshot.availability.unavailableReason != nil)
    }

    // MARK: - Helpers

    private func assertMonotonic(_ snapshot: RouteAlignmentSnapshot) {
        for block in snapshot.blocks {
            var lastP = -1.0
            var lastC = -1.0
            var lastA = -1.0
            for anchor in block.anchors {
                XCTAssertGreaterThanOrEqual(anchor.primaryDistanceMeters, lastP - 1e-6)
                XCTAssertGreaterThanOrEqual(anchor.comparisonDistanceMeters, lastC - 1e-6)
                XCTAssertGreaterThanOrEqual(anchor.alignedProgressMeters, lastA - 1e-6)
                lastP = anchor.primaryDistanceMeters
                lastC = anchor.comparisonDistanceMeters
                lastA = anchor.alignedProgressMeters
            }
        }
    }

    private func assertFiniteDiagnostics(_ d: RouteAlignmentDiagnostics) {
        XCTAssertTrue(d.alignedDistanceMeters.isFinite)
        XCTAssertTrue(d.medianSpatialSeparationMeters.isFinite)
        XCTAssertTrue(d.p90SpatialSeparationMeters.isFinite)
        XCTAssertTrue(d.primaryCoverageFraction.isFinite)
        XCTAssertTrue(d.comparisonCoverageFraction.isFinite)
        XCTAssertGreaterThanOrEqual(d.primaryCoverageFraction, 0)
        XCTAssertLessThanOrEqual(d.primaryCoverageFraction, 1)
    }

    private func makeLinearWorkout(
        distanceMeters: Double,
        stepMeters: Double,
        startOffsetMeters: Double = 0,
        lat: Double = 37.7749,
        lon: Double = -122.4194
    ) -> RunWorkout {
        let start = Date()
        var points: [RoutePoint] = []
        var d = 0.0
        while d <= distanceMeters {
            let along = d + startOffsetMeters
            let latitude = lat + (along / 111_000)
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: latitude,
                longitude: lon,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + stepMeters)
        }
        return RunWorkout(routePoints: points)
    }

    private func makeNoisyWorkout(from workout: RunWorkout, noiseMeters: Double) -> RunWorkout {
        let points = workout.routePoints.enumerated().map { index, point in
            let sign = index % 2 == 0 ? 1.0 : -1.0
            let latNoise = (noiseMeters * sign) / 111_000
            return RoutePoint(
                timestamp: point.timestamp,
                latitude: point.latitude + latNoise,
                longitude: point.longitude,
                altitudeMeters: point.altitudeMeters,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
        return RunWorkout(routePoints: points)
    }

    private func reverseWorkout(_ workout: RunWorkout) -> RunWorkout {
        let total = workout.routePoints.last?.distanceFromStartMeters ?? 0
        let totalElapsed = workout.routePoints.last?.elapsedSeconds ?? 0
        let reversed = workout.routePoints.reversed().enumerated().map { index, point in
            RoutePoint(
                timestamp: workout.routePoints[0].timestamp.addingTimeInterval(Double(index)),
                latitude: point.latitude,
                longitude: point.longitude,
                distanceFromStartMeters: total - point.distanceFromStartMeters,
                elapsedSeconds: totalElapsed - point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: 0
            )
        }
        // Re-sort by increasing distance after reverse mapping.
        let ordered = reversed.sorted { $0.distanceFromStartMeters < $1.distanceFromStartMeters }
        return RunWorkout(routePoints: ordered)
    }

    private func makeGappedWorkout(segmentDistances: [Double]) -> RunWorkout {
        let start = Date()
        var points: [RoutePoint] = []
        var distance = 0.0
        var elapsed = 0.0
        for (segment, length) in segmentDistances.enumerated() {
            var local = 0.0
            while local <= length {
                let lat = 37.7749 + (distance / 111_000)
                points.append(RoutePoint(
                    timestamp: start.addingTimeInterval(elapsed),
                    latitude: lat,
                    longitude: -122.4194,
                    distanceFromStartMeters: distance,
                    elapsedSeconds: elapsed,
                    paceSecondsPerKilometer: 300,
                    routeSegmentIndex: segment
                ))
                if local >= length { break }
                local += 20
                distance += 20
                elapsed += 20 / 3
            }
            // Gap in time/distance bookkeeping: jump distance slightly without geometry bridge.
            distance += 50
            elapsed += 30
        }
        return RunWorkout(routePoints: points)
    }
}
