import Foundation
import Testing
@testable import RunPlayCore

struct RunPlayPersonalHeatmapCoverageBridgeTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    /// Pure-Swift per-workout coverage oracle for testing parity.
    private struct SwiftWorkoutCoverageOracle {
        static func computeCoverage(
            routePoints: [RoutePoint],
            cellSizeMeters: Double,
            maximumIntervalMeters: Double
        ) throws -> (cells: [PersonalHeatmapCellID], validPoints: Int, effectiveSegments: Int, invalidIntervals: Int) {
            var projected: [(x: Double, y: Double, segment: Int)] = []
            projected.reserveCapacity(routePoints.count)

            var effectiveSegment = 0
            var previousSourceSegment: Int?
            var requiresNewSegment = true

            for point in routePoints {
                guard GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude),
                      let xy = PersonalHeatmapProjection.project(latitude: point.latitude, longitude: point.longitude)
                else {
                    requiresNewSegment = true
                    continue
                }

                if requiresNewSegment || previousSourceSegment != point.routeSegmentIndex {
                    effectiveSegment += 1
                }
                projected.append((xy.x, xy.y, effectiveSegment))
                previousSourceSegment = point.routeSegmentIndex
                requiresNewSegment = false
            }

            guard !projected.isEmpty else {
                return (cells: [], validPoints: 0, effectiveSegments: 0, invalidIntervals: 0)
            }

            var visited = Set<PersonalHeatmapCellID>()
            var invalidIntervals = 0

            for p in projected {
                if let x = PersonalHeatmapProjection.cellIndex(projected: p.x, cellSizeMeters: cellSizeMeters),
                   let y = PersonalHeatmapProjection.cellIndex(projected: p.y, cellSizeMeters: cellSizeMeters) {
                    visited.insert(PersonalHeatmapCellID(x: x, y: y))
                }
            }

            if projected.count > 1 {
                for i in 0..<(projected.count - 1) {
                    let a = projected[i]
                    let b = projected[i + 1]

                    guard a.segment == b.segment else { continue }

                    let dx = b.x - a.x
                    let dy = b.y - a.y
                    let length = (dx * dx + dy * dy).squareRoot()

                    if length == 0 {
                        if let x = PersonalHeatmapProjection.cellIndex(projected: a.x, cellSizeMeters: cellSizeMeters),
                           let y = PersonalHeatmapProjection.cellIndex(projected: a.y, cellSizeMeters: cellSizeMeters) {
                            visited.insert(PersonalHeatmapCellID(x: x, y: y))
                        }
                        continue
                    }

                    if length > maximumIntervalMeters {
                        invalidIntervals += 1
                        continue
                    }

                    let intervalCells = try PersonalHeatmapGridTraversal.cells(
                        from: (a.x, a.y),
                        to: (b.x, b.y),
                        cellSizeMeters: cellSizeMeters
                    )
                    for cell in intervalCells {
                        visited.insert(cell)
                    }
                }
            }

            let sortedCells = visited.sorted()
            return (
                cells: sortedCells,
                validPoints: projected.count,
                effectiveSegments: effectiveSegment,
                invalidIntervals: invalidIntervals
            )
        }
    }

    private func point(
        latitude: Double,
        longitude: Double,
        index: Int,
        segment: Int = 0
    ) -> RoutePoint {
        RoutePoint(
            timestamp: origin.addingTimeInterval(Double(index)),
            latitude: latitude,
            longitude: longitude,
            routeSegmentIndex: segment
        )
    }

    private func assertAccumulationParity(
        route: [RoutePoint],
        cellSizeMeters: Double = 10,
        maximumIntervalMeters: Double = 50_000,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: [route],
            isCancelled: { false }
        )
        let arrayCoverage = try batch.coverage(
            workoutIndex: 0,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: 10_000,
            isCancelled: { false }
        )
        var counts: [PersonalHeatmapCellID: Int] = [:]
        let metadata = try batch.accumulateCoverage(
            workoutIndex: 0,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: 10_000,
            into: &counts,
            isCancelled: { false }
        )
        let expectedCounts = Dictionary(
            uniqueKeysWithValues: arrayCoverage.cells.map { ($0, 1) }
        )

        #expect(counts == expectedCounts, sourceLocation: sourceLocation)
        #expect(metadata.cellCount == arrayCoverage.cells.count, sourceLocation: sourceLocation)
        #expect(
            metadata.validProjectedPointCount == arrayCoverage.validProjectedPointCount,
            sourceLocation: sourceLocation
        )
        #expect(
            metadata.effectiveSegmentCount == arrayCoverage.effectiveSegmentCount,
            sourceLocation: sourceLocation
        )
        #expect(
            metadata.invalidIntervalCount == arrayCoverage.invalidIntervalCount,
            sourceLocation: sourceLocation
        )
    }

    @Test
    func testEmptyWorkoutRoute() throws {
        let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: [[]],
            isCancelled: { false }
        )
        let result = try batch.coverage(
            workoutIndex: 0,
            cellSizeMeters: 10.0,
            maximumIntervalMeters: 500.0,
            maximumCellsPerInterval: 10_000,
            isCancelled: { false }
        )
        #expect(result.cells.isEmpty)
        #expect(result.validProjectedPointCount == 0)
        #expect(result.effectiveSegmentCount == 0)
        #expect(result.invalidIntervalCount == 0)
    }

    @Test
    func testDirectAccumulationMatchesArrayCoverageFixtureMatrix() throws {
        let single = [point(latitude: 1.30, longitude: 103.80, index: 0)]
        let repeated = (0..<32).map {
            point(latitude: 1.30, longitude: 103.80, index: $0)
        }
        let loopCoordinates = [
            (1.3000, 103.8000),
            (1.3000, 103.8010),
            (1.3010, 103.8010),
            (1.3010, 103.8000),
            (1.3000, 103.8000)
        ]
        let loop = loopCoordinates.enumerated().map {
            point(latitude: $0.element.0, longitude: $0.element.1, index: $0.offset)
        }
        let segments = [
            point(latitude: 1.30, longitude: 103.80, index: 0, segment: 0),
            point(latitude: 1.30, longitude: 103.801, index: 1, segment: 0),
            point(latitude: 1.40, longitude: 103.90, index: 2, segment: 1),
            point(latitude: 1.40, longitude: 103.901, index: 3, segment: 1)
        ]
        let invalidGap = [
            point(latitude: 1.30, longitude: 103.80, index: 0),
            point(latitude: 200, longitude: 103.81, index: 1),
            point(latitude: 1.30, longitude: 103.82, index: 2)
        ]
        let oversizedInterval = [
            point(latitude: 1.30, longitude: 103.80, index: 0),
            point(latitude: 1.40, longitude: 103.90, index: 1)
        ]
        let negativeIndexes = [
            point(latitude: -33.86, longitude: -122.42, index: 0),
            point(latitude: -33.861, longitude: -122.421, index: 1)
        ]

        try assertAccumulationParity(route: [])
        try assertAccumulationParity(route: single)
        try assertAccumulationParity(route: repeated)
        try assertAccumulationParity(route: loop)
        try assertAccumulationParity(route: segments)
        try assertAccumulationParity(route: invalidGap)
        try assertAccumulationParity(
            route: oversizedInterval,
            maximumIntervalMeters: 100
        )
        try assertAccumulationParity(route: negativeIndexes)
    }

    @Test
    func testDirectAccumulationTwiceProducesCountTwo() throws {
        let route = (0..<20).map {
            point(
                latitude: 1.30,
                longitude: 103.80 + Double($0) * 0.000_1,
                index: $0
            )
        }
        let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: [route],
            isCancelled: { false }
        )
        var counts: [PersonalHeatmapCellID: Int] = [:]
        let first = try batch.accumulateCoverage(
            workoutIndex: 0,
            cellSizeMeters: 10,
            maximumIntervalMeters: 50_000,
            maximumCellsPerInterval: 10_000,
            into: &counts,
            isCancelled: { false }
        )
        let second = try batch.accumulateCoverage(
            workoutIndex: 0,
            cellSizeMeters: 10,
            maximumIntervalMeters: 50_000,
            maximumCellsPerInterval: 10_000,
            into: &counts,
            isCancelled: { false }
        )

        #expect(first == second)
        #expect(counts.count == first.cellCount)
        #expect(counts.values.allSatisfy { $0 == 2 })
    }

    @Test
    func testDirectAccumulationCapacityRetryAndCachedReuse() throws {
        let route = [
            point(latitude: 0, longitude: 0, index: 0),
            point(latitude: 0, longitude: 0.03, index: 1)
        ]
        let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: [route],
            isCancelled: { false }
        )
        var counts: [PersonalHeatmapCellID: Int] = [:]

        let first = try batch.profiledAccumulateCoverage(
            workoutIndex: 0,
            cellSizeMeters: 1,
            maximumIntervalMeters: 5_000,
            maximumCellsPerInterval: 10_000,
            into: &counts,
            isCancelled: { false }
        )
        let second = try batch.profiledAccumulateCoverage(
            workoutIndex: 0,
            cellSizeMeters: 1,
            maximumIntervalMeters: 5_000,
            maximumCellsPerInterval: 10_000,
            into: &counts,
            isCancelled: { false }
        )

        #expect(first.metadata.cellCount > 64)
        #expect(first.profile.capacityRetryCount == 1)
        #expect(first.profile.nativeCallCount == 2)
        #expect(second.profile.capacityRetryCount == 0)
        #expect(second.profile.nativeCallCount == 1)
        #expect(second.metadata == first.metadata)
        #expect(counts.values.allSatisfy { $0 == 2 })
    }

    @Test
    func testSinglePointWorkoutRoute() throws {
        let route = [RoutePoint(timestamp: Date(), latitude: 37.7749, longitude: -122.4194, routeSegmentIndex: 0)]
        let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: [route],
            isCancelled: { false }
        )
        let result = try batch.coverage(
            workoutIndex: 0,
            cellSizeMeters: 10.0,
            maximumIntervalMeters: 500.0,
            maximumCellsPerInterval: 10_000,
            isCancelled: { false }
        )
        #expect(result.cells.count == 1)
        #expect(result.validProjectedPointCount == 1)
        #expect(result.effectiveSegmentCount == 1)
        #expect(result.invalidIntervalCount == 0)
    }

    @Test
    func testDeterministicGeneratedParityFixtures() throws {
        // 1,000 deterministic generated fixtures using pseudo-random LCG algorithm
        var seed: UInt64 = 0x123456789ABCDEF
        func nextRandom() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed & 0xFFFFFFFF) / Double(0xFFFFFFFF)
        }

        var allRoutes: [[RoutePoint]] = []
        allRoutes.reserveCapacity(1_000)

        let now = Date()

        for _ in 0..<1_000 {
            let pointCount = Int(nextRandom() * 50) + 1
            var points: [RoutePoint] = []
            points.reserveCapacity(pointCount)

            var lat = 37.7749 + (nextRandom() - 0.5) * 0.1
            var lon = -122.4194 + (nextRandom() - 0.5) * 0.1
            var segment = 0

            for p in 0..<pointCount {
                let timestamp = now.addingTimeInterval(Double(p))
                let pType = nextRandom()
                if pType < 0.05 {
                    // Invalid lat
                    points.append(RoutePoint(timestamp: timestamp, latitude: 200.0, longitude: lon, routeSegmentIndex: segment))
                } else if pType < 0.10 {
                    // Segment increment
                    segment += Int(nextRandom() * 3) + 1
                    points.append(RoutePoint(timestamp: timestamp, latitude: lat, longitude: lon, routeSegmentIndex: segment))
                } else if pType < 0.15 {
                    // Large step (oversized interval)
                    lat += 0.5
                    lon += 0.5
                    points.append(RoutePoint(timestamp: timestamp, latitude: lat, longitude: lon, routeSegmentIndex: segment))
                } else {
                    // Normal step
                    lat += (nextRandom() - 0.5) * 0.001
                    lon += (nextRandom() - 0.5) * 0.001
                    points.append(RoutePoint(timestamp: timestamp, latitude: lat, longitude: lon, routeSegmentIndex: segment))
                }
            }
            allRoutes.append(points)
        }

        let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: allRoutes,
            isCancelled: { false }
        )

        for (i, route) in allRoutes.enumerated() {
            let cellSize = 10.0 + (Double(i % 5) * 5.0)
            let maxInterval = 200.0 + (Double(i % 3) * 100.0)

            let expected = try SwiftWorkoutCoverageOracle.computeCoverage(
                routePoints: route,
                cellSizeMeters: cellSize,
                maximumIntervalMeters: maxInterval
            )

            let actual = try batch.coverage(
                workoutIndex: i,
                cellSizeMeters: cellSize,
                maximumIntervalMeters: maxInterval,
                maximumCellsPerInterval: 10_000,
                isCancelled: { false }
            )

            #expect(actual.cells == expected.cells, "Fixture \(i) cell mismatch")
            #expect(actual.validProjectedPointCount == expected.validPoints, "Fixture \(i) valid points mismatch")
            #expect(actual.effectiveSegmentCount == expected.effectiveSegments, "Fixture \(i) effective segments mismatch")
            #expect(actual.invalidIntervalCount == expected.invalidIntervals, "Fixture \(i) invalid intervals mismatch")

            var directCounts: [PersonalHeatmapCellID: Int] = [:]
            let metadata = try batch.accumulateCoverage(
                workoutIndex: i,
                cellSizeMeters: cellSize,
                maximumIntervalMeters: maxInterval,
                maximumCellsPerInterval: 10_000,
                into: &directCounts,
                isCancelled: { false }
            )
            #expect(
                directCounts == Dictionary(
                    uniqueKeysWithValues: actual.cells.map { ($0, 1) }
                ),
                "Fixture \(i) direct accumulation mismatch"
            )
            #expect(metadata.cellCount == actual.cells.count, "Fixture \(i) cell metadata mismatch")
            #expect(
                metadata.validProjectedPointCount == actual.validProjectedPointCount,
                "Fixture \(i) valid-point metadata mismatch"
            )
            #expect(
                metadata.effectiveSegmentCount == actual.effectiveSegmentCount,
                "Fixture \(i) segment metadata mismatch"
            )
            #expect(
                metadata.invalidIntervalCount == actual.invalidIntervalCount,
                "Fixture \(i) interval metadata mismatch"
            )
        }
    }

    @Test
    func testCancellationSupport() throws {
        let route = (0..<4_096).map {
            point(
                latitude: 37.7749,
                longitude: -122.4194 + Double($0) * 0.000_001,
                index: $0
            )
        }

        #expect(throws: CancellationError.self) {
            _ = try RunPlayPersonalHeatmapCoverageBridge.prepare(
                workoutRoutes: [route],
                isCancelled: { true }
            )
        }

        let conversionGate = BridgeCancellationGate(cancelOnCall: 2)
        #expect(throws: CancellationError.self) {
            _ = try RunPlayPersonalHeatmapCoverageBridge.prepare(
                workoutRoutes: [route],
                isCancelled: { conversionGate.shouldCancel() }
            )
        }
        #expect(conversionGate.callCount == 2)

        let batch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: [route],
            isCancelled: { false }
        )

        #expect(throws: CancellationError.self) {
            _ = try batch.coverage(
                workoutIndex: 0,
                cellSizeMeters: 10.0,
                maximumIntervalMeters: 500.0,
                maximumCellsPerInterval: 10_000,
                isCancelled: { true }
            )
        }

        var beforeNativeCounts = [
            PersonalHeatmapCellID(x: 7, y: 9): 3
        ]
        #expect(throws: CancellationError.self) {
            _ = try batch.accumulateCoverage(
                workoutIndex: 0,
                cellSizeMeters: 10,
                maximumIntervalMeters: 500,
                maximumCellsPerInterval: 10_000,
                into: &beforeNativeCounts,
                isCancelled: { true }
            )
        }
        #expect(beforeNativeCounts == [PersonalHeatmapCellID(x: 7, y: 9): 3])

        let afterNativeGate = BridgeCancellationGate(cancelOnCall: 2)
        var afterNativeCounts: [PersonalHeatmapCellID: Int] = [:]
        #expect(throws: CancellationError.self) {
            _ = try batch.accumulateCoverage(
                workoutIndex: 0,
                cellSizeMeters: 10,
                maximumIntervalMeters: 500,
                maximumCellsPerInterval: 10_000,
                into: &afterNativeCounts,
                isCancelled: { afterNativeGate.shouldCancel() }
            )
        }
        #expect(afterNativeCounts.isEmpty)
        #expect(afterNativeGate.callCount == 2)

        let longIntervalBatch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: [[
                point(latitude: 0, longitude: 0, index: 0),
                point(latitude: 0, longitude: 0.30, index: 1)
            ]],
            isCancelled: { false }
        )
        let consumptionGate = BridgeCancellationGate(cancelOnCall: 4)
        var partialLocalCounts: [PersonalHeatmapCellID: Int] = [:]
        #expect(throws: CancellationError.self) {
            _ = try longIntervalBatch.accumulateCoverage(
                workoutIndex: 0,
                cellSizeMeters: 10,
                maximumIntervalMeters: 50_000,
                maximumCellsPerInterval: 10_000,
                into: &partialLocalCounts,
                isCancelled: { consumptionGate.shouldCancel() }
            )
        }
        #expect(partialLocalCounts.count == 2_048)
        #expect(partialLocalCounts.values.allSatisfy { $0 == 1 })
        #expect(consumptionGate.callCount == 4)
    }
}

private final class BridgeCancellationGate: @unchecked Sendable {
    private let cancelOnCall: Int
    private let lock = NSLock()
    private var calls = 0

    init(cancelOnCall: Int) {
        self.cancelOnCall = cancelOnCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls >= cancelOnCall
    }
}
