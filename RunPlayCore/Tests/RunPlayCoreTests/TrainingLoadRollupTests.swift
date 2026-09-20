import XCTest
@testable import RunPlayCore

final class TrainingLoadRollupTests: XCTestCase {

    private var calendar = Calendar(identifier: .iso8601)
    private let zone = TimeZone(secondsFromGMT: 0)!

    private func day(_ offset: Int, from base: Date = Date(timeIntervalSince1970: 1_767_225_600)) -> Date {
        let start = calendar.startOfDay(for: base)
        return calendar.date(byAdding: .day, value: offset, to: start)!
    }

    private func measuredSnapshot(trimp: Double) -> TrainingLoadSnapshot {
        TrainingLoadSnapshot(
            kind: .measured,
            banisterTRIMP: trimp,
            zoneSeconds: [0, trimp, 0, 0, 0],
            meanHeartRateBPM: 140,
            validHeartRateSeconds: 1_800,
            coveredActiveSeconds: 1_800,
            profile: AthleteProfile()
        )
    }

    private func estimatedSnapshot(trimp: Double) -> TrainingLoadSnapshot {
        TrainingLoadSnapshot(
            kind: .estimated,
            banisterTRIMP: trimp,
            zoneSeconds: nil,
            meanHeartRateBPM: nil,
            validHeartRateSeconds: 0,
            coveredActiveSeconds: 1_800,
            estimateBasis: .paceDuration,
            assumedHeartRateReserve: 0.6,
            profile: AthleteProfile()
        )
    }

    private func contribution(
        _ dayOffset: Int,
        load: TrainingLoadSnapshot?
    ) -> (date: Date, recordedUTCOffsetSeconds: Int?, load: TrainingLoadSnapshot?) {
        (day(dayOffset), 0, load)
    }

    // MARK: - Closed-form exponential rollup

    /// Constant daily load L for n days from a zero start converges as
    /// `L × (1 − (1 − 1/τ)^n)` for both states — the closed-form check.
    func testConstantLoadMatchesClosedForm() {
        let days = (0..<30).map { TrainingLoadDay(
            date: day($0),
            measuredLoad: 50,
            estimatedLoad: 0,
            contribution: .hrDay,
            runCount: 1
        ) }
        let model = TrainingLoadRollup.fitnessFatigue(
            over: days,
            ctlTimeConstantDays: 42,
            atlTimeConstantDays: 7,
            includeEstimatedLoads: false
        )
        XCTAssertEqual(model.count, 30)
        let ctlExpected = 50 * (1 - pow(1 - 1.0 / 42.0, 30))
        let atlExpected = 50 * (1 - pow(1 - 1.0 / 7.0, 30))
        XCTAssertEqual(model[29].ctl, ctlExpected, accuracy: 1e-9)
        XCTAssertEqual(model[29].atl, atlExpected, accuracy: 1e-9)
        XCTAssertEqual(model[29].tsb, model[29].ctl - model[29].atl, accuracy: 1e-12)
        // Fatigue converges much faster than fitness at these constants.
        XCTAssertGreaterThan(model[29].atl, model[29].ctl - 1)
        XCTAssertLessThan(model[9].atl / atlExpected, 0.999)
    }

    /// Changing the time constants changes the same history's curve: the
    /// 42-day fitness constant carries far more history than the 7-day one.
    func testTimeConstantChangesShape() {
        let days = (0..<60).map { TrainingLoadDay(
            date: day($0),
            measuredLoad: 40,
            estimatedLoad: 0,
            contribution: .hrDay,
            runCount: 1
        ) }
        let slow = TrainingLoadRollup.fitnessFatigue(
            over: days, ctlTimeConstantDays: 42, atlTimeConstantDays: 7,
            includeEstimatedLoads: false
        )
        let fast = TrainingLoadRollup.fitnessFatigue(
            over: days, ctlTimeConstantDays: 7, atlTimeConstantDays: 3,
            includeEstimatedLoads: false
        )
        XCTAssertLessThan(slow[59].ctl, fast[59].ctl)
        XCTAssertGreaterThan(slow[30].ctl, 40 * 0.4)
        XCTAssertGreaterThan(fast[59].atl, slow[59].atl)
    }

