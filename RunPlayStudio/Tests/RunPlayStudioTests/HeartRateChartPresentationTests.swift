import XCTest
import Accessibility
import RunPlayCore
@testable import RunPlayStudio

/// Workouts for the heart-rate display tests, built the way an Apple Health
/// export run is: its heart rate is a standalone series, because the route GPX
/// files hold none, and a run without a route reports only totals.
enum HeartRateDisplayFixtures {
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Route points 30 s and 100 m apart. `heartRate` supplies each point's own
    /// reading, as a FIT or TCX route does; none by default.
    static func routePoints(count: Int, heartRate: ((Int) -> Double?)? = nil) -> [RoutePoint] {
        (0..<count).map { index in
            RoutePoint(
                timestamp: start.addingTimeInterval(Double(index) * 30),
                latitude: 1.3 + Double(index) * 0.001,
                longitude: 103.8 + Double(index) * 0.001,
                distanceFromStartMeters: Double(index) * 100,
                elapsedSeconds: Double(index) * 30,
                heartRateBPM: heartRate?(index)
            )
        }
    }

    static func series(_ readings: [(seconds: Double, bpm: Double?)], segment: Int = 0) -> [HeartRateSample] {
        readings.map {
            HeartRateSample(elapsedSeconds: $0.seconds, heartRateBPM: $0.bpm, segmentIndex: segment)
        }
    }

    /// An analyzed workout. A workout with no route points is seeded with the
    /// totals its source reported, which is all a route-less run has.
    static func workout(
        source: WorkoutSource = .healthKit,
        routePoints: [RoutePoint] = [],
        series: [HeartRateSample]? = nil
    ) -> RunWorkout {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Fixture", startDate: start),
            source: source,
            routePoints: routePoints,
            summary: RunSummary(totalDistanceMeters: 5_000, totalElapsedSeconds: 1_500),
            analysisVersion: RunWorkout.currentAnalysisVersion,
            heartRateSeries: series
        )
        WorkoutAnalyzer().analyze(&workout)
        return workout
    }
}

/// Heart rate on the workout detail: where it is charted from, and what the
/// chart says. A Health export run keeps its heart rate in a standalone series,
/// so the chart reads it through the workout's single accessor, not from route
/// points.
@MainActor
final class HeartRateChartPresentationTests: XCTestCase {
    private typealias Fixtures = HeartRateDisplayFixtures

    // MARK: - Which plan a workout gets

    func testRouteLessRunWithASeriesIsChartedOverTime() {
        let workout = Fixtures.workout(series: Fixtures.series([(0, 120), (60, 130), (120, 140)]))

        guard case .timeDomain(let points) = HeartRateChartPlan.plan(for: workout) else {
            return XCTFail("a route-less run with readings charts them over time")
        }
        XCTAssertEqual(points.map(\.minutes), [0, 1, 2])
        XCTAssertEqual(points.map(\.bpm), [120, 130, 140])
        XCTAssertEqual(Set(points.map(\.seriesID)).count, 1)
    }

    func testRoutedRunWithRoutePointHeartRateKeepsTheDistanceChart() {
        let workout = Fixtures.workout(
            source: .fit,
            routePoints: Fixtures.routePoints(count: 4) { 150 + Double($0) }
        )

        XCTAssertEqual(HeartRateChartPlan.plan(for: workout), .routePoints)
    }

    func testRoutedRunWhoseHeartRateIsOnlyASeriesIsAlignedByTimestamp() {
        let workout = Fixtures.workout(
            routePoints: Fixtures.routePoints(count: 4),
            series: Fixtures.series([(0, 120), (60, 130)])
        )

        // The route points sit at 0, 30, 60 and 90 s; each takes the reading
        // that applies at its own time, held until the next one arrives.
        guard case .alignedToRoute(let values, let readings) = HeartRateChartPlan.plan(for: workout) else {
            return XCTFail("a series on a routed run is aligned to the route")
        }
        XCTAssertEqual(values, [120, 120, 130, 130])
        XCTAssertEqual(readings, [120, 130])
    }

    func testRoutePointsBeforeTheFirstReadingHaveNoValue() {
        let workout = Fixtures.workout(
            routePoints: Fixtures.routePoints(count: 4),
            series: Fixtures.series([(45, 120), (75, 130)])
        )

        XCTAssertEqual(
            HeartRateChartPlan.plan(for: workout).heldValuesByRoutePoint,
            [nil, nil, 120, 130],
            "a reading is never invented before the source reported one"
        )
    }

