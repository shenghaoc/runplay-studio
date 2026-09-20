import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class TrainingLoadTrendsTests: XCTestCase {

    private let utc = TimeZone(secondsFromGMT: 0)!

    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))!
    }

    private func makeWorkout(
        name: String,
        start: Date,
        trainingLoad: TrainingLoadSnapshot?
    ) -> RunWorkout {
        return RunWorkout(
            id: UUID(),
            metadata: WorkoutMetadata(name: name, activityType: "running", startDate: start),
            routePoints: [
                RoutePoint(
                    timestamp: start,
                    latitude: 1.3,
                    longitude: 103.8,
                    elapsedSeconds: 0
                ),
                RoutePoint(
                    timestamp: start.addingTimeInterval(1_800),
                    latitude: 1.31,
                    longitude: 103.9,
                    distanceFromStartMeters: 5_000,
                    elapsedSeconds: 1_800
                )
            ],
            summary: RunSummary(
                totalDistanceMeters: 5_000,
                totalElapsedSeconds: 1_800,
                totalActiveSeconds: 1_800,
                averageSpeedMetersPerSecond: 2.8
            ),
            trainingLoad: trainingLoad,
            analysisVersion: RunWorkout.currentAnalysisVersion
        )
    }

    private func measured(_ trimp: Double) -> TrainingLoadSnapshot {
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

    private func estimated(_ trimp: Double) -> TrainingLoadSnapshot {
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

    private func makeViewModel() -> TrendsViewModel {
        let viewModel = TrendsViewModel(timeZone: utc)
        viewModel.range = .allTime
        return viewModel
    }

    /// Polls until the applied series satisfies `predicate`, so a refresh
    /// after a preference change is not confused with the still-applied
    /// previous result.
    private func waitForSeries(
        _ viewModel: TrendsViewModel,
        matching predicate: (FitnessFatigueSeries) -> Bool = { _ in true },
        timeout: TimeInterval = 2
    ) async -> FitnessFatigueSeries? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let series = viewModel.trainingLoad, predicate(series) { return series }
            if case .failed = viewModel.loadState { return nil }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    /// Reference recursion for mixed daily-load sequences.
    private func ctlAfter(_ loads: [Double], tau: Double) -> Double {
        var state = 0.0
        for load in loads {
            state += (load - state) / tau
        }
        return state
    }

    // MARK: - Series computation through the view model

    func testTrendsComputesSeriesFromSnapshots() async {
        let viewModel = makeViewModel()
        let workouts = [
            makeWorkout(
                name: "A",
                start: utcDate(2026, 8, 10),
                trainingLoad: measured(60)
            ),
            makeWorkout(
                name: "B",
                start: utcDate(2026, 8, 11),
                trainingLoad: measured(60)
            ),
            makeWorkout(
                name: "C",
                start: utcDate(2026, 8, 12),
                trainingLoad: measured(60)
            ),
        ]
        viewModel.refresh(inputs: TrendsRefreshInputs(
            workouts: workouts,
            entries: [],
            documents: [:],
            smartCollections: [],
            currentQuery: nil
        ))

        let series = await waitForSeries(viewModel)
        XCTAssertNotNil(series)
        // Ten days: Aug 10 is 65 days before the series' latest day (Aug 12
        // through the day the test's `now` lands on); assert contiguity
        // structurally instead of pinning today's date.
        guard let series else { return }
        XCTAssertGreaterThan(series.loadDays.count, 2)
        XCTAssertEqual(series.loadDays.first?.contribution, .hrDay)
        XCTAssertEqual(series.loadDays[1].contribution, .hrDay)
        XCTAssertEqual(series.loadDays[2].contribution, .hrDay)
        XCTAssertEqual(series.modelDays.count, series.loadDays.count)
        // Closed form after three 60-TRIMP days at τ = 42:
        XCTAssertEqual(series.modelDays[2].ctl, ctlAfter([60, 60, 60], tau: 42), accuracy: 1e-9)
        // Estimated days later in the window never join by default.
        XCTAssertFalse(series.includesEstimatedLoads)
    }

    func testEstimatedLoadsExcludedByDefaultAndIncludedOnOptIn() async {
        let viewModel = makeViewModel()
        let workouts = [
            makeWorkout(name: "M", start: utcDate(2026, 7, 1), trainingLoad: measured(50)),
            makeWorkout(name: "E", start: utcDate(2026, 7, 2), trainingLoad: estimated(40)),
            makeWorkout(name: "M2", start: utcDate(2026, 7, 3), trainingLoad: measured(50)),
        ]
        viewModel.refresh(inputs: TrendsRefreshInputs(
            workouts: workouts,
            entries: [],
            documents: [:],
            smartCollections: [],
            currentQuery: nil
        ))
        guard let excluded = await waitForSeries(viewModel) else {
            return XCTFail("series never published")
        }
        XCTAssertEqual(excluded.loadDays[1].contribution, .noHRData)
        XCTAssertEqual(excluded.loadDays[1].estimatedLoad, 40)
        // The no-HR day walks the model as a zero-load day — the zero-
        // contribution rule — so the sequence is (50, 0, 50).
        XCTAssertEqual(excluded.modelDays[2].ctl, ctlAfter([50, 0, 50], tau: 42), accuracy: 1e-9)
        XCTAssertEqual(excluded.hrCoverageFraction ?? -1, 2.0 / 3.0, accuracy: 1e-12)

        viewModel.includeEstimatedLoads = true
        viewModel.refresh(inputs: TrendsRefreshInputs(
            workouts: workouts,
            entries: [],
            documents: [:],
            smartCollections: [],
            currentQuery: nil
        ))
        guard let included = await waitForSeries(viewModel, matching: { $0.includesEstimatedLoads }) else {
            return XCTFail("opt-in series never published")
        }
        XCTAssertTrue(included.includesEstimatedLoads)
        // The estimated day now contributes: the sequence is (50, 40, 50).
        XCTAssertEqual(included.modelDays[2].ctl, ctlAfter([50, 40, 50], tau: 42), accuracy: 1e-9)
    }

    func testTimeConstantPreferenceChangesCurve() async {
        let viewModel = makeViewModel()
        let workouts = (0..<10).map { offset in
            makeWorkout(
                name: "R\(offset)",
                start: utcDate(2026, 7, 1 + offset),
                trainingLoad: measured(40)
            )
        }
        let inputs = TrendsRefreshInputs(
            workouts: workouts,
            entries: [],
            documents: [:],
            smartCollections: [],
            currentQuery: nil
        )
        viewModel.refresh(inputs: inputs)
        guard let slow = await waitForSeries(viewModel) else {
            return XCTFail("series never published")
        }
        let slowATL = slow.modelDays.last?.atl ?? 0
        XCTAssertEqual(slowATL, ctlAfter(Array(repeating: 40, count: 10), tau: 7), accuracy: 1e-9)

        viewModel.atlTimeConstantDays = 14
        viewModel.refresh(inputs: inputs)
        guard let changed = await waitForSeries(
            viewModel,
            matching: { ($0.modelDays.last?.atl ?? 0) != slowATL }
        ) else {
            return XCTFail("changed series never published")
        }
        XCTAssertEqual(changed.modelDays.count, slow.modelDays.count)
        XCTAssertEqual(changed.modelDays.last?.atl ?? 0, ctlAfter(Array(repeating: 40, count: 10), tau: 14), accuracy: 1e-9)
    }

    // MARK: - Backfill state and orchestration

    func testBackfillStateTransitions() {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.trainingLoadBackfillState, .idle)

        viewModel.trainingLoadBackfillStarted(totalCount: 4)
        XCTAssertEqual(
            viewModel.trainingLoadBackfillState,
            .running(completedCount: 0, totalCount: 4, currentWorkoutName: "")
        )

        viewModel.trainingLoadBackfillProgress(
            completedCount: 2,
            totalCount: 4,
            currentWorkoutName: "Morning Run"
        )
        XCTAssertEqual(
            viewModel.trainingLoadBackfillState,
            .running(completedCount: 2, totalCount: 4, currentWorkoutName: "Morning Run")
        )

        viewModel.trainingLoadBackfillFinished(failureMessage: nil)
        XCTAssertEqual(viewModel.trainingLoadBackfillState, .idle)

        viewModel.trainingLoadBackfillProgress(
            completedCount: 1,
            totalCount: 4,
            currentWorkoutName: "X"
        )
        viewModel.trainingLoadBackfillFinished(failureMessage: "could not save 1 run(s)")
        XCTAssertEqual(viewModel.trainingLoadBackfillState, .failed("could not save 1 run(s)"))
    }

    func testEnterTrendsBackfillsPendingSnapshots() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrainingLoadTrends-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = FileWorkoutLibraryStore(rootURL: tempDir)
        let storeActor = WorkoutLibraryStoreActor(store: store)

        let pending = makeWorkout(
            name: "Pending",
            start: utcDate(2026, 8, 20),
            trainingLoad: nil
        )
        try store.saveWorkout(pending)
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: [pending.id],
            selectedWorkoutID: pending.id
        ))

        let appState = AppState(storeActor: storeActor)
        appState.workouts = [pending]
        appState.hasPersistedLibrary = true

        appState.showTrends()

        // The pass is async; poll for the snapshot to appear in memory.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if appState.workouts.first?.trainingLoad != nil { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(appState.workouts.first?.trainingLoad)
        // With a single-point-per-route fixture there is no usable HR
        // interval, so the estimate path must have produced the snapshot.
        XCTAssertEqual(appState.workouts.first?.trainingLoad?.kind, .estimated)
    }

    // MARK: - Accessibility summary

    func testChartAccessibilitySummarySpeaksDisclosures() {
        let viewModel = makeViewModel()
        viewModel.trainingLoadBackfillStarted(totalCount: 0)

        let summary = TrainingLoadChartAccessibilitySummary(
            includesEstimatedLoads: false,
            hrCoverageFraction: 0.75,
            dayCount: 30,
            hrDayCount: 15,
            noHRDataDayCount: 5,
            latestLoad: 62,
            latestCTL: 48,
            latestATL: 31,
            latestTSB: 17
        )
        let spoken = summary.spokenSummary
        XCTAssertTrue(spoken.contains("Fitness 48"))
        XCTAssertTrue(spoken.contains("Fatigue 31"))
        XCTAssertTrue(spoken.contains("Form +17"))
        XCTAssertTrue(spoken.contains("62 TRIMP"))
        XCTAssertTrue(spoken.contains("5 days with runs have no heart rate"))
        XCTAssertTrue(spoken.contains("75 percent"))

        let optIn = TrainingLoadChartAccessibilitySummary(
            includesEstimatedLoads: true,
            hrCoverageFraction: nil,
            dayCount: 3,
            hrDayCount: 1,
            noHRDataDayCount: 0,
            latestLoad: nil,
            latestCTL: 10,
            latestATL: 5,
            latestTSB: 5
        )
        XCTAssertTrue(optIn.spokenSummary.contains("invented values"))

        let phrase = TrainingLoadChartAccessibilitySummary.dayPhrase(
            load: 40,
            estimatedLoad: true,
            ctl: 30,
            atl: 20,
            tsb: 10,
            hasHRData: false
        )
        XCTAssertTrue(phrase.contains("estimated, not in model"))
        XCTAssertTrue(phrase.contains("form +10"))
    }

    // MARK: - Uncertainty spans

    /// Dense day series: one entry per day from `start`, contribution taken
    /// from `marks` (h = measured HR day, n = runs but no usable HR, r =
    /// rest).
    private func days(from start: Date, _ marks: String) -> [TrainingLoadDay] {
        marks.enumerated().map { offset, mark in
            let contribution: TrainingLoadDay.Contribution
            switch mark {
            case "h": contribution = .hrDay
            case "n": contribution = .noHRData
            default: contribution = .restDay
            }
            return TrainingLoadDay(
                date: start.addingTimeInterval(Double(offset) * 86_400),
                measuredLoad: contribution == .hrDay ? 50 : 0,
                estimatedLoad: 0,
                contribution: contribution,
                runCount: contribution == .restDay ? 0 : 1
            )
        }
    }

    func testUncertaintySpansMergeConsecutiveUnknownDays() {
        let start = utcDate(2026, 3, 1)
        let spans = TrainingLoadUncertainty.spans(in: days(from: start, "hnnnh"))

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.dayCount, 3)
        XCTAssertEqual(spans.first?.start, start.addingTimeInterval(86_400))
        // Exclusive end is the following day's own day start, so the band
        // covers the third unknown day in full.
        XCTAssertEqual(spans.first?.endExclusive, start.addingTimeInterval(4 * 86_400))
    }

    func testUncertaintySpansSplitOnMeasuredOrRestDays() {
        let start = utcDate(2026, 3, 1)

        let splitByMeasured = TrainingLoadUncertainty.spans(in: days(from: start, "nnhnn"))
        XCTAssertEqual(splitByMeasured.map(\.dayCount), [2, 2])

        // A rest day is a *measured* zero, so it ends a span just as a
        // measured load day does — that distinction is the whole point.
        let splitByRest = TrainingLoadUncertainty.spans(in: days(from: start, "nrn"))
        XCTAssertEqual(splitByRest.map(\.dayCount), [1, 1])
    }

    func testUncertaintySpanAtSeriesEndClosesOnItsOwnLastDay() {
        let start = utcDate(2026, 3, 1)
        let spans = TrainingLoadUncertainty.spans(in: days(from: start, "hnn"))

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.endExclusive, start.addingTimeInterval(3 * 86_400))
    }

    func testUncertaintySpansAreEmptyWithoutUnknownDays() {
        let start = utcDate(2026, 3, 1)
        XCTAssertTrue(TrainingLoadUncertainty.spans(in: days(from: start, "hhrh")).isEmpty)
        XCTAssertTrue(TrainingLoadUncertainty.spans(in: []).isEmpty)
    }

    func testUncertaintySpansIgnoreEstimatedLoads() {
        let start = utcDate(2026, 3, 1)
        // An estimated value standing in for a missing measurement does not
        // make the day measured, so the span is unchanged whether or not the
        // user opted estimates into the model.
        let withEstimates = days(from: start, "hnnh").map { day in
            TrainingLoadDay(
                date: day.date,
                measuredLoad: day.measuredLoad,
                estimatedLoad: day.contribution == .noHRData ? 35 : 0,
                contribution: day.contribution,
                runCount: day.runCount
            )
        }
        XCTAssertEqual(TrainingLoadUncertainty.spans(in: withEstimates).map(\.dayCount), [2])
    }

    func testSpokenSummaryStatesBiasDirectionInBothModes() {
        let excluded = TrainingLoadChartAccessibilitySummary(
            includesEstimatedLoads: false,
            hrCoverageFraction: 0.5,
            dayCount: 20,
            hrDayCount: 6,
            noHRDataDayCount: 4,
            latestLoad: 30,
            latestCTL: 25,
            latestATL: 20,
            latestTSB: 5
        )
        XCTAssertTrue(excluded.spokenSummary.contains("decays as if you had rested"))
        XCTAssertTrue(excluded.spokenSummary.contains("lost fitness and gained freshness"))

        // Opting estimates in does not silence the disclosure: days with no
        // estimate at all are still decayed as rest.
        let optedIn = TrainingLoadChartAccessibilitySummary(
            includesEstimatedLoads: true,
            hrCoverageFraction: 0.5,
            dayCount: 20,
            hrDayCount: 6,
            noHRDataDayCount: 4,
            latestLoad: 30,
            latestCTL: 25,
            latestATL: 20,
            latestTSB: 5
        )
        XCTAssertTrue(optedIn.spokenSummary.contains("invented values"))
        XCTAssertTrue(optedIn.spokenSummary.contains("decays as if you had rested"))
    }

    func testDayPhraseMarksUnknownLoadAsModelledRest() {
        let phrase = TrainingLoadChartAccessibilitySummary.dayPhrase(
            load: 0,
            estimatedLoad: false,
            ctl: 30,
            atl: 22,
            tsb: 8,
            hasHRData: false
        )
        XCTAssertTrue(phrase.contains("No heart-rate load, modelled as rest"))
        XCTAssertTrue(phrase.contains("fitness 30"))
    }
}
