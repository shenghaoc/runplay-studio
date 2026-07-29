import Foundation
import Testing
@testable import RunPlayCore

struct RunPlayPersonalHeatmapCoverageBridgeTests {

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
        }
    }

    @Test
    func testCancellationSupport() throws {
        let route = [
            RoutePoint(timestamp: Date(), latitude: 37.7749, longitude: -122.4194, routeSegmentIndex: 0),
            RoutePoint(timestamp: Date(), latitude: 37.7750, longitude: -122.4195, routeSegmentIndex: 0)
        ]

        #expect(throws: CancellationError.self) {
            _ = try RunPlayPersonalHeatmapCoverageBridge.prepare(
                workoutRoutes: [route],
                isCancelled: { true }
            )
        }

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
    }
}
