import Foundation
import XCTest
@testable import RunPlayCore

final class ElevationProfileTests: XCTestCase {
    func testFlatJitterDoesNotAccumulateMaterialGainOrLoss() throws {
        let jitter = [-1.0, 0, 1, 0]
        let points = (0...100).map { index in
            elevationPoint(
                distance: Double(index) * 10,
                altitude: 100 + jitter[index % jitter.count]
            )
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertTrue(profile.hasMeaningfulElevation)
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 1)
    }

    func testGradualHundredMeterClimbRemainsApproximatelyHundredMeters() throws {
        let points = (0...100).map { index in
            let fraction = Double(index) / 100
            return elevationPoint(distance: fraction * 1_000, altitude: fraction * 100)
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 100, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(profile.signedChange(from: 0, to: 1_000)), 100, accuracy: 3)
    }

    func testClimbFollowedByDescentReportsBothDirections() throws {
        let points = (0...200).map { index -> RoutePoint in
            let distance = Double(index) * 10
            let altitude = distance <= 1_000 ? distance / 10 : 200 - distance / 10
            return elevationPoint(distance: distance, altitude: altitude)
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 100, accuracy: 4)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 100, accuracy: 4)
        XCTAssertEqual(try XCTUnwrap(profile.signedChange(from: 0, to: 2_000)), 0, accuracy: 2)
    }

    func testBelowSeaLevelElevationSupportsGainAndLoss() throws {
        let points = [
            elevationPoint(distance: 0, altitude: -50),
            elevationPoint(distance: 500, altitude: -20),
            elevationPoint(distance: 1_000, altitude: -40)
        ]

        let profile = ElevationProfile(routePoints: points)

        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 20, accuracy: 0.001)
        XCTAssertEqual(profile.correctedAltitude(atPointIndex: 0), -50)
    }

    func testIsolatedAltitudeSpikeIsRejectedWithoutMutatingSourceAltitude() throws {
        let points = [
            elevationPoint(distance: 0, altitude: 100),
            elevationPoint(distance: 25, altitude: 100),
            elevationPoint(distance: 50, altitude: 500),
            elevationPoint(distance: 75, altitude: 100),
            elevationPoint(distance: 100, altitude: 100)
        ]

        let profile = ElevationProfile(routePoints: points)

        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 2))
        XCTAssertEqual(
            try XCTUnwrap(profile.correctedAltitude(atPointIndex: 2)),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(points[2].altitudeMeters, 500)
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 0, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 0.5)
    }

    func testExtremeTwoSampleAltitudeExcursionIsRejected() throws {
        let points = [100.0, 100, 500, 500, 100, 100].enumerated().map { index, altitude in
            elevationPoint(distance: Double(index) * 20, altitude: altitude)
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 2))
        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 3))
        XCTAssertNil(profile.correctedAltitude(atPointIndex: 2))
        XCTAssertNil(profile.correctedAltitude(atPointIndex: 3))
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 0, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 0.5)
        XCTAssertEqual(points[2].altitudeMeters, 500)
        XCTAssertEqual(points[3].altitudeMeters, 500)
    }

    func testExtremeLeadingAltitudeSpikeIsRejectedConservatively() throws {
        let points = [500.0, 100, 100, 100, 100].enumerated().map { index, altitude in
            elevationPoint(distance: Double(index) * 25, altitude: altitude)
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 0))
        XCTAssertNil(profile.correctedAltitude(atPointIndex: 0))
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 0.001)
        XCTAssertEqual(points[0].altitudeMeters, 500)
    }

    func testExtremeTrailingAltitudeSpikeIsRejectedConservatively() throws {
        let points = [100.0, 100, 100, 100, 500].enumerated().map { index, altitude in
            elevationPoint(distance: Double(index) * 25, altitude: altitude)
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 4))
        XCTAssertNil(profile.correctedAltitude(atPointIndex: 4))
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 0.001)
        XCTAssertEqual(points[4].altitudeMeters, 500)
    }

    func testSustainedEndpointClimbIsNotRejected() throws {
        let points = [100.0, 140, 180, 220].enumerated().map { index, altitude in
            elevationPoint(distance: Double(index) * 25, altitude: altitude)
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertFalse(profile.samples.contains { $0.sourceAltitudeWasRejected })
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 120, accuracy: 0.001)
    }

    func testExtremeSpikeAtSegmentStartIsRejected() throws {
        let points = [
            elevationPoint(distance: 0, altitude: 100, segment: 0),
            elevationPoint(distance: 25, altitude: 100, segment: 0),
            elevationPoint(distance: 50, altitude: 100, segment: 0),
            elevationPoint(distance: 50, altitude: 500, segment: 1),
            elevationPoint(distance: 75, altitude: 100, segment: 1),
            elevationPoint(distance: 100, altitude: 100, segment: 1)
        ]

        let profile = ElevationProfile(routePoints: points)

        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 3))
        XCTAssertNil(profile.correctedAltitude(atPointIndex: 3))
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 0.001)
    }

    func testExtremeSpikeAfterMissingAltitudeGapIsRejected() throws {
        let points = [
            elevationPoint(distance: 0, altitude: 100),
            elevationPoint(distance: 25, altitude: 100),
            elevationPoint(distance: 50, altitude: nil),
            elevationPoint(distance: 75, altitude: 500),
            elevationPoint(distance: 100, altitude: 100),
            elevationPoint(distance: 125, altitude: 100)
        ]

        let profile = ElevationProfile(routePoints: points)

        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 3))
        XCTAssertNil(profile.correctedAltitude(atPointIndex: 3))
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 0.001)
    }

    func testRejectedEndpointsDoNotBecomeBaselinesForInteriorRejection() throws {
        let points = [500.0, 100, 100, 500].enumerated().map { index, altitude in
            elevationPoint(distance: Double(index) * 25, altitude: altitude)
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 0))
        XCTAssertFalse(profile.sourceAltitudeWasRejected(atPointIndex: 1))
        XCTAssertFalse(profile.sourceAltitudeWasRejected(atPointIndex: 2))
        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 3))
        XCTAssertEqual(profile.correctedAltitude(atPointIndex: 1), 100)
        XCTAssertEqual(profile.correctedAltitude(atPointIndex: 2), 100)
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 0.001)
    }

    func testSustainedSteepClimbIsPreserved() throws {
        let points = (0...10).map { index in
            elevationPoint(
                distance: Double(index) * 10,
                altitude: Double(index) * 10
            )
        }

        let profile = ElevationProfile(routePoints: points)

        XCTAssertFalse(profile.samples.contains { $0.sourceAltitudeWasRejected })
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 100, accuracy: 4)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 0, accuracy: 1)
    }

    func testSwitchbackHillUsesTraveledSpanInsteadOfEndpointChord() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            RoutePoint(timestamp: start, latitude: 1, longitude: 103, altitudeMeters: 100, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: start.addingTimeInterval(60), latitude: 1.0015, longitude: 103.0015, altitudeMeters: 140, distanceFromStartMeters: 165, elapsedSeconds: 60),
            RoutePoint(timestamp: start.addingTimeInterval(120), latitude: 1.0009, longitude: 103, altitudeMeters: 100, distanceFromStartMeters: 330, elapsedSeconds: 120)
        ]

        let profile = ElevationProfile(routePoints: points)

        XCTAssertFalse(profile.sourceAltitudeWasRejected(atPointIndex: 1))
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 40, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 40, accuracy: 0.001)
    }

    func testCustomMinimumElevationHighlightWindowIsHonored() throws {
        let points = (0...4).map { index in
            elevationPoint(distance: Double(index) * 20, altitude: Double(index) * 10)
        }
        let workout = RunWorkout(routePoints: points)
        let policy = RouteQualityPolicy(
            elevationHighlightWindowRouteFraction: 1,
            elevationHighlightMinimumWindowMeters: 50,
            elevationHighlightMaximumWindowMeters: 50,
            elevationHighlightMinimumStepMeters: 10,
            elevationHighlightStepsPerWindow: 5
        )
        let context = WorkoutAnalysisContext(workout: workout, policy: policy)

        let segments = try SegmentDetector.detectSegments(
            from: workout,
            context: context,
            policy: policy,
            isCancelled: { false }
        )

        XCTAssertNotNil(segments.first { $0.type == .biggestClimb })
    }

    func testMissingAltitudeRemainsAGapAndIsNotInterpolated() throws {
        let policy = RouteQualityPolicy(elevationSmoothingRadiusMeters: 100)
        let points = [
            elevationPoint(distance: 0, altitude: 100),
            elevationPoint(distance: 10, altitude: 105),
            elevationPoint(distance: 20, altitude: nil),
            elevationPoint(distance: 30, altitude: 110),
            elevationPoint(distance: 40, altitude: 115)
        ]

        let profile = ElevationProfile(routePoints: points, policy: policy)

        XCTAssertNil(profile.correctedAltitude(atPointIndex: 2))
        XCTAssertNil(profile.correctedAltitude(atDistance: 20))
        XCTAssertFalse(profile.hasContinuousReliableElevation(from: 0, to: 40))
        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 10, accuracy: 0.001)
    }

    func testRouteSegmentsUseIndependentSmoothingAndGainLoss() throws {
        let policy = RouteQualityPolicy(elevationSmoothingRadiusMeters: 100)
        let points = [
            elevationPoint(distance: 0, altitude: 0, segment: 0),
            elevationPoint(distance: 50, altitude: 5, segment: 0),
            elevationPoint(distance: 100, altitude: 10, segment: 0),
            elevationPoint(distance: 100, altitude: 1_000, segment: 1),
            elevationPoint(distance: 150, altitude: 995, segment: 1),
            elevationPoint(distance: 200, altitude: 990, segment: 1)
        ]

        let profile = ElevationProfile(routePoints: points, policy: policy)

        XCTAssertEqual(try XCTUnwrap(profile.totalAscentMeters), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(profile.totalDescentMeters), 10, accuracy: 0.001)
        XCTAssertFalse(profile.hasContinuousReliableElevation(from: 0, to: 200))
        XCTAssertEqual(profile.correctedAltitude(atDistance: 100, boundary: .rangeEnd), 10)
        XCTAssertEqual(profile.correctedAltitude(atDistance: 100, boundary: .rangeStart), 1_000)
    }

    func testSamplesKeepExactPointIdentityDistanceAndMissingGapAlignment() {
        let points = [
            elevationPoint(distance: 0, altitude: 10),
            elevationPoint(distance: 25, altitude: nil),
            elevationPoint(distance: 50, altitude: 20)
        ]

        let profile = ElevationProfile(routePoints: points)

        XCTAssertEqual(profile.samples.map(\.routePointID), points.map(\.id))
        XCTAssertEqual(
            profile.samples.map(\.distanceFromStartMeters),
            points.map(\.distanceFromStartMeters)
        )
        XCTAssertNil(profile.samples[1].correctedAltitudeMeters)
    }

    func testDifferentSamplingFrequenciesProduceSimilarGainAndLoss() throws {
        let sparse = sampledHill(pointCount: 21)
        let dense = sampledHill(pointCount: 201)

        let sparseProfile = ElevationProfile(routePoints: sparse)
        let denseProfile = ElevationProfile(routePoints: dense)
        let sparseAscent = try XCTUnwrap(sparseProfile.totalAscentMeters)
        let denseAscent = try XCTUnwrap(denseProfile.totalAscentMeters)
        let sparseDescent = try XCTUnwrap(sparseProfile.totalDescentMeters)
        let denseDescent = try XCTUnwrap(denseProfile.totalDescentMeters)

        XCTAssertEqual(sparseAscent, denseAscent, accuracy: 3)
        XCTAssertEqual(sparseDescent, denseDescent, accuracy: 3)
    }

    func testEmptySinglePointAndSparseShortRoutesUseSafeFallbacks() throws {
        let empty = ElevationProfile(routePoints: [])
        XCTAssertTrue(empty.samples.isEmpty)
        XCTAssertFalse(empty.hasMeaningfulElevation)
        XCTAssertNil(empty.totalAscentMeters)
        XCTAssertNil(empty.totalDescentMeters)

        let single = ElevationProfile(routePoints: [elevationPoint(distance: 0, altitude: 12)])
        XCTAssertEqual(single.correctedAltitude(atPointIndex: 0), 12)
        XCTAssertFalse(single.hasMeaningfulElevation)
        XCTAssertNil(single.totalAscentMeters)

        let sparsePolicy = RouteQualityPolicy(minimumReliableAltitudeSampleCount: 3)
        let sparse = ElevationProfile(
            routePoints: [
                elevationPoint(distance: 0, altitude: 12),
                elevationPoint(distance: 10, altitude: 13)
            ],
            policy: sparsePolicy
        )
        XCTAssertEqual(sparse.samples.count, 2)
        XCTAssertEqual(sparse.correctedAltitude(atPointIndex: 1), 13)
        XCTAssertFalse(sparse.hasMeaningfulElevation)
        XCTAssertNil(sparse.totalAscentMeters)
    }

    func testHundredThousandPointProfileCompletesWithinLinearTimeBudget() throws {
        let pointCount = 100_000
        var points: [RoutePoint] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            points.append(elevationPoint(
                distance: Double(index) * 2,
                altitude: 100 + Double((index % 3) - 1)
            ))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let profile = ElevationProfile(routePoints: points)
        let duration = start.duration(to: clock.now)

        XCTAssertEqual(profile.samples.count, pointCount)
        XCTAssertTrue(profile.hasMeaningfulElevation)
        XCTAssertLessThan(duration, .seconds(20), "100,000-point elevation profile took \(duration)")
    }

    func testCancellationAfterElevationProcessingHasBegunStillPropagates() {
        let policy = RouteQualityPolicy(cancellationCheckStride: 100)
        let probe = CancellationProbe(cancelAfterCheckCount: 250)
        let points = (0..<20_000).map { index in
            elevationPoint(
                distance: Double(index) * 2,
                altitude: 100 + Double(index % 4)
            )
        }

        XCTAssertThrowsError(
            try ElevationProfile.build(
                routePoints: points,
                policy: policy,
                isCancelled: probe.shouldCancel
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(probe.checkCount, 250)
    }

    func testOutOfRangeAltitudeIsUnavailableWithoutMutatingSource() throws {
        let points = [
            elevationPoint(distance: 0, altitude: 20_000),
            elevationPoint(distance: 20, altitude: 20_001)
        ]

        let built = try ElevationProfile.build(
            routePoints: points,
            policy: .runningDefault,
            isCancelled: { false }
        )

        XCTAssertFalse(built.profile.hasMeaningfulElevation)
        XCTAssertNil(built.profile.correctedAltitude(atPointIndex: 0))
        XCTAssertNil(built.profile.correctedAltitude(atPointIndex: 1))
        XCTAssertEqual(built.rejectedAltitudeCount, 2)
        XCTAssertEqual(points[0].altitudeMeters, 20_000)
    }

    private func sampledHill(pointCount: Int) -> [RoutePoint] {
        (0..<pointCount).map { index in
            let fraction = Double(index) / Double(pointCount - 1)
            let distance = fraction * 1_000
            let altitude = 50 + 20 * sin(fraction * 2 * .pi)
            return elevationPoint(distance: distance, altitude: altitude)
        }
    }

    private func elevationPoint(
        distance: Double,
        altitude: Double?,
        segment: Int = 0,
        id: UUID = UUID()
    ) -> RoutePoint {
        RoutePoint(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + distance),
            latitude: 1 + distance / 111_132,
            longitude: 103,
            altitudeMeters: altitude,
            distanceFromStartMeters: distance,
            elapsedSeconds: distance,
            routeSegmentIndex: segment
        )
    }

    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let cancelAfterCheckCount: Int
        private var checks = 0

        init(cancelAfterCheckCount: Int) {
            self.cancelAfterCheckCount = cancelAfterCheckCount
        }

        var checkCount: Int {
            lock.withLock { checks }
        }

        func shouldCancel() -> Bool {
            lock.withLock {
                checks += 1
                return checks > cancelAfterCheckCount
            }
        }
    }
}
