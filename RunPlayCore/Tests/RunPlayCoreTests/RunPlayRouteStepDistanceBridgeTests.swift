import Foundation
import XCTest
@testable import RunPlayCore

final class RunPlayRouteStepDistanceBridgeTests: XCTestCase {
    func testEmptyRoute() throws {
        let result = try RunPlayRouteStepDistanceBridge.compute([])
        XCTAssertTrue(result.stepDistancesMeters.isEmpty)
        XCTAssertEqual(result.totalDistanceMeters, 0)
        XCTAssertEqual(result.segmentTransitionCount, 0)
        XCTAssertEqual(result.invalidCoordinatePairCount, 0)
    }

    func testSinglePoint() throws {
        let points = [point(index: 0, latitude: 1.0, longitude: 103.0, segment: 0)]
        let result = try RunPlayRouteStepDistanceBridge.compute(points)
        let oracle = SwiftRouteStepDistanceOracle.compute(points)
        assertParity(result, oracle)
    }

    func testNormalRouteMatchesSwiftOracle() throws {
        let points = (0..<8).map { index in
            point(
                index: index,
                latitude: 1.0 + Double(index) * 0.001,
                longitude: 103.0 + Double(index) * 0.0005,
                segment: 0
            )
        }
        let result = try RunPlayRouteStepDistanceBridge.compute(points)
        assertParity(result, SwiftRouteStepDistanceOracle.compute(points))
    }

    func testRepeatedCoordinates() throws {
        let points = [
            point(index: 0, latitude: 37.7749, longitude: -122.4194, segment: 0),
            point(index: 1, latitude: 37.7749, longitude: -122.4194, segment: 0),
            point(index: 2, latitude: 37.7749, longitude: -122.4194, segment: 0),
        ]
        let result = try RunPlayRouteStepDistanceBridge.compute(points)
        assertParity(result, SwiftRouteStepDistanceOracle.compute(points))
        XCTAssertEqual(result.stepDistancesMeters[1], 0)
        XCTAssertEqual(result.stepDistancesMeters[2], 0)
    }

    func testMultipleSegmentsZeroAtBoundaries() throws {
        let points = [
            point(index: 0, latitude: 0, longitude: 0, segment: 0),
            point(index: 1, latitude: 0, longitude: 0.01, segment: 0),
            point(index: 2, latitude: 0, longitude: 0.01, segment: 1),
            point(index: 3, latitude: 0, longitude: 0.02, segment: 1),
            point(index: 4, latitude: 0.01, longitude: 0.02, segment: 2),
        ]
        let result = try RunPlayRouteStepDistanceBridge.compute(points)
        let oracle = SwiftRouteStepDistanceOracle.compute(points)
        assertParity(result, oracle)
        XCTAssertEqual(result.segmentTransitionCount, 2)
        XCTAssertEqual(result.stepDistancesMeters[2], 0)
        XCTAssertEqual(result.stepDistancesMeters[4], 0)
    }

    func testInvalidCoordinatesCountAsZeroSteps() throws {
        let points = [
            point(index: 0, latitude: 0, longitude: 0, segment: 0),
            point(index: 1, latitude: .nan, longitude: 1, segment: 0),
            point(index: 2, latitude: 0, longitude: 2, segment: 0),
            point(index: 3, latitude: 0, longitude: 3, segment: 0),
        ]
        let result = try RunPlayRouteStepDistanceBridge.compute(points)
        let oracle = SwiftRouteStepDistanceOracle.compute(points)
        assertParity(result, oracle)
        XCTAssertEqual(result.invalidCoordinatePairCount, 2)
        XCTAssertEqual(result.stepDistancesMeters[1], 0)
        XCTAssertEqual(result.stepDistancesMeters[2], 0)
        XCTAssertGreaterThan(result.stepDistancesMeters[3], 0)
    }

    func testAntimeridianAndNearPole() throws {
        let antimeridian = [
            point(index: 0, latitude: 0, longitude: 179.5, segment: 0),
            point(index: 1, latitude: 0, longitude: -179.5, segment: 0),
        ]
        assertParity(
            try RunPlayRouteStepDistanceBridge.compute(antimeridian),
            SwiftRouteStepDistanceOracle.compute(antimeridian)
        )

        let nearPole = [
            point(index: 0, latitude: 89.9, longitude: 10, segment: 0),
            point(index: 1, latitude: 89.9, longitude: 20, segment: 0),
        ]
        assertParity(
            try RunPlayRouteStepDistanceBridge.compute(nearPole),
            SwiftRouteStepDistanceOracle.compute(nearPole)
        )
    }

    func testExactlyAntipodalNaNBehaviorPreserved() throws {
        let points = [
            point(index: 0, latitude: 0, longitude: 0, segment: 0),
            point(index: 1, latitude: 0, longitude: 180, segment: 0),
        ]
        let result = try RunPlayRouteStepDistanceBridge.compute(points)
        let oracle = SwiftRouteStepDistanceOracle.compute(points)
        assertParity(result, oracle)
    }

