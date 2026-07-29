import Foundation
import XCTest
@testable import RunPlayCore

final class RouteQualityProcessorTests: XCTestCase {
    private let processor = RouteQualityProcessor()

    func testCleanStraightRouteRemainsUnchanged() throws {
        let points = (0..<6).map { index in
            point(northMeters: Double(index) * 20, time: Double(index) * 10)
        }

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.id), points.map(\.id))
        XCTAssertEqual(result.routePoints.map(\.latitude), points.map(\.latitude))
        XCTAssertEqual(result.routePoints.map(\.longitude), points.map(\.longitude))
        XCTAssertEqual(result.diagnostics, .empty)
        XCTAssertEqual(result.distanceSource, .coordinateDerived)
    }

    func testNormalSharpTurnRemainsUnchanged() throws {
        let points = [
            point(northMeters: 0, eastMeters: 0, time: 0),
            point(northMeters: 30, eastMeters: 0, time: 10),
            point(northMeters: 30, eastMeters: 30, time: 20),
            point(northMeters: 60, eastMeters: 30, time: 30)
        ]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.id), points.map(\.id))
        XCTAssertEqual(result.diagnostics.discardedCoordinatePointCount, 0)
        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 0)
    }

    func testOutAndBackTurnaroundRemainsUnchanged() throws {
        let points = [
            point(northMeters: 0, time: 0),
            point(northMeters: 50, time: 10),
            point(northMeters: 0, time: 20)
        ]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.id), points.map(\.id))
        XCTAssertEqual(result.diagnostics.discardedCoordinatePointCount, 0)
    }

    func testIsolatedTeleportIsRemovedWithoutAccuracyData() throws {
        let points = isolatedTeleportPoints(spikeAccuracy: nil)

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.id), [points[0].id, points[2].id])
        XCTAssertEqual(result.diagnostics.discardedCoordinatePointCount, 1)
        XCTAssertTrue(result.analysisWarnings.contains(.coordinateOutliersRemoved))
    }

    func testIsolatedTeleportWithPoorAccuracyIsRemoved() throws {
        let points = isolatedTeleportPoints(spikeAccuracy: 250)

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.id), [points[0].id, points[2].id])
        XCTAssertEqual(result.diagnostics.discardedCoordinatePointCount, 1)
        XCTAssertEqual(points[1].horizontalAccuracy, 250)
    }

    func testInternallyCoherentHighSpeedSamplesRemain() throws {
        // Every step is 13 m/s, above the outlier-evidence threshold. The direct
        // bridge is equally fast, so no individual point is an isolated spike.
        let points = (0..<4).map { index in
            point(northMeters: Double(index) * 130, time: Double(index) * 10)
        }

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.id), points.map(\.id))
        XCTAssertEqual(result.diagnostics.discardedCoordinatePointCount, 0)
        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 0)
    }

    func testSustainedRelocatedClusterIntroducesOneCompactBoundary() throws {
        let points = [
            point(northMeters: 0, time: 0),
            point(northMeters: 20, time: 10),
            point(northMeters: 520, time: 20),
            point(northMeters: 540, time: 30),
            point(northMeters: 560, time: 40)
        ]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.id), points.map(\.id))
        XCTAssertEqual(result.routePoints.map(\.routeSegmentIndex), [0, 0, 1, 1, 1])
        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 1)
        XCTAssertTrue(result.analysisWarnings.contains(.implicitRouteGapIntroduced))
        XCTAssertEqual(result.routePoints[2].distanceFromStartMeters, result.routePoints[1].distanceFromStartMeters, accuracy: 0.5)
        XCTAssertEqual(result.routePoints.last?.distanceFromStartMeters ?? -1, 60, accuracy: 1)
    }

    func testLongTimestampGapWithoutGeographicJumpDoesNotCreateBoundary() throws {
        let points = [
            point(northMeters: 0, time: 0),
            point(northMeters: 20, time: 10),
            point(northMeters: 25, time: 310),
            point(northMeters: 30, time: 320)
        ]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(Set(result.routePoints.map(\.routeSegmentIndex)), [0])
        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 0)
    }

    func testLongTimestampGapWithCoherentRelocationCreatesBoundary() throws {
        let points = [
            point(northMeters: 0, time: 0),
            point(northMeters: 20, time: 10),
            point(northMeters: 520, time: 310),
            point(northMeters: 540, time: 320),
            point(northMeters: 560, time: 330)
        ]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.routeSegmentIndex), [0, 0, 1, 1, 1])
        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 1)
    }

    func testExplicitRouteSegmentBoundaryIsPreservedWithoutDuplicateInference() throws {
        let points = [
            point(northMeters: 0, time: 0, segment: 0),
            point(northMeters: 20, time: 10, segment: 0),
            point(northMeters: 1_000, time: 20, segment: 1),
            point(northMeters: 1_020, time: 30, segment: 1),
            point(northMeters: 1_040, time: 40, segment: 1)
        ]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.routeSegmentIndex), [0, 0, 1, 1, 1])
        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 0)
    }

    func testFirstAndLastAnomaliesAreRetainedConservatively() throws {
        let leading = [
            point(northMeters: 1_000, time: 0),
            point(northMeters: 0, time: 10),
            point(northMeters: 20, time: 20),
            point(northMeters: 40, time: 30)
        ]
        let trailing = [
            point(northMeters: 0, time: 0),
            point(northMeters: 20, time: 10),
            point(northMeters: 40, time: 20),
            point(northMeters: 1_000, time: 30)
        ]

        let leadingResult = try processor.process(leading, sortByTimestamp: false)
        let trailingResult = try processor.process(trailing, sortByTimestamp: false)

        XCTAssertEqual(leadingResult.routePoints.map(\.id), leading.map(\.id))
        XCTAssertEqual(trailingResult.routePoints.map(\.id), trailing.map(\.id))
        XCTAssertEqual(leadingResult.diagnostics.discardedCoordinatePointCount, 0)
        XCTAssertEqual(trailingResult.diagnostics.discardedCoordinatePointCount, 0)
    }

    func testSparseCadenceRelocatedClusterStillCreatesBoundary() throws {
        let points = [
            point(northMeters: 0, time: 0),
            point(northMeters: 20, time: 10),
            point(northMeters: 520, time: 300),
            point(northMeters: 820, time: 360),
            point(northMeters: 1_120, time: 420)
        ]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.routeSegmentIndex), [0, 0, 1, 1, 1])
        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 1)
        XCTAssertEqual(
            result.routePoints[2].distanceFromStartMeters,
            result.routePoints[1].distanceFromStartMeters,
            accuracy: 0.5
        )
    }

    func testUniformSparseCadenceDoesNotCreateFalseBoundaries() throws {
        let points = (0..<6).map { index in
            point(
                northMeters: Double(index) * 500,
                time: Double(index) * 300
            )
        }

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(Set(result.routePoints.map(\.routeSegmentIndex)), [0])
        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 0)
    }

    func testInferredGapPreservesMixedDistanceProvenanceBySourceSegment() throws {
        let points = [
            point(northMeters: 0, time: 0, suppliedDistance: 0, segment: 0),
            point(northMeters: 20, time: 10, suppliedDistance: 20, segment: 0),
            point(northMeters: 520, time: 20, suppliedDistance: 520, segment: 0),
            point(northMeters: 540, time: 30, suppliedDistance: 540, segment: 0),
            point(northMeters: 560, time: 40, suppliedDistance: 560, segment: 0),
            point(northMeters: 2_000, time: 50, suppliedDistance: 1_000, segment: 1),
            point(northMeters: 2_020, time: 60, suppliedDistance: 1_100, segment: 1)
        ]

        let result = try processor.process(
            points,
            distancePolicy: .useSuppliedDistancesForSegments([1]),
            sortByTimestamp: false
        )

        XCTAssertEqual(result.routePoints.map(\.routeSegmentIndex), [0, 0, 1, 1, 1, 2, 2])
        XCTAssertEqual(
            result.distanceProvenance.segmentSources,
            [.coordinateDerived, .coordinateDerived, .deviceSupplied]
        )
        XCTAssertEqual(result.routePoints.last?.distanceFromStartMeters ?? -1, 160, accuracy: 2)
    }

    func testSuppliedDistanceSurvivesCoordinateCleanupWhileComputedDistanceExcludesSpike() throws {
        let points = [
            point(northMeters: 0, time: 0, suppliedDistance: 100),
            point(northMeters: 1_000, time: 10, suppliedDistance: 200),
            point(northMeters: 20, time: 20, suppliedDistance: 300)
        ]

        let supplied = try processor.process(
            points,
            distancePolicy: .useSuppliedDistancesWhenValid,
            sortByTimestamp: false
        )
        let computed = try processor.process(
            points,
            distancePolicy: .computeFromCoordinates,
            sortByTimestamp: false
        )

        XCTAssertEqual(supplied.routePoints.map(\.id), [points[0].id, points[2].id])
        XCTAssertEqual(supplied.routePoints.last?.distanceFromStartMeters ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(supplied.distanceSource, .deviceSupplied)

        XCTAssertEqual(computed.routePoints.map(\.id), [points[0].id, points[2].id])
        XCTAssertEqual(computed.routePoints.last?.distanceFromStartMeters ?? -1, 20, accuracy: 1)
        XCTAssertEqual(computed.distanceSource, .coordinateDerived)
    }

    func testRetainedPointIDsStayStableAfterFiltering() throws {
        let points = isolatedTeleportPoints(spikeAccuracy: nil)
        let retainedIDs = [points[0].id, points[2].id]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertEqual(result.routePoints.map(\.id), retainedIDs)
        XCTAssertFalse(result.routePoints.contains { $0.id == points[1].id })
    }

    func testImpossibleSourceSpeedAndItsPaceAreRejectedButLegitimateSprintIsPreserved() throws {
        let points = [
            point(
                northMeters: 0,
                time: 0,
                speedMetersPerSecond: 25,
                paceSecondsPerKilometer: 40
            ),
            point(
                northMeters: 140,
                time: 10,
                speedMetersPerSecond: 14,
                paceSecondsPerKilometer: 1_000 / 14
            )
        ]

        let result = try processor.process(points, sortByTimestamp: false)

        XCTAssertNil(result.routePoints[0].speedMetersPerSecond)
        XCTAssertNil(result.routePoints[0].paceSecondsPerKilometer)
        XCTAssertEqual(result.routePoints[1].speedMetersPerSecond ?? -1, 14, accuracy: 0.001)
        XCTAssertEqual(result.diagnostics.invalidSourceSpeedSampleCount, 1)
    }

    func testStaleZeroSourceSpeedIsReplacedByDerivedMovementSpeed() throws {
        var workout = RunWorkout(routePoints: [
            point(northMeters: 0, time: 0),
            point(northMeters: 30, time: 10, speedMetersPerSecond: 0)
        ])

        try WorkoutAnalyzer().normalizeAndAnalyze(
            &workout,
            distancePolicy: .computeFromCoordinates
        )

        XCTAssertEqual(workout.routePoints[1].speedMetersPerSecond ?? -1, 3, accuracy: 0.05)
        XCTAssertEqual(
            workout.routePoints[1].paceSecondsPerKilometer ?? -1,
            1_000 / 3,
            accuracy: 5
        )
        XCTAssertEqual(workout.qualityDiagnostics.invalidSourceSpeedSampleCount, 1)
    }

    func testPositiveSourceSpeedOnStationaryIntervalIsDiscarded() throws {
        let result = try RouteQualityProcessor().process([
            point(northMeters: 0, time: 0),
            point(northMeters: 0, time: 10, speedMetersPerSecond: 3)
        ])

        XCTAssertNil(result.routePoints[1].speedMetersPerSecond)
        XCTAssertNil(result.routePoints[1].paceSecondsPerKilometer)
        XCTAssertEqual(result.diagnostics.invalidSourceSpeedSampleCount, 1)
    }

    func testImpossibleDerivedSpeedFromSuppliedDistanceRemainsUnavailable() throws {
        var workout = RunWorkout(routePoints: [
            point(northMeters: 0, time: 0, suppliedDistance: 0),
            point(northMeters: 10, time: 1, suppliedDistance: 1_000)
        ])

        try WorkoutAnalyzer().normalizeAndAnalyze(
            &workout,
            distancePolicy: .useSuppliedDistancesWhenValid
        )

        XCTAssertNil(workout.routePoints[1].speedMetersPerSecond)
        XCTAssertNil(workout.routePoints[1].paceSecondsPerKilometer)
        XCTAssertEqual(workout.summary.averageSpeedMetersPerSecond, 0)
        XCTAssertEqual(workout.summary.averagePaceSecondsPerKilometer, 0)
    }

    func testHeartRateAndCadenceRemainSourceValues() throws {
        var first = point(northMeters: 0, time: 0)
        first.heartRateBPM = .infinity
        first.cadence = -12
        var second = point(northMeters: 20, time: 10)
        second.heartRateBPM = 500
        second.cadence = 0

        let result = try processor.process([first, second], sortByTimestamp: false)

        XCTAssertEqual(result.routePoints[0].heartRateBPM, .infinity)
        XCTAssertEqual(result.routePoints[0].cadence, -12)
        XCTAssertEqual(result.routePoints[1].heartRateBPM, 500)
        XCTAssertEqual(result.routePoints[1].cadence, 0)
    }

    func testMalformedCoordinatesAndAltitudesDoNotTrap() throws {
        var invalidCoordinate = point(northMeters: 0, time: 0)
        invalidCoordinate.latitude = .nan
        var nonFiniteAltitude = point(northMeters: 10, time: 10)
        nonFiniteAltitude.altitudeMeters = .infinity
        var outOfRangeAltitude = point(northMeters: 20, time: 20)
        outOfRangeAltitude.altitudeMeters = 20_000

        let result = try processor.process(
            [invalidCoordinate, nonFiniteAltitude, outOfRangeAltitude],
            sortByTimestamp: false
        )

        XCTAssertEqual(result.routePoints.count, 2)
        XCTAssertNil(result.routePoints[0].altitudeMeters)
        XCTAssertEqual(result.routePoints[1].altitudeMeters, 20_000)
        XCTAssertEqual(result.diagnostics.invalidCoordinatePointCount, 1)
        XCTAssertEqual(result.diagnostics.discardedAltitudeSampleCount, 2)
        XCTAssertTrue(result.analysisWarnings.contains(.insufficientReliableElevation))
    }

    func testCancellationPropagatesAsCancellationError() {
        let policy = RouteQualityPolicy(cancellationCheckStride: 1)
        let processor = RouteQualityProcessor(policy: policy)
        let points = (0..<10).map { index in
            point(northMeters: Double(index) * 10, time: Double(index))
        }

        XCTAssertThrowsError(
            try processor.process(points, sortByTimestamp: false, isCancelled: { true })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationAfterCoordinateProcessingHasBegunStillPropagates() {
        let policy = RouteQualityPolicy(cancellationCheckStride: 100)
        let processor = RouteQualityProcessor(policy: policy)
        let probe = CancellationProbe(cancelAfterCheckCount: 650)
        let points = (0..<20_000).map { index in
            point(northMeters: Double(index) * 2, time: Double(index))
        }

        XCTAssertThrowsError(
            try processor.process(
                points,
                sortByTimestamp: false,
                isCancelled: probe.shouldCancel
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(probe.checkCount, 650)
    }

    func testCancellationAfterQualityPassLeavesWorkoutUnchanged() throws {
        let policy = RouteQualityPolicy(cancellationCheckStride: 1)
        let points = (0..<100).map { index in
            point(northMeters: Double(index) * 2, time: Double(index))
        }
        let qualityProbe = CancellationProbe(cancelAfterCheckCount: .max)
        _ = try RouteQualityProcessor(policy: policy).process(
            points,
            sortByTimestamp: false,
            isCancelled: qualityProbe.shouldCancel
        )

        var workout = RunWorkout(routePoints: points)
        let original = workout
        let analysisProbe = CancellationProbe(
            cancelAfterCheckCount: qualityProbe.checkCount
        )

        XCTAssertThrowsError(
            try WorkoutAnalyzer().normalizeAndAnalyze(
                &workout,
                distancePolicy: .computeFromCoordinates,
                policy: policy,
                isCancelled: analysisProbe.shouldCancel
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(workout, original)
    }

    func testHundredThousandPointRouteCompletesWithinLinearTimeBudget() throws {
        let pointCount = 100_000
        var points: [RoutePoint] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            points.append(point(
                northMeters: Double(index) * 10,
                time: Double(index),
                suppliedDistance: Double(index) * 10
            ))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let result = try processor.process(points, sortByTimestamp: false)
        let duration = start.duration(to: clock.now)

        XCTAssertEqual(result.routePoints.count, pointCount)
        let expectedDistance = GeoDistance.distanceMeters(
            fromLat: points[0].latitude,
            lon: points[0].longitude,
            toLat: points[pointCount - 1].latitude,
            lon: points[pointCount - 1].longitude
        )
        XCTAssertEqual(
            result.routePoints.last?.distanceFromStartMeters ?? -1,
            expectedDistance,
            accuracy: 1
        )
        XCTAssertLessThan(duration, .seconds(20), "100,000-point processing took \(duration)")
    }

    // MARK: - C++ step-distance production cutover

    func testCoordinateDerivedRouteUsesBulkNativeSteps() throws {
        let points = (0..<5).map { index in
            point(northMeters: Double(index) * 25, time: Double(index) * 10)
        }
        let result = try processor.process(
            points,
            distancePolicy: .computeFromCoordinates,
            sortByTimestamp: false
        )

        XCTAssertEqual(result.routePoints.map(\.id), points.map(\.id))
        XCTAssertEqual(result.distanceSource, .coordinateDerived)
        XCTAssertEqual(
            result.distanceProvenance.segmentSources,
            [.coordinateDerived]
        )
        var expected = 0.0
        for index in 1..<points.count {
            expected += GeoDistance.distanceMeters(
                fromLat: points[index - 1].latitude,
                lon: points[index - 1].longitude,
                toLat: points[index].latitude,
                lon: points[index].longitude
            )
            XCTAssertEqual(
                result.routePoints[index].distanceFromStartMeters,
                expected,
                accuracy: max(1e-6, abs(expected) * 1e-12)
            )
        }
    }

    func testMultipleCoordinateDerivedSegmentsResetAtBoundaries() throws {
        let points = [
            point(northMeters: 0, time: 0, segment: 0),
            point(northMeters: 40, time: 10, segment: 0),
            point(northMeters: 200, time: 20, segment: 1),
            point(northMeters: 250, time: 30, segment: 1),
        ]
        let result = try processor.process(
            points,
            distancePolicy: .computeFromCoordinates,
            sortByTimestamp: false
        )

        XCTAssertEqual(result.routePoints.map(\.routeSegmentIndex), [0, 0, 1, 1])
        XCTAssertEqual(
            result.routePoints[2].distanceFromStartMeters,
            result.routePoints[1].distanceFromStartMeters,
            accuracy: 0.001
        )
        let secondSegmentStep = GeoDistance.distanceMeters(
            fromLat: points[2].latitude,
            lon: points[2].longitude,
            toLat: points[3].latitude,
            lon: points[3].longitude
        )
        XCTAssertEqual(
            result.routePoints[3].distanceFromStartMeters,
            result.routePoints[2].distanceFromStartMeters + secondSegmentStep,
            accuracy: max(1e-6, abs(secondSegmentStep) * 1e-12)
        )
        XCTAssertEqual(result.distanceSource, .coordinateDerived)
    }

    func testFullySuppliedDistanceRouteSkipsNativeStepDependency() throws {
        let points = (0..<4).map { index in
            point(
                northMeters: Double(index) * 100,
                time: Double(index) * 10,
                suppliedDistance: Double(index) * 50
            )
        }
        let result = try processor.process(
            points,
            distancePolicy: .useSuppliedDistancesWhenValid,
            sortByTimestamp: false
        )

        XCTAssertEqual(result.distanceSource, .deviceSupplied)
        XCTAssertEqual(
            result.distanceProvenance.segmentSources,
            [.deviceSupplied]
        )
        XCTAssertEqual(result.routePoints.map(\.distanceFromStartMeters), [0, 50, 100, 150])
    }

    func testMixedSuppliedAndCoordinateDerivedSegments() throws {
        let points = [
            point(northMeters: 0, time: 0, suppliedDistance: 0, segment: 0),
            point(northMeters: 30, time: 10, suppliedDistance: 30, segment: 0),
            point(northMeters: 100, time: 20, suppliedDistance: 1_000, segment: 1),
            point(northMeters: 160, time: 30, suppliedDistance: 1_100, segment: 1),
        ]
        let result = try processor.process(
            points,
            distancePolicy: .useSuppliedDistancesForSegments([1]),
            sortByTimestamp: false
        )

        XCTAssertEqual(result.distanceSource, .mixed)
        XCTAssertEqual(
            result.distanceProvenance.segmentSources,
            [.coordinateDerived, .deviceSupplied]
        )
        let firstSegment = GeoDistance.distanceMeters(
            fromLat: points[0].latitude,
            lon: points[0].longitude,
            toLat: points[1].latitude,
            lon: points[1].longitude
        )
        XCTAssertEqual(
            result.routePoints[1].distanceFromStartMeters,
            firstSegment,
            accuracy: max(1e-6, abs(firstSegment) * 1e-12)
        )
        XCTAssertEqual(
            result.routePoints[2].distanceFromStartMeters,
            result.routePoints[1].distanceFromStartMeters,
            accuracy: 0.001
        )
        XCTAssertEqual(
            result.routePoints[3].distanceFromStartMeters,
            result.routePoints[2].distanceFromStartMeters + 100,
            accuracy: 0.001
        )
    }

    func testDuplicateCoordinatesProduceZeroStepDistance() throws {
        let points = [
            point(northMeters: 0, time: 0),
            point(northMeters: 0, time: 10),
            point(northMeters: 25, time: 20),
        ]
        let result = try processor.process(
            points,
            distancePolicy: .computeFromCoordinates,
            sortByTimestamp: false
        )

        XCTAssertEqual(result.routePoints[1].distanceFromStartMeters, 0, accuracy: 1e-9)
        XCTAssertEqual(
            result.routePoints[2].distanceFromStartMeters,
            GeoDistance.distanceMeters(
                fromLat: points[1].latitude,
                lon: points[1].longitude,
                toLat: points[2].latitude,
                lon: points[2].longitude
            ),
            accuracy: 1e-6
        )
    }

    func testInferredGapStillUsesCoordinateDerivedNativeSteps() throws {
        let points = [
            point(northMeters: 0, time: 0),
            point(northMeters: 20, time: 10),
            point(northMeters: 520, time: 20),
            point(northMeters: 540, time: 30),
            point(northMeters: 560, time: 40),
        ]
        let result = try processor.process(
            points,
            distancePolicy: .computeFromCoordinates,
            sortByTimestamp: false
        )

        XCTAssertEqual(result.diagnostics.inferredRouteGapCount, 1)
        XCTAssertEqual(result.routePoints.map(\.routeSegmentIndex), [0, 0, 1, 1, 1])
        XCTAssertEqual(
            result.routePoints[2].distanceFromStartMeters,
            result.routePoints[1].distanceFromStartMeters,
            accuracy: 0.5
        )
        XCTAssertEqual(result.distanceSource, .coordinateDerived)
    }

    func testInvalidCoordinatesRemovedBeforeDistanceNormalization() throws {
        var points = (0..<4).map { index in
            point(northMeters: Double(index) * 20, time: Double(index) * 10)
        }
        points.insert(
            RoutePoint(
                timestamp: Date(timeIntervalSince1970: 1_700_000_005),
                latitude: .nan,
                longitude: 103,
                altitudeMeters: nil,
                distanceFromStartMeters: 0,
                elapsedSeconds: 5,
                routeSegmentIndex: 0
            ),
            at: 1
        )

        let result = try processor.process(
            points,
            distancePolicy: .computeFromCoordinates,
            sortByTimestamp: false
        )

        XCTAssertEqual(result.diagnostics.invalidCoordinatePointCount, 1)
        XCTAssertEqual(result.routePoints.count, 4)
        XCTAssertEqual(result.distanceSource, .coordinateDerived)
        XCTAssertGreaterThan(result.routePoints.last?.distanceFromStartMeters ?? 0, 0)
    }

    func testSourceSpeedValidationStillUsesNormalizedDistances() throws {
        let points = [
            point(
                northMeters: 0,
                time: 0,
                speedMetersPerSecond: 25,
                paceSecondsPerKilometer: 40
            ),
            point(
                northMeters: 140,
                time: 10,
                speedMetersPerSecond: 14,
                paceSecondsPerKilometer: 1_000 / 14
            ),
        ]
        let result = try processor.process(points, sortByTimestamp: false)
        XCTAssertNil(result.routePoints[0].speedMetersPerSecond)
        XCTAssertEqual(result.routePoints[1].speedMetersPerSecond ?? -1, 14, accuracy: 0.001)
    }

    func testCancellationDuringNativeDistancePassPropagates() throws {
        let policy = RouteQualityPolicy(cancellationCheckStride: 1)
        let points = (0..<200).map { index in
            point(northMeters: Double(index) * 2, time: Double(index))
        }
        // Cancel on the first cancellation probe of the native step-distance pass.
        // Earlier stages still check cancellation; a low threshold is enough to
        // prove CancellationError still propagates for coordinate-derived routes.
        let probe = CancellationProbe(cancelAfterCheckCount: 5)

        XCTAssertThrowsError(
            try RouteQualityProcessor(policy: policy).process(
                points,
                distancePolicy: .computeFromCoordinates,
                sortByTimestamp: false,
                isCancelled: probe.shouldCancel
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(probe.checkCount, 5)
    }

    private func isolatedTeleportPoints(spikeAccuracy: Double?) -> [RoutePoint] {
        [
            point(northMeters: 0, time: 0, horizontalAccuracy: spikeAccuracy == nil ? nil : 5),
            point(northMeters: 1_000, time: 10, horizontalAccuracy: spikeAccuracy),
            point(northMeters: 20, time: 20, horizontalAccuracy: spikeAccuracy == nil ? nil : 5)
        ]
    }

    private func point(
        northMeters: Double,
        eastMeters: Double = 0,
        time: Double,
        suppliedDistance: Double = 0,
        altitudeMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        paceSecondsPerKilometer: Double? = nil,
        horizontalAccuracy: Double? = nil,
        segment: Int = 0,
        id: UUID = UUID()
    ) -> RoutePoint {
        let originLatitude = 1.0
        let originLongitude = 103.0
        let latitude = originLatitude + northMeters / 111_132
        let longitudeScale = 111_320 * cos(originLatitude * .pi / 180)
        let longitude = originLongitude + eastMeters / longitudeScale
        return RoutePoint(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + time),
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: altitudeMeters,
            distanceFromStartMeters: suppliedDistance,
            elapsedSeconds: time,
            speedMetersPerSecond: speedMetersPerSecond,
            paceSecondsPerKilometer: paceSecondsPerKilometer,
            horizontalAccuracy: horizontalAccuracy,
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
