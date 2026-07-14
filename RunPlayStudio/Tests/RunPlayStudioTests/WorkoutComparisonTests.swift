import XCTest
import RunPlayCore
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

    func testDifferentPauseDurationsSeparateBothClocksAndKeepActivePaceEqual() {
        let paused = createPauseComparisonWorkout(pauseSeconds: 120)
        let uninterrupted = createPauseComparisonWorkout(pauseSeconds: 0)

        let summary = service.compare(primary: paused, comparison: uninterrupted)

        XCTAssertEqual(summary.elapsedTimeDeltaSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(summary.activeTimeDeltaSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(summary.pausedTimeDeltaSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(summary.paceDeltaSecondsPerKm, 0, accuracy: 0.001)
        XCTAssertEqual(summary.elapsedPaceDeltaSecondsPerKm, 120, accuracy: 0.001)
        XCTAssertEqual(summary.winner, .tie)
        XCTAssertTrue(summary.warnings.contains(.differentPauseDurations))
    }

    func testPauseDurationWarningUsesThirtySecondThreshold() {
        let uninterrupted = createPauseComparisonWorkout(pauseSeconds: 0)
        let belowThreshold = service.compare(
            primary: createPauseComparisonWorkout(pauseSeconds: 29),
            comparison: uninterrupted
        )
        let atThreshold = service.compare(
            primary: createPauseComparisonWorkout(pauseSeconds: 30),
            comparison: uninterrupted
        )

        XCTAssertFalse(belowThreshold.warnings.contains(.differentPauseDurations))
        XCTAssertTrue(atThreshold.warnings.contains(.differentPauseDurations))
    }

    func testSelectedDistanceComparisonExposesElapsedAndActiveDeltas() {
        let paused = createPauseComparisonWorkout(pauseSeconds: 120)
        let uninterrupted = createPauseComparisonWorkout(pauseSeconds: 0)

        let metrics = service.metricsAtDistance(
            750,
            primary: paused,
            comparison: uninterrupted
        )

        XCTAssertEqual(metrics.primaryElapsedSeconds ?? -1, 345, accuracy: 0.001)
        XCTAssertEqual(metrics.comparisonElapsedSeconds ?? -1, 225, accuracy: 0.001)
        XCTAssertEqual(metrics.elapsedTimeDeltaSeconds ?? -1, 120, accuracy: 0.001)
        XCTAssertEqual(metrics.primaryActiveSeconds ?? -1, 225, accuracy: 0.001)
        XCTAssertEqual(metrics.comparisonActiveSeconds ?? -1, 225, accuracy: 0.001)
        XCTAssertEqual(metrics.activeTimeDeltaSeconds ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.paceDeltaSecondsPerKm ?? -1, 0, accuracy: 0.001)
    }

    func testSelectedTerminalDistanceIncludesSameSegmentStationaryTime() {
        let start = Date()
        let primary = RunWorkout(routePoints: [
            RoutePoint(timestamp: start, latitude: 1, longitude: 1, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: start.addingTimeInterval(300), latitude: 1.01, longitude: 1, distanceFromStartMeters: 1_000, elapsedSeconds: 300),
            RoutePoint(timestamp: start.addingTimeInterval(400), latitude: 1.01, longitude: 1, distanceFromStartMeters: 1_000, elapsedSeconds: 400)
        ])
        let comparison = RunWorkout(routePoints: [
            RoutePoint(timestamp: start, latitude: 1, longitude: 1, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: start.addingTimeInterval(300), latitude: 1.01, longitude: 1, distanceFromStartMeters: 1_000, elapsedSeconds: 300),
            RoutePoint(timestamp: start.addingTimeInterval(350), latitude: 1.01, longitude: 1, distanceFromStartMeters: 1_000, elapsedSeconds: 350)
        ])

        let metrics = service.metricsAtDistance(1_000, primary: primary, comparison: comparison)

        XCTAssertEqual(metrics.primaryElapsedSeconds ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(metrics.primaryActiveSeconds ?? -1, 400, accuracy: 0.001)
        XCTAssertEqual(metrics.comparisonElapsedSeconds ?? -1, 350, accuracy: 0.001)
        XCTAssertEqual(metrics.comparisonActiveSeconds ?? -1, 350, accuracy: 0.001)
        XCTAssertEqual(metrics.elapsedTimeDeltaSeconds ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(metrics.activeTimeDeltaSeconds ?? -1, 50, accuracy: 0.001)
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
        XCTAssertEqual(summary.durationDeltaFormatted, "-5:00 shorter")
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

        XCTAssertEqual(split.formattedPaceDelta, "-1:00 /km faster")
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

    func testTinyMetricIntervalIsBoundedAndStillCoversCommonEndpoint() throws {
        let start = Date()
        let points = [
            RoutePoint(timestamp: start, latitude: 1, longitude: 103, altitudeMeters: 10, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: start.addingTimeInterval(100), latitude: 1.001, longitude: 103, altitudeMeters: 20, distanceFromStartMeters: 1_000_000_000, elapsedSeconds: 100)
        ]
        let primary = RunWorkout(routePoints: points)
        let comparison = RunWorkout(routePoints: points)

        let metrics = service.compareMetricsOverDistance(
            primary: primary,
            comparison: comparison,
            sampleIntervalMeters: .leastNonzeroMagnitude
        )

        XCTAssertEqual(metrics.count, 1_000)
        XCTAssertEqual(try XCTUnwrap(metrics.last).distanceMeters, 1_000_000_000, accuracy: 0.001)
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
        XCTAssertNil(summary.primaryElevationGainMeters)
        XCTAssertNotNil(summary.comparisonElevationGainMeters)
        XCTAssertNil(summary.elevationGainDeltaMeters)
        XCTAssertEqual(summary.elevationGainDeltaFormatted, "N/A")
    }

    func testElevationGainComparisonUsesCorrectedProfilesInsteadOfStoredSummaryValues() throws {
        var noisyFlat = createSampleWorkout(distance: 5_000, pace: 300)
        for index in noisyFlat.routePoints.indices {
            noisyFlat.routePoints[index].altitudeMeters = 100 + Double((index % 3) - 1)
        }
        noisyFlat.summary.elevationGainMeters = 999
        let climb = createSampleWorkout(distance: 5_000, pace: 300)

        let summary = service.compare(primary: noisyFlat, comparison: climb)

        XCTAssertEqual(try XCTUnwrap(summary.primaryElevationGainMeters), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(summary.comparisonElevationGainMeters), 30, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(summary.elevationGainDeltaMeters), -30, accuracy: 3)
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
        XCTAssertEqual(ComparisonWarning.differentRouteShape.rawValue, "Routes differ; comparison based on distance")
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

    // MARK: - Common Distance

    func testCommonDistanceClampsToShorterRoute() {
        let primary = createSampleWorkout(distance: 10000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let common = service.commonDistance(primary: primary, comparison: comparison)

        XCTAssertEqual(common, 5000, accuracy: 10)
    }

    func testCommonDistanceIsZeroForEmptyRoute() {
        let primary = RunWorkout(routePoints: [])
        let comparison = createSampleWorkout(distance: 5000, pace: 300)
        let common = service.commonDistance(primary: primary, comparison: comparison)

        XCTAssertEqual(common, 0, accuracy: 0.1)
    }

    // MARK: - Distance Selection Interpolation

    func testMetricsAtDistanceStart() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let metrics = service.metricsAtDistance(0, primary: primary, comparison: comparison)

        XCTAssertEqual(metrics.selectedDistanceMeters, 0, accuracy: 0.1)
        XCTAssertEqual(metrics.primaryElapsedSeconds ?? -1, 0, accuracy: 1)
        XCTAssertEqual(metrics.comparisonElapsedSeconds ?? -1, 0, accuracy: 1)
        XCTAssertEqual(metrics.timeDeltaSeconds ?? -1, 0, accuracy: 1)
    }

    func testMetricsAtDistanceMidpoint() {
        let primary = createSampleWorkout(distance: 5000, pace: 300) // 5:00/km
        let comparison = createSampleWorkout(distance: 5000, pace: 330) // 5:30/km

        let metrics = service.metricsAtDistance(2500, primary: primary, comparison: comparison)

        // At 2.5 km with pace 300 s/km: elapsed = 2500 * 300 / 1000 = 750s
        XCTAssertEqual(metrics.primaryElapsedSeconds ?? 0, 750, accuracy: 10)
        // At 2.5 km with pace 330 s/km: elapsed = 2500 * 330 / 1000 = 825s
        XCTAssertEqual(metrics.comparisonElapsedSeconds ?? 0, 825, accuracy: 10)
        // Elapsed-time delta: primary is shorter by 75s.
        XCTAssertEqual(metrics.timeDeltaSeconds ?? 0, -75, accuracy: 10)
    }

    func testMetricsAtDistanceEnd() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let metrics = service.metricsAtDistance(5000, primary: primary, comparison: comparison)

        // Primary: 5000m at 300 s/km = 1500s
        XCTAssertEqual(metrics.primaryElapsedSeconds ?? 0, 1500, accuracy: 10)
        // Comparison: 5000m at 330 s/km = 1650s
        XCTAssertEqual(metrics.comparisonElapsedSeconds ?? 0, 1650, accuracy: 10)
        // Elapsed-time delta: -150s (primary shorter).
        XCTAssertEqual(metrics.timeDeltaSeconds ?? 0, -150, accuracy: 10)
    }

    func testMetricsAtDistancePaceDelta() {
        let primary = createSampleWorkout(distance: 5000, pace: 270) // 4:30/km
        let comparison = createSampleWorkout(distance: 5000, pace: 330) // 5:30/km

        let metrics = service.metricsAtDistance(2500, primary: primary, comparison: comparison)

        // Pace delta should indicate primary is faster (negative)
        if let delta = metrics.paceDeltaSecondsPerKm {
            XCTAssertTrue(delta.isFinite)
            XCTAssertLessThan(delta, 0, "Primary with shorter elapsed time should have lower pace delta")
        }
    }

    func testMetricsAtDistanceClampsBeyondRoute() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 3000, pace: 300)

        let metrics = service.metricsAtDistance(4000, primary: primary, comparison: comparison)

        // Should clamp comparison to 3000m
        XCTAssertNotNil(metrics.comparisonElapsedSeconds)
        XCTAssertNotNil(metrics.primaryElapsedSeconds)
    }

    func testMetricsAtDistanceEmptyRoute() {
        let primary = RunWorkout(routePoints: [])
        let comparison = createSampleWorkout(distance: 5000, pace: 300)

        let metrics = service.metricsAtDistance(2500, primary: primary, comparison: comparison)

        // Primary is empty, so primary metrics are nil
        XCTAssertNil(metrics.primaryElapsedSeconds)
        XCTAssertNil(metrics.primaryPaceSecondsPerKm)
        // Comparison still has data, so its metrics are non-nil
        XCTAssertNotNil(metrics.comparisonElapsedSeconds)
        // Time/pace delta are nil because primary is missing
        XCTAssertNil(metrics.timeDeltaSeconds)
        XCTAssertNil(metrics.paceDeltaSecondsPerKm)
    }

    func testMetricsAtDistanceOnePointRoute() {
        let singlePoint = RunWorkout(routePoints: [
            RoutePoint(timestamp: Date(), latitude: 37.7749, longitude: -122.4194,
                       altitudeMeters: 10, distanceFromStartMeters: 0, elapsedSeconds: 0,
                       paceSecondsPerKilometer: 300)
        ])
        let comparison = createSampleWorkout(distance: 5000, pace: 300)

        let metrics = service.metricsAtDistance(0, primary: singlePoint, comparison: comparison)

        XCTAssertNotNil(metrics.primaryElapsedSeconds)
        XCTAssertNotNil(metrics.comparisonElapsedSeconds)
    }

    func testMetricsAtDistanceDifferentLengths() {
        let primary = createSampleWorkout(distance: 10000, pace: 300)
        let comparison = createSampleWorkout(distance: 3000, pace: 330)

        // At 2.5 km, both should have values
        let metrics2500 = service.metricsAtDistance(2500, primary: primary, comparison: comparison)
        XCTAssertNotNil(metrics2500.primaryElapsedSeconds)
        XCTAssertNotNil(metrics2500.comparisonElapsedSeconds)
        XCTAssertNotNil(metrics2500.timeDeltaSeconds)

        // At 5 km, primary still has data, comparison gets clamped to 3000m
        let metrics5000 = service.metricsAtDistance(5000, primary: primary, comparison: comparison)
        XCTAssertNotNil(metrics5000.primaryElapsedSeconds)
        XCTAssertNotNil(metrics5000.comparisonElapsedSeconds) // Clamped to 3000m
        XCTAssertNotNil(metrics5000.timeDeltaSeconds)

        // At 0, both should be at start
        let metrics0 = service.metricsAtDistance(0, primary: primary, comparison: comparison)
        XCTAssertNotNil(metrics0.primaryElapsedSeconds)
        XCTAssertNotNil(metrics0.comparisonElapsedSeconds)
    }

    func testMetricsAtDistanceNoNaN() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let metrics = service.metricsAtDistance(2500, primary: primary, comparison: comparison)

        if let t = metrics.primaryElapsedSeconds { XCTAssertTrue(t.isFinite) }
        if let t = metrics.comparisonElapsedSeconds { XCTAssertTrue(t.isFinite) }
        if let d = metrics.timeDeltaSeconds { XCTAssertTrue(d.isFinite); XCTAssertFalse(d.isNaN) }
        if let p = metrics.primaryPaceSecondsPerKm { XCTAssertTrue(p.isFinite) }
        if let p = metrics.comparisonPaceSecondsPerKm { XCTAssertTrue(p.isFinite) }
        if let d = metrics.paceDeltaSecondsPerKm { XCTAssertTrue(d.isFinite); XCTAssertFalse(d.isNaN) }
    }

    func testMetricsAtNegativeDistance() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let metrics = service.metricsAtDistance(-100, primary: primary, comparison: comparison)

        // Should return safe defaults
        XCTAssertEqual(metrics.selectedDistanceMeters, 0)
    }

    // MARK: - Scene Point Interpolation

    func testMetricsAtDistanceWithScenePoints() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let projService = ComparisonRouteProjectionService()
        let scene = projService.project(primary: primary.routePoints, comparison: comparison.routePoints)

        let metrics = service.metricsAtDistance(
            2500,
            primary: primary,
            comparison: comparison,
            primaryScenePoints: scene.primaryRoute,
            comparisonScenePoints: scene.comparisonRoute
        )

        XCTAssertNotNil(metrics.primaryScenePoint)
        XCTAssertNotNil(metrics.comparisonScenePoint)

        if let pp = metrics.primaryScenePoint {
            XCTAssertTrue(pp.xMeters.isFinite)
            XCTAssertTrue(pp.yMeters.isFinite)
            XCTAssertTrue(pp.zMeters.isFinite)
            XCTAssertEqual(pp.distanceFromStartMeters, 2500, accuracy: 10)
        }

        if let cp = metrics.comparisonScenePoint {
            XCTAssertTrue(cp.xMeters.isFinite)
            XCTAssertTrue(cp.yMeters.isFinite)
            XCTAssertTrue(cp.zMeters.isFinite)
            XCTAssertEqual(cp.distanceFromStartMeters, 2500, accuracy: 10)
        }
    }

    func testMetricsAtDistanceScenePointAtStart() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let projService = ComparisonRouteProjectionService()
        let scene = projService.project(primary: primary.routePoints, comparison: comparison.routePoints)

        let metrics = service.metricsAtDistance(
            0,
            primary: primary,
            comparison: comparison,
            primaryScenePoints: scene.primaryRoute,
            comparisonScenePoints: scene.comparisonRoute
        )

        if let pp = metrics.primaryScenePoint {
            XCTAssertEqual(pp.distanceFromStartMeters, 0, accuracy: 1)
        }
    }

    func testMetricsAtDistanceScenePointEmptyScenePoints() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 330)

        let metrics = service.metricsAtDistance(
            2500,
            primary: primary,
            comparison: comparison,
            primaryScenePoints: [],
            comparisonScenePoints: []
        )

        XCTAssertNil(metrics.primaryScenePoint)
        XCTAssertNil(metrics.comparisonScenePoint)
    }

    // MARK: - Demo Fixtures Distance Selection

    func testDemoComparisonFixturesDistanceSelection() throws {
        let primary = try loadFixture("sample_run.json")
        let comparison = try loadFixture("fixtures/comparison_park_run.json")

        let common = service.commonDistance(primary: primary, comparison: comparison)
        XCTAssertGreaterThan(common, 0)

        let midMetrics = service.metricsAtDistance(common / 2, primary: primary, comparison: comparison)
        XCTAssertNotNil(midMetrics.primaryElapsedSeconds)
        XCTAssertNotNil(midMetrics.comparisonElapsedSeconds)
        XCTAssertNotNil(midMetrics.timeDeltaSeconds)

        if let t = midMetrics.primaryElapsedSeconds { XCTAssertTrue(t.isFinite) }
        if let t = midMetrics.comparisonElapsedSeconds { XCTAssertTrue(t.isFinite) }
        if let d = midMetrics.timeDeltaSeconds { XCTAssertTrue(d.isFinite); XCTAssertFalse(d.isNaN) }
    }

    func testDemoComparisonFixturesScenePointMarkers() throws {
        let primary = try loadFixture("sample_run.json")
        let comparison = try loadFixture("fixtures/comparison_park_run.json")

        let projService = ComparisonRouteProjectionService()
        let scene = projService.project(primary: primary.routePoints, comparison: comparison.routePoints)
        let common = service.commonDistance(primary: primary, comparison: comparison)

        let metrics = service.metricsAtDistance(
            common / 2,
            primary: primary,
            comparison: comparison,
            primaryScenePoints: scene.primaryRoute,
            comparisonScenePoints: scene.comparisonRoute
        )

        XCTAssertNotNil(metrics.primaryScenePoint)
        XCTAssertNotNil(metrics.comparisonScenePoint)

        if let pp = metrics.primaryScenePoint {
            XCTAssertTrue(pp.xMeters.isFinite)
            XCTAssertTrue(pp.yMeters.isFinite)
            XCTAssertTrue(pp.zMeters.isFinite)
        }
        if let cp = metrics.comparisonScenePoint {
            XCTAssertTrue(cp.xMeters.isFinite)
            XCTAssertTrue(cp.yMeters.isFinite)
            XCTAssertTrue(cp.zMeters.isFinite)
        }
    }

    // MARK: - ComparisonDistanceMetrics Formatting

    func testComparisonDistanceMetricsFormatting() {
        let metrics = ComparisonDistanceMetrics(
            selectedDistanceMeters: 2500,
            primaryElapsedSeconds: 750,
            comparisonElapsedSeconds: 825,
            timeDeltaSeconds: -75,
            primaryPaceSecondsPerKm: 300,
            comparisonPaceSecondsPerKm: 330,
            paceDeltaSecondsPerKm: -60,
            primaryScenePoint: nil,
            comparisonScenePoint: nil
        )

        XCTAssertEqual(metrics.selectedDistanceFormatted, "2.50 km")
        XCTAssertEqual(metrics.primaryElapsedFormatted, "12:30")
        XCTAssertEqual(metrics.comparisonElapsedFormatted, "13:45")
        XCTAssertEqual(metrics.timeDeltaFormatted, "-1:15 shorter")
        XCTAssertEqual(metrics.primaryPaceFormatted, "5:00 /km")
        XCTAssertEqual(metrics.comparisonPaceFormatted, "5:30 /km")
        XCTAssertEqual(metrics.paceDeltaFormatted, "-1:00 /km faster")
    }

    func testComparisonDistanceMetricsNilValues() {
        let metrics = ComparisonDistanceMetrics(
            selectedDistanceMeters: 0,
            primaryElapsedSeconds: nil,
            comparisonElapsedSeconds: nil,
            timeDeltaSeconds: nil,
            primaryPaceSecondsPerKm: nil,
            comparisonPaceSecondsPerKm: nil,
            paceDeltaSecondsPerKm: nil,
            primaryScenePoint: nil,
            comparisonScenePoint: nil
        )

        XCTAssertEqual(metrics.primaryElapsedFormatted, "--:--")
        XCTAssertEqual(metrics.comparisonElapsedFormatted, "--:--")
        XCTAssertEqual(metrics.timeDeltaFormatted, "N/A")
        XCTAssertEqual(metrics.primaryPaceFormatted, "--:-- /km")
        XCTAssertEqual(metrics.comparisonPaceFormatted, "--:-- /km")
        XCTAssertEqual(metrics.paceDeltaFormatted, "N/A")
    }

    // MARK: - Chart Data With Different Route Lengths

    func testMetricSeriesVeryDifferentRouteLengths() {
        let primary = createSampleWorkout(distance: 20000, pace: 300)
        let comparison = createSampleWorkout(distance: 3000, pace: 330)
        let metrics = service.compareMetricsOverDistance(primary: primary, comparison: comparison)

        XCTAssertFalse(metrics.isEmpty)
        // Should clamp to shorter route (3000m)
        if let last = metrics.last {
            XCTAssertLessThanOrEqual(last.distanceMeters, 3100)
        }
        // All pace values should be finite or nil
        for point in metrics {
            if let p = point.primaryPace {
                XCTAssertTrue(p.isFinite, "Primary pace must be finite at \(point.distanceMeters)m")
                XCTAssertGreaterThan(p, 0, "Primary pace must be positive")
            }
            if let p = point.comparisonPace {
                XCTAssertTrue(p.isFinite, "Comparison pace must be finite at \(point.distanceMeters)m")
                XCTAssertGreaterThan(p, 0, "Comparison pace must be positive")
            }
        }
    }

    func testMetricSeriesVeryDifferentRouteLengthsNoInfiniteValues() {
        let primary = createSampleWorkout(distance: 15000, pace: 280)
        let comparison = createSampleWorkout(distance: 2000, pace: 350)
        let metrics = service.compareMetricsOverDistance(primary: primary, comparison: comparison)

        for point in metrics {
            XCTAssertFalse(point.distanceMeters.isInfinite, "Distance must not be infinite")
            XCTAssertFalse(point.distanceMeters.isNaN, "Distance must not be NaN")
            XCTAssertFalse(point.distanceKm.isInfinite, "DistanceKm must not be infinite")
            if let d = point.paceDelta {
                XCTAssertTrue(d.isFinite, "Pace delta must be finite at \(point.distanceKm) km")
            }
        }
    }

    func testDemoFixturesStillLoad() throws {
        let primary = try loadFixture("sample_run.json")
        let comparison = try loadFixture("fixtures/comparison_park_run.json")

        XCTAssertFalse(primary.routePoints.isEmpty)
        XCTAssertFalse(comparison.routePoints.isEmpty)
        XCTAssertNotEqual(primary.id, comparison.id)

        let summary = service.compare(primary: primary, comparison: comparison)
        XCTAssertFalse(summary.primaryTitle.isEmpty)
        XCTAssertFalse(summary.comparisonTitle.isEmpty)

        let metrics = service.compareMetricsOverDistance(primary: primary, comparison: comparison)
        XCTAssertGreaterThan(metrics.count, 10, "Demo fixtures should produce enough chart points")
    }

    func testSplitDeltaFormattingEvenSplit() {
        let primary = createSampleWorkout(distance: 5000, pace: 300)
        let comparison = createSampleWorkout(distance: 5000, pace: 300) // Same pace
        let splits = service.compareSplits(primary: primary, comparison: comparison)

        // With same pace, delta should show "even"
        for split in splits {
            XCTAssertEqual(split.formattedPaceDelta, "0:00 /km even")
            XCTAssertEqual(split.winner, .tie)
        }
    }

    func testComparisonResultLabels() {
        XCTAssertEqual(ComparisonResult.primary.label, "Selected run faster")
        XCTAssertEqual(ComparisonResult.comparison.label, "Compared run faster")
        XCTAssertEqual(ComparisonResult.tie.label, "About the same")
        XCTAssertEqual(ComparisonResult.unavailable.label, "N/A")
    }

    // MARK: - Helpers

    private func loadFixture(_ path: String) throws -> RunWorkout {
        let testFile = URL(filePath: #filePath)
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

    private func createPauseComparisonWorkout(pauseSeconds: Double) -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            RoutePoint(
                timestamp: start,
                latitude: 1,
                longitude: 1,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0,
                routeSegmentIndex: 0
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(180),
                latitude: 1.006,
                longitude: 1,
                distanceFromStartMeters: 600,
                elapsedSeconds: 180,
                routeSegmentIndex: 0
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(180 + pauseSeconds),
                latitude: 1.006,
                longitude: 1,
                distanceFromStartMeters: 600,
                elapsedSeconds: 180 + pauseSeconds,
                routeSegmentIndex: 1
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(300 + pauseSeconds),
                latitude: 1.01,
                longitude: 1,
                distanceFromStartMeters: 1_000,
                elapsedSeconds: 300 + pauseSeconds,
                routeSegmentIndex: 1
            )
        ]
        var workout = RunWorkout(routePoints: points)
        WorkoutAnalyzer().analyze(&workout)
        return workout
    }
}
