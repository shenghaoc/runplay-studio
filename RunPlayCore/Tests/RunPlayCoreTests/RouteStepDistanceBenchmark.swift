import XCTest
@testable import RunPlayCore

/// Reproducible release benchmark for the route step-distance cutover.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`, so ordinary CI never runs a
/// wall-clock measurement or asserts on one. Run it through
/// `scripts/run-step-distance-benchmark.sh`, which builds in release and sets
/// the variable.
///
/// Reports the three measurements the cutover is judged on:
///
/// 1. the pure Swift step loop this PR replaces;
/// 2. the complete bridge, including `RouteInputSample` conversion and output
///    buffer handling — the fixed boundary tax, not kernel speed;
/// 3. `RouteQualityProcessor.process`, the production operation actually being
///    replaced and therefore the merge gate.
///
/// Measurement 2 is expected to be materially slower than measurement 1. That
/// is diagnostic evidence for combining the larger route-quality pipeline into
/// one call, not a regression to hide. See `docs/phase-plan.md`.
final class RouteStepDistanceBenchmark: XCTestCase {

    private static let pointCount = 100_000
    private static let warmupIterations = 5
    private static let measuredIterations = 20

    func testStepDistanceBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1",
            "Set RUNPLAY_BENCHMARK=1 to run the release benchmark."
        )

        let points = Self.makePoints(Self.pointCount)
        let processor = RouteQualityProcessor()

        var swiftSamples: [Double] = []
        var bridgeSamples: [Double] = []
        var processSamples: [Double] = []

        var swiftTotal = 0.0
        var bridgeTotal = 0.0
        var processedDistance = 0.0

        let total = Self.warmupIterations + Self.measuredIterations
        for iteration in 0..<total {
            let swiftElapsed = Self.time { swiftTotal = Self.swiftStepTotal(points) }
            let bridgeElapsed = try Self.timeThrowing {
                bridgeTotal = try RunPlayRouteStepDistanceBridge
                    .compute(points)
                    .totalDistanceMeters
            }
            let processElapsed = try Self.timeThrowing {
                let result = try processor.process(
                    points,
                    distancePolicy: .computeFromCoordinates,
                    isCancelled: { false }
                )
                processedDistance = result.routePoints.last?.distanceFromStartMeters ?? 0
            }

            guard iteration >= Self.warmupIterations else { continue }
            swiftSamples.append(swiftElapsed)
            bridgeSamples.append(bridgeElapsed)
            processSamples.append(processElapsed)
        }

        // Parity is the point of the cutover; assert it rather than timing.
        XCTAssertEqual(bridgeTotal, swiftTotal, "bridge must match the Swift step loop")
        XCTAssertGreaterThan(processedDistance, 0)

        let swiftMedian = Self.median(swiftSamples)
        let bridgeMedian = Self.median(bridgeSamples)
        let processMedian = Self.median(processSamples)

        print("""

        RunPlay route step-distance benchmark
        fixture: \(Self.pointCount) points, coordinate-derived, 4 segments
        \(Self.warmupIterations) warm-ups + \(Self.measuredIterations) measured iterations, medians

          1. pure Swift step loop              \(Self.ms(swiftMedian))
          2. complete bridge (incl. conversion) \(Self.ms(bridgeMedian))  \
        (\(String(format: "%.2f", bridgeMedian / swiftMedian))x measurement 1)
          3. RouteQualityProcessor.process      \(Self.ms(processMedian))

        Measurement 3 is the merge gate: it is the production operation this
        cutover replaces. Measurement 2 is the fixed per-call boundary tax.

        """)
    }

    // MARK: - Fixture

    /// Deterministic synthetic route. No private data, no randomness.
    static func makePoints(_ count: Int) -> [RoutePoint] {
        var points: [RoutePoint] = []
        points.reserveCapacity(count)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for index in 0..<count {
            let meters = Double(index) * 10
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(Double(index)),
                    latitude: 1.0 + meters / 111_132,
                    longitude: 103.0,
                    altitudeMeters: nil,
                    distanceFromStartMeters: 0,
                    elapsedSeconds: Double(index),
                    routeSegmentIndex: index / 25_000
                )
            )
        }
        return points
    }

    /// The pure Swift step series this PR replaces, summed left to right.
    private static func swiftStepTotal(_ points: [RoutePoint]) -> Double {
        guard !points.isEmpty else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            guard previous.routeSegmentIndex == current.routeSegmentIndex else { continue }
            total += GeoDistance.distanceMeters(
                fromLat: previous.latitude,
                lon: previous.longitude,
                toLat: current.latitude,
                lon: current.longitude
            )
        }
        return total
    }

    // MARK: - Timing

    private static func time(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func timeThrowing(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty)
        return values.sorted()[values.count / 2]
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%8.3f ms", value)
    }
}