    func testAlignedValuesAgreeWithWhatReplayShowsAtEachRoutePoint() {
        let workout = Fixtures.workout(
            routePoints: Fixtures.routePoints(count: 6),
            series: Fixtures.series([(0, 118), (50, 126), (95, 137), (140, 149)])
        )

        let values = HeartRateChartPlan.plan(for: workout).heldValuesByRoutePoint
        XCTAssertEqual(values?.count, workout.routePoints.count)
        for index in workout.routePoints.indices {
            XCTAssertEqual(
                values?[index],
                workout.heartRateBPM(atRoutePointIndex: index),
                "the chart and replay must name the same reading at route point \(index)"
            )
        }
    }

    func testAlignedValuesBuildChartDataOnTheDistanceAxis() {
        let workout = Fixtures.workout(
            routePoints: Fixtures.routePoints(count: 4),
            series: Fixtures.series([(0, 120), (60, 130)])
        )

        let values = HeartRateChartPlan.plan(for: workout).heldValuesByRoutePoint ?? []
        let data = MetricChartDataBuilder.build(routePoints: workout.routePoints, values: values)

        XCTAssertEqual(data.map(\.distanceKm), [0, 0.1, 0.2, 0.3])
        XCTAssertEqual(data.map(\.value), [120, 120, 130, 130])
        XCTAssertEqual(Set(data.map(\.seriesID)).count, 1)
    }

    func testAnInvalidReadingBreaksTheLineInsteadOfBeingDrawnThrough() {
        let workout = Fixtures.workout(
            routePoints: Fixtures.routePoints(count: 3),
            series: Fixtures.series([(0, 120), (30, 500), (60, 130)])
        )

        let values = HeartRateChartPlan.plan(for: workout).heldValuesByRoutePoint ?? []
        XCTAssertEqual(values, [120, nil, 130])

        let data = MetricChartDataBuilder.build(routePoints: workout.routePoints, values: values)
        XCTAssertEqual(data.map(\.value), [120, 130])
        XCTAssertEqual(Set(data.map(\.seriesID)).count, 2, "the two sides of the gap are separate lines")
    }

    func testRunsWithNoHeartRateHaveNoPlan() {
        XCTAssertEqual(HeartRateChartPlan.plan(for: Fixtures.workout()), HeartRateChartPlan.none)
        XCTAssertEqual(
            HeartRateChartPlan.plan(for: Fixtures.workout(
                source: .gpx,
                routePoints: Fixtures.routePoints(count: 4)
            )),
            HeartRateChartPlan.none
        )
    }

    func testASeriesOfOnlyInvalidReadingsHasNoPlan() {
        let invalid = Fixtures.series([(0, 0), (30, 500), (60, nil)])

        XCTAssertEqual(HeartRateChartPlan.plan(for: Fixtures.workout(series: invalid)), HeartRateChartPlan.none)
        XCTAssertEqual(
            HeartRateChartPlan.plan(for: Fixtures.workout(
                routePoints: Fixtures.routePoints(count: 3),
                series: invalid
            )),
            HeartRateChartPlan.none
        )
    }

    func testPlanKindFollowsTheWorkoutsOwnHeartRateSource() {
        let shapes: [(name: String, workout: RunWorkout, source: HeartRateSampleSource)] = [
            ("route-less, no series", Fixtures.workout(), .none),
            (
                "route-less series",
                Fixtures.workout(series: Fixtures.series([(0, 120), (60, 130)])),
                .standaloneSeries
            ),
            (
                "routed, heart rate on the points",
                Fixtures.workout(source: .fit, routePoints: Fixtures.routePoints(count: 3) { _ in 140 }),
                .routePoints
            ),
            (
                "routed, series only",
                Fixtures.workout(
                    routePoints: Fixtures.routePoints(count: 3),
                    series: Fixtures.series([(0, 120), (60, 130)])
                ),
                .standaloneSeries
            ),
            (
                // Heart rate lives in one place. A route that carries its own
                // readings owns them, and the standalone series is dropped.
                "routed, points and a series",
                Fixtures.workout(
                    routePoints: Fixtures.routePoints(count: 3) { _ in 140 },
                    series: Fixtures.series([(0, 90), (60, 95)])
                ),
                .routePoints
            ),
        ]

        for shape in shapes {
            XCTAssertEqual(shape.workout.heartRateSampleSource, shape.source, shape.name)
            switch (HeartRateChartPlan.plan(for: shape.workout), shape.source) {
            case (.none, .none), (.routePoints, .routePoints),
                 (.alignedToRoute, .standaloneSeries), (.timeDomain, .standaloneSeries):
                break
            case (let plan, _):
                XCTFail("\(shape.name): unexpected plan \(plan)")
            }
        }
    }

    // MARK: - Time axis

