import XCTest
@testable import RunPlayCore

final class RouteMetricScaleBucketParityTests: XCTestCase {
    private let builder = RouteMetricProfileBuilder()

    func testAllModesAndCustomPolicies() throws {
        let workout = HotspotProfilingFixtures.makeWorkout(options: .init(
            pointCount: 600,
            segmentCount: 7,
            stationaryWindows: true,
            pauseEvery: 73,
            seed: 81_001,
            name: "metric-parity"
        ))
        try assertProfileParity(workout: workout, mode: .solid)
        for mode in [WorkoutRouteColorMode.pace, .heartRate, .correctedElevation] {
            try assertProfileParity(workout: workout, mode: mode)
        }

        let custom = RouteMetricColorPolicy(
            paceSmoothingHalfWindowMeters: 0,
            heartRateSmoothingHalfWindowMeters: 0,
            minimumElevationSpanMeters: .nan,
            lowerQuantile: -1,
            upperQuantile: 2,
            bucketCount: 2,
            minimumValidIntervalCount: 3,
            cancellationStride: 1
        )
        for mode in [WorkoutRouteColorMode.pace, .heartRate, .correctedElevation] {
            try assertProfileParity(workout: workout, mode: mode, policy: custom)
        }

        let noElevation = HotspotProfilingFixtures.makeWorkout(options: .init(
            pointCount: 80,
            includeAltitude: false,
            seed: 81_002,
            name: "no-elevation"
        ))
        try assertProfileParity(workout: noElevation, mode: .correctedElevation)
    }

    func testOneMillionPointCompleteProfileParity() throws {
        try assertProfileParity(workout: HotspotProfilingFixtures.c5(), mode: .pace)
    }

    private func assertProfileParity(
        workout: RunWorkout,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy = .runningDefault
    ) throws {
        let profile = try builder.build(
            workout: workout,
            context: WorkoutAnalysisContext(workout: workout),
            mode: mode,
            policy: policy
        )
        let totalDistance = max(0, workout.routePoints.last?.distanceFromStartMeters ?? 0)
        XCTAssertEqual(profile.mode, mode)
        XCTAssertEqual(profile.totalRouteDistanceMeters, totalDistance)
        XCTAssertEqual(profile.diagnostics.intervalCount, profile.intervals.count)
        XCTAssertEqual(profile.diagnostics.bucketCount, policy.bucketCount)
        XCTAssertEqual(profile.diagnostics.policyVersion, policy.policyVersion)

        if mode == .solid {
            XCTAssertTrue(profile.intervals.isEmpty)
            XCTAssertNil(profile.scale)
            XCTAssertEqual(profile.validCoverageDistanceMeters, totalDistance)
            return
        }

        let values = profile.intervals.map(\.metricValue)
        let weights = profile.intervals.map {
            max(0, $0.endDistanceMeters - $0.startDistanceMeters)
        }
        let oracle = SwiftRouteMetricScaleBucketOracle.assign(
            metricValues: values,
            weightsMeters: weights,
            lowerQuantile: policy.lowerQuantile,
            upperQuantile: policy.upperQuantile,
            minimumScaleSpan: mode == .correctedElevation ? policy.minimumElevationSpanMeters : 0,
            minimumValidIntervalCount: policy.minimumValidIntervalCount,
            bucketCount: policy.bucketCount
        )

        XCTAssertEqual(profile.scale?.lowerBound, oracle.scale?.lowerBound)
        XCTAssertEqual(profile.scale?.median, oracle.scale?.median)
        XCTAssertEqual(profile.scale?.upperBound, oracle.scale?.upperBound)
        XCTAssertEqual(profile.validCoverageDistanceMeters, oracle.validCoverageDistanceMeters)
        XCTAssertEqual(profile.diagnostics.validIntervalCount, oracle.validIntervalCount)
        XCTAssertEqual(profile.diagnostics.noDataIntervalCount, oracle.noDataIntervalCount)
        XCTAssertEqual(profile.validCoverageFraction, totalDistance > 0
            ? min(1, max(0, oracle.validCoverageDistanceMeters / totalDistance))
            : 0)

        for index in profile.intervals.indices {
            let interval = profile.intervals[index]
            let expected = oracle.assignments[index]
            XCTAssertEqual(interval.normalizedValue, expected.normalizedValue)
            switch (interval.bucket, expected.bucketIndex) {
            case (.noData, nil): break
            case let (.level(actual), .some(expected)): XCTAssertEqual(actual, expected)
            default: XCTFail("bucket mismatch at \(index)")
            }
            XCTAssertEqual(interval.endPointIndex, interval.startPointIndex + 1)
            XCTAssertEqual(interval.routeSegmentIndex, workout.routePoints[interval.startPointIndex].routeSegmentIndex)
            XCTAssertEqual(interval.routeSegmentIndex, workout.routePoints[interval.endPointIndex].routeSegmentIndex)
            XCTAssertEqual(interval.startDistanceMeters, workout.routePoints[interval.startPointIndex].distanceFromStartMeters)
            XCTAssertEqual(interval.endDistanceMeters, max(
                interval.startDistanceMeters,
                workout.routePoints[interval.endPointIndex].distanceFromStartMeters
            ))
        }

        if let scale = profile.scale {
            assertScalePresentation(scale, mode: mode)
        }
    }

    private func assertScalePresentation(
        _ scale: RouteMetricScale,
        mode: WorkoutRouteColorMode
    ) {
        switch mode {
        case .pace:
            XCTAssertEqual(scale.direction, .lowerIsBetter)
            XCTAssertEqual(scale.lowerLabel, DisplayFormatter.formatPace(scale.lowerBound))
            XCTAssertEqual(scale.medianLabel, DisplayFormatter.formatPace(scale.median))
            XCTAssertEqual(scale.upperLabel, DisplayFormatter.formatPace(scale.upperBound))
        case .heartRate:
            XCTAssertEqual(scale.direction, .higherIsMore)
            XCTAssertEqual(scale.lowerLabel, DisplayFormatter.formatHeartRate(scale.lowerBound))
            XCTAssertEqual(scale.medianLabel, DisplayFormatter.formatHeartRate(scale.median))
            XCTAssertEqual(scale.upperLabel, DisplayFormatter.formatHeartRate(scale.upperBound))
        case .correctedElevation:
            XCTAssertEqual(scale.direction, .higherIsMore)
            XCTAssertEqual(scale.lowerLabel, DisplayFormatter.formatElevation(scale.lowerBound))
            XCTAssertEqual(scale.medianLabel, DisplayFormatter.formatElevation(scale.median))
            XCTAssertEqual(scale.upperLabel, DisplayFormatter.formatElevation(scale.upperBound))
        case .solid:
            XCTFail("solid mode has no scale")
        }
    }
}