    func testDeterministicHundredThousandPointRoute() throws {
        let pointCount = 100_000
        var points: [RoutePoint] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let meters = Double(index) * 10
            points.append(
                point(
                    index: index,
                    latitude: 1.0 + meters / 111_132,
                    longitude: 103.0,
                    segment: index / 25_000
                )
            )
        }

        let first = try RunPlayRouteStepDistanceBridge.compute(points)
        let second = try RunPlayRouteStepDistanceBridge.compute(points)
        let oracle = SwiftRouteStepDistanceOracle.compute(points)

        XCTAssertEqual(first.stepDistancesMeters.count, pointCount)
        XCTAssertEqual(first.segmentTransitionCount, 3)
        XCTAssertEqual(first.stepDistancesMeters[0], 0)
        XCTAssertEqual(first.stepDistancesMeters[25_000], 0)
        assertParity(first, oracle)
        assertParity(second, oracle)
        XCTAssertEqual(first.totalDistanceMeters, second.totalDistanceMeters)
    }

    func testHardCodedEquatorOneDegreeFixture() throws {
        let points = [
            point(index: 0, latitude: 0, longitude: 0, segment: 0),
            point(index: 1, latitude: 0, longitude: 1, segment: 0),
        ]
        let result = try RunPlayRouteStepDistanceBridge.compute(points)
        let expected = GeoDistance.distanceMeters(
            fromLat: 0, lon: 0, toLat: 0, lon: 1
        )
        assertFiniteEqual(result.stepDistancesMeters[1], expected)
        assertFiniteEqual(result.totalDistanceMeters, expected)
    }

    private func point(
        index: Int,
        latitude: Double,
        longitude: Double,
        segment: Int
    ) -> RoutePoint {
        RoutePoint(
            timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
            latitude: latitude,
            longitude: longitude,
            altitudeMeters: nil,
            distanceFromStartMeters: 0,
            elapsedSeconds: Double(index),
            routeSegmentIndex: segment
        )
    }

    private func assertParity(
        _ result: RunPlayRouteStepDistanceResult,
        _ oracle: SwiftRouteStepDistanceOracle.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            result.stepDistancesMeters.count,
            oracle.stepDistancesMeters.count,
            file: file,
            line: line
        )
        XCTAssertEqual(
            result.segmentTransitionCount,
            oracle.segmentTransitionCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            result.invalidCoordinatePairCount,
            oracle.invalidCoordinatePairCount,
            file: file,
            line: line
        )
        for index in result.stepDistancesMeters.indices {
            assertClassifiedEqual(
                result.stepDistancesMeters[index],
                oracle.stepDistancesMeters[index],
                file: file,
                line: line
            )
        }
        assertClassifiedEqual(
            result.totalDistanceMeters,
            oracle.totalDistanceMeters,
            file: file,
            line: line
        )
    }

    private func assertFiniteEqual(
        _ value: Double,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tolerance = max(1e-6, abs(expected) * 1e-12)
        XCTAssertEqual(value, expected, accuracy: tolerance, file: file, line: line)
    }

    private func assertClassifiedEqual(
        _ value: Double,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if expected.isNaN {
            XCTAssertTrue(value.isNaN, file: file, line: line)
            return
        }
        if expected.isInfinite {
            XCTAssertEqual(value, expected, file: file, line: line)
            return
        }
        assertFiniteEqual(value, expected, file: file, line: line)
    }
}

/// Pure Swift oracle for route step distances. Does not call the C++ bridge,
/// shared digests, or production `normalizeDistances`.
private enum SwiftRouteStepDistanceOracle {
    struct Result {
        var stepDistancesMeters: [Double]
        var totalDistanceMeters: Double
        var segmentTransitionCount: UInt64
        var invalidCoordinatePairCount: UInt64
    }

    static func compute(_ points: [RoutePoint]) -> Result {
        guard !points.isEmpty else {
            return Result(
                stepDistancesMeters: [],
                totalDistanceMeters: 0,
                segmentTransitionCount: 0,
                invalidCoordinatePairCount: 0
            )
        }

        var steps = Array(repeating: 0.0, count: points.count)
        var segmentTransitions: UInt64 = 0
        var invalidPairs: UInt64 = 0
        var total = 0.0

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            if previous.routeSegmentIndex != current.routeSegmentIndex {
                steps[index] = 0
                segmentTransitions += 1
            } else if !GeoDistance.isValidCoordinate(
                lat: previous.latitude,
                lon: previous.longitude
            ) || !GeoDistance.isValidCoordinate(
                lat: current.latitude,
                lon: current.longitude
            ) {
                steps[index] = 0
                invalidPairs += 1
            } else {
                steps[index] = GeoDistance.distanceMeters(
                    fromLat: previous.latitude,
                    lon: previous.longitude,
                    toLat: current.latitude,
                    lon: current.longitude
                )
            }
            total += steps[index]
        }

        return Result(
            stepDistancesMeters: steps,
            totalDistanceMeters: total,
            segmentTransitionCount: segmentTransitions,
            invalidCoordinatePairCount: invalidPairs
        )
    }
}