    func testRecordingGapStartsANewSeries() {
        let samples = Fixtures.series([(0, 120), (60, 125)], segment: 0)
            + Fixtures.series([(600, 130), (660, 135)], segment: 1)

        let points = HeartRateChartPlan.timePoints(from: samples)

        XCTAssertEqual(points.map(\.seriesID), [1, 1, 2, 2])
        XCTAssertEqual(points.map(\.minutes), [0, 1, 10, 11])
    }

    func testAnInvalidReadingEndsTheLineOnTheTimeAxis() {
        let points = HeartRateChartPlan.timePoints(
            from: Fixtures.series([(0, 120), (30, 0), (60, 140)])
        )

        XCTAssertEqual(points.map(\.bpm), [120, 140])
        XCTAssertEqual(points.map(\.seriesID), [1, 2], "an unreadable reading is a gap, not a value")
    }

    func testTimePointsAreIdentifiedInOrder() {
        let points = HeartRateChartPlan.timePoints(
            from: Fixtures.series([(0, 120), (30, 0), (60, 140), (90, 141)])
        )

        XCTAssertEqual(points.map(\.id), [0, 1, 2])
    }

    func testReadingsWithoutAFiniteTimeAreSkipped() {
        let points = HeartRateChartPlan.timePoints(
            from: Fixtures.series([(0, 120), (.nan, 130), (60, 140)])
        )

        XCTAssertEqual(points.map(\.bpm), [120, 140])
    }

    // MARK: - The metric picker

    func testOnlyARouteLessSeriesOpensTheChartOnHeartRate() {
        let timeDomain = HeartRateChartPlan.timeDomain(points: [
            HeartRateTimePoint(id: 0, minutes: 0, bpm: 120, seriesID: 1)
        ])

        XCTAssertTrue(timeDomain.opensOnHeartRate)
        XCTAssertFalse(HeartRateChartPlan.none.opensOnHeartRate)
        XCTAssertFalse(HeartRateChartPlan.routePoints.opensOnHeartRate)
        XCTAssertFalse(
            HeartRateChartPlan.alignedToRoute(valuesByRoutePoint: [120], readings: [120]).opensOnHeartRate,
            "a routed run opens where every routed run does"
        )
    }

    func testSelectingARouteLessRunAfterARoutedOneMovesThePickerToHeartRate() {
        let timeDomain = HeartRateChartPlan.timeDomain(points: [
            HeartRateTimePoint(id: 0, minutes: 0, bpm: 120, seriesID: 1)
        ])

        XCTAssertTrue(HeartRateChartPlan.movesPickerToHeartRate(from: .routePoints, to: timeDomain))
        XCTAssertTrue(HeartRateChartPlan.movesPickerToHeartRate(from: .none, to: timeDomain))
        XCTAssertFalse(
            HeartRateChartPlan.movesPickerToHeartRate(from: timeDomain, to: timeDomain),
            "a metric the user chose on the same kind of run is left alone"
        )
        XCTAssertFalse(HeartRateChartPlan.movesPickerToHeartRate(from: timeDomain, to: .routePoints))
        XCTAssertFalse(HeartRateChartPlan.movesPickerToHeartRate(from: .none, to: .routePoints))
    }

    func testPickerOpensOnHeartRateOnlyForARouteLessSeries() {
        let timeDomain = HeartRateChartPlan.timeDomain(points: [
            HeartRateTimePoint(id: 0, minutes: 0, bpm: 120, seriesID: 1)
        ])

        XCTAssertEqual(MetricsChartView.initialMetric(for: timeDomain), .heartRate)
        XCTAssertEqual(MetricsChartView.initialMetric(for: HeartRateChartPlan.none), .elevation)
        XCTAssertEqual(MetricsChartView.initialMetric(for: .routePoints), .elevation)
        XCTAssertEqual(
            MetricsChartView.initialMetric(for: .alignedToRoute(valuesByRoutePoint: [120], readings: [120])),
            .elevation
        )
    }

    // MARK: - The header and the chart cannot disagree

    func testHeaderAverageIsTheMeanOfTheReadingsTheAlignedChartReports() throws {
        let workout = Fixtures.workout(
            routePoints: Fixtures.routePoints(count: 8),
            series: Fixtures.series([(0, 118), (50, 126), (95, 137), (140, 149), (200, 152)])
        )

        let readings = try XCTUnwrap(HeartRateChartPlan.plan(for: workout).reportedReadings)
        let mean = readings.reduce(0, +) / Double(readings.count)
        let average = try XCTUnwrap(AverageHeartRateDisplay.value(for: workout.summary))

        XCTAssertEqual(average, mean, accuracy: 1e-9)
    }

