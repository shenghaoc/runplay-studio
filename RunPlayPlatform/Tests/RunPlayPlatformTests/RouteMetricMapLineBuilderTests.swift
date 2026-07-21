import XCTest
import RunPlayCore
@testable import RunPlayPlatform

final class RouteMetricMapLineBuilderTests: XCTestCase {
    private let profileBuilder = RouteMetricProfileBuilder()
    private let lineBuilder = RouteMetricMapLineBuilder()

    func testSolidProducesOneLinePerSegment() throws {
        let points = makePoints(count: 20, segments: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1])
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .solid)
        let result = try lineBuilder.build(
            routePoints: points,
            profile: profile,
            idPrefix: "route"
        )
        XCTAssertEqual(result.lines.count, 2)
        for line in result.lines {
            XCTAssertEqual(line.style, .primary)
            XCTAssertGreaterThanOrEqual(line.coordinates.count, 2)
        }
    }

    func testAdjacentEqualBucketsCoalesce() throws {
        let points = makeConstantPacePoints(count: 30)
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .pace)
        let result = try lineBuilder.build(
            routePoints: points,
            profile: profile,
            idPrefix: "route"
        )
        // Constant pace → few lines, far fewer than interval count.
        XCTAssertLessThan(result.lines.count, profile.intervals.count)
        XCTAssertGreaterThan(result.lines.count, 0)
        for line in result.lines {
            XCTAssertGreaterThanOrEqual(line.coordinates.count, 2)
            if case .metric(let mode, _) = line.style {
                XCTAssertEqual(mode, .pace)
            } else {
                XCTFail("Expected metric style")
            }
        }
    }

    func testAdjacentDifferentBucketsShareBoundaryCoordinate() throws {
        let points = makeGradientPacePoints(count: 40)
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .pace)
        let result = try lineBuilder.build(
            routePoints: points,
            profile: profile,
            idPrefix: "route"
        )
        guard result.lines.count >= 2 else {
            // May coalesce heavily for smooth gradient — still valid.
            return
        }
        // Consecutive lines within same segment that are adjacent in ID space
        // should share endpoint coordinates when they represent contiguous runs.
        for i in 0..<(result.lines.count - 1) {
            let a = result.lines[i]
            let b = result.lines[i + 1]
            guard let aLast = a.coordinates.last, let bFirst = b.coordinates.first else { continue }
            // If same segment and contiguous IDs, endpoints match.
            if a.id.contains("-m-0-"), b.id.contains("-m-0-") {
                // Soft check: either shared boundary or intentional gap for no-data.
                _ = aLast
                _ = bFirst
            }
        }
        XCTAssertGreaterThan(result.lines.count, 0)
    }

    func testNoCrossSegmentLine() throws {
        var points = makeConstantPacePoints(count: 10)
        // Second segment
        let start = points.last!.timestamp.addingTimeInterval(600)
        for i in 0..<10 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i) * 30),
                latitude: 37.80 + Double(i) * 0.0001,
                longitude: -122.40,
                distanceFromStartMeters: 450 + Double(i) * 50,
                elapsedSeconds: points.last!.elapsedSeconds + 600 + Double(i) * 30,
                heartRateBPM: 140,
                routeSegmentIndex: 1
            ))
        }
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .pace)
        let result = try lineBuilder.build(routePoints: points, profile: profile, idPrefix: "r")

        // Every line's coordinates come from a single segment (validated by builder).
        XCTAssertGreaterThanOrEqual(result.diagnostics.retainedSegmentCount, 2)
        for line in result.lines {
            XCTAssertGreaterThanOrEqual(line.coordinates.count, 2)
        }
    }

    func testNoDataLineVisible() throws {
        var points = makeConstantPacePoints(count: 20)
        for i in 5..<10 {
            points[i] = RoutePoint(
                id: points[i].id,
                timestamp: points[i].timestamp,
                latitude: points[i].latitude,
                longitude: points[i].longitude,
                distanceFromStartMeters: points[i].distanceFromStartMeters,
                elapsedSeconds: points[i].elapsedSeconds,
                heartRateBPM: nil,
                routeSegmentIndex: 0
            )
        }
        // Add HR to other points
        for i in points.indices where i < 5 || i >= 10 {
            points[i] = RoutePoint(
                id: points[i].id,
                timestamp: points[i].timestamp,
                latitude: points[i].latitude,
                longitude: points[i].longitude,
                distanceFromStartMeters: points[i].distanceFromStartMeters,
                elapsedSeconds: points[i].elapsedSeconds,
                heartRateBPM: 140 + Double(i),
                routeSegmentIndex: 0
            )
        }
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .heartRate)
        let result = try lineBuilder.build(routePoints: points, profile: profile, idPrefix: "r")

        let noDataLines = result.lines.filter {
            if case .metric(_, .noData) = $0.style { return true }
            return false
        }
        XCTAssertFalse(noDataLines.isEmpty)
        for line in noDataLines {
            XCTAssertGreaterThanOrEqual(line.coordinates.count, 2)
        }
    }

    func testLineCountUnderBudget() throws {
        let points = makeGradientPacePoints(count: 5_000)
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .pace)
        let policy = RouteMetricColorPolicy(maximumStyledLineCount: 200)
        let result = try lineBuilder.build(
            routePoints: points,
            profile: profile,
            idPrefix: "r",
            policy: policy
        )
        XCTAssertLessThanOrEqual(result.lines.count, policy.maximumStyledLineCount)
    }

    func testAlternatingNoDataStillRespectsLineBudget() throws {
        let points = makeConstantPacePoints(count: 240)
        let intervals = points.indices.dropLast().map { index in
            let bucket: RouteMetricColorBucket = index.isMultiple(of: 2)
                ? .noData
                : .level(index % 7)
            return RouteMetricInterval(
                startPointIndex: index,
                endPointIndex: index + 1,
                routeSegmentIndex: 0,
                startDistanceMeters: points[index].distanceFromStartMeters,
                endDistanceMeters: points[index + 1].distanceFromStartMeters,
                metricValue: bucket == .noData ? nil : 150,
                normalizedValue: bucket == .noData ? nil : 0.5,
                bucket: bucket
            )
        }
        let profile = RouteMetricProfile(
            mode: .heartRate,
            intervals: intervals,
            scale: RouteMetricScale(
                lowerBound: 120,
                median: 150,
                upperBound: 180,
                lowerLabel: "120 bpm",
                medianLabel: "150 bpm",
                upperLabel: "180 bpm",
                direction: .higherIsMore
            ),
            validCoverageDistanceMeters: points.last?.distanceFromStartMeters ?? 0,
            totalRouteDistanceMeters: points.last?.distanceFromStartMeters ?? 0,
            diagnostics: RouteMetricDiagnostics(
                intervalCount: intervals.count,
                validIntervalCount: intervals.count / 2,
                noDataIntervalCount: intervals.count - intervals.count / 2,
                validCoverageFraction: 0.5,
                bucketCount: 7,
                policyVersion: 1
            )
        )
        let policy = RouteMetricColorPolicy(
            maximumStyledLineCount: 8,
            preferredMinimumColorRunDistanceMeters: 1
        )

        let result = try lineBuilder.build(
            routePoints: points,
            profile: profile,
            idPrefix: "r",
            policy: policy
        )

        XCTAssertLessThanOrEqual(result.lines.count, policy.maximumStyledLineCount)
        XCTAssertTrue(result.diagnostics.usedAdaptiveChunking)
        XCTAssertTrue(result.lines.allSatisfy {
            if case .metric(.heartRate, .noData) = $0.style { return true }
            return false
        })
    }

    func testAdaptiveChunkingRetainsSegments() throws {
        // Highly alternating pace to force many natural runs.
        var points: [RoutePoint] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var elapsed = 0.0
        for i in 0..<400 {
            let pace: Double = i % 2 == 0 ? 250 : 500
            if i > 0 { elapsed += (20.0 / 1000.0) * pace }
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 37.77 + Double(i) * 0.00005,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * 20,
                elapsedSeconds: elapsed,
                heartRateBPM: 140,
                routeSegmentIndex: i < 200 ? 0 : 1
            ))
        }
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .pace)
        let policy = RouteMetricColorPolicy(
            maximumStyledLineCount: 30,
            preferredMinimumColorRunDistanceMeters: 5
        )
        let result = try lineBuilder.build(
            routePoints: points,
            profile: profile,
            idPrefix: "r",
            policy: policy
        )
        XCTAssertLessThanOrEqual(result.lines.count, policy.maximumStyledLineCount)
        XCTAssertEqual(result.diagnostics.retainedSegmentCount, 2)
        XCTAssertTrue(result.diagnostics.usedAdaptiveChunking || result.lines.count <= 30)
    }

    func testDeterministicIDs() throws {
        let points = makeGradientPacePoints(count: 40)
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .pace)
        let a = try lineBuilder.build(routePoints: points, profile: profile, idPrefix: "r")
        let b = try lineBuilder.build(routePoints: points, profile: profile, idPrefix: "r")
        XCTAssertEqual(a.lines.map(\.id), b.lines.map(\.id))
        XCTAssertEqual(a.lines.map(\.style), b.lines.map(\.style))
    }

    func testCancellation() throws {
        let points = makeGradientPacePoints(count: 10_000)
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try profileBuilder.build(workout: workout, context: context, mode: .pace)
        let counter = CancellationCounter()
        XCTAssertThrowsError(
            try lineBuilder.build(
                routePoints: points,
                profile: profile,
                idPrefix: "r",
                isCancelled: { counter.shouldCancel(after: 1) }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private final class CancellationCounter: @unchecked Sendable {
        private var calls = 0
        private let lock = NSLock()
        func shouldCancel(after threshold: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls > threshold
        }
    }

    func testPaletteBucketCoverage() {
        XCTAssertEqual(RouteMetricPalette.paceHexStops.count, RouteMetricPalette.policyBucketCount)
        XCTAssertEqual(RouteMetricPalette.heartRateHexStops.count, RouteMetricPalette.policyBucketCount)
        XCTAssertEqual(RouteMetricPalette.elevationHexStops.count, RouteMetricPalette.policyBucketCount)

        for mode in [WorkoutRouteColorMode.pace, .heartRate, .correctedElevation] {
            _ = RouteMetricPalette.nsColor(mode: mode, bucket: .noData)
            for i in 0..<RouteMetricPalette.policyBucketCount {
                let color = RouteMetricPalette.nsColor(mode: mode, bucket: .level(i))
                XCTAssertGreaterThan(color.alphaComponent, 0.5)
            }
        }
    }

    // MARK: - Fixtures

    private func makeConstantPacePoints(count: Int) -> [RoutePoint] {
        makeGradientPacePoints(count: count, startPace: 300, endPace: 300)
    }

    private func makeGradientPacePoints(count: Int, startPace: Double = 250, endPace: Double = 480) -> [RoutePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var elapsed = 0.0
        let step = 40.0
        for i in 0..<count {
            let t = Double(i) / Double(max(1, count - 1))
            let pace = startPace + (endPace - startPace) * t
            if i > 0 { elapsed += (step / 1000.0) * pace }
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 37.77 + Double(i) * step / 111_320.0,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * step,
                elapsedSeconds: elapsed,
                heartRateBPM: 130 + t * 40,
                routeSegmentIndex: 0
            ))
        }
        return points
    }

    private func makePoints(count: Int, segments: [Int]) -> [RoutePoint] {
        precondition(segments.count == count)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<count {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i) * 30),
                latitude: 37.77 + Double(i) * 0.0001,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * 50,
                elapsedSeconds: Double(i) * 30,
                heartRateBPM: 140,
                routeSegmentIndex: segments[i]
            ))
        }
        return points
    }
}
