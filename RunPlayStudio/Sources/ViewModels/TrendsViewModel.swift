import Foundation
import RunPlayCore
import SwiftUI

/// UI-facing load state for the Trends workspace.
enum TrendsLoadState: Equatable {
    case idle
    case loading
    case ready
    case empty(TrendsEmptyReason)
    case failed(String)
}

enum TrendsEmptyReason: Equatable {
    /// Library has no workouts at all.
    case noWorkouts
    /// No workout carries a usable start date.
    case noDatedWorkouts
    /// The selected scope matched no workouts.
    case scopeExcludedAll
}

/// Inline one-off training-load backfill state, driven by `AppState` so a
/// resumable pass survives leaving the workspace. Mirrors the records
/// backfill banner contract.
enum TrainingLoadBackfillState: Equatable {
    case idle
    case running(completedCount: Int, totalCount: Int, currentWorkoutName: String)
    case failed(String)
}

extension WorkoutTrendsPeriod {
    var title: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
}

extension WorkoutTrendsRange {
    var title: String {
        switch self {
        case .last3Months: return "Last 3 Months"
        case .last6Months: return "Last 6 Months"
        case .last12Months: return "Last 12 Months"
        case .allTime: return "All Time"
        }
    }
}

/// One chart-ready period value. `value` is `nil` for a gap.
struct TrendsChartPoint: Identifiable, Hashable {
    let key: WorkoutTrendsPeriodKey
    /// Period start in the display zone (chart x position).
    let periodStart: Date
    /// Short localized axis label.
    let label: String
    let value: Double?
    let runCount: Int
    let contributingRuns: Int?

    var id: WorkoutTrendsPeriodKey { key }

    /// Splits one period series into runs of *adjacent* periods that carry a
    /// value, so a chart never bridges a gap.
    ///
    /// `points` mirrors `WorkoutTrendsAggregation.buckets`, which is
    /// contiguous across the whole window including empty periods, so
    /// adjacency in the array is adjacency in time. Ordering alone is not
    /// enough: every later period compares greater, which would join every
    /// value into one unbroken series.
    static func gapSplitSeries(_ points: [TrendsChartPoint]) -> [[TrendsChartPoint]] {
        var series: [[TrendsChartPoint]] = []
        var previousValuedIndex: Int?
        for index in points.indices where points[index].value != nil {
            if previousValuedIndex == index - 1 {
                series[series.count - 1].append(points[index])
            } else {
                series.append([points[index]])
            }
            previousValuedIndex = index
        }
        return series
    }
}

/// The four Trends metrics.
enum TrendsMetric: CaseIterable, Identifiable {
    case distance
    case pace
    case heartRate
    case ascent

    var id: String { chartTitle }

    var chartTitle: String {
        switch self {
        case .distance: return "Distance"
        case .pace: return "Active Pace"
        case .heartRate: return "Heart Rate"
        case .ascent: return "Ascent"
        }
    }

    var unit: String {
        switch self {
        case .distance: return "km"
        case .pace: return "s/km"
        case .heartRate: return "bpm"
        case .ascent: return "m"
        }
    }

    var accessibilityUnit: String {
        switch self {
        case .distance: return "kilometres"
        case .pace: return "s/km"
        case .heartRate: return "beats per minute"
        case .ascent: return "metres"
        }
    }
}

/// Inputs captured per refresh: the whole library plus the lightweight query
/// surface used for scope resolution.
struct TrendsRefreshInputs: Sendable {
    let workouts: [RunWorkout]
    let entries: [WorkoutLibraryEntry]
    let documents: [UUID: WorkoutLibrarySearchDocument]
    let smartCollections: [WorkoutSmartCollection]
    let currentQuery: WorkoutLibraryQuery?

    static let empty = TrendsRefreshInputs(
        workouts: [],
        entries: [],
        documents: [:],
        smartCollections: [],
        currentQuery: nil
    )
}