    // MARK: - Zero-contribution is not zero-load

    /// A mid-series stretch of HR-less days integrates as zero — CTL decays
    /// exactly like rest days — while the days are flagged `noHRData`, not
    /// `restDay`. The math agrees; the semantics do not, and the flag is
    /// what the chart discloses.
    func testMidSeriesHRlessDaysAreZeroContributionNotZeroLoad() {
        var contributions: [(date: Date, recordedUTCOffsetSeconds: Int?, load: TrainingLoadSnapshot?)] = []
        // Ten measured days at 60/day.
        for offset in 0..<10 {
            contributions.append(contribution(offset, load: measuredSnapshot(trimp: 60)))
        }
        // Five HR-less days with estimated loads that must NOT enter the model.
        for offset in 10..<15 {
            contributions.append(contribution(offset, load: estimatedSnapshot(trimp: 45)))
        }
        // Back to measured.
        contributions.append(contribution(15, load: measuredSnapshot(trimp: 60)))

        let series = TrainingLoadRollup.series(
            contributions: contributions,
            fallbackTimeZone: zone,
            ctlTimeConstantDays: 42,
            atlTimeConstantDays: 7,
            includeEstimatedLoads: false
        )

        XCTAssertEqual(series.loadDays.count, 16)
        XCTAssertEqual(series.loadDays[3].contribution, .hrDay)
        XCTAssertEqual(series.loadDays[12].contribution, .noHRData)
        XCTAssertEqual(series.loadDays[12].estimatedLoad, 45)
        XCTAssertNotEqual(series.loadDays[12].contribution, .restDay)

        // The model treats the stretch exactly like rest days: run the same
        // measured days without the HR-less ones and compare day-for-day.
        var restOnly: [(date: Date, recordedUTCOffsetSeconds: Int?, load: TrainingLoadSnapshot?)] = []
        for offset in 0..<10 {
            restOnly.append(contribution(offset, load: measuredSnapshot(trimp: 60)))
        }
        restOnly.append(contribution(15, load: measuredSnapshot(trimp: 60)))
        let restSeries = TrainingLoadRollup.series(
            contributions: restOnly,
            fallbackTimeZone: zone,
            ctlTimeConstantDays: 42,
            atlTimeConstantDays: 7,
            includeEstimatedLoads: false
        )
        XCTAssertEqual(series.modelDays.map(\.ctl), restSeries.modelDays.map(\.ctl))
        XCTAssertEqual(series.modelDays.map(\.atl), restSeries.modelDays.map(\.atl))

        // Opting in changes the curve: the estimates now contribute.
        let optedIn = TrainingLoadRollup.series(
            contributions: contributions,
            fallbackTimeZone: zone,
            ctlTimeConstantDays: 42,
            atlTimeConstantDays: 7,
            includeEstimatedLoads: true
        )
        XCTAssertGreaterThan(optedIn.modelDays[14].atl, series.modelDays[14].atl)
        XCTAssertEqual(optedIn.includesEstimatedLoads, true)
    }

    /// Runs without any snapshot at all still mark their day `noHRData`, so
    /// an un-backfilled library shows honest gaps rather than fake rest.
    func testMissingSnapshotsAreHonestGaps() {
        let series = TrainingLoadRollup.series(
            contributions: [
                contribution(0, load: measuredSnapshot(trimp: 50)),
                contribution(2, load: nil),
                contribution(4, load: measuredSnapshot(trimp: 50)),
            ],
            fallbackTimeZone: zone
        )
        XCTAssertEqual(series.loadDays.count, 5)
        XCTAssertEqual(series.loadDays[0].contribution, .hrDay)
        XCTAssertEqual(series.loadDays[1].contribution, .restDay)
        XCTAssertEqual(series.loadDays[2].contribution, .noHRData)
        XCTAssertEqual(series.loadDays[2].runCount, 1)
        XCTAssertEqual(series.loadDays[3].contribution, .restDay)
        XCTAssertEqual(series.loadDays[4].contribution, .hrDay)
    }

