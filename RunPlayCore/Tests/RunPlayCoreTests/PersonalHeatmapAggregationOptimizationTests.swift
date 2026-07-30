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
        let expected = try SwiftPersonalHeatmapBuilderOracle().build(
            workouts: workouts,
            configuration: configuration
        )
        XCTAssertEqual(actual, expected)
        XCTAssertGreaterThan(actual.diagnostics.adaptiveResolutionRetries, 0)
    }

    func testGeneratedCompleteSnapshotParityForOneThousandFixtures() throws {
        var generator = DeterministicGenerator(state: 0xA76E_31D9_B54C_208F)
        let builder = PersonalHeatmapBuilder()
        let oracle = SwiftPersonalHeatmapBuilderOracle()
        let cellSizes: [Double] = [10, 25, 50, 100]
        let renderBudgets = [8, 64, 5_000]
        let intervalLimits: [Double] = [100, 1_000, 50_000]

        for fixtureIndex in 0..<1_000 {
            let workoutCount = generator.nextInt(upperBound: 6)
            var workouts: [RunWorkout] = []
            workouts.reserveCapacity(workoutCount)

            for workoutIndex in 0..<workoutCount {
                let pointCount = generator.nextInt(upperBound: 13)
                let hemisphere = generator.nextInt(upperBound: 4)
                var latitude = hemisphere < 2 ? 1.30 : -33.86
                var longitude = hemisphere.isMultiple(of: 2) ? 103.80 : -122.42
                var points: [RoutePoint] = []
                points.reserveCapacity(pointCount)

                for pointIndex in 0..<pointCount {
                    let selector = generator.nextInt(upperBound: 23)
                    if selector == 0 {
                        points.append(point(
                            latitude: 95,
                            longitude: longitude,
                            elapsed: Double(pointIndex),
                            segment: pointIndex / 4
                        ))
                        continue
                    }
                    if selector == 1 {
                        latitude += 0.2
                        longitude += 0.2
                    } else if selector != 2 {
                        latitude += generator.nextSignedUnit() * 0.000_08
                        longitude += generator.nextSignedUnit() * 0.000_08
                    }
                    points.append(point(
                        latitude: latitude,
                        longitude: longitude,
                        distance: Double(pointIndex) * 8,
                        elapsed: Double(pointIndex) * 4,
                        segment: pointIndex / 4
                    ))
                }

                let date: Date? = (fixtureIndex + workoutIndex).isMultiple(of: 7)
                    ? nil
                    : origin.addingTimeInterval(Double(workoutIndex) * 3_600)
                let distance: Double
                if (fixtureIndex + workoutIndex).isMultiple(of: 41) {
                    distance = .nan
                } else if (fixtureIndex + workoutIndex).isMultiple(of: 37) {
                    distance = -10
                } else {
                    distance = Double(pointCount) * 8
                }
                workouts.append(workout(
                    name: "F\(fixtureIndex)-W\(workoutIndex)",
                    points: points,
                    startDate: date,
                    distanceMeters: distance
                ))
            }

            let dateFilter: PersonalHeatmapDateFilter = fixtureIndex.isMultiple(of: 5)
                ? .range(
                    start: origin.addingTimeInterval(-1),
                    end: origin.addingTimeInterval(7_200)
                )
                : .allTime
            let configuration = PersonalHeatmapConfiguration(
                dateFilter: dateFilter,
                cellSizeMeters: cellSizes[fixtureIndex % cellSizes.count],
                minimumWorkoutCount: fixtureIndex % 3 + 1,
                maximumRenderedCellCount: renderBudgets[fixtureIndex % renderBudgets.count],
                maximumIntervalMeters: intervalLimits[fixtureIndex % intervalLimits.count]
            )

            let expected = try oracle.build(
                workouts: workouts,
                configuration: configuration
            )
            let actual = try builder.build(
                workouts: workouts,
                configuration: configuration
            )
            XCTAssertEqual(actual, expected, "generated fixture \(fixtureIndex)")
        }
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

private struct DeterministicGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func nextSignedUnit() -> Double {
        let unit = Double(next() >> 11) / Double(UInt64(1) << 53)
        return unit * 2 - 1
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