    func testHeaderAverageIsTheMeanOfTheReadingsTheTimeChartDraws() throws {
        let workout = Fixtures.workout(series: Fixtures.series([(0, 118), (60, 126), (120, 137), (180, 149)]))

        let points = try XCTUnwrap(HeartRateChartPlan.plan(for: workout).timeDomainPoints)
        let model = try XCTUnwrap(TimeDomainHeartRateChartModel.make(points: points))
        let average = try XCTUnwrap(AverageHeartRateDisplay.value(for: workout.summary))

        XCTAssertEqual(average, model.average, accuracy: 1e-9)
    }

    // MARK: - The time-domain model

    func testNothingToChartMakesNoModel() {
        XCTAssertNil(TimeDomainHeartRateChartModel.make(points: []))
    }

    func testModelSummarisesTheReadings() throws {
        let points = HeartRateChartPlan.timePoints(from: Fixtures.series([(0, 120), (60, 130), (120, 140)]))

        let model = try XCTUnwrap(TimeDomainHeartRateChartModel.make(points: points))

        XCTAssertEqual(model.minimum, 120)
        XCTAssertEqual(model.maximum, 140)
        XCTAssertEqual(model.average, 130)
        XCTAssertEqual(model.durationMinutes, 2)
        XCTAssertEqual(model.sectionCount, 1)
        XCTAssertEqual(model.gapCount, 0)
    }

    func testSpokenSummaryIsInTimeAndNeverClaimsADistance() throws {
        let points = HeartRateChartPlan.timePoints(from: Fixtures.series([(0, 120), (60, 130), (120, 140)]))
        let model = try XCTUnwrap(TimeDomainHeartRateChartModel.make(points: points))

        let summary = model.spokenSummary

        XCTAssertTrue(summary.contains("Heart Rate over time chart"), summary)
        XCTAssertTrue(summary.contains("Time in minutes."), summary)
        XCTAssertTrue(summary.contains("Range 120 bpm to 140 bpm."), summary)
        XCTAssertTrue(summary.contains("Average 130 bpm."), summary)
        XCTAssertTrue(summary.contains("3 readings over 2 minutes."), summary)
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("distance"), summary)
        XCTAssertFalse(summary.contains("gap"), summary)
    }

    func testSpokenSummaryNamesRecordingGaps() throws {
        let samples = Fixtures.series([(0, 120), (60, 125)], segment: 0)
            + Fixtures.series([(600, 130), (660, 135)], segment: 1)
        let model = try XCTUnwrap(TimeDomainHeartRateChartModel.make(
            points: HeartRateChartPlan.timePoints(from: samples)
        ))

        XCTAssertEqual(model.sectionCount, 2)
        XCTAssertEqual(model.gapCount, 1)
        XCTAssertTrue(model.spokenSummary.contains("1 recording gap breaks the series."), model.spokenSummary)
    }

    func testSpokenSummaryAgreesInNumber() throws {
        let model = try XCTUnwrap(TimeDomainHeartRateChartModel.make(
            points: HeartRateChartPlan.timePoints(from: Fixtures.series([(0, 120)]))
        ))

        XCTAssertTrue(model.spokenSummary.contains("1 reading over 0 minutes."), model.spokenSummary)
    }

    func testEveryReadingIsMarkedOnlyWhileTheyCanBeToldApart() throws {
        func model(readings: Int) throws -> TimeDomainHeartRateChartModel {
            let samples = (0..<readings).map {
                HeartRateSample(elapsedSeconds: Double($0), heartRateBPM: 120 + Double($0 % 20), segmentIndex: 0)
            }
            return try XCTUnwrap(TimeDomainHeartRateChartModel.make(
                points: HeartRateChartPlan.timePoints(from: samples)
            ))
        }

        let limit = TimeDomainHeartRateChartModel.maximumMarkedReadings
        XCTAssertTrue(try model(readings: limit).marksEachReading)
        XCTAssertFalse(try model(readings: limit + 1).marksEachReading)
    }

    func testDescriptorHasOneSeriesPerSectionAndTheModelsSummary() throws {
        let samples = Fixtures.series([(0, 120), (60, 125)], segment: 0)
            + Fixtures.series([(600, 130), (660, 135)], segment: 1)
        let model = try XCTUnwrap(TimeDomainHeartRateChartModel.make(
            points: HeartRateChartPlan.timePoints(from: samples)
        ))

        let descriptor = TimeDomainHeartRateChartDescriptor(model: model).makeChartDescriptor()

        XCTAssertEqual(descriptor.series.count, 2)
        XCTAssertEqual(descriptor.title, model.title)
        XCTAssertEqual(descriptor.summary, model.spokenSummary)
        XCTAssertEqual(descriptor.series.map { $0.dataPoints.count }, [2, 2])
    }
}