/// Strongly typed cache key so library or scope changes invalidate.
private struct TrendsRequestKey: Hashable {
    struct WorkoutRevision: Hashable {
        let id: UUID
        let analysisVersion: Int
        let startDate: Date?
        let recordedUTCOffsetSeconds: Int?
        /// Training-load snapshots do not bump `analysisVersion`; this
        /// in-session digest is what makes a backfilled or recomputed load
        /// visible to the cache.
        let trainingLoadRevision: Int?
        /// A DEM correction changes ascent and descent without bumping
        /// `analysisVersion`; the summary totals themselves key the cache.
        let elevationGainMeters: Double
        let elevationLossMeters: Double
    }

    let workouts: [WorkoutRevision]
    /// Query-surface revisions that can change scope resolution without
    /// changing any workout snapshot.
    let entriesDigest: String
    let smartCollectionIDs: [UUID]
    let currentQuery: WorkoutLibraryQuery?
    let period: WorkoutTrendsPeriod
    let range: WorkoutTrendsRange
    let scopeKind: String
    let scopeCollectionID: UUID?
    let ctlTimeConstantDays: Double
    let atlTimeConstantDays: Double
    let includeEstimatedLoads: Bool
    /// Hour-floored so relative range anchors stay stable within a session hour.
    let now: Date
}

/// One finished aggregation plus everything the view needs to render it.
///
/// Chart points and period labels are built once here, off the main actor,
/// rather than recomputed in the view body: the body reads four panels plus
/// four accessibility summaries per pass, and each rebuild was constructing a
/// `Calendar` twice per period.
private struct TrendsResult: Sendable {
    let aggregation: WorkoutTrendsAggregation
    let undatedRunCount: Int
    /// The empty state this result implies, or `nil` when it has runs. Cached
    /// with the aggregation so a cache hit restores the same explanation.
    let emptyReason: TrendsEmptyReason?
    let chartPoints: [TrendsMetric: [TrendsChartPoint]]
    let trainingLoad: FitnessFatigueSeries?

    /// Period keys present in this window, for O(1) membership tests.
    var bucketKeys: Set<WorkoutTrendsPeriodKey> {
        Set(aggregation.buckets.map(\.id))
    }
}

/// Dedicated view model for the Trends workspace.
///
/// Owns period/range/scope selections and a cancellable, stale-suppressed
/// aggregation pipeline. Rows derive from stored summaries only; no source
/// files are re-parsed and no route points are walked.
@MainActor
final class TrendsViewModel: ObservableObject {
    @Published private(set) var loadState: TrendsLoadState = .idle
    @Published private(set) var aggregation: WorkoutTrendsAggregation?
    @Published private(set) var undatedRunCount = 0
    @Published private(set) var isComputing = false

    @Published var period: WorkoutTrendsPeriod = .month
    @Published var range: WorkoutTrendsRange = .last12Months
    @Published var scope: WorkoutTrendsScope = .entireLibrary

    /// Fitness/fatigue time constants and the estimated-inclusion opt-in.
    /// Presentation preferences: they never touch stored snapshots, so they
    /// live here rather than in the athlete profile.
    @Published var ctlTimeConstantDays = TrainingLoadRollup.defaultCTLTimeConstantDays
    @Published var atlTimeConstantDays = TrainingLoadRollup.defaultATLTimeConstantDays
    @Published var includeEstimatedLoads = false

    /// The applied training-load series for the panel.
    @Published private(set) var trainingLoad: FitnessFatigueSeries?

    /// Feature-local backfill progress (never a library-wide token).
    @Published private(set) var trainingLoadBackfillState: TrainingLoadBackfillState = .idle