    /// A day mixing measured and estimated runs is an HR day whose measured
    /// load feeds the model by default.
    func testMixedDayIsHRDayWithMeasuredLoadOnly() {
        let series = TrainingLoadRollup.series(
            contributions: [
                contribution(0, load: measuredSnapshot(trimp: 50)),
                contribution(0, load: estimatedSnapshot(trimp: 30)),
            ],
            fallbackTimeZone: zone
        )
        XCTAssertEqual(series.loadDays[0].contribution, .hrDay)
        XCTAssertEqual(series.loadDays[0].measuredLoad, 50)
        XCTAssertEqual(series.loadDays[0].estimatedLoad, 30)
        XCTAssertEqual(series.loadDays[0].runCount, 2)
        XCTAssertEqual(series.modelDays[0].ctl, 50 / 42, accuracy: 1e-12)
    }

    func testSameDayRunsSumTheirLoads() {
        let series = TrainingLoadRollup.series(
            contributions: [
                contribution(0, load: measuredSnapshot(trimp: 40)),
                contribution(0, load: measuredSnapshot(trimp: 20)),
                contribution(1, load: measuredSnapshot(trimp: 10)),
            ],
            fallbackTimeZone: zone
        )
        XCTAssertEqual(series.loadDays.count, 2)
        XCTAssertEqual(series.loadDays[0].measuredLoad, 60)
        XCTAssertEqual(series.loadDays[1].measuredLoad, 10)
    }

    func testEmptyContributionsProduceEmptySeries() {
        let series = TrainingLoadRollup.series(contributions: [], fallbackTimeZone: zone)
        XCTAssertTrue(series.loadDays.isEmpty)
        XCTAssertTrue(series.modelDays.isEmpty)
        XCTAssertNil(series.hrCoverageFraction)
    }

    func testHRCoverageFraction() {
        let series = TrainingLoadRollup.series(
            contributions: [
                contribution(0, load: measuredSnapshot(trimp: 50)),
                contribution(1, load: measuredSnapshot(trimp: 50)),
                contribution(2, load: estimatedSnapshot(trimp: 50)),
                contribution(3, load: nil),
            ],
            fallbackTimeZone: zone
        )
        // 4 days with runs, 2 of them measured.
        XCTAssertEqual(series.hrCoverageFraction ?? -1, 0.5, accuracy: 1e-12)
    }

    /// A run recorded near midnight in a non-zero offset lands on its local
    /// day, re-resolved on the display-zone axis. The series spans only
    /// contributing days, so this is exactly one day: the local one.
    func testRecordedOffsetHonoursLocalDay() {
        calendar.timeZone = zone
        // 2026-01-01 23:30 UTC == 2026-01-02 01:30 at +02:00.
        let instant = day(0).addingTimeInterval(23.5 * 3_600)
        let series = TrainingLoadRollup.series(
            contributions: [(instant, 7_200, measuredSnapshot(trimp: 50))],
            fallbackTimeZone: zone
        )
        XCTAssertEqual(series.loadDays.count, 1)
        XCTAssertEqual(series.loadDays[0].contribution, .hrDay)
        XCTAssertEqual(series.loadDays[0].date, day(1))
    }

    func testDefaultConstantsMatchBanisterConventions() {
        XCTAssertEqual(TrainingLoadRollup.defaultCTLTimeConstantDays, 42)
        XCTAssertEqual(TrainingLoadRollup.defaultATLTimeConstantDays, 7)
    }
}
