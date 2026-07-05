import XCTest
@testable import RunPlayStudio

final class WorkoutComparisonTests: XCTestCase {

    let service = WorkoutComparisonService()

    // MARK: - Summary Comparison

    func testIdenticalWorkoutsGiveZeroDeltas() {
        let workout = createSampleWorkout(distance: 5000, pace: 300)
        let summary = service.compare(primary: workout, comparison: workout)

        XCTAssertEqual(summary.distanceDeltaMeters, 0, accuracy: 0.1)
        XCTAssertEqual(summary.durationDeltaSeconds, 0, accuracy: 0.1)
        XCTAssertEqual(summary.paceDeltaSecondsPerKm, 0, accuracy: 0.1)
    }

    func testFasterRunGivesCorrectPaceDelta() {
        let faster = createSampleWorkout(distance: 5000, pace: 270) // 4:30/km
        let slower = createSampleWorkout(distance: 5000, pace: 330) // 5:30/km
        let summary = service.compare(primary: faster, comparison: slower)

        // Primary is faster, so pace delta should be negative
        XCTAssertLessThan(summary.paceDeltaSecondsPerKm, 0)
        XCTAssertEqual(summary.paceDeltaSecondsPerKm, -60, accuracy: 5)
    }

    func testSummaryDeltaFormattingShowsDirection() {
        let faster = createSampleWorkout(distance: 5000, pace: 270)
        let slower = createSampleWorkout(distance: 5000, pace: 330)

        let summary = service.compare(primary: faster, comparison: slower)

        XCTAssertEqual(summary.distanceDeltaFormatted, "0.00 km even")
        XCTAssertEqual(summary.durationDeltaFormatted, "-5:00 faster")
        XCTAssertEqual(summary.paceDeltaFormatted, "-1:00 /km faster")
    }

    func testLongerRunGivesCorrectDistanceDelta() {
        let longer = createSampleWorkout(distance: 10000, pace: 300)
        let shorter = createSampleWorkout(distance: 5000, pace: 300)
        let summary = service.compare(primary: longer, comparison: shorter)

        XCTAssertEqual(summary.distanceDeltaMeters, 5000, accuracy: 10)
        XCTAssertEqual(summary.distanceDeltaFormatted, "+5.00 km longer")
    }

    func testWinnerIsCorrect() {
        let faster = createSampleWorkout(distance: 5000, pace: 270)
        let slower = createSampleWorkout(distance: 5000, pace: 330)

        let summary1 = service.compare(primary: faster, comparison: slower)
        XCTAssertEqual(summary1.winner, .primary)

        let summary2 = service.compare(primary: slower, comparison: faster)
        XCTAssertEqual(summary2.winner, .comparison)
    }

    func testMaxHeartRateDeltaIsReportedWhenAvailable() {
        var primary = createSampleWorkout(distance: 5000, pace: 300)
        var comparison = createSampleWorkout(distance: 5000, pace: 300)
        primary.summary.maxHeartRateBPM = 182
        comparison.summary.maxHeartRateBPM = 171

        let summary = service.compare(primary: primary, comparison: comparison)

        XCTAssertEqual(summary.maxHRDelta, 11)
        XCTAssertEqual(summary.maxHRDeltaFormatted, "+11 bpm higher")
    }

    func testSimilarPaceIsTie() {
        let run1 = createSampleWorkout(distance: 5000, pace: 300)
        let run2 = createSampleWorkout(distance: 5000, pace: 303) // Only 3 sec difference
        let summary = service.compare(primary: run1, comparison: run2)

        XCTAssertEqual(summary.winner, .tie)
    }

    func testDemoComparisonFixturesCompareSafely() throws {
        let primary = try loadFixture("sample_run.json")
        let comparison = try loadFixture("fixtures/comparison_park_run.json")

        let summary = service.compare(primary: primary, comparison: comparison)
        let splits = service.compareSplits(primary: primary, comparison: comparison)
        let metrics = service.compareMetricsOverDistance(primary: primary, comparison: comparison)

        XCTAssertNotEqual(primary.id, comparison.id)
        XCTAssertFalse(summary.warnings.contains(.differentRouteShape))
        XCTAssertFalse(summary.warnings.contains(.differentDistances))
        XCTAssertGreaterThanOrEqual(splits.count, 7)
        XCTAssertFalse(metrics.isEmpty)
        XCTAssertLessThanOrEqual(metrics.last?.distanceMeters ?? .infinity, min(primary.summary.totalDistanceMeters, comparison.summary.totalDistanceMeters))
    }

