import Foundation
import XCTest
@testable import RunPlayCore

final class PersonalHeatmapAggregationOptimizationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testCellIDHashingPreservesCoordinateIdentityAndDictionaryUpdates() {
        let originID = PersonalHeatmapCellID(x: 0, y: 0)
        let xChanged = PersonalHeatmapCellID(x: 1, y: 0)
        let yChanged = PersonalHeatmapCellID(x: 0, y: 1)
        let negative = PersonalHeatmapCellID(x: -1, y: -1)
        let extremes = PersonalHeatmapCellID(x: .min, y: .max)

        XCTAssertEqual(Set([originID, xChanged, yChanged, negative, extremes]).count, 5)

        var counts: [PersonalHeatmapCellID: Int] = [:]
        for id in [originID, xChanged, yChanged, negative, extremes] {
            counts[id, default: 0] += 1
            counts[id, default: 0] += 1
        }

        XCTAssertEqual(counts.count, 5)
        XCTAssertTrue(counts.values.allSatisfy { $0 == 2 })
    }

    func testCellIDCodableAndYThenXOrderingRemainStable() throws {
        let id = PersonalHeatmapCellID(x: .min, y: .max)
        let data = try JSONEncoder().encode(id)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: NSNumber]
        )

        XCTAssertEqual(Set(object.keys), ["x", "y"])
        XCTAssertEqual(object["x"]?.int64Value, .min)
        XCTAssertEqual(object["y"]?.int64Value, .max)
        XCTAssertEqual(try JSONDecoder().decode(PersonalHeatmapCellID.self, from: data), id)

        let ordered = [
            PersonalHeatmapCellID(x: 4, y: 1),
            PersonalHeatmapCellID(x: -2, y: 0),
            PersonalHeatmapCellID(x: 3, y: 0),
            PersonalHeatmapCellID(x: -5, y: 1)
        ].sorted()
        XCTAssertEqual(
            ordered,
            [
                PersonalHeatmapCellID(x: -2, y: 0),
                PersonalHeatmapCellID(x: 3, y: 0),
                PersonalHeatmapCellID(x: -5, y: 1),
                PersonalHeatmapCellID(x: 4, y: 1)
            ]
        )
    }

    func testCellIDDictionaryHandlesOneHundredThousandDeterministicKeys() {
        let keyCount = 100_000
        var values: [PersonalHeatmapCellID: Int] = [:]
        values.reserveCapacity(keyCount)

        for index in 0..<keyCount {
            let id = PersonalHeatmapCellID(
                x: Int64(index % 1_000) - 500,
                y: Int64(index / 1_000) - 50
            )
            values[id, default: 0] += 1
            values[id, default: 0] += 1
        }

        XCTAssertEqual(values.count, keyCount)
        for index in 0..<keyCount {
            let id = PersonalHeatmapCellID(
                x: Int64(index % 1_000) - 500,
                y: Int64(index / 1_000) - 50
            )
            XCTAssertEqual(values[id], 2)
        }
    }

    func testCapacityPolicyInitialAndLaterHintsAreBounded() {
        typealias Policy = PersonalHeatmapAggregationCapacityPolicy

        XCTAssertEqual(
            Policy.initialHint(cappedTotalRoutePointCount: 0, maximumRenderedCellCount: 5_000),
            64
        )
        XCTAssertEqual(
            Policy.initialHint(cappedTotalRoutePointCount: 17, maximumRenderedCellCount: 5_000),
            64
        )
        XCTAssertEqual(
            Policy.initialHint(cappedTotalRoutePointCount: 1_000, maximumRenderedCellCount: 10),
            640
        )
        XCTAssertEqual(
            Policy.initialHint(
                cappedTotalRoutePointCount: Int.max,
                maximumRenderedCellCount: Int.max
            ),
            262_144
        )
        XCTAssertEqual(
            Policy.renderedBudgetBound(maximumRenderedCellCount: Int.max),
            262_144
        )
        XCTAssertEqual(
            Policy.laterPassHint(previousAggregatedCellCount: 0, maximumRenderedCellCount: 5_000),
            64
        )
        XCTAssertEqual(
            Policy.laterPassHint(previousAggregatedCellCount: 129, maximumRenderedCellCount: 5_000),
            65
        )
        XCTAssertEqual(
            Policy.laterPassHint(previousAggregatedCellCount: 131, maximumRenderedCellCount: 5_000),
            66
        )
        XCTAssertEqual(
            Policy.laterPassHint(
                previousAggregatedCellCount: Int.max,
                maximumRenderedCellCount: Int.max
            ),
            262_144
        )
        XCTAssertEqual(
            Policy.laterPassHint(previousAggregatedCellCount: -1, maximumRenderedCellCount: 0),
            64
        )
    }

    func testCapacityPolicyCapsDateEligibleRoutePointTotal() {
        XCTAssertEqual(
            PersonalHeatmapAggregationCapacityPolicy.cappedRoutePointCount(
                routePointCounts: [31, 47]
            ),
            78
        )
        XCTAssertEqual(
            PersonalHeatmapAggregationCapacityPolicy.cappedRoutePointCount(
                routePointCounts: [Int.max, 1]
            ),
            262_144
        )
    }

    func testReservationPolicyDoesNotChangeCompleteSnapshot() throws {
        let workouts = (0..<8).map { workoutIndex in
            workout(
                name: "W\(workoutIndex)",
                points: route(
                    pointCount: 24,
                    latitude: 1.30 + Double(workoutIndex % 2) * 0.000_02,
                    longitude: 103.80
                ),
                startDate: origin.addingTimeInterval(Double(workoutIndex) * 60),
                distanceMeters: 500
            )
        }
        let configuration = PersonalHeatmapConfiguration(
            cellSizeMeters: 10,
            minimumWorkoutCount: 1,
            maximumRenderedCellCount: 1
        )

        let actual = try PersonalHeatmapBuilder().build(
            workouts: workouts,
            configuration: configuration
        )
        XCTAssertGreaterThan(actual.diagnostics.adaptiveResolutionRetries, 0)

        // The complete snapshot, field by field. The values were taken from the
        // production builder once the golden digests pinned the engine; they
        // replace the comparison with the retired pre-migration builder, which
        // also compared the whole snapshot exactly.
        let expectedBounds = (
            minLatitude: 1.2949128620196582, maxLatitude: 1.3006670438748733,
            minLongitude: 103.79754138328568, maxLongitude: 103.80329704156355
        )
        XCTAssertEqual(actual.cells.count, 1)
        let cell = try XCTUnwrap(actual.cells.first)
        XCTAssertEqual(cell.id.x, 18_034)
        XCTAssertEqual(cell.id.y, 225)
        XCTAssertEqual(cell.workoutCount, 8)
        XCTAssertEqual(cell.normalizedIntensity, 1.0)
        XCTAssertEqual(cell.bounds.minLatitude, expectedBounds.minLatitude)
        XCTAssertEqual(cell.bounds.maxLatitude, expectedBounds.maxLatitude)
        XCTAssertEqual(cell.bounds.minLongitude, expectedBounds.minLongitude)
        XCTAssertEqual(cell.bounds.maxLongitude, expectedBounds.maxLongitude)

        XCTAssertEqual(actual.statistics.includedWorkoutCount, 8)
        XCTAssertEqual(actual.statistics.totalDistanceMeters, 4_000)
        XCTAssertEqual(actual.statistics.maximumOverlap, 8)
        XCTAssertEqual(actual.statistics.requestedCellSizeMeters, 10)
        XCTAssertEqual(actual.statistics.effectiveCellSizeMeters, 640)
        XCTAssertTrue(actual.statistics.resolutionWasAdjusted)
        XCTAssertEqual(actual.statistics.excludedUndatedWorkoutCount, 0)
        XCTAssertEqual(actual.statistics.excludedNoRouteWorkoutCount, 0)

        XCTAssertEqual(actual.diagnostics.totalCandidateWorkouts, 8)
        XCTAssertEqual(actual.diagnostics.includedWorkouts, 8)
        XCTAssertEqual(actual.diagnostics.excludedUndatedWorkouts, 0)
        XCTAssertEqual(actual.diagnostics.excludedNoRouteWorkouts, 0)
        XCTAssertEqual(actual.diagnostics.invalidRouteIntervalsSkipped, 0)
        XCTAssertEqual(actual.diagnostics.adaptiveResolutionRetries, 6)
        XCTAssertEqual(actual.diagnostics.requestedCellSizeMeters, 10)
        XCTAssertEqual(actual.diagnostics.effectiveCellSizeMeters, 640)
        XCTAssertEqual(actual.diagnostics.aggregatedCellCount, 1)
        XCTAssertEqual(actual.diagnostics.renderedCellCount, 1)

        XCTAssertEqual(actual.configuration.dateFilter, .allTime)
        XCTAssertEqual(actual.configuration.cellSizeMeters, 640)
        XCTAssertEqual(actual.configuration.minimumWorkoutCount, 1)
        XCTAssertEqual(actual.configuration.maximumRenderedCellCount, 1)
        XCTAssertEqual(actual.configuration.maximumIntervalMeters, 50_000)

        let bounds = try XCTUnwrap(actual.bounds)
        XCTAssertEqual(bounds.minLatitude, expectedBounds.minLatitude)
        XCTAssertEqual(bounds.maxLatitude, expectedBounds.maxLatitude)
        XCTAssertEqual(bounds.minLongitude, expectedBounds.minLongitude)
        XCTAssertEqual(bounds.maxLongitude, expectedBounds.maxLongitude)
    }

    func testCancellationDuringDirectConsumptionPublishesNoSnapshot() {
        let gate = CancellationGate(cancelOnCall: 9)
        let longInterval = [
            point(latitude: 0, longitude: 0, elapsed: 0),
            point(latitude: 0, longitude: 0.30, elapsed: 1)
        ]
        let workouts = [
            workout(
                name: "Long",
                points: longInterval,
                startDate: origin,
                distanceMeters: 33_000
            )
        ]
        var publishedSnapshot: PersonalHeatmapSnapshot?

        XCTAssertThrowsError(
            publishedSnapshot = try PersonalHeatmapBuilder().build(
                workouts: workouts,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 10,
                    maximumRenderedCellCount: 5_000,
                    maximumIntervalMeters: 50_000
                ),
                isCancelled: { gate.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(publishedSnapshot)
        XCTAssertGreaterThanOrEqual(gate.callCount, 9)
    }

    private func route(
        pointCount: Int,
        latitude: Double = 1.30,
        longitude: Double = 103.80
    ) -> [RoutePoint] {
        (0..<pointCount).map { index in
            point(
                latitude: latitude,
                longitude: longitude + Double(index) * 0.000_02,
                distance: Double(index) * 2,
                elapsed: Double(index),
                segment: index / 16
            )
        }
    }

    private func point(
        latitude: Double,
        longitude: Double,
        distance: Double = 0,
        elapsed: Double,
        segment: Int = 0
    ) -> RoutePoint {
        RoutePoint(
            timestamp: origin.addingTimeInterval(elapsed),
            latitude: latitude,
            longitude: longitude,
            distanceFromStartMeters: distance,
            elapsedSeconds: elapsed,
            routeSegmentIndex: segment
        )
    }

    private func workout(
        name: String,
        points: [RoutePoint],
        startDate: Date?,
        distanceMeters: Double? = nil
    ) -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: startDate),
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: distanceMeters ?? Double(points.count),
                totalElapsedSeconds: points.last?.elapsedSeconds ?? 0
            )
        )
    }
}

private final class CancellationGate: @unchecked Sendable {
    private let cancelOnCall: Int
    private let lock = NSLock()
    private(set) var callCount = 0

    init(cancelOnCall: Int) {
        self.cancelOnCall = cancelOnCall
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return callCount >= cancelOnCall
    }
}
