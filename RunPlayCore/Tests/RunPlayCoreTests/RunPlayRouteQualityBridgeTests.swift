import XCTest
@testable import RunPlayCore

/// Parity coverage for the combined route-quality geometry bridge versus the
/// independent Swift stages 2–4 oracle.
final class RunPlayRouteQualityBridgeTests: XCTestCase {
    private let toleranceBase = 1e-6
    private let toleranceRelative = 1e-12

    func testEmptyRoute() throws {
        let result = try RunPlayRouteQualityBridge.process(
            [],
            policy: .runningDefault,
            distancePolicy: .computeFromCoordinates,
            cancellationCheckStride: 2_048,
            isCancelled: { false }
        )
        XCTAssertTrue(result.routePoints.isEmpty)
        XCTAssertEqual(result.discardedCoordinatePointCount, 0)
        XCTAssertEqual(result.distanceSource, .coordinateDerived)
    }

    func testStraightRouteMatchesOracle() throws {
        let points = makeStraightRoute(count: 20, stepMeters: 10)
        try assertBridgeMatchesOracle(points)
    }

    func testIsolatedTeleportMatchesOracle() throws {
        var points = makeStraightRoute(count: 6, stepMeters: 10)
        // Teleport the middle point ~5 km north.
        points[2] = RoutePoint(
            id: points[2].id,
            timestamp: points[2].timestamp,
            latitude: points[2].latitude + 5_000.0 / 111_132.0,
            longitude: points[2].longitude,
            distanceFromStartMeters: points[2].distanceFromStartMeters,
            elapsedSeconds: points[2].elapsedSeconds,
            routeSegmentIndex: 0
        )
        try assertBridgeMatchesOracle(points)
    }

    /// Adjacent outlier candidates are ambiguous rather than isolated, so every
    /// member of a run is retained — including the trailing one.
    func testAdjacentCandidatesMatchOracle() throws {
        // Two adjacent candidates (indexes 2 and 3).
        let pair = makeOscillatingRoute([0, 0, 5_000, 0, 5_000, 5_000])
        try assertBridgeMatchesOracle(pair)

        // A run of three adjacent candidates (indexes 2, 3 and 4).
        let run = makeOscillatingRoute([0, 0, 5_000, 0, 5_000, 0, 0])
        try assertBridgeMatchesOracle(run)

        // Parity alone would pass if both sides regressed together, so pin the
        // expected production behaviour directly.
        for points in [pair, run] {
            let bridge = try RunPlayRouteQualityBridge.process(
                points,
                policy: .runningDefault,
                distancePolicy: .computeFromCoordinates,
                cancellationCheckStride: RouteQualityPolicy.runningDefault
                    .cancellationCheckStride,
                isCancelled: { false }
            )
            XCTAssertEqual(bridge.discardedCoordinatePointCount, 0)
            XCTAssertEqual(bridge.routePoints.count, points.count)
            XCTAssertEqual(bridge.routePoints.map(\.id), points.map(\.id))
        }

        // An isolated candidate is still rejected.
        let isolated = makeOscillatingRoute([0, 0, 5_000, 0, 0, 0])
        try assertBridgeMatchesOracle(isolated)
        let isolatedResult = try RunPlayRouteQualityBridge.process(
            isolated,
            policy: .runningDefault,
            distancePolicy: .computeFromCoordinates,
            cancellationCheckStride: RouteQualityPolicy.runningDefault
                .cancellationCheckStride,
            isCancelled: { false }
        )
        XCTAssertEqual(isolatedResult.discardedCoordinatePointCount, 1)
        XCTAssertEqual(isolatedResult.routePoints.count, isolated.count - 1)
    }

    func testInferredGapMatchesOracle() throws {
        var points = makeStraightRoute(count: 8, stepMeters: 10)
        let jump = 1_000.0 / 111_132.0
        for index in 4..<points.count {
            points[index] = RoutePoint(
                id: points[index].id,
                timestamp: points[index].timestamp,
                latitude: points[index].latitude + jump,
                longitude: points[index].longitude,
                distanceFromStartMeters: points[index].distanceFromStartMeters,
                elapsedSeconds: points[index].elapsedSeconds,
                routeSegmentIndex: 0
            )
        }
        try assertBridgeMatchesOracle(points)
    }

    func testExplicitSegmentsMatchOracle() throws {
        var points = makeStraightRoute(count: 6, stepMeters: 25)
        for index in 3..<points.count {
            var point = points[index]
            point.routeSegmentIndex = 1
            point.latitude += 1.0
            points[index] = point
        }
        try assertBridgeMatchesOracle(points)
    }

    func testSuppliedDistancePoliciesMatchOracle() throws {
        let points = makeStraightRoute(count: 8, stepMeters: 50, suppliedDistance: true)
        try assertBridgeMatchesOracle(points, distancePolicy: .useSuppliedDistancesWhenValid)
        try assertBridgeMatchesOracle(points, distancePolicy: .useSuppliedDistancesPerSegment)
        try assertBridgeMatchesOracle(
            points,
            distancePolicy: .useSuppliedDistancesForSegments([0])
        )
    }

