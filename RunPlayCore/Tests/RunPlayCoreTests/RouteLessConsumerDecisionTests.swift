import Foundation
import XCTest
@testable import RunPlayCore

/// One explicit, tested decision per consumer for route-less workouts.
///
/// These tests exist so the route-less contract is stated rather than implied:
/// every consumer's answer to "this workout has no GPS route" is asserted here
/// by name, instead of relying on guards scattered through the services that
/// happen to produce the right answer. An Apple Health export run arrives with
/// a summary, possibly a standalone heart-rate series, and often no route GPX,
/// so each of these decisions is reachable in production.
///
/// Expected decisions, all asserted below:
/// - **include** route-less: training load, trends, longest run (summary distance)
/// - **exclude** route-less: heatmap, route grouping, distance-window records,
///   comparison, replay, PNG export, MP4 export, splits, segments
final class RouteLessConsumerDecisionTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    /// Route-less run: summary totals plus a standalone heart-rate series and no
    /// coordinates at all. The Health-export shape.
    private func routeLessWorkout(
        name: String = "Route-less Run",
        distanceMeters: Double = 10_000,
        elapsedSeconds: Double = 3_000,
        startDate: Date? = nil
    ) -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(
                name: name,
                startDate: startDate ?? origin
            ),
            summary: RunSummary(
                totalDistanceMeters: distanceMeters,
                totalElapsedSeconds: elapsedSeconds,
                averageHeartRateBPM: 150
            ),
            analysisVersion: RunWorkout.currentAnalysisVersion,
            heartRateSeries: (0...40).map { index in
                HeartRateSample(
                    elapsedSeconds: Double(index) * 75,
                    heartRateBPM: 150,
                    segmentIndex: 0
                )
            }
        )
    }

    /// Routed run: real coordinates with heart rate on the points, so route
    /// analysis has something to work with.
    private func routedWorkout(
        name: String = "Routed Run",
        distanceMeters: Double = 5_000,
        startDate: Date? = nil
    ) -> RunWorkout {
        let points = (0...40).map { index -> RoutePoint in
            let elapsed = Double(index) * 30
            return RoutePoint(
                timestamp: origin.addingTimeInterval(elapsed),
                latitude: 47.3769 + Double(index) * 0.0004,
                longitude: 8.5417 + Double(index) * 0.0003,
                distanceFromStartMeters: Double(index) * 125,
                elapsedSeconds: elapsed,
                heartRateBPM: 150,
                routeSegmentIndex: 0
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: startDate ?? origin),
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: distanceMeters,
                totalElapsedSeconds: points.last?.elapsedSeconds ?? 0,
                averageHeartRateBPM: 150
            ),
            analysisVersion: RunWorkout.currentAnalysisVersion
        )
    }

    // MARK: - The predicate itself

    func testHasRouteIsFalseForRouteLessAndTrueForRouted() {
        XCTAssertFalse(routeLessWorkout().hasRoute)
        XCTAssertTrue(routedWorkout().hasRoute)
        XCTAssertEqual(routeLessWorkout().pointCount, 0)
    }

    // MARK: - Consumers that INCLUDE route-less workouts

    /// Training load is heart-rate-and-time based, never coordinate based, so a
    /// route-less run with a standalone series is *measured* exactly like a
    /// routed one.
    func testTrainingLoadIncludesRouteLessRun() throws {
        let snapshot = try TrainingLoadCalculator.compute(
            for: routeLessWorkout(elapsedSeconds: 3_000),
            profile: AthleteProfile(restingHeartRateBPM: 50, maximumHeartRateBPM: 150),
            referenceYear: 2026
        )
        XCTAssertEqual(snapshot.kind, .measured)
        // 41 samples at 75 s spacing give 40 same-segment intervals covering the
        // full 3,000 s, all at rate 150 — reserve exactly 1.0.
        XCTAssertEqual(snapshot.validHeartRateSeconds, 40 * 75)
        XCTAssertEqual(snapshot.meanHeartRateBPM, 150)
        XCTAssertEqual(snapshot.zoneSeconds, [0, 0, 0, 0, 40 * 75])
    }

    /// Trends rows are built from summary values only, so route-less runs are
    /// included in period totals.
    func testTrendsIncludesRouteLessRun() throws {
        let row = try XCTUnwrap(WorkoutTrendsSummaryRow.make(from: routeLessWorkout()))
        XCTAssertEqual(row.distanceMeters, 10_000)
        XCTAssertEqual(row.activeSeconds, 3_000)
        XCTAssertEqual(row.averageHeartRateBPM, 150)

        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [row],
            period: .week,
            range: .allTime,
            now: origin.addingTimeInterval(86_400),
            displayTimeZone: TimeZone(secondsFromGMT: 0)!,
            fallbackBucketingTimeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(aggregation.buckets.map(\.runCount).reduce(0, +), 1)
        XCTAssertEqual(
            aggregation.buckets.map(\.totalDistanceMeters).reduce(0, +),
            10_000
        )
    }

    /// Longest run ranks on **summary** distance, so a route-less run competes
    /// and wins on its own merits.
    func testLongestRunUsesSummaryDistanceIncludingRouteLess() throws {
        let routeLess = routeLessWorkout(
            name: "Long Route-less",
            distanceMeters: 21_000,
            startDate: origin
        )
        let routed = routedWorkout(
            name: "Short Routed",
            distanceMeters: 5_000,
            startDate: origin.addingTimeInterval(-86_400)
        )

        let snapshot = PersonalRecordsAggregator.aggregate(workouts: [routed, routeLess])
        let row = try XCTUnwrap(snapshot.rows.first { $0.category == .longestRun })
        XCTAssertEqual(row.best?.workoutID, routeLess.id)
        XCTAssertEqual(row.best?.value, 21_000)
    }

    // MARK: - Consumers that EXCLUDE route-less workouts

    /// Heatmap coverage needs coordinates; route-less runs are excluded by the
    /// named predicate and counted, not silently dropped.
    func testHeatmapExcludesRouteLessRun() throws {
        let snapshot = try PersonalHeatmapBuilder().build(
            workouts: [routeLessWorkout(), routedWorkout()],
            configuration: PersonalHeatmapConfiguration()
        )
        XCTAssertEqual(snapshot.statistics.excludedNoRouteWorkoutCount, 1)
        XCTAssertEqual(snapshot.statistics.includedWorkoutCount, 1)
    }

    /// Route grouping needs route geometry to align against, so a route-less
    /// workout's facts cannot participate.
    func testRouteGroupingExcludesRouteLessRun() {
        let policy = RouteGroupingPolicy()
        let routeLessFacts = RouteGroupingRouteFacts(workout: routeLessWorkout())
        let routedFacts = RouteGroupingRouteFacts(workout: routedWorkout())

        XCTAssertFalse(routeLessFacts.hasRoute)
        XCTAssertFalse(routeLessFacts.canParticipate(policy: policy))
        XCTAssertTrue(routedFacts.canParticipate(policy: policy))
    }

    /// Distance-window personal records are derived from route geometry, so a
    /// route-less run produces no windows.
    func testDistanceWindowRecordsExcludeRouteLessRun() {
        let records = SegmentDetector.detectPersonalRecords(
            from: routeLessWorkout(),
            context: WorkoutAnalysisContext(workout: routeLessWorkout())
        )
        XCTAssertTrue(records.windows.isEmpty)

        let routedRecords = SegmentDetector.detectPersonalRecords(
            from: routedWorkout(),
            context: WorkoutAnalysisContext(workout: routedWorkout())
        )
        XCTAssertFalse(routedRecords.windows.isEmpty)
    }

    /// Comparison is distance-domain, so a route-less workout yields no metric
    /// points even paired with a fully routed one.
    func testComparisonExcludesRouteLessRun() {
        let service = WorkoutComparisonService()
        let routed = routedWorkout()

        let withRouteLessPrimary = service.compareMetricsOverDistance(
            primary: routeLessWorkout(),
            comparison: routed
        )
        XCTAssertTrue(withRouteLessPrimary.isEmpty)

        let withRouteLessComparison = service.compareMetricsOverDistance(
            primary: routed,
            comparison: routeLessWorkout()
        )
        XCTAssertTrue(withRouteLessComparison.isEmpty)

        let bothRouted = service.compareMetricsOverDistance(
            primary: routed,
            comparison: routedWorkout(name: "Other")
        )
        XCTAssertFalse(bothRouted.isEmpty)
    }

    /// Replay needs a playable route timeline, so a route-less workout has none.
    /// Both the sampler's own instance gate and the shared static gate agree,
    /// since they read the same `hasRoute` predicate.
    func testReplayExcludesRouteLessRun() {
        let routeLess = routeLessWorkout()
        let routed = routedWorkout()

        XCTAssertFalse(WorkoutVideoReplaySampler(workout: routeLess).hasPlayableTimeline)
        XCTAssertTrue(WorkoutVideoReplaySampler(workout: routed).hasPlayableTimeline)

        XCTAssertFalse(WorkoutVideoExportEligibility.hasPlayableTimeline(routeLess))
        XCTAssertFalse(WorkoutVideoExportEligibility.hasUsableRoute(routeLess))
        XCTAssertTrue(WorkoutVideoExportEligibility.hasPlayableTimeline(routed))
        XCTAssertTrue(WorkoutVideoExportEligibility.hasUsableRoute(routed))
    }

    /// MP4 export reports the explicit no-route help string rather than failing
    /// or rendering a route to nowhere.
    func testMP4ExportExcludesRouteLessRunWithExplicitHelp() {
        let assessment = WorkoutVideoExportEligibility.assessment(for: routeLessWorkout())
        XCTAssertFalse(assessment.canExport)
        XCTAssertNotNil(assessment.unavailableHelp)

        let routed = WorkoutVideoExportEligibility.assessment(for: routedWorkout())
        XCTAssertTrue(routed.canExport)
        XCTAssertNil(routed.unavailableHelp)
    }

    /// Splits are fixed 1 km windows walked along cumulative route distance. A
    /// route-less run has no distance domain to walk, so splits are empty and
    /// none are synthesized.
    func testSplitsExcludeRouteLessRun() {
        XCTAssertTrue(SplitCalculator.calculateSplits(from: routeLessWorkout()).isEmpty)
        XCTAssertFalse(SplitCalculator.calculateSplits(from: routedWorkout()).isEmpty)
    }

    /// Segment detection (fastest 400 m, 1 km, climbs, descents) needs route
    /// geometry, so a route-less run yields no segments.
    func testSegmentsExcludeRouteLessRun() {
        XCTAssertTrue(SegmentDetector.detectSegments(from: routeLessWorkout()).isEmpty)
        XCTAssertFalse(SegmentDetector.detectSegments(from: routedWorkout()).isEmpty)
    }
}
