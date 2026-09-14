import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class TrendsWorkspaceTests: XCTestCase {

    private let utc = TimeZone(secondsFromGMT: 0)!

    private func makeWorkout(
        name: String,
        id: UUID = UUID(),
        start: Date,
        distanceMeters: Double = 1_000,
        activeSeconds: Double = 300,
        heartRate: Double? = nil,
        ascent: Double? = nil
    ) -> RunWorkout {
        var summary = RunSummary(
            totalDistanceMeters: distanceMeters,
            totalElapsedSeconds: activeSeconds + 60,
            totalActiveSeconds: activeSeconds
        )
        summary.averageHeartRateBPM = heartRate
        if let ascent {
            summary.elevationGainMeters = ascent
        }
        return RunWorkout(
            id: id,
            metadata: WorkoutMetadata(name: name, activityType: "running", startDate: start),
            routePoints: [
                RoutePoint(
                    timestamp: start,
                    latitude: 1.3,
                    longitude: 103.8,
                    elapsedSeconds: 0
                ),
                RoutePoint(
                    timestamp: start.addingTimeInterval(activeSeconds),
                    latitude: 1.31,
                    longitude: 103.9,
                    distanceFromStartMeters: distanceMeters,
                    elapsedSeconds: activeSeconds
                )
            ],
            summary: summary
        )
    }

    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))!
    }

    /// Polls until the async trends build publishes, bounded in time.
    private func waitForTrendsReady(_ viewModel: TrendsViewModel, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .ready = viewModel.loadState { return true }
            if case .empty = viewModel.loadState { return true }
            if case .failed = viewModel.loadState { return false }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    // MARK: - Workspace transitions

    func testEnteringTrendsSetsWorkspaceModeAndKeepsSelection() {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout(name: "A", start: utcDate(2026, 9, 2))
        appState.workouts = [workout]
        appState.selectWorkout(workout)

        appState.showTrends()

        XCTAssertEqual(appState.workspaceMode, .trends)
        XCTAssertEqual(appState.selectedWorkout?.id, workout.id)
        XCTAssertEqual(appState.sidebarSelection, .trends)
    }

    func testSelectingWorkoutExitsTrends() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A", start: utcDate(2026, 9, 2))
        let b = makeWorkout(name: "B", start: utcDate(2026, 8, 2))
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showTrends()

        appState.selectWorkout(b)

        XCTAssertEqual(appState.workspaceMode, .workout)
    }

    func testEnteringComparisonAndAllRunsExitTrends() {
        let appState = AppState(storeActor: nil, importService: nil)
        let a = makeWorkout(name: "A", start: utcDate(2026, 9, 2))
        let b = makeWorkout(name: "B", start: utcDate(2026, 8, 2))
        appState.workouts = [a, b]
        appState.selectWorkout(a)
        appState.showTrends()

        appState.setComparison(b)
        XCTAssertEqual(appState.workspaceMode, .comparison)

        appState.showTrends()
        appState.showWorkoutLibrary()
        XCTAssertEqual(appState.workspaceMode, .workoutLibrary)
    }

    func testShowTrendsPreselectsActiveSmartCollectionScope() {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout(name: "A", start: utcDate(2026, 9, 2))
        appState.workouts = [workout]
        let collection = WorkoutSmartCollection(name: "Trail", query: WorkoutLibrarySavedQuery())
        appState.smartCollections = [collection]
        appState.showSmartCollection(id: collection.id)

        appState.showTrends()

        XCTAssertEqual(appState.trends.scope, .smartCollection(collection.id))

        // An explicit user selection is never overwritten on re-entry.
        appState.trends.scope = .entireLibrary
        appState.showWorkoutLibrary(restoreManualQuery: true)
        appState.showSmartCollection(id: collection.id)
        appState.showTrends()
        XCTAssertEqual(appState.trends.scope, .entireLibrary)
    }

    func testPeriodNavigationFiltersAllRuns() async {
        let appState = AppState(storeActor: nil, importService: nil)
        let inPeriod = makeWorkout(name: "Sep", start: utcDate(2026, 9, 2))
        let outOfPeriod = makeWorkout(name: "Jul", start: utcDate(2026, 7, 2))
        appState.workouts = [inPeriod, outOfPeriod]
        appState.selectWorkout(inPeriod)
        appState.showTrends()

        let key = WorkoutTrendsPeriodKey(kind: .month, year: 2026, ordinal: 9)
        appState.showWorkoutsInTrendsPeriod(key)

        XCTAssertEqual(appState.workspaceMode, .workoutLibrary)
        let expectedBounds = WorkoutTrendsAggregator.periodBounds(for: key, timeZone: .current)
        XCTAssertEqual(
            appState.workoutLibrary.dateFilter,
            .custom(start: expectedBounds.start, end: expectedBounds.end.addingTimeInterval(-1))
        )
        XCTAssertEqual(appState.workoutLibrary.customDateStart, expectedBounds.start)

        // The filtered result publishes asynchronously; poll bounded in time.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              !appState.workoutLibrary.resultIDs.contains(inPeriod.id) {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(appState.workoutLibrary.resultIDs.contains(inPeriod.id))
        XCTAssertFalse(appState.workoutLibrary.resultIDs.contains(outOfPeriod.id))
    }

    func testPeriodNavigationOverCollectionMarksModified() {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout(name: "A", start: utcDate(2026, 9, 2))
        appState.workouts = [workout]
        let collection = WorkoutSmartCollection(name: "All the runs", query: WorkoutLibrarySavedQuery())
        appState.smartCollections = [collection]
        appState.showSmartCollection(id: collection.id)

        appState.showWorkoutsInTrendsPeriod(
            WorkoutTrendsPeriodKey(kind: .year, year: 2026, ordinal: 1)
        )

        XCTAssertEqual(appState.workoutLibrary.queryContext, .smartCollection(id: collection.id, isModified: true))
    }

    // MARK: - View model

    func testViewModelAggregatesAndDisclosesContributors() async throws {
        let viewModel = TrendsViewModel(
            calendar: Calendar(identifier: .iso8601),
            timeZone: utc
        )
        viewModel.nowProvider = { self.utcDate(2026, 9, 14) }
        let workouts = [
            makeWorkout(name: "A", start: utcDate(2026, 9, 2), distanceMeters: 10_000, activeSeconds: 3_600, heartRate: 150, ascent: 200),
            makeWorkout(name: "B", start: utcDate(2026, 9, 10), distanceMeters: 5_000, activeSeconds: 1_200)
        ]
        viewModel.period = .month
        viewModel.range = .allTime

        viewModel.refresh(inputs: TrendsRefreshInputs(
            workouts: workouts,
            entries: workouts.map {
                WorkoutLibraryEntry.make(from: $0, manifestIndex: 0, isFavorite: false)
            },
            documents: [:],
            smartCollections: [],
            currentQuery: nil
        ))

        let ready = await waitForTrendsReady(viewModel)
        XCTAssertTrue(ready)
        XCTAssertEqual(viewModel.aggregation?.buckets.count, 1)
        XCTAssertEqual(viewModel.aggregation?.includedRunCount, 2)
        XCTAssertEqual(viewModel.aggregation?.heartRateContributingRuns, 1)
        let spoken = viewModel.accessibilitySummary()?.spokenSummary
        XCTAssertTrue(spoken?.contains("1 of 2 runs") == true)
    }

    func testViewModelSmartCollectionScopeFiltersRows() async throws {
        let viewModel = TrendsViewModel(
            calendar: Calendar(identifier: .iso8601),
            timeZone: utc
        )
        viewModel.nowProvider = { self.utcDate(2026, 9, 14) }
        viewModel.range = .allTime
        let tagged = makeWorkout(name: "Tagged", start: utcDate(2026, 9, 2))
        let untagged = makeWorkout(name: "Untagged", start: utcDate(2026, 9, 3))
        let workouts = [tagged, untagged]
        let tagID = UUID()
        let tag = WorkoutTag(id: tagID, name: "Trail")
        let collection = WorkoutSmartCollection(
            name: "Trail",
            query: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(tags: .selected(tagIDs: [tagID], match: .any))
            )
        )
        viewModel.scope = .smartCollection(collection.id)

        viewModel.refresh(inputs: TrendsRefreshInputs(
            workouts: workouts,
            entries: [
                WorkoutLibraryEntry.make(from: tagged, manifestIndex: 0, isFavorite: false, tagIDs: [tagID], tagsByID: [tagID: tag]),
                WorkoutLibraryEntry.make(from: untagged, manifestIndex: 1, isFavorite: false)
            ],
            documents: [:],
            smartCollections: [collection],
            currentQuery: nil
        ))

        let ready = await waitForTrendsReady(viewModel)
        XCTAssertTrue(ready)
        XCTAssertEqual(viewModel.aggregation?.includedRunCount, 1)
        XCTAssertEqual(viewModel.aggregation?.totalDistanceMeters ?? 0, 1_000, accuracy: 1e-9)
    }

    func testViewModelEmptyLibraryShowsEmptyState() async throws {
        let viewModel = TrendsViewModel(timeZone: utc)
        viewModel.refresh(inputs: .empty)
        let settled = await waitForTrendsReady(viewModel)
        XCTAssertTrue(settled)
        XCTAssertEqual(viewModel.loadState, .empty(.noWorkouts))
    }

    // MARK: - Session persistence

    func testSessionRoundTripRestoresTrendsDestinationAndFilters() async throws {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = makeWorkout(name: "A", start: utcDate(2026, 9, 2))
        appState.workouts = [workout]
        appState.selectWorkout(workout)
        let collection = WorkoutSmartCollection(name: "Trail", query: WorkoutLibrarySavedQuery())
        appState.smartCollections = [collection]
        appState.showTrends()
        appState.trends.period = .week
        appState.trends.range = .last6Months
        appState.trends.scope = .smartCollection(collection.id)

        let snapshot = appState.makeSessionSnapshot()
        XCTAssertEqual(snapshot.destination, .trends)
        XCTAssertEqual(snapshot.trends.periodRaw, "week")
        XCTAssertEqual(snapshot.trends.rangeRaw, "last6Months")
        XCTAssertEqual(snapshot.trends.scopeKindRaw, "smartCollection")
        XCTAssertEqual(snapshot.trends.scopeSmartCollectionID, collection.id)

        // Apply to a fresh state mimicking relaunch restore.
        let restored = AppState(storeActor: nil, importService: nil)
        restored.workouts = [workout]
        restored.selectWorkout(workout)
        restored.smartCollections = [collection]
        restored.applySessionSnapshot(snapshot)
        XCTAssertEqual(restored.workspaceMode, .trends)
        XCTAssertEqual(restored.trends.period, .week)
        XCTAssertEqual(restored.trends.range, .last6Months)
        XCTAssertEqual(restored.trends.scope, .smartCollection(collection.id))
    }

    func testVersion2SessionDecodesWithDefaultTrendsState() throws {
        let json = """
        {
          "version": 2,
          "destination": { "kind": "trends" }
        }
        """
        let snapshot = try JSONDecoder().decode(AppSessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.version, AppSessionSnapshot.currentVersion)
        XCTAssertEqual(snapshot.destination, .trends)
        XCTAssertEqual(snapshot.trends.periodRaw, "month")
        XCTAssertEqual(snapshot.trends.rangeRaw, "last12Months")
        XCTAssertEqual(snapshot.trends.scopeKindRaw, "entireLibrary")
    }

    func testValidatorRepairsInvalidTrendsState() {
        let context = AppSessionValidationContext(smartCollectionIDs: [])
        let snapshot = AppSessionSnapshot(
            destination: .trends,
            trends: AppSessionTrendsState(
                periodRaw: "decade",
                rangeRaw: "forever",
                scopeKindRaw: "smartCollection",
                scopeSmartCollectionID: UUID()
            )
        )
        let result = AppSessionValidator.validate(snapshot, context: context)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.snapshot.trends.periodRaw, "month")
        XCTAssertEqual(result.snapshot.trends.rangeRaw, "last12Months")
        XCTAssertEqual(result.snapshot.trends.scopeKindRaw, "entireLibrary")
        XCTAssertNil(result.snapshot.trends.scopeSmartCollectionID)
    }

    // MARK: - Empty-state caching and cancellation

    func testCachedResultRestoresScopeExcludedEmptyState() async throws {
        let viewModel = TrendsViewModel(
            calendar: Calendar(identifier: .iso8601),
            timeZone: utc
        )
        viewModel.nowProvider = { self.utcDate(2026, 9, 14) }
        viewModel.range = .allTime
        let workout = makeWorkout(name: "A", start: utcDate(2026, 9, 2))
        let collection = WorkoutSmartCollection(
            name: "Nothing",
            query: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(tags: .selected(tagIDs: [UUID()], match: .any))
            )
        )
        viewModel.scope = .smartCollection(collection.id)
        let inputs = TrendsRefreshInputs(
            workouts: [workout],
            entries: [WorkoutLibraryEntry.make(from: workout, manifestIndex: 0, isFavorite: false)],
            documents: [:],
            smartCollections: [collection],
            currentQuery: nil
        )

        viewModel.refresh(inputs: inputs)
        let first = await waitForTrendsReady(viewModel)
        XCTAssertTrue(first)
        XCTAssertEqual(viewModel.loadState, .empty(.scopeExcludedAll))

        // Switch period and back: the second pass is served from the cache and
        // must restore the same explanation, not a bare "ready" blank chart.
        viewModel.period = .week
        viewModel.refresh(inputs: inputs)
        let second = await waitForTrendsReady(viewModel)
        XCTAssertTrue(second)
        viewModel.period = .month
        viewModel.refresh(inputs: inputs)
        XCTAssertEqual(viewModel.loadState, .empty(.scopeExcludedAll))
    }

    private actor CancellationRecorder {
        private(set) var didStart = false
        private(set) var sawCancellation = false
        func recordStart() { didStart = true }
        func record() { sawCancellation = true }
    }

    /// Query service that blocks long enough to be cancelled, and records
    /// whether cancellation actually reached it.
    private final class SlowQueryService: WorkoutLibraryQuerying {
        let recorder = CancellationRecorder()

        func execute(
            entries: [WorkoutLibraryEntry],
            documents: [UUID: WorkoutLibrarySearchDocument],
            query: WorkoutLibraryQuery
        ) async throws -> WorkoutLibraryQueryResult {
            await recorder.recordStart()
            for _ in 0..<200 {
                if Task.isCancelled {
                    await recorder.record()
                    throw CancellationError()
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return WorkoutLibraryQueryResult(
                matchingIDs: entries.map(\.id),
                totalCount: entries.count,
                filteredCount: entries.count,
                query: query
            )
        }
    }

    func testCancelReachesTheAggregationWork() async throws {
        let service = SlowQueryService()
        let viewModel = TrendsViewModel(
            queryService: service,
            calendar: Calendar(identifier: .iso8601),
            timeZone: utc
        )
        viewModel.nowProvider = { self.utcDate(2026, 9, 14) }
        viewModel.scope = .currentLibraryFilter
        let workout = makeWorkout(name: "A", start: utcDate(2026, 9, 2))

        viewModel.refresh(inputs: TrendsRefreshInputs(
            workouts: [workout],
            entries: [WorkoutLibraryEntry.make(from: workout, manifestIndex: 0, isFavorite: false)],
            documents: [:],
            smartCollections: [],
            currentQuery: WorkoutLibraryQuery(
                searchText: "",
                filter: WorkoutLibraryFilter(),
                sort: .dateNewest,
                now: utcDate(2026, 9, 14),
                calendar: Calendar(identifier: .iso8601)
            )
        ))
        XCTAssertTrue(viewModel.isComputing)

        // Let the query actually start, so cancellation has to travel into
        // in-flight work rather than being caught at the first checkpoint.
        let startDeadline = Date().addingTimeInterval(2)
        var didStart = await service.recorder.didStart
        while Date() < startDeadline, !didStart {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
            didStart = await service.recorder.didStart
        }
        XCTAssertTrue(didStart)

        viewModel.cancel()

        // A detached task would run on regardless; a structured child task
        // carries the cancellation into the query.
        let deadline = Date().addingTimeInterval(2)
        var sawCancellation = await service.recorder.sawCancellation
        while Date() < deadline, !sawCancellation {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
            sawCancellation = await service.recorder.sawCancellation
        }
        XCTAssertTrue(sawCancellation)
        XCTAssertFalse(viewModel.isComputing)
    }

    func testContainsPeriodTracksTheAppliedWindow() async throws {
        let viewModel = TrendsViewModel(
            calendar: Calendar(identifier: .iso8601),
            timeZone: utc
        )
        viewModel.nowProvider = { self.utcDate(2026, 9, 14) }
        viewModel.range = .allTime
        let workout = makeWorkout(name: "A", start: utcDate(2026, 9, 2))
        viewModel.refresh(inputs: TrendsRefreshInputs(
            workouts: [workout],
            entries: [],
            documents: [:],
            smartCollections: [],
            currentQuery: nil
        ))
        let ready = await waitForTrendsReady(viewModel)
        XCTAssertTrue(ready)

        XCTAssertTrue(viewModel.containsPeriod(
            WorkoutTrendsPeriodKey(kind: .month, year: 2026, ordinal: 9)
        ))
        // A period the window never covered: the inspector must not hold a
        // selection for it.
        XCTAssertFalse(viewModel.containsPeriod(
            WorkoutTrendsPeriodKey(kind: .month, year: 2019, ordinal: 3)
        ))
    }

    // MARK: - Chart gap splitting

    private func chartPoint(_ ordinal: Int, _ value: Double?) -> TrendsChartPoint {
        let key = WorkoutTrendsPeriodKey(kind: .month, year: 2026, ordinal: ordinal)
        return TrendsChartPoint(
            key: key,
            periodStart: Date(timeIntervalSince1970: Double(ordinal) * 86_400),
            label: "M\(ordinal)",
            value: value,
            runCount: value == nil ? 0 : 1,
            contributingRuns: nil
        )
    }

    func testGapSplitSeriesBreaksAtValuelessPeriods() {
        // Jan and Mar carry a value, Feb does not: two series, never one line
        // drawn straight across the gap.
        let series = TrendsChartPoint.gapSplitSeries([
            chartPoint(1, 5),
            chartPoint(2, nil),
            chartPoint(3, 7)
        ])
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.first?.map(\.value), [5])
        XCTAssertEqual(series.last?.map(\.value), [7])
    }

    func testGapSplitSeriesKeepsAdjacentPeriodsTogether() {
        let series = TrendsChartPoint.gapSplitSeries([
            chartPoint(1, 5),
            chartPoint(2, 6),
            chartPoint(3, nil),
            chartPoint(4, 8),
            chartPoint(5, 9)
        ])
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.first?.map(\.value), [5, 6])
        XCTAssertEqual(series.last?.map(\.value), [8, 9])
    }

    func testGapSplitSeriesHandlesLeadingTrailingAndEmptyInput() {
        XCTAssertTrue(TrendsChartPoint.gapSplitSeries([]).isEmpty)
        XCTAssertTrue(TrendsChartPoint.gapSplitSeries([chartPoint(1, nil)]).isEmpty)

        let edges = TrendsChartPoint.gapSplitSeries([
            chartPoint(1, nil),
            chartPoint(2, 6),
            chartPoint(3, 7),
            chartPoint(4, nil)
        ])
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.map(\.value), [6, 7])
    }

    func testUnknownTrendsDestinationKindFallsBackToWorkout() throws {
        let json = """
        {
          "version": 3,
          "destination": { "kind": "spaceStation" }
        }
        """
        let snapshot = try JSONDecoder().decode(AppSessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.destination, .workout)
    }
}
