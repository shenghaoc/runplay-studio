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
    /// Hour-floored so relative range anchors stay stable within a session hour.
    let now: Date
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

    private let queryService: any WorkoutLibraryQuerying
    private let calendar: Calendar
    private let displayTimeZone: TimeZone
    private let announcementPolicy: AccessibilityAnnouncementPolicy
    private var computeTask: Task<Void, Never>?
    private var lastKey: TrendsRequestKey?
    private var cache: [TrendsRequestKey: WorkoutTrendsAggregation] = [:]
    private var lastInputs: TrendsRefreshInputs = .empty
    /// Injectable clock for relative ranges (tests).
    var nowProvider: () -> Date = { Date() }

    /// Period label formatters, display-zone and locale aware.
    private lazy var weekLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = displayTimeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
    private lazy var monthLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = displayTimeZone
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()
    private lazy var yearLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = displayTimeZone
        formatter.dateFormat = "yyyy"
        return formatter
    }()

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
        hasBeenOpened = true
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
                    recordedUTCOffsetSeconds: $0.metadata.recordedUTCOffsetSeconds
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
            now: cacheNow(for: range, now: now)
        )

        lastKey = key
        computeTask?.cancel()
        computeTask = nil

        if let cached = cache[key] {
            apply(aggregation: cached, inputs: inputs, key: key)
            return
        }

        let workouts = inputs.workouts
        let entries = inputs.entries
        let documents = inputs.documents
        let collections = inputs.smartCollections
        let currentQuery = inputs.currentQuery
        let scope = self.scope
        let period = self.period
        let range = self.range
        let displayTimeZone = self.displayTimeZone
        let fallbackZone = self.displayTimeZone
        let calendar = self.calendar
        let queryService = self.queryService

        isComputing = true
        loadState = .loading

        computeTask = Task { [weak self] in
            let result: Result<
                (aggregation: WorkoutTrendsAggregation, undated: Int, allRowsEmpty: Bool, scopedRowsEmpty: Bool),
                Error
            > = await Task.detached(priority: .userInitiated) {
                do {
                let allRows = workouts.compactMap { WorkoutTrendsSummaryRow.make(from: $0) }
                let undated = workouts.count - allRows.count
                let resolution = try await WorkoutTrendsScopeResolver.resolve(
                    scope: scope,
                    entries: entries,
                    documents: documents,
                    smartCollections: collections,
                    currentQuery: currentQuery,
                    now: now,
                    calendar: calendar,
                    service: queryService
                )
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
                    fallbackBucketingTimeZone: fallbackZone
                )
                return .success((
                    aggregation: aggregation,
                    undated: undated,
                    allRowsEmpty: allRows.isEmpty,
                    scopedRowsEmpty: rows.isEmpty
                ))
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self, self.lastKey == key, !Task.isCancelled else { return }

            switch result {
            case .success(let payload):
                self.undatedRunCount = payload.undated
                self.cache[key] = payload.aggregation
                if self.cache.count > 12 {
                    let keep = payload.aggregation
                    self.cache.removeAll(keepingCapacity: true)
                    self.cache[key] = keep
                }
                self.apply(aggregation: payload.aggregation, inputs: inputs, key: key)
                if !inputs.workouts.isEmpty {
                    if payload.allRowsEmpty {
                        self.loadState = .empty(.noDatedWorkouts)
                    } else if payload.scopedRowsEmpty {
                        self.loadState = .empty(.scopeExcludedAll)
                    }
                }
            case .failure(let error):
                if error is CancellationError {
                    self.isComputing = false
                    if self.aggregation == nil, self.loadState == .loading {
                        self.loadState = .idle
                    } else if self.loadState == .loading {
                        self.loadState = .ready
                    }
                    return
                }
                self.isComputing = false
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Chart points for one metric, in display-zone period order.
    func chartPoints(for metric: TrendsMetric) -> [TrendsChartPoint] {
        guard let aggregation else { return [] }
        return aggregation.buckets.map { bucket in
            let bounds = WorkoutTrendsAggregator.periodBounds(
                for: bucket.id,
                timeZone: displayTimeZone
            )
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
            return TrendsChartPoint(
                key: bucket.id,
                periodStart: bounds.start,
                label: periodLabel(for: bucket.id),
                value: value,
                runCount: bucket.runCount,
                contributingRuns: contributing
            )
        }
    }

    /// Short localized period label for axes and the inspector.
    func periodLabel(for key: WorkoutTrendsPeriodKey) -> String {
        let bounds = WorkoutTrendsAggregator.periodBounds(for: key, timeZone: displayTimeZone)
        switch key.kind {
        case .week:
            return weekLabelFormatter.string(from: bounds.start)
        case .month:
            return monthLabelFormatter.string(from: bounds.start)
        case .year:
            return yearLabelFormatter.string(from: bounds.start)
        }
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

    // MARK: - Private

    private func apply(
        aggregation: WorkoutTrendsAggregation,
        inputs: TrendsRefreshInputs,
        key: TrendsRequestKey
    ) {
        self.aggregation = aggregation
        self.isComputing = false
        if inputs.workouts.isEmpty {
            loadState = .empty(.noWorkouts)
        } else {
            loadState = .ready
        }
        if aggregation.includedRunCount > 0 {
            announcementPolicy.handle(.trendsReady(runCount: aggregation.includedRunCount))
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
