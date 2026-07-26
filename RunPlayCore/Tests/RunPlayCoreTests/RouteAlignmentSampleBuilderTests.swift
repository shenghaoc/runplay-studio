import XCTest
@testable import RunPlayCore

final class RouteAlignmentSampleBuilderTests: XCTestCase {
    private let builder = RouteAlignmentSampleBuilder()
    private let policy = RouteAlignmentPolicy.default

    func testEvenlySampledRouteProducesEndpointsAndIntervalSamples() throws {
        let workout = makeLinearWorkout(distanceMeters: 2_000, stepMeters: 50)
        let pair = try builder.build(primary: workout, comparison: workout, policy: policy)
        XCTAssertGreaterThanOrEqual(pair.primary.count, policy.minimumSamplesPerRoute)
        XCTAssertEqual(pair.primary.first?.distanceFromStartMeters ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(pair.primary.last?.distanceFromStartMeters ?? -1, 2_000, accuracy: 1)
        XCTAssertLessThanOrEqual(pair.primary.count, policy.maximumSamplesPerRoute)
        XCTAssertEqual(pair.effectiveSampleIntervalMeters, policy.preferredSampleIntervalMeters, accuracy: 0.01)
    }

    func testAdaptiveIntervalRespectsMaximumSampleCap() throws {
        // 100k-class distance would exceed 2000 samples at 20 m without coarsening.
        let long = makeLinearWorkout(distanceMeters: 80_000, stepMeters: 100)
        let pair = try builder.build(primary: long, comparison: long, policy: policy)
        XCTAssertLessThanOrEqual(pair.primary.count, policy.maximumSamplesPerRoute)
        XCTAssertGreaterThan(pair.effectiveSampleIntervalMeters, policy.preferredSampleIntervalMeters)
    }

    func testMultipleRouteSegmentsDoNotInterpolateAcrossGaps() throws {
        let start = Date()
        var points: [RoutePoint] = []
        // Segment 0: 0–1000 m
        for i in 0...10 {
            let d = Double(i) * 100
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: 37.77 + d * 0.00001,
                longitude: -122.42,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                routeSegmentIndex: 0
            ))
        }
        // Segment 1: continues distance after gap
        for i in 0...10 {
            let d = 1_200 + Double(i) * 100
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: 37.78 + Double(i) * 0.00001,
                longitude: -122.42,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                routeSegmentIndex: 1
            ))
        }
        let workout = RunWorkout(routePoints: points)
        let pair = try builder.build(primary: workout, comparison: workout, policy: policy)
        let segments = Set(pair.primary.map(\.routeSegmentIndex))
        XCTAssertEqual(segments, Set([0, 1]))
        // No sample should sit strictly between 1000 and 1200 with synthetic segment bridging.
        let midGap = pair.primary.filter { $0.distanceFromStartMeters > 1000 && $0.distanceFromStartMeters < 1200 }
        XCTAssertTrue(midGap.isEmpty)
    }

    func testInvalidCoordinatesAreDropped() throws {
        let start = Date()
        let points = [
            RoutePoint(timestamp: start, latitude: 37.77, longitude: -122.42, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: start.addingTimeInterval(30), latitude: .nan, longitude: -122.42, distanceFromStartMeters: 100, elapsedSeconds: 30),
            RoutePoint(timestamp: start.addingTimeInterval(60), latitude: 37.78, longitude: -122.42, distanceFromStartMeters: 1_000, elapsedSeconds: 300),
            RoutePoint(timestamp: start.addingTimeInterval(90), latitude: 37.79, longitude: -122.42, distanceFromStartMeters: 2_000, elapsedSeconds: 600)
        ]
        let workout = RunWorkout(routePoints: points)
        let pair = try builder.build(primary: workout, comparison: workout, policy: policy)
        XCTAssertFalse(pair.primary.isEmpty)
        XCTAssertTrue(pair.primary.allSatisfy { $0.xMeters.isFinite && $0.zMeters.isFinite })
    }

    func testCancellationThrows() {
        let workout = makeLinearWorkout(distanceMeters: 5_000, stepMeters: 25)
        XCTAssertThrowsError(
            try builder.build(primary: workout, comparison: workout, policy: policy, isCancelled: { true })
        ) { error in
            XCTAssertEqual(error as? RouteAlignmentSampleError, .cancelled)
        }
    }

    func testInsufficientRouteDataFails() {
        let short = makeLinearWorkout(distanceMeters: 100, stepMeters: 50)
        XCTAssertThrowsError(
            try builder.build(primary: short, comparison: short, policy: policy)
        )
    }

    func testPolicyDefaultsAreDocumented() {
        let p = RouteAlignmentPolicy.default
        XCTAssertEqual(p.preferredSampleIntervalMeters, 20)
        XCTAssertEqual(p.maximumSamplesPerRoute, 2_000)
        XCTAssertEqual(p.minimumSamplesPerRoute, 20)
        XCTAssertEqual(p.minimumAlignedDistanceMeters, 500)
        XCTAssertEqual(p.bandWidthFraction, 0.15, accuracy: 0.0001)
        XCTAssertEqual(p.maximumUnmatchedPrefixSuffixMeters, 500)
        XCTAssertEqual(p.maximumUnmatchedPrefixSuffixFraction, 0.10, accuracy: 0.0001)
        XCTAssertEqual(p.maximumConsecutiveWarpSteps, 6)
        XCTAssertEqual(p.minimumCoverageFraction, 0.70, accuracy: 0.0001)
        XCTAssertEqual(p.goodMedianSeparationMeters, 35)
        XCTAssertEqual(p.acceptableMedianSeparationMeters, 75)
        XCTAssertEqual(p.maximumAcceptedP90SeparationMeters, 200)
        XCTAssertEqual(p.algorithmVersion, 1)
    }

    // MARK: - Helpers

    private func makeLinearWorkout(distanceMeters: Double, stepMeters: Double) -> RunWorkout {
        let start = Date()
        var points: [RoutePoint] = []
        var d = 0.0
        var i = 0
        while d <= distanceMeters {
            // ~1 m north per metre of distance at this scale approximation via lat delta.
            let lat = 37.7749 + (d / 111_000)
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: lat,
                longitude: -122.4194,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            i += 1
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + stepMeters)
            if i > 200_000 { break }
        }
        return RunWorkout(routePoints: points)
    }
}
