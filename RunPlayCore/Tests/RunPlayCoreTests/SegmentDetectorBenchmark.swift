import XCTest
@testable import RunPlayCore

/// Reproducible release benchmark for the complete SegmentDetector.
///
/// Ordinary CI skips wall-clock work. Run through
/// `scripts/run-segment-detector-benchmark.sh`. Each case prints one
/// `BenchmarkBaselineLine`: an absolute Swift timing with no ratio gate. The
/// only assertions are that repeated runs give identical durable highlights
/// and identical adapter candidates.
final class SegmentDetectorBenchmark: XCTestCase {
    private static let benchmarkName = "SegmentDetectorBenchmark"
    private static let standardPointCount = 100_000
    private static let productLimitPointCount = 1_000_000
    private static let warmupIterations = 3
    private static let measuredIterations = 10

    func testSegmentDetectorBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1",
            "Set RUNPLAY_BENCHMARK=1 to run the release benchmark."
        )

        print("""

        RunPlay SegmentDetector benchmark
        fixture: four segments, elevation and heart rate; medians in ms
        """)

        try Self.runFixture(
            casePrefix: "",
            pointCount: Self.standardPointCount,
            warmups: Self.warmupIterations,
            measurements: Self.measuredIterations
        )

        if ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1" {
            try Self.runFixture(
                casePrefix: "product-limit-",
                pointCount: Self.productLimitPointCount,
                warmups: 1,
                measurements: 3
            )
        }
    }

    private static func runFixture(
        casePrefix: String,
        pointCount: Int,
        warmups: Int,
        measurements: Int
    ) throws {
        let workout = RunWorkout(routePoints: makeFixture(pointCount))
        let context = WorkoutAnalysisContext(workout: workout)
        let config = SegmentDetector.searchConfiguration(
            points: workout.routePoints, timeline: context.timeline, elevationProfile: context.elevationProfile,
            policy: .runningDefault
        )
        var swiftAdapterTimes: [Double] = []
        var productionSamples: [Double] = []
        var referenceHighlights: [String]?
        var referenceCandidates: [UInt64]?
        var candidateCount = 0

        for iteration in 0..<(warmups + measurements) {
            var productionResult: [SegmentHighlight] = []
            let productionElapsed = try timeThrowing {
                productionResult = try SegmentDetector.detectSegments(
                    from: workout,
                    context: context,
                    policy: .runningDefault,
                    isCancelled: { false }
                )
            }
            let highlights = digest(productionResult)
            if let referenceHighlights {
                XCTAssertEqual(highlights, referenceHighlights)
            }
            referenceHighlights = highlights

            var swift: RunPlaySegmentWindowSearchResult?
            let swiftElapsed = try timeThrowing {
                swift = try RunPlaySegmentDetectorAdapter.search(
                    routePoints: workout.routePoints, timeline: context.timeline, elevationProfile: context.elevationProfile,
                    configuration: config, cancellationCheckStride: RouteQualityPolicy.runningDefault.cancellationCheckStride,
                    isCancelled: { false }
                )
            }
            let searchResult = try XCTUnwrap(swift)
            candidateCount = searchResult.candidates.count
            let candidates = candidateDigest(searchResult)
            if let referenceCandidates {
                XCTAssertEqual(candidates, referenceCandidates)
            }
            referenceCandidates = candidates

            guard iteration >= warmups else { continue }
            swiftAdapterTimes.append(swiftElapsed)
            productionSamples.append(productionElapsed)
        }

        print(BenchmarkBaselineLine.make(
            benchmarkName,
            "\(casePrefix)detector",
            counts: ["points": pointCount, "highlights": referenceHighlights?.count ?? 0],
            iterations: measurements,
            medianMilliseconds: median(productionSamples)
        ))
        print(BenchmarkBaselineLine.make(
            benchmarkName,
            "\(casePrefix)adapter",
            counts: ["points": pointCount, "candidates": candidateCount],
            iterations: measurements,
            medianMilliseconds: median(swiftAdapterTimes)
        ))
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

    private static func candidateDigest(_ result: RunPlaySegmentWindowSearchResult) -> [UInt64] {
        var words = [
            UInt64(result.paceEvaluationCount), UInt64(result.elevationEvaluationCount), UInt64(result.candidates.count),
        ]
        for c in result.candidates {
            words.append(UInt64(c.kind.rawValue))
            words.append(c.startDistanceMeters.bitPattern)
            words.append(c.endDistanceMeters.bitPattern)
            words.append(c.selectionValue.bitPattern)
        }
        return words
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
}
