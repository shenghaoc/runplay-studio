import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// What the run detail says about a run that has no GPS route: where its
/// distance came from, why it has no splits, and what it still offers.
final class RunDetailPresentationTests: XCTestCase {
    private typealias Fixtures = HeartRateDisplayFixtures

    // MARK: - Distance provenance

    func testRouteLessHealthRunLabelsItsDistanceAsAppleHealths() {
        let workout = Fixtures.workout(source: .healthKit)

        XCTAssertEqual(workout.summary.distanceProvenance, .sourceReported)
        XCTAssertEqual(
            DistanceProvenancePresentation.label(for: workout),
            "Distance from Apple Health (no GPS route)"
        )
    }

    func testGPSDerivedDistanceNeedsNoLabel() {
        let routed = Fixtures.workout(
            source: .healthKit,
            routePoints: Fixtures.routePoints(count: 4),
            series: Fixtures.series([(0, 120), (60, 130)])
        )

        XCTAssertEqual(routed.summary.distanceProvenance, .gpsDerived)
        XCTAssertNil(
            DistanceProvenancePresentation.label(for: routed),
            "a routed Health run's distance is measured along its route"
        )
        XCTAssertNil(DistanceProvenancePresentation.label(for: Fixtures.workout(
            source: .fit,
            routePoints: Fixtures.routePoints(count: 4)
        )))
    }

    func testASourceReportedDistanceFromAnotherSourceIsStillLabelled() throws {
        var workout = Fixtures.workout(source: .healthKit)
        workout.source = .strava

        let label = try XCTUnwrap(DistanceProvenancePresentation.label(for: workout))

        XCTAssertEqual(label, "Distance reported by the source (no GPS route)")
        XCTAssertFalse(label.contains("Apple Health"), "a label never names a source the run did not come from")
    }

    func testDistanceHelpOnlyClaimsARouteWhenThereIsOne() {
        XCTAssertEqual(
            DistanceProvenancePresentation.distanceHelp(for: Fixtures.workout(
                source: .fit,
                routePoints: Fixtures.routePoints(count: 4)
            )),
            "Total recorded route distance."
        )

        let help = DistanceProvenancePresentation.distanceHelp(for: Fixtures.workout(source: .healthKit))
        XCTAssertTrue(help.contains("Apple Health"), help)
        XCTAssertTrue(help.contains("did not measure"), help)
        XCTAssertFalse(help.contains("route distance"), help)
    }

    // MARK: - Splits

    func testSplitsSaySoPlainlyWhenThereIsNoRoute() {
        XCTAssertTrue(SplitsPresentation.needsRouteMessage.contains("GPS route"))
        XCTAssertEqual(SplitsPresentation.distanceSplitsContent(hasRoute: false), .needsRoute)
        XCTAssertEqual(SplitsPresentation.distanceSplitsContent(hasRoute: true), .table)
    }

    func testNoSplitsMessageEverPromisesSplitsAreAvailable() {
        XCTAssertFalse(SplitsPresentation.needsRouteMessage.contains("still available"))
        // Without a route the table is not shown, so the line that promises
        // calculated splits must not be either.
        XCTAssertNil(SplitsPresentation.noRecordedLapsNotice(hasRoute: false, hasRecordedLaps: false))
        XCTAssertNil(SplitsPresentation.noRecordedLapsNotice(hasRoute: false, hasRecordedLaps: true))
    }

    func testARoutedRunWithoutLapsKeepsItsExistingNotice() {
        XCTAssertEqual(
            SplitsPresentation.noRecordedLapsNotice(hasRoute: true, hasRecordedLaps: false),
            "No recorded laps in this file. Calculated distance splits are still available."
        )
        XCTAssertNil(SplitsPresentation.noRecordedLapsNotice(hasRoute: true, hasRecordedLaps: true))
    }

    func testTheViewsRouteStateComesFromTheWorkoutsOnePredicate() {
        XCTAssertFalse(Fixtures.workout().hasRoute)
        XCTAssertTrue(Fixtures.workout(routePoints: Fixtures.routePoints(count: 3)).hasRoute)
    }

    // MARK: - The route-less notice

    func testRouteLessNoticeOffersHeartRateOnlyWhenTheRunHasIt() {
        let withHeartRate = RouteLessNoticePresentation.message(hasHeartRate: true)
        let without = RouteLessNoticePresentation.message(hasHeartRate: false)

        XCTAssertTrue(withHeartRate.contains("heart rate and summary metrics"), withHeartRate)
        XCTAssertFalse(without.localizedCaseInsensitiveContains("heart rate"), without)
        XCTAssertTrue(without.contains("only summary metrics"), without)
    }

    func testRouteLessNoticeNeverPromisesCadence() {
        // Cadence rides on route points, so a run with none cannot have it.
        for hasHeartRate in [true, false] {
            let message = RouteLessNoticePresentation.message(hasHeartRate: hasHeartRate)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("cadence"), message)
            XCTAssertTrue(message.contains("No GPS route"), message)
            XCTAssertTrue(message.contains("splits"), message)
        }
    }

    func testTheNoticeFollowsWhetherTheWorkoutReallyHasHeartRate() {
        XCTAssertTrue(Fixtures.workout(series: Fixtures.series([(0, 120), (60, 130)])).hasHeartRateData)
        XCTAssertFalse(Fixtures.workout().hasHeartRateData)
    }

    // MARK: - Average heart rate in the header and the sidebar

    func testAverageHeartRateShowsWhenTheSummaryHasOne() {
        var summary = RunSummary()
        summary.averageHeartRateBPM = 142.5

        XCTAssertEqual(AverageHeartRateDisplay.value(for: summary), 142.5)
    }

    func testNothingShowsWhenTheSummaryHasNoAverage() {
        XCTAssertNil(AverageHeartRateDisplay.value(for: RunSummary()))

        for notAnAverage in [0, -1, .nan, .infinity, -.infinity] as [Double] {
            var summary = RunSummary()
            summary.averageHeartRateBPM = notAnAverage
            XCTAssertNil(
                AverageHeartRateDisplay.value(for: summary),
                "\(notAnAverage) is not an average heart rate"
            )
        }
    }

    // MARK: - Analyzed runs, with and without heart rate

    func testRouteLessRunWithHeartRateShowsAnAverageAndMax() throws {
        let workout = Fixtures.workout(series: Fixtures.series([(0, 120), (60, 130), (120, 140)]))

        XCTAssertEqual(AverageHeartRateDisplay.value(for: workout.summary), 130)
        XCTAssertEqual(workout.summary.maxHeartRateBPM, 140)
    }

    func testRoutedRunWhoseHeartRateIsASeriesShowsAnAverageAndMax() throws {
        let workout = Fixtures.workout(
            routePoints: Fixtures.routePoints(count: 6),
            series: Fixtures.series([(0, 118), (60, 130), (120, 142)])
        )

        XCTAssertEqual(try XCTUnwrap(AverageHeartRateDisplay.value(for: workout.summary)), 130, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.maxHeartRateBPM, 142)
    }

    func testRunsWithoutHeartRateShowNoAverageRatherThanZero() {
        for workout in [
            Fixtures.workout(),
            Fixtures.workout(routePoints: Fixtures.routePoints(count: 4)),
        ] {
            XCTAssertNil(workout.summary.averageHeartRateBPM)
            XCTAssertNil(workout.summary.maxHeartRateBPM)
            XCTAssertNil(AverageHeartRateDisplay.value(for: workout.summary))
        }
    }
}
