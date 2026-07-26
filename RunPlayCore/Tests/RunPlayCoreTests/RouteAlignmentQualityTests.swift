import XCTest
@testable import RunPlayCore

final class RouteAlignmentQualityTests: XCTestCase {
    private let aligner = ConstrainedDynamicTimeWarpingAligner()

    func testExcellentForNearIdenticalRoutes() throws {
        let workout = makeWorkout(distanceMeters: 4_000, step: 20)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout)
        )
        guard case .available(let quality) = snapshot.availability else {
            return XCTFail("Expected available")
        }
        XCTAssertTrue([RouteAlignmentQuality.excellent, .good].contains(quality))
        XCTAssertGreaterThan(snapshot.diagnostics.primaryCoverageFraction, 0.85)
        XCTAssertLessThan(snapshot.diagnostics.medianSpatialSeparationMeters, 25)
    }

    func testInsufficientCoverageRejected() {
        // Very short accepted fragment vs long routes: force min aligned distance failure.
        let shortPolicy = RouteAlignmentPolicy(
            minimumAlignedDistanceMeters: 10_000,
            minimumCoverageFraction: 0.99
        )
        let workout = makeWorkout(distanceMeters: 1_500, step: 20)
        let snapshot = try? aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout),
            policy: shortPolicy
        )
        guard let snapshot else {
            return XCTFail("align threw")
        }
        XCTAssertFalse(snapshot.availability.isAvailable)
    }

    func testDistanceWeightedStatisticsIndependentOfSamplingDensity() {
        // One high-weight interval must outweigh many tiny low-weight samples.
        let dense: [DistanceWeightedStatistics.WeightedSample] = (0..<10).map { _ in
            .init(value: 5, weight: 1)
        }
        let sparse: [DistanceWeightedStatistics.WeightedSample] = [
            .init(value: 100, weight: 200)
        ]
        let median = DistanceWeightedStatistics.weightedMedian(dense + sparse)
        // Total weight 10 at 5 and 200 at 100 → median is 100.
        XCTAssertEqual(median ?? -1, 100, accuracy: 0.01)
    }

    func testUnavailableReasonsHaveUserFacingCopy() {
        for reason in RouteAlignmentUnavailableReason.allCases {
            XCTAssertFalse(reason.userFacingExplanation.isEmpty)
        }
    }

    private func makeWorkout(distanceMeters: Double, step: Double) -> RunWorkout {
        let start = Date()
        var points: [RoutePoint] = []
        var d = 0.0
        while d <= distanceMeters {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: 37.77 + d / 111_000,
                longitude: -122.42,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + step)
        }
        return RunWorkout(routePoints: points)
    }
}
