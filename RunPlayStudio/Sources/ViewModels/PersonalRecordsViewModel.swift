import Foundation
import RunPlayCore
import SwiftUI

/// UI-facing load state for the Personal Records workspace.
enum PersonalRecordsLoadState: Equatable {
    case idle
    case loading
    case ready
    case empty(PersonalRecordsEmptyReason)
    case failed(String)
}

enum PersonalRecordsEmptyReason: Equatable {
    /// Library has no workouts at all.
    case noWorkouts
    /// The selected scope matched no workouts.
    case scopeExcludedAll
}

/// One-off library backfill state surfaced inline in the Records workspace.
enum PersonalRecordsBackfillState: Equatable {
    case idle
    case running(completedCount: Int, totalCount: Int, currentWorkoutName: String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Inputs captured per refresh: the whole library plus the lightweight query
/// surface used for scope resolution. Same shape as the Trends inputs because
/// both workspaces resolve scopes identically.
struct PersonalRecordsRefreshInputs: Sendable {
    let workouts: [RunWorkout]
    let entries: [WorkoutLibraryEntry]
    let documents: [UUID: WorkoutLibrarySearchDocument]
    let smartCollections: [WorkoutSmartCollection]
    let currentQuery: WorkoutLibraryQuery?

    static let empty = PersonalRecordsRefreshInputs(
        workouts: [],
        entries: [],
        documents: [:],
        smartCollections: [],
        currentQuery: nil
    )
}

/// Strongly typed cache key so library or scope changes invalidate.
private struct PersonalRecordsRequestKey: Hashable {
    struct WorkoutRevision: Hashable {
        let id: UUID
        let analysisVersion: Int
        let startDate: Date?
        /// Record windows are the only persisted input; their identity is the
        /// marker plus per-category window bounds.
        let recordWindowsDigest: String
    }

    let workouts: [WorkoutRevision]
    let entriesDigest: String
    let smartCollectionIDs: [UUID]
    let currentQuery: WorkoutLibraryQuery?
    let scopeKind: String
    let scopeCollectionID: UUID?
}

/// Dedicated view model for the Personal Records workspace.
///
/// Owns the scope selection and a cancellable, stale-suppressed aggregation
/// pipeline, plus the inline one-off backfill progress state. Rows derive
/// from stored record windows and summaries only; no route points are walked
/// and no source files are re-parsed.
@MainActor
final class PersonalRecordsViewModel: ObservableObject {
    @Published private(set) var loadState: PersonalRecordsLoadState = .idle
    @Published private(set) var snapshot: PersonalRecordsSnapshot?
    @Published private(set) var isComputing = false
    @Published private(set) var backfillState: PersonalRecordsBackfillState = .idle

    /// Reuses the Trends scope enum and resolver: entire library, the current
    /// All Runs query, or a smart collection all resolve through the same
    /// `WorkoutLibraryQueryService` path as the All Runs table.
    @Published var scope: WorkoutTrendsScope = .entireLibrary

    private let queryService: any WorkoutLibraryQuerying
    private let calendar: Calendar
    private let announcementPolicy: AccessibilityAnnouncementPolicy
    private var computeTask: Task<Void, Never>?
    private var lastKey: PersonalRecordsRequestKey?
    private var cache: [PersonalRecordsRequestKey: PersonalRecordsSnapshot] = [:]
    private var lastInputs: PersonalRecordsRefreshInputs = .empty
    /// Injectable clock for relative date filters in scope resolution (tests).
    var nowProvider: () -> Date = { Date() }

    init(
        queryService: any WorkoutLibraryQuerying = WorkoutLibraryQueryService(),
        calendar: Calendar = .current,
        announcementPolicy: AccessibilityAnnouncementPolicy = AccessibilityAnnouncementPolicy()
    ) {
        self.queryService = queryService
        self.calendar = calendar
        self.announcementPolicy = announcementPolicy
    }

    deinit {
        computeTask?.cancel()
    }

    /// Apply durable scope selection without rebuilding. The visible Records
    /// workspace owns the subsequent refresh.
    func restoreSessionState(_ session: AppSessionPersonalRecordsState) {
        cancel()
        scope = WorkoutTrendsScope.make(
            sessionKindRawValue: session.scopeKindRaw,
            collectionID: session.scopeSmartCollectionID
        )
    }

    /// Cancel in-flight work when leaving the Records workspace. The library
    /// backfill is owned by `AppState`, not this view model, so leaving the
    /// workspace does not cancel a resumable backfill.
    func cancel() {
        computeTask?.cancel()
        computeTask = nil
        isComputing = false
        if loadState == .loading {
            loadState = snapshot == nil ? .idle : .ready
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

    // MARK: - Backfill progress (driven by AppState)

    func backfillStarted(totalCount: Int) {
        backfillState = .running(
            completedCount: 0,
            totalCount: totalCount,
            currentWorkoutName: ""
        )
    }

    func backfillProgress(
        completedCount: Int,
        totalCount: Int,
        currentWorkoutName: String
    ) {
        backfillState = .running(
            completedCount: completedCount,
            totalCount: totalCount,
            currentWorkoutName: currentWorkoutName
        )
    }

    func backfillFinished(failureMessage: String?) {
        backfillState = failureMessage.map { .failed($0) } ?? .idle
    }

    // MARK: - Refresh

    /// Recompute when the library, All Runs state, scope, or backfill output
    /// changes.
    func refresh(inputs: PersonalRecordsRefreshInputs) {
        lastInputs = inputs
        let key = PersonalRecordsRequestKey(
            workouts: inputs.workouts.map {
                PersonalRecordsRequestKey.WorkoutRevision(
                    id: $0.id,
                    analysisVersion: $0.analysisVersion,
                    startDate: $0.metadata.startDate ?? $0.routePoints.first?.timestamp,
                    recordWindowsDigest: Self.recordWindowsDigest($0.personalRecords)
                )
            },
            entriesDigest: Self.entriesDigest(inputs.entries),
            smartCollectionIDs: inputs.smartCollections.map(\.id),
            currentQuery: inputs.currentQuery,
            scopeKind: scope.sessionKindRawValue,
            scopeCollectionID: {
                if case .smartCollection(let id) = self.scope { return id }
                return nil
            }()
        )

        lastKey = key
        computeTask?.cancel()
        computeTask = nil

        if let cached = cache[key] {
            apply(snapshot: cached, inputs: inputs)
            return
        }

        let scope = self.scope
        let calendar = self.calendar
        let queryService = self.queryService
        let now = nowProvider()

        isComputing = true
        loadState = .loading

        computeTask = Task { [weak self] in
            do {
                let result = try await Self.computeResult(
                    inputs: inputs,
                    scope: scope,
                    now: now,
                    calendar: calendar,
                    queryService: queryService
                )
                guard let self, self.lastKey == key, !Task.isCancelled else { return }
                self.cache[result.key] = result.snapshot
                if self.cache.count > 12 {
                    self.cache.removeAll(keepingCapacity: true)
                    self.cache[result.key] = result.snapshot
                }
                self.apply(snapshot: result.snapshot, inputs: inputs)
            } catch is CancellationError {
                guard let self, self.lastKey == key else { return }
                self.isComputing = false
                if self.loadState == .loading {
                    self.loadState = self.snapshot == nil ? .idle : .ready
                }
            } catch {
                guard let self, self.lastKey == key else { return }
                self.isComputing = false
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private struct ComputedResult {
        let key: PersonalRecordsRequestKey
        let snapshot: PersonalRecordsSnapshot
    }

    /// Scope resolution and aggregation, off the main actor.
    private nonisolated static func computeResult(
        inputs: PersonalRecordsRefreshInputs,
        scope: WorkoutTrendsScope,
        now: Date,
        calendar: Calendar,
        queryService: any WorkoutLibraryQuerying
    ) async throws -> ComputedResult {
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
        let workouts: [RunWorkout]
        if let matching = resolution.matchingWorkoutIDs {
            workouts = inputs.workouts.filter { matching.contains($0.id) }
        } else {
            workouts = inputs.workouts
        }
        return ComputedResult(
            key: PersonalRecordsRequestKey(
                workouts: inputs.workouts.map {
                    PersonalRecordsRequestKey.WorkoutRevision(
                        id: $0.id,
                        analysisVersion: $0.analysisVersion,
                        startDate: $0.metadata.startDate ?? $0.routePoints.first?.timestamp,
                        recordWindowsDigest: recordWindowsDigest($0.personalRecords)
                    )
                },
                entriesDigest: entriesDigest(inputs.entries),
                smartCollectionIDs: inputs.smartCollections.map(\.id),
                currentQuery: inputs.currentQuery,
                scopeKind: scope.sessionKindRawValue,
                scopeCollectionID: {
                    if case .smartCollection(let id) = scope { return id }
                    return nil
                }()
            ),
            snapshot: PersonalRecordsAggregator.aggregate(workouts: workouts)
        )
    }

    private func apply(snapshot: PersonalRecordsSnapshot, inputs: PersonalRecordsRefreshInputs) {
        self.snapshot = snapshot
        isComputing = false
        if inputs.workouts.isEmpty {
            loadState = .empty(.noWorkouts)
        } else if snapshot.includedWorkoutCount == 0 {
            loadState = .empty(.scopeExcludedAll)
        } else {
            loadState = .ready
            announcementPolicy.handle(
                .recordsReady(runCount: snapshot.includedWorkoutCount)
            )
        }
    }

    /// Spoken workspace summary for accessibility.
    func accessibilitySummary() -> PersonalRecordsAccessibilitySummary? {
        guard let snapshot else { return nil }
        return PersonalRecordsAccessibilitySummary(
            scopeDescription: scopeTitle,
            snapshot: snapshot
        )
    }

    // MARK: - Digests

    private nonisolated static func recordWindowsDigest(
        _ records: WorkoutPersonalRecords?
    ) -> String {
        guard let records else { return "nil" }
        var digest = ""
        digest.reserveCapacity(records.windows.count * 24)
        for window in records.windows {
            digest += window.category.rawValue
            digest += ":"
            digest += window.startDistanceMeters.description
            digest += "-"
            digest += window.endDistanceMeters.description
            digest += "@"
            digest += window.paceSecondsPerKilometer.description
            digest += ";"
        }
        return digest
    }

    private nonisolated static func entriesDigest(_ entries: [WorkoutLibraryEntry]) -> String {
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
}