    func testUUIDAndOptionalFieldRetention() throws {
        let id = UUID()
        let points = [
            RoutePoint(
                id: id,
                timestamp: Date(timeIntervalSinceReferenceDate: 100),
                latitude: 0,
                longitude: 0,
                altitudeMeters: 12,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0,
                speedMetersPerSecond: 3,
                paceSecondsPerKilometer: 300,
                heartRateBPM: 140,
                cadence: 170,
                horizontalAccuracy: 5,
                routeSegmentIndex: 0
            ),
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 101),
                latitude: 0.001,
                longitude: 0,
                altitudeMeters: 13,
                distanceFromStartMeters: 100,
                elapsedSeconds: 1,
                speedMetersPerSecond: 3.1,
                heartRateBPM: 141,
                cadence: 171,
                horizontalAccuracy: 6,
                routeSegmentIndex: 0
            ),
        ]
        let result = try RunPlayRouteQualityBridge.process(
            points,
            policy: .runningDefault,
            distancePolicy: .computeFromCoordinates,
            cancellationCheckStride: 2_048,
            isCancelled: { false }
        )
        XCTAssertEqual(result.routePoints.first?.id, id)
        XCTAssertEqual(result.routePoints.first?.altitudeMeters, 12)
        XCTAssertEqual(result.routePoints.first?.heartRateBPM, 140)
        XCTAssertEqual(result.routePoints.first?.cadence, 170)
        XCTAssertEqual(result.routePoints.first?.horizontalAccuracy, 5)
        XCTAssertEqual(
            result.routePoints.first?.timestamp.timeIntervalSinceReferenceDate ?? -1,
            100,
            accuracy: 0
        )
    }

    func testDeterministicPropertyFixtures() throws {
        var seed: UInt64 = 0xC0FFEE42
        for fixture in 0..<1_000 {
            let count = 3 + Int(next(&seed) % 24)
            let segments = 1 + Int(next(&seed) % 3)
            let points = makePropertyFixture(
                count: count,
                segments: segments,
                seed: &seed,
                fixture: fixture
            )
            let policy = RouteQualityPolicy(
                maximumPlausibleRunningSpeedMetersPerSecond: 10 + Double(next(&seed) % 5),
                coordinateSpikeMinimumExcessDistanceMeters: 150 + Double(next(&seed) % 100),
                implicitGapMinimumDistanceMeters: 150 + Double(next(&seed) % 100),
                cancellationCheckStride: 2_048
            )
            let distancePolicy: RouteDistancePolicy
            switch next(&seed) % 4 {
            case 0:
                distancePolicy = .computeFromCoordinates
            case 1:
                distancePolicy = .useSuppliedDistancesWhenValid
            case 2:
                distancePolicy = .useSuppliedDistancesPerSegment
            default:
                distancePolicy = .useSuppliedDistancesForSegments([0, 1])
            }
            try assertBridgeMatchesOracle(
                points,
                policy: policy,
                distancePolicy: distancePolicy,
                file: #filePath,
                line: #line
            )
        }
    }

    func testRepeatedDeterministicCalls() throws {
        let points = makeStraightRoute(count: 40, stepMeters: 12)
        let first = try RunPlayRouteQualityBridge.process(
            points,
            policy: .runningDefault,
            distancePolicy: .computeFromCoordinates,
            cancellationCheckStride: 2_048,
            isCancelled: { false }
        )
        let second = try RunPlayRouteQualityBridge.process(
            points,
            policy: .runningDefault,
            distancePolicy: .computeFromCoordinates,
            cancellationCheckStride: 2_048,
            isCancelled: { false }
        )
        XCTAssertEqual(first.routePoints.map(\.id), second.routePoints.map(\.id))
        XCTAssertEqual(
            first.routePoints.map(\.distanceFromStartMeters),
            second.routePoints.map(\.distanceFromStartMeters)
        )
        XCTAssertEqual(first.distanceSource, second.distanceSource)
        XCTAssertEqual(first.distanceProvenance, second.distanceProvenance)
    }

    func testCancellationDuringConversion() {
        let points = makeStraightRoute(count: 100, stepMeters: 5)
        XCTAssertThrowsError(
            try RunPlayRouteQualityBridge.process(
                points,
                policy: .runningDefault,
                distancePolicy: .computeFromCoordinates,
                cancellationCheckStride: 8,
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Helpers

    private func assertBridgeMatchesOracle(
        _ orderedPoints: [RoutePoint],
        policy: RouteQualityPolicy = .runningDefault,
        distancePolicy: RouteDistancePolicy = .computeFromCoordinates,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let oracle = try SwiftRouteQualityGeometryOracle.process(
            orderedPoints,
            policy: policy,
            distancePolicy: distancePolicy
        )
        let bridge = try RunPlayRouteQualityBridge.process(
            orderedPoints,
            policy: policy,
            distancePolicy: distancePolicy,
            cancellationCheckStride: policy.cancellationCheckStride,
            isCancelled: { false }
        )

        XCTAssertEqual(
            bridge.discardedCoordinatePointCount,
            oracle.discardedCoordinatePointCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            bridge.inferredRouteGapCount,
            oracle.inferredRouteGapCount,
            file: file,
            line: line
        )
        XCTAssertEqual(bridge.distanceSource, oracle.distanceSource, file: file, line: line)
        XCTAssertEqual(
            bridge.distanceProvenance.segmentSources,
            oracle.distanceProvenance.segmentSources,
            file: file,
            line: line
        )
        XCTAssertEqual(
            bridge.routePoints.count,
            oracle.routePoints.count,
            file: file,
            line: line
        )
        XCTAssertEqual(
            bridge.routePoints.map(\.id),
            oracle.routePoints.map(\.id),
            file: file,
            line: line
        )
        XCTAssertEqual(
            bridge.routePoints.map(\.routeSegmentIndex),
            oracle.routePoints.map(\.routeSegmentIndex),
            file: file,
            line: line
        )
        for (lhs, rhs) in zip(bridge.routePoints, oracle.routePoints) {
            assertClose(
                lhs.distanceFromStartMeters,
                rhs.distanceFromStartMeters,
                file: file,
                line: line
            )
        }
    }

    private func assertClose(
        _ value: Double,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if value.isNaN || expected.isNaN {
            XCTAssertEqual(value.isNaN, expected.isNaN, file: file, line: line)
            return
        }
        if value.isInfinite || expected.isInfinite {
            XCTAssertEqual(value, expected, file: file, line: line)
            return
        }
        let tolerance = max(toleranceBase, abs(expected) * toleranceRelative)
        XCTAssertEqual(value, expected, accuracy: tolerance, file: file, line: line)
    }

    private func makeStraightRoute(
        count: Int,
        stepMeters: Double,
        suppliedDistance: Bool = false
    ) -> [RoutePoint] {
        (0..<count).map { index in
            let metres = stepMeters * Double(index)
            return RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                latitude: metres / 111_132.0,
                longitude: 0,
                distanceFromStartMeters: suppliedDistance ? metres : 0,
                elapsedSeconds: Double(index),
                routeSegmentIndex: 0
            )
        }
    }

    /// Track that alternates between the baseline and the supplied offsets, so
    /// each interior point is straddled by neighbours while the bridge across
    /// it stays short — the shape that produces adjacent outlier candidates.
    private func makeOscillatingRoute(_ metres: [Double]) -> [RoutePoint] {
        metres.enumerated().map { index, offset in
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                latitude: offset / 111_132.0,
                longitude: 0,
                distanceFromStartMeters: 0,
                elapsedSeconds: Double(index),
                routeSegmentIndex: 0
            )
        }
    }

    private func makePropertyFixture(
        count: Int,
        segments: Int,
        seed: inout UInt64,
        fixture: Int
    ) -> [RoutePoint] {
        var points: [RoutePoint] = []
        points.reserveCapacity(count)
        var latitude = Double(fixture % 50) * 0.01
        let longitude = Double(fixture % 30) * 0.01
        for index in 0..<count {
            let segment = min(segments - 1, index * segments / max(1, count))
            if index > 0, segment != points[index - 1].routeSegmentIndex {
                latitude += 0.5
            } else {
                latitude += (Double(next(&seed) % 20) + 1.0) / 111_132.0
            }
            if next(&seed) % 37 == 0, index > 0, index + 1 < count {
                // Occasional isolated teleport candidate.
                latitude += 4_000.0 / 111_132.0
            }
            if next(&seed) % 41 == 0, index > 2 {
                // Occasional long time jump without geographic jump (should not gap alone).
            }
            let timestamp: Double
            if next(&seed) % 53 == 0, index > 0 {
                timestamp = points[index - 1].timestamp.timeIntervalSinceReferenceDate + 200
                latitude += 800.0 / 111_132.0
            } else {
                timestamp = Double(index) * (1.0 + Double(next(&seed) % 3))
            }
            let supplied: Double
            if next(&seed) % 11 == 0 {
                supplied = Double.nan
            } else if next(&seed) % 13 == 0 {
                supplied = -1
            } else {
                supplied = Double(index) * 8
            }
            let accuracy: Double? = (next(&seed) % 5 == 0) ? Double(next(&seed) % 250) : nil
            points.append(
                RoutePoint(
                    timestamp: Date(timeIntervalSinceReferenceDate: timestamp),
                    latitude: latitude,
                    longitude: longitude,
                    distanceFromStartMeters: supplied,
                    elapsedSeconds: Double(index),
                    horizontalAccuracy: accuracy,
                    routeSegmentIndex: segment
                )
            )
        }
        return points
    }

    private func next(_ seed: inout UInt64) -> UInt64 {
        // xorshift64*
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return seed
    }
}
