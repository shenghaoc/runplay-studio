import XCTest
@testable import RunPlayCore

/// Reproducible release benchmark for the complete SegmentDetector cutover.
///
/// Ordinary CI skips wall-clock work. Run through
/// `scripts/run-segment-detector-benchmark.sh`; the benchmark reports timings
/// but asserts only semantic parity.
final class SegmentDetectorBenchmark: XCTestCase {
    private static let standardPointCount = 100_000
    private static let productLimitPointCount = 1_000_000
    private static let warmupIterations = 3
    private static let measuredIterations = 10

    func testSegmentDetectorBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1",
            "Set RUNPLAY_BENCHMARK=1 to run the release benchmark."
        )

        try Self.runFixture(
            pointCount: Self.standardPointCount,
            warmups: Self.warmupIterations,
            measurements: Self.measuredIterations
        )

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.runFixture(
                pointCount: Self.productLimitPointCount,
                warmups: 1,
                measurements: 3
            )
        }
    }

    private static func runFixture(
        pointCount: Int,
        warmups: Int,
        measurements: Int
    ) throws {
        let workout = RunWorkout(routePoints: makeFixture(pointCount))
        let context = WorkoutAnalysisContext(workout: workout)
        var oracleSamples: [Double] = []
        var productionSamples: [Double] = []
        var oracleResult: [SegmentHighlight] = []
        var productionResult: [SegmentHighlight] = []

        for iteration in 0..<(warmups + measurements) {
            let oracleElapsed = time {
                oracleResult = SwiftSegmentDetectorOracle.detectSegments(
                    from: workout,
                    context: context
                )
            }
            let productionElapsed = try timeThrowing {
                productionResult = try SegmentDetector.detectSegments(
                    from: workout,
                    context: context,
                    policy: .runningDefault,
                    isCancelled: { false }
                )
            }

            guard iteration >= warmups else { continue }
            oracleSamples.append(oracleElapsed)
            productionSamples.append(productionElapsed)
        }

        XCTAssertEqual(digest(productionResult), digest(oracleResult))

        let oracleMedian = median(oracleSamples)
        let productionMedian = median(productionSamples)
        print("""

        RunPlay SegmentDetector benchmark
        fixture: \(pointCount) points, four segments, elevation and heart rate
        \(warmups) warm-ups + \(measurements) measured iterations, medians
        pre-migration Swift oracle: \(format(oracleMedian)) ms
        production C++23 path:      \(format(productionMedian)) ms
        production / oracle ratio:  \(String(format: "%.3f", productionMedian / max(oracleMedian, 1e-12)))
        semantic merge gate: exact durable highlight digest parity
        """)
    }

    private static func makeFixture(_ count: Int) -> [RoutePoint] {
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        var points: [RoutePoint] = []
        points.reserveCapacity(count)
        let pointsPerSegment = max(1, count / 4)

        for index in 0..<count {
            let distance = Double(index) * 10
            let elapsed = Double(index) * 3
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 1 + Double(index % 10_000) / 1_000_000,
                longitude: 103 + Double(index / 10_000) / 1_000_000,
                altitudeMeters: 40 + Double((index * 17) % 80) / 4,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                heartRateBPM: 125 + Double(index % 45),
                routeSegmentIndex: index / pointsPerSegment
            ))
        }
        return points
    }

    private static func digest(_ segments: [SegmentHighlight]) -> [String] {
        segments.map { segment in
            let sourceRange = String(segment.sourcePointRange.lowerBound)
                + "..<"
                + String(segment.sourcePointRange.upperBound)
            let pace = segment.paceSecondsPerKilometer
                .map { String($0.bitPattern) } ?? "nil"
            let elevation = segment.elevationDeltaMeters
                .map { String($0.bitPattern) } ?? "nil"
            let heartRate = segment.averageHeartRate
                .map { String($0.bitPattern) } ?? "nil"

            var fields: [String] = []
            fields.reserveCapacity(14)
            fields.append(segment.type.rawValue)
            fields.append(segment.title)
            fields.append(segment.subtitle)
            fields.append(String(segment.startDistanceMeters.bitPattern))
            fields.append(String(segment.endDistanceMeters.bitPattern))
            fields.append(String(segment.startElapsedSeconds.bitPattern))
            fields.append(String(segment.endElapsedSeconds.bitPattern))
            fields.append(String(segment.durationSeconds.bitPattern))
            fields.append(String(segment.distanceMeters.bitPattern))
            fields.append(pace)
            fields.append(elevation)
            fields.append(heartRate)
            fields.append(sourceRange)
            fields.append(String(segment.displayPriority))
            return fields.joined(separator: "|")
        }
    }

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
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }
}