    private let queryService: any WorkoutLibraryQuerying
    private let calendar: Calendar
    private let displayTimeZone: TimeZone
    private let announcementPolicy: AccessibilityAnnouncementPolicy
    private var computeTask: Task<Void, Never>?
    private var lastKey: TrendsRequestKey?
    private var cache: [TrendsRequestKey: TrendsResult] = [:]
    private var lastInputs: TrendsRefreshInputs = .empty
    /// Chart points, period labels, and key membership for the applied
    /// result. Plain stored state, not `@Published`: reading it from a view
    /// body must not schedule another render.
    private var appliedChartPoints: [TrendsMetric: [TrendsChartPoint]] = [:]
    private var appliedPeriodLabels: [WorkoutTrendsPeriodKey: String] = [:]
    private var appliedBucketKeys: Set<WorkoutTrendsPeriodKey> = []
    /// Injectable clock for relative ranges (tests).
    var nowProvider: () -> Date = { Date() }

    /// Period label formatters, display-zone and locale aware.
    ///
    /// One set per aggregation, built where the labels are: `DateFormatter` is
    /// not safe to share across actors, and labels are produced off the main
    /// actor alongside the chart points.
    private struct PeriodLabelFormatters {
        let week: DateFormatter
        let month: DateFormatter
        let year: DateFormatter

        init(timeZone: TimeZone) {
            week = Self.make(timeZone: timeZone, format: "d MMM yyyy")
            month = Self.make(timeZone: timeZone, format: "MMM yyyy")
            year = Self.make(timeZone: timeZone, format: "yyyy")
        }

        private static func make(timeZone: TimeZone, format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            return formatter
        }

        func label(for kind: WorkoutTrendsPeriod, start: Date) -> String {
            switch kind {
            case .week: return week.string(from: start)
            case .month: return month.string(from: start)
            case .year: return year.string(from: start)
            }
        }
    }

