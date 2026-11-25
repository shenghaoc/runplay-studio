import XCTest
@testable import RunPlayCore

/// Behaviour coverage for the combined route-quality geometry bridge. The
/// golden digest in `RouteQualityGoldenTests` pins the full output.
final class RunPlayRouteQualityBridgeTests: XCTestCase {

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

    /// Adjacent outlier candidates are ambiguous rather than isolated, so every
    /// member of a run is retained — including the trailing one.
    func testAdjacentCandidatesAreRetained() throws {
        // Two adjacent candidates (indexes 2 and 3).
        let pair = makeOscillatingRoute([0, 0, 5_000, 0, 5_000, 5_000])

        // A run of three adjacent candidates (indexes 2, 3 and 4).
        let run = makeOscillatingRoute([0, 0, 5_000, 0, 5_000, 0, 0])

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

    private func makeStraightRoute(
        count: Int,
        stepMeters: Double
    ) -> [RoutePoint] {
        (0..<count).map { index in
            let metres = stepMeters * Double(index)
            return RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                latitude: metres / 111_132.0,
                longitude: 0,
                distanceFromStartMeters: 0,
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
}