    // MARK: - Split Comparison

    func testSplitComparisonAlignsByIndex() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)
        let splits = service.compareSplits(primary: primary, comparison: comparison)

        XCTAssertFalse(splits.isEmpty)
        XCTAssertEqual(splits[0].splitIndex, 1)
    }

    func testDifferentSplitCountHandled() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 3000, pace: 300)
        let splits = service.compareSplits(primary: primary, comparison: comparison)

        // Should have splits for the longer workout
        XCTAssertGreaterThan(splits.count, 0)

        // Later splits should have nil for the shorter workout
        if splits.count > 3 {
            XCTAssertNil(splits.last?.comparisonSplit)
        }
    }

    func testSplitWinnerIsCorrect() {
        let primary = createSampleWorkout(distance: 5000, pace: 270) // Faster
        let comparison = createSampleWorkout(distance: 5000, pace: 330) // Slower
        let splits = service.compareSplits(primary: primary, comparison: comparison)

        // All splits should have a winner (not unavailable)
        for split in splits where split.winner != .unavailable {
            // Winner should be consistent
            XCTAssertNotEqual(split.winner, .tie, "Different paces should not tie")
        }
    }

    func testSplitDeltaFormattingShowsDirection() {
        let primary = createSampleWorkout(distance: 5000, pace: 270)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let split = service.compareSplits(primary: primary, comparison: comparison)[0]

        XCTAssertEqual(split.formattedPaceDelta, "-0:55 /km faster")
    }

    // MARK: - Metric Series

    func testMetricSeriesClampsToCommonDistance() {
        let primary = createSampleWorkout(distance: 10000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let metrics = service.compareMetricsOverDistance(primary: primary, comparison: comparison)

        XCTAssertFalse(metrics.isEmpty)
        // Last point should not exceed the shorter workout's distance
        if let last = metrics.last {
            XCTAssertLessThanOrEqual(last.distanceMeters, 5100) // Allow small margin
        }
    }

    func testMetricSeriesHandlesEmptyRoute() {
        let primary = RunWorkout(routePoints: [])
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let metrics = service.compareMetricsOverDistance(primary: primary, comparison: comparison)

        XCTAssertTrue(metrics.isEmpty)
    }

    func testMetricSeriesNoNaN() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)
        let metrics = service.compareMetricsOverDistance(primary: primary, comparison: comparison)

        for point in metrics {
            if let pace = point.primaryPace {
                XCTAssertTrue(pace.isFinite, "Primary pace should be finite")
                XCTAssertFalse(pace.isNaN, "Primary pace should not be NaN")
            }
            if let pace = point.comparisonPace {
                XCTAssertTrue(pace.isFinite, "Comparison pace should be finite")
                XCTAssertFalse(pace.isNaN, "Comparison pace should not be NaN")
            }
            if let delta = point.paceDelta {
                XCTAssertTrue(delta.isFinite, "Pace delta should be finite")
                XCTAssertFalse(delta.isNaN, "Pace delta should not be NaN")
            }
        }
    }

    func testMetricSeriesFiltersNonFiniteValues() {
        var primary = createSampleWorkout(distance: 5000, pace: 300)
        var comparison = createSampleWorkout(distance: 5000, pace: 330)
        primary.routePoints[0].paceSecondsPerKilometer = .nan
        primary.routePoints[0].altitudeMeters = .infinity
        comparison.routePoints[0].heartRateBPM = .nan

        let metrics = service.compareMetricsOverDistance(primary: primary, comparison: comparison)

        XCTAssertNil(metrics.first?.primaryPace)
        XCTAssertNil(metrics.first?.primaryElevation)
        XCTAssertNil(metrics.first?.comparisonHR)
    }

    func testInvalidMetricSampleIntervalReturnsEmptySeries() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let metrics = service.compareMetricsOverDistance(
            primary: primary,
            comparison: comparison,
            sampleIntervalMeters: 0
        )

        XCTAssertTrue(metrics.isEmpty)
    }

    // MARK: - Warnings

    func testDifferentDistancesWarning() {
        let primary = createSampleWorkout(distance: 10000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let summary = service.compare(primary: primary, comparison: comparison)

        XCTAssertTrue(summary.warnings.contains(.differentDistances))
    }

    func testMissingHRWarning() {
        let primary = createSampleWorkout(distance: 5000, pace: 300, includeHR: false)
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let summary = service.compare(primary: primary, comparison: comparison)

        XCTAssertTrue(summary.warnings.contains(.missingHeartRate))
    }

    func testMissingElevationWarning() {
        let primary = createSampleWorkout(distance: 5000, pace: 300, includeElevation: false)
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let summary = service.compare(primary: primary, comparison: comparison)

        XCTAssertTrue(summary.warnings.contains(.missingElevation))
    }

    func testFewPointsWarning() {
        let primary = createShortWorkout()
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let summary = service.compare(primary: primary, comparison: comparison)

        XCTAssertTrue(summary.warnings.contains(.tooFewPoints))
    }

    func testInsufficientOverlapWarning() {
        let primary = createSampleWorkout(distance: 200, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let summary = service.compare(primary: primary, comparison: comparison)

        XCTAssertTrue(summary.warnings.contains(.insufficientOverlap))
    }

    func testDifferentRouteShapeWarning() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        var comparison = createSampleWorkout(distance: 5000, pace: 300)
        comparison.routePoints = comparison.routePoints.map { point in
            var shifted = point
            shifted.latitude += 0.1
            return shifted
        }

        let summary = service.compare(primary: primary, comparison: comparison)

        XCTAssertTrue(summary.warnings.contains(.differentRouteShape))
        XCTAssertEqual(ComparisonWarning.differentRouteShape.rawValue, "Routes differ; comparison uses distance alignment")
    }

    // MARK: - Edge Cases

    func testEmptyRouteDoesNotCrash() {
        let primary = RunWorkout(routePoints: [])
        let comparison = RunWorkout(routePoints: [])
        let summary = service.compare(primary: primary, comparison: comparison)

        XCTAssertNotNil(summary)
    }

    func testOnePointRouteDoesNotCrash() {
        let points = [
            RoutePoint(timestamp: Date(), latitude: 37.7749, longitude: -122.4194,
                       altitudeMeters: 10, distanceFromStartMeters: 0, elapsedSeconds: 0)
        ]
        let primary = RunWorkout(routePoints: points)
        let comparison = createSampleWorkout(distance: 5000, pace: 300)

        let summary = service.compare(primary: primary, comparison: comparison)
        XCTAssertNotNil(summary)
    }

    // MARK: - Helpers

    private func loadFixture(_ path: String) throws -> RunWorkout {
        let testFile = URL(fileURLWithPath: #filePath)
        let url = testFile
            .deletingLastPathComponent()  // WorkoutComparisonTests
            .deletingLastPathComponent()  // RunPlayStudioTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Resources")
            .appendingPathComponent(path)
        return try JSONWorkoutImporter().importWorkout(from: url)
    }

    private func createSampleWorkout(
        distance: Double,
        pace: Double,
        includeHR: Bool = true,
        includeElevation: Bool = true
    ) -> RunWorkout {
        let count = 50
        let startDate = Date()
        var points: [RoutePoint] = []

        for i in 0..<count {
            let fraction = Double(i) / Double(count - 1)
            let dist = fraction * distance
            let time = dist * pace / 1000

            points.append(RoutePoint(
                timestamp: startDate.addingTimeInterval(time),
                latitude: 37.7749 + fraction * 0.01,
                longitude: -122.4194,
                altitudeMeters: includeElevation ? 10 + fraction * 30 : nil,
                distanceFromStartMeters: dist,
                elapsedSeconds: time,
                heartRateBPM: includeHR ? 120 + fraction * 40 : nil
            ))
        }

        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Test Run", activityType: "running"),
            source: .json,
            routePoints: points
        )

        let analyzer = WorkoutAnalyzer()
        analyzer.analyze(&workout)
        return workout
    }

    private func createShortWorkout() -> RunWorkout {
        let points = (0..<5).map { i in
            RoutePoint(
                timestamp: Date(),
                latitude: 37.7749 + Double(i) * 0.001,
                longitude: -122.4194,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(i) * 50,
                elapsedSeconds: Double(i) * 15
            )
        }
        return RunWorkout(routePoints: points)
    }
}