    init(
        queryService: any WorkoutLibraryQuerying = WorkoutLibraryQueryService(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        announcementPolicy: AccessibilityAnnouncementPolicy = AccessibilityAnnouncementPolicy()
    ) {
        self.queryService = queryService
        self.calendar = calendar
        self.displayTimeZone = timeZone
        self.announcementPolicy = announcementPolicy
    }

    deinit {
        computeTask?.cancel()
    }

    /// Whether Trends has been opened this process. The smart-collection
    /// scope preselect applies only before the first open; afterwards an
    /// explicit user choice is never overwritten.
    private(set) var hasBeenOpened = false

    func markOpened() {
        hasBeenOpened = true
    }

    /// Apply durable selections without rebuilding. The visible Trends
    /// workspace owns the subsequent refresh.
    func restoreSessionState(_ session: AppSessionTrendsState) {
        cancel()
        // Startup restores a session even when no file exists, synthesizing
        // defaults. Treating that as "already opened" disarmed the
        // smart-collection preselect before the user could ever reach Trends,
        // so it never fired in the running app. Only a session that actually
        // carries a Trends selection is a user choice worth protecting.
        hasBeenOpened = session != AppSessionTrendsState()
        period = WorkoutTrendsPeriod(rawValue: session.periodRaw) ?? .month
        range = WorkoutTrendsRange(rawValue: session.rangeRaw) ?? .last12Months
        scope = WorkoutTrendsScope.make(
            sessionKindRawValue: session.scopeKindRaw,
            collectionID: session.scopeSmartCollectionID
        )
    }

    /// Cancel in-flight work when leaving the Trends workspace.
    func cancel() {
        computeTask?.cancel()
        computeTask = nil
        isComputing = false
        if loadState == .loading {
            loadState = aggregation == nil ? .idle : .ready
        }
    }

    /// Human-readable scope title for headers and accessibility.
    var scopeTitle: String {
        switch scope {
        case .entireLibrary:
            return "All Workouts"
        case .currentLibraryFilter:
            return "Current All Runs Filter"
        case .smartCollection(let id):
            let name = lastInputs.smartCollections.first { $0.id == id }?.name
            return name ?? "Missing Collection"
        }
    }

    /// Recompute when the library, All Runs state, or filters change.
    func refresh(inputs: TrendsRefreshInputs) {
        lastInputs = inputs
        let now = nowProvider()
        let key = TrendsRequestKey(
            workouts: inputs.workouts.map {
                TrendsRequestKey.WorkoutRevision(
                    id: $0.id,
                    analysisVersion: $0.analysisVersion,
                    startDate: $0.metadata.startDate ?? $0.routePoints.first?.timestamp,
                    recordedUTCOffsetSeconds: $0.metadata.recordedUTCOffsetSeconds,
                    trainingLoadRevision: $0.trainingLoad.map(\.hashValue),
                    elevationGainMeters: $0.summary.elevationGainMeters,
                    elevationLossMeters: $0.summary.elevationLossMeters
                )
            },
            entriesDigest: Self.entriesDigest(inputs.entries),
            smartCollectionIDs: inputs.smartCollections.map(\.id),
            currentQuery: inputs.currentQuery,
            period: period,
            range: range,
            scopeKind: scope.sessionKindRawValue,
            scopeCollectionID: {
                if case .smartCollection(let id) = self.scope { return id }
                return nil
            }(),
            ctlTimeConstantDays: ctlTimeConstantDays,
            atlTimeConstantDays: atlTimeConstantDays,
            includeEstimatedLoads: includeEstimatedLoads,
            now: cacheNow(for: range, now: now)
        )

        lastKey = key
        computeTask?.cancel()
        computeTask = nil

        if let cached = cache[key] {
            apply(result: cached, inputs: inputs)
            return
        }

        let scope = self.scope
        let period = self.period
        let range = self.range
        let displayTimeZone = self.displayTimeZone
        let calendar = self.calendar
        let queryService = self.queryService
        let ctlTimeConstantDays = self.ctlTimeConstantDays
        let atlTimeConstantDays = self.atlTimeConstantDays
        let includeEstimatedLoads = self.includeEstimatedLoads

        isComputing = true
        loadState = .loading

        // A structured child task, not `Task.detached`: a detached task does
        // not inherit cancellation, so cancelling would discard the result
        // while the work ran on to completion. `computeResult` is
        // `nonisolated`, so the aggregation still runs off the main actor.
        computeTask = Task { [weak self] in
            do {
                let result = try await Self.computeResult(
                    inputs: inputs,
                    scope: scope,
                    period: period,
                    range: range,
                    now: now,
                    displayTimeZone: displayTimeZone,
                    calendar: calendar,
                    queryService: queryService,
                    ctlTimeConstantDays: ctlTimeConstantDays,
                    atlTimeConstantDays: atlTimeConstantDays,
                    includeEstimatedLoads: includeEstimatedLoads
                )
                guard let self, self.lastKey == key, !Task.isCancelled else { return }
                self.store(result: result, for: key)
                self.apply(result: result, inputs: inputs)
            } catch is CancellationError {
                guard let self, self.lastKey == key else { return }
                self.isComputing = false
                if self.loadState == .loading {
                    self.loadState = self.aggregation == nil ? .idle : .ready
                }
            } catch {
                guard let self, self.lastKey == key else { return }
                self.isComputing = false
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Row derivation, scope resolution, and bucketing, off the main actor.
    ///
    /// Cancellation is cooperative Swift work checked around each stage; the
    /// synchronous aggregation itself cannot be interrupted, so it is bracketed
    /// rather than polled.
    private nonisolated static func computeResult(
        inputs: TrendsRefreshInputs,
        scope: WorkoutTrendsScope,
        period: WorkoutTrendsPeriod,
        range: WorkoutTrendsRange,
        now: Date,
        displayTimeZone: TimeZone,
        calendar: Calendar,
        queryService: any WorkoutLibraryQuerying,
        ctlTimeConstantDays: Double,
        atlTimeConstantDays: Double,
        includeEstimatedLoads: Bool
    ) async throws -> TrendsResult {
        try Task.checkCancellation()
        let allRows = inputs.workouts.compactMap { WorkoutTrendsSummaryRow.make(from: $0) }
        let undated = inputs.workouts.count - allRows.count

        try Task.checkCancellation()
        let resolution = try await WorkoutTrendsScopeResolver.resolve(
            scope: scope,
            entries: inputs.entries,
            documents: inputs.documents,
            smartCollections: inputs.smartCollections,
            currentQuery: inputs.currentQuery,
            now: now,
            calendar: calendar,
            service: queryService
        )

        try Task.checkCancellation()
        let rows: [WorkoutTrendsSummaryRow]
        if let matching = resolution.matchingWorkoutIDs {
            rows = allRows.filter { matching.contains($0.id) }
        } else {
            rows = allRows
        }
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: rows,
            period: period,
            range: range,
            now: now,
            displayTimeZone: displayTimeZone,
            fallbackBucketingTimeZone: displayTimeZone
        )
        try Task.checkCancellation()

        // Training-load series over the same scope resolution; "all time"
        // spans every scoped day, month-count ranges slice by anchor day.
        let trainingLoadSeries: FitnessFatigueSeries?
        if let matching = resolution.matchingWorkoutIDs {
            let scopedWorkouts = inputs.workouts.filter { matching.contains($0.id) }
            trainingLoadSeries = Self.trainingLoadSeries(
                workouts: scopedWorkouts,
                range: range,
                now: now,
                displayTimeZone: displayTimeZone,
                calendar: calendar,
                ctlTimeConstantDays: ctlTimeConstantDays,
                atlTimeConstantDays: atlTimeConstantDays,
                includeEstimatedLoads: includeEstimatedLoads
            )
        } else {
            trainingLoadSeries = Self.trainingLoadSeries(
                workouts: inputs.workouts,
                range: range,
                now: now,
                displayTimeZone: displayTimeZone,
                calendar: calendar,
                ctlTimeConstantDays: ctlTimeConstantDays,
                atlTimeConstantDays: atlTimeConstantDays,
                includeEstimatedLoads: includeEstimatedLoads
            )
        }
        try Task.checkCancellation()

        let emptyReason: TrendsEmptyReason?
        if allRows.isEmpty {
            emptyReason = .noDatedWorkouts
        } else if rows.isEmpty {
            emptyReason = .scopeExcludedAll
        } else {
            emptyReason = nil
        }
        return TrendsResult(
            aggregation: aggregation,
            undatedRunCount: undated,
            emptyReason: emptyReason,
            chartPoints: chartPoints(for: aggregation, displayTimeZone: displayTimeZone),
            trainingLoad: trainingLoadSeries
        )
    }

    /// Daily load series + fitness/fatigue model over the scoped workouts,
    /// sliced to the range anchor day for month-count ranges.
    private nonisolated static func trainingLoadSeries(
        workouts: [RunWorkout],
        range: WorkoutTrendsRange,
        now: Date,
        displayTimeZone: TimeZone,
        calendar: Calendar,
        ctlTimeConstantDays: Double,
        atlTimeConstantDays: Double,
        includeEstimatedLoads: Bool
    ) -> FitnessFatigueSeries? {
        let contributions: [(date: Date, recordedUTCOffsetSeconds: Int?, load: TrainingLoadSnapshot?)] =
            workouts.compactMap { workout in
                guard let start = WorkoutLibraryEntry.canonicalStartDate(for: workout) else {
                    return nil
                }
                return (
                    start,
                    workout.metadata.recordedUTCOffsetSeconds,
                    workout.trainingLoad
                )
            }
        guard !contributions.isEmpty else { return nil }
        var full = TrainingLoadRollup.series(
            contributions: contributions,
            fallbackTimeZone: displayTimeZone,
            ctlTimeConstantDays: ctlTimeConstantDays,
            atlTimeConstantDays: atlTimeConstantDays,
            includeEstimatedLoads: includeEstimatedLoads
        )
        guard let monthCount = range.monthCount else { return full }
        let anchor = calendar.date(byAdding: .month, value: -monthCount, to: now) ?? now
        var anchorCalendar = calendar
        anchorCalendar.timeZone = displayTimeZone
        let anchorDay = anchorCalendar.startOfDay(for: anchor)
        let cutoff = full.loadDays.firstIndex { $0.date >= anchorDay } ?? full.loadDays.count
        guard cutoff > 0 else { return nil }
        guard cutoff < full.loadDays.count else { return full }
        full = FitnessFatigueSeries(
            loadDays: Array(full.loadDays[cutoff...]),
            modelDays: Array(full.modelDays[cutoff...]),
            hrCoverageFraction: full.hrCoverageFraction,
            includesEstimatedLoads: full.includesEstimatedLoads
        )
        return full
    }

    /// Builds every metric's chart points in one pass over the buckets.
    ///
    /// Period bounds and the localized label are resolved once per period and
    /// shared by all four metrics, instead of once per metric per body pass.
    private nonisolated static func chartPoints(
        for aggregation: WorkoutTrendsAggregation,
        displayTimeZone: TimeZone
    ) -> [TrendsMetric: [TrendsChartPoint]] {
        let formatters = PeriodLabelFormatters(timeZone: displayTimeZone)
        var points: [TrendsMetric: [TrendsChartPoint]] = [:]
        for metric in TrendsMetric.allCases {
            points[metric] = []
            points[metric]?.reserveCapacity(aggregation.buckets.count)
        }
        for bucket in aggregation.buckets {
            let start = WorkoutTrendsAggregator.periodBounds(
                for: bucket.id,
                timeZone: displayTimeZone
            ).start
            let label = formatters.label(for: bucket.id.kind, start: start)
            for metric in TrendsMetric.allCases {
                let value: Double?
                let contributing: Int?
                switch metric {
                case .distance:
                    value = bucket.totalDistanceMeters / 1_000
                    contributing = nil
                case .pace:
                    value = bucket.meanActivePaceSecondsPerKilometer
                    contributing = nil
                case .heartRate:
                    value = bucket.meanHeartRateBPM
                    contributing = bucket.heartRateContributingRuns
                case .ascent:
                    value = bucket.totalAscentMeters
                    contributing = bucket.ascentContributingRuns
                }
                points[metric]?.append(TrendsChartPoint(
                    key: bucket.id,
                    periodStart: start,
                    label: label,
                    value: value,
                    runCount: bucket.runCount,
                    contributingRuns: contributing
                ))
            }
        }
        return points
    }

    /// Chart points for one metric, in display-zone period order. A lookup:
    /// the points were built when the aggregation was applied.
    func chartPoints(for metric: TrendsMetric) -> [TrendsChartPoint] {
        appliedChartPoints[metric] ?? []
    }

    /// Whether the applied window still contains this period.
    func containsPeriod(_ key: WorkoutTrendsPeriodKey) -> Bool {
        appliedBucketKeys.contains(key)
    }

    /// Short localized period label for axes and the inspector.
    func periodLabel(for key: WorkoutTrendsPeriodKey) -> String {
        if let cached = appliedPeriodLabels[key] {
            return cached
        }
        let start = WorkoutTrendsAggregator.periodBounds(for: key, timeZone: displayTimeZone).start
        return PeriodLabelFormatters(timeZone: displayTimeZone).label(for: key.kind, start: start)
    }

    /// Spoken workspace summary for accessibility.
    func accessibilitySummary() -> TrendsAccessibilitySummary? {
        guard let aggregation else { return nil }
        return TrendsAccessibilitySummary(
            periodDescription: period.title.lowercased(),
            rangeDescription: range.title.lowercased(),
            scopeDescription: scopeTitle,
            includedRunCount: aggregation.includedRunCount,
            outOfWindowRunCount: aggregation.outOfWindowRunCount,
            undatedRunCount: undatedRunCount,
            aggregation: aggregation
        )
    }

    /// Spoken chart summary for one metric.
    func chartAccessibilitySummary(for metric: TrendsMetric) -> TrendsChartAccessibilitySummary {
        let points = chartPoints(for: metric)
        return TrendsChartAccessibilitySummary(
            metricName: metric.chartTitle,
            unit: metric.unit,
            periodDescription: period.title.lowercased(),
            values: points.map(\.value),
            contributorCounts: metric == .heartRate || metric == .ascent
                ? points.map { $0.contributingRuns ?? 0 }
                : nil,
            runCounts: points.map(\.runCount)
        )
    }

    /// True when the trailing period is the in-progress current period.
    var showsInProgressPeriod: Bool {
        guard let aggregation else { return false }
        return aggregation.currentPeriodKey != nil
    }

    // MARK: - Training-load backfill progress (driven by AppState)

    /// The pass survives leaving Trends: ownership lives with `AppState`,
    /// which keeps running it and reports progress here.
    func trainingLoadBackfillStarted(totalCount: Int) {
        trainingLoadBackfillState = .running(
            completedCount: 0,
            totalCount: totalCount,
            currentWorkoutName: ""
        )
    }

    func trainingLoadBackfillProgress(
        completedCount: Int,
        totalCount: Int,
        currentWorkoutName: String
    ) {
        trainingLoadBackfillState = .running(
            completedCount: completedCount,
            totalCount: totalCount,
            currentWorkoutName: currentWorkoutName
        )
    }

    func trainingLoadBackfillFinished(failureMessage: String?) {
        trainingLoadBackfillState = failureMessage.map { .failed($0) } ?? .idle
    }

    /// Spoken chart summary for the training-load panel.
    func trainingLoadChartAccessibilitySummary() -> TrainingLoadChartAccessibilitySummary? {
        guard let series = trainingLoad else { return nil }
        let lastLoad = series.loadDays.last?.contribution == .hrDay
            ? series.loadDays.last?.measuredLoad
            : nil
        return TrainingLoadChartAccessibilitySummary(
            includesEstimatedLoads: series.includesEstimatedLoads,
            hrCoverageFraction: series.hrCoverageFraction,
            dayCount: series.loadDays.count,
            hrDayCount: series.loadDays.filter { $0.contribution == .hrDay }.count,
            noHRDataDayCount: series.loadDays.filter { $0.contribution == .noHRData }.count,
            latestLoad: lastLoad,
            latestCTL: series.modelDays.last?.ctl,
            latestATL: series.modelDays.last?.atl,
            latestTSB: series.modelDays.last?.tsb
        )
    }

    // MARK: - Private

    private func store(result: TrendsResult, for key: TrendsRequestKey) {
        cache[key] = result
        if cache.count > 12 {
            cache.removeAll(keepingCapacity: true)
            cache[key] = result
        }
    }

    /// Publishes one result. A cached result restores exactly the same state a
    /// fresh computation would, empty-state explanation and undated count
    /// included.
    private func apply(result: TrendsResult, inputs: TrendsRefreshInputs) {
        aggregation = result.aggregation
        undatedRunCount = result.undatedRunCount
        trainingLoad = result.trainingLoad
        appliedChartPoints = result.chartPoints
        appliedBucketKeys = result.bucketKeys
        appliedPeriodLabels = Dictionary(
            result.chartPoints[.distance]?.map { ($0.key, $0.label) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        isComputing = false
        if inputs.workouts.isEmpty {
            loadState = .empty(.noWorkouts)
        } else if let emptyReason = result.emptyReason {
            loadState = .empty(emptyReason)
        } else {
            loadState = .ready
        }
        if result.aggregation.includedRunCount > 0 {
            announcementPolicy.handle(.trendsReady(runCount: result.aggregation.includedRunCount))
        }
    }

    private static func entriesDigest(_ entries: [WorkoutLibraryEntry]) -> String {
        var digest = ""
        digest.reserveCapacity(entries.count * 24)
        for entry in entries {
            digest += entry.id.uuidString
            digest += "|"
            digest += entry.nameNotesRevision
            digest += "|"
            digest += entry.tagRevision
            digest += ";"
        }
        return digest
    }

    /// Cache-key clock: month-count ranges anchor on `now`, so they stabilize
    /// within the hour; all time uses one stable sentinel.
    private func cacheNow(for range: WorkoutTrendsRange, now: Date) -> Date {
        guard range.monthCount != nil else { return .distantPast }
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
    }
}
