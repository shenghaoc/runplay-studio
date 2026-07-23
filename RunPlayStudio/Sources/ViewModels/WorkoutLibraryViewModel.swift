import Foundation
import RunPlayCore
import SwiftUI

/// UI-facing load state for the All Runs workspace.
enum WorkoutLibraryLoadState: Equatable {
    case idle
    case loading
    case ready
    case emptyLibrary
    case emptySearch(query: String)
    case emptyFilters
    case failed(String)
}

/// Dedicated view model for All Runs search, filter, sort, and result state.
///
/// Keeps heavy query work out of `AppState`. Search documents are in-memory only.
@MainActor
final class WorkoutLibraryViewModel: ObservableObject {
    @Published private(set) var entries: [WorkoutLibraryEntry] = []
    @Published private(set) var resultIDs: [UUID] = []
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var filteredCount: Int = 0
    @Published private(set) var loadState: WorkoutLibraryLoadState = .idle
    @Published private(set) var favoriteIDs: Set<UUID> = []

    @Published var searchText: String = "" {
        didSet { scheduleQuery() }
    }
    @Published var sort: WorkoutLibrarySort = .dateNewest {
        didSet { scheduleQuery() }
    }
    @Published var favoriteFilter: WorkoutLibraryFavoriteFilter = .all {
        didSet { scheduleQuery() }
    }
    @Published var sourceFilter: WorkoutLibrarySourceFilter = .all {
        didSet { scheduleQuery() }
    }
    @Published var dateFilter: WorkoutLibraryDateFilter = .allTime {
        didSet { scheduleQuery() }
    }
    @Published var customDateStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var customDateEnd: Date = Date()
    @Published var dataFilters: WorkoutLibraryDataFilters = .none {
        didSet { scheduleQuery() }
    }

    @Published var tableSelection: UUID?
    @Published var editorError: String?

    private var documents: [UUID: WorkoutLibrarySearchDocument] = [:]
    private var entryByID: [UUID: WorkoutLibraryEntry] = [:]
    private var queryTask: Task<Void, Never>?
    private var queryGeneration: UInt64 = 0
    private var lastPublishedKey: QueryCacheKey?
    private var isBatchingQueryChanges = false
    private let queryService: any WorkoutLibraryQuerying
    private let calendar: Calendar
    /// Injected clock for relative filters (tests).
    var nowProvider: () -> Date = { Date() }

    init(
        queryService: any WorkoutLibraryQuerying = WorkoutLibraryQueryService(),
        calendar: Calendar = .current
    ) {
        self.queryService = queryService
        self.calendar = calendar
    }

    deinit {
        queryTask?.cancel()
    }

    // MARK: - Library revisions

    /// Replace the full library used by All Runs (import, load, batch commit).
    func replaceLibrary(workouts: [RunWorkout], favoriteIDs: Set<UUID>) {
        self.favoriteIDs = favoriteIDs
        rebuildEntries(from: workouts)
        scheduleQuery(force: true)
    }

    /// Apply a single workout mutation (metadata) without full rebuild of unrelated documents.
    func applyWorkoutUpdate(_ workout: RunWorkout) {
        guard let index = entries.firstIndex(where: { $0.id == workout.id }) else {
            // New workout not yet in entries — full rebuild path preferred via replaceLibrary.
            return
        }
        let entry = WorkoutLibraryEntry.make(
            from: workout,
            manifestIndex: entries[index].manifestIndex,
            isFavorite: favoriteIDs.contains(workout.id)
        )
        entries[index] = entry
        entryByID[entry.id] = entry
        documents[entry.id] = WorkoutLibrarySearchDocument.make(from: entry, calendar: calendar)
        scheduleQuery(force: true)
    }

    func applyFavoriteChange(workoutID: UUID, isFavorite: Bool) {
        if isFavorite {
            favoriteIDs.insert(workoutID)
        } else {
            favoriteIDs.remove(workoutID)
        }
        if let index = entries.firstIndex(where: { $0.id == workoutID }) {
            let old = entries[index]
            let updated = WorkoutLibraryEntry(
                id: old.id,
                manifestIndex: old.manifestIndex,
                isFavorite: isFavorite,
                displayName: old.displayName,
                metadataName: old.metadataName,
                notes: old.notes,
                activityType: old.activityType,
                deviceName: old.deviceName,
                source: old.source,
                importProvider: old.importProvider,
                originalFilename: old.originalFilename,
                startDate: old.startDate,
                totalDistanceMeters: old.totalDistanceMeters,
                activePaceSecondsPerKilometer: old.activePaceSecondsPerKilometer,
                totalElapsedSeconds: old.totalElapsedSeconds,
                hasHeartRate: old.hasHeartRate,
                hasCorrectedElevation: old.hasCorrectedElevation,
                hasRecordedLaps: old.hasRecordedLaps,
                nameNotesRevision: old.nameNotesRevision
            )
            entries[index] = updated
            entryByID[updated.id] = updated
        }
        scheduleQuery(force: true)
    }

    func removeWorkout(id: UUID) {
        favoriteIDs.remove(id)
        entries.removeAll { $0.id == id }
        entryByID.removeValue(forKey: id)
        documents.removeValue(forKey: id)
        // Reindex manifest positions.
        for i in entries.indices {
            let old = entries[i]
            if old.manifestIndex != i {
                let updated = WorkoutLibraryEntry(
                    id: old.id,
                    manifestIndex: i,
                    isFavorite: old.isFavorite,
                    displayName: old.displayName,
                    metadataName: old.metadataName,
                    notes: old.notes,
                    activityType: old.activityType,
                    deviceName: old.deviceName,
                    source: old.source,
                    importProvider: old.importProvider,
                    originalFilename: old.originalFilename,
                    startDate: old.startDate,
                    totalDistanceMeters: old.totalDistanceMeters,
                    activePaceSecondsPerKilometer: old.activePaceSecondsPerKilometer,
                    totalElapsedSeconds: old.totalElapsedSeconds,
                    hasHeartRate: old.hasHeartRate,
                    hasCorrectedElevation: old.hasCorrectedElevation,
                    hasRecordedLaps: old.hasRecordedLaps,
                    nameNotesRevision: old.nameNotesRevision
                )
                entries[i] = updated
                entryByID[updated.id] = updated
            }
        }
        if tableSelection == id {
            tableSelection = nil
        }
        scheduleQuery(force: true)
    }

    func entry(for id: UUID) -> WorkoutLibraryEntry? {
        entryByID[id]
    }

    var matchingEntries: [WorkoutLibraryEntry] {
        resultIDs.compactMap { entryByID[$0] }
    }

    var activeFilterCount: Int {
        currentFilter.activeFilterCount
    }

    var hasActiveSearchOrFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !currentFilter.isDefault
    }

    func clearSearch() {
        searchText = ""
    }

    func clearFilters() {
        updateQueryState {
            favoriteFilter = .all
            sourceFilter = .all
            dateFilter = .allTime
            dataFilters = .none
        }
    }

    func clearSearchAndFilters() {
        updateQueryState {
            searchText = ""
            favoriteFilter = .all
            sourceFilter = .all
            dateFilter = .allTime
            dataFilters = .none
        }
    }

    /// Show the complete favourites collection from the sidebar overflow action.
    /// Prior All Runs constraints must not hide favourites from this destination.
    func showAllFavorites() {
        updateQueryState {
            searchText = ""
            favoriteFilter = .favoritesOnly
            sourceFilter = .all
            dateFilter = .allTime
            dataFilters = .none
        }
    }

    func retryQuery() {
        scheduleQuery(force: true)
    }

    // MARK: - Private

    private var currentFilter: WorkoutLibraryFilter {
        let date: WorkoutLibraryDateFilter
        switch dateFilter {
        case .custom:
            date = .custom(start: customDateStart, end: customDateEnd)
        default:
            date = dateFilter
        }
        return WorkoutLibraryFilter(
            favorite: favoriteFilter,
            date: date,
            source: sourceFilter,
            data: dataFilters
        )
    }

    private func rebuildEntries(from workouts: [RunWorkout]) {
        var built: [WorkoutLibraryEntry] = []
        built.reserveCapacity(workouts.count)
        var docs: [UUID: WorkoutLibrarySearchDocument] = [:]
        var byID: [UUID: WorkoutLibraryEntry] = [:]
        for (index, workout) in workouts.enumerated() {
            let entry = WorkoutLibraryEntry.make(
                from: workout,
                manifestIndex: index,
                isFavorite: favoriteIDs.contains(workout.id)
            )
            built.append(entry)
            byID[entry.id] = entry
            docs[entry.id] = WorkoutLibrarySearchDocument.make(from: entry, calendar: calendar)
        }
        entries = built
        entryByID = byID
        documents = docs
        totalCount = built.count
    }

    private func scheduleQuery(force: Bool = false) {
        guard !isBatchingQueryChanges else { return }

        queryTask?.cancel()
        queryGeneration &+= 1
        let generation = queryGeneration

        let query = WorkoutLibraryQuery(
            searchText: searchText,
            filter: currentFilter,
            sort: sort,
            now: nowProvider(),
            calendar: calendar
        )
        let key = QueryCacheKey(
            entries: entries,
            favoriteIDs: favoriteIDs,
            query: query
        )
        if !force, key == lastPublishedKey, loadState == .ready || loadState == .emptyLibrary
            || loadState == .emptySearch(query: searchText) || loadState == .emptyFilters {
            return
        }

        let snapshotEntries = entries
        let snapshotDocs = documents
        let service = queryService

        if snapshotEntries.isEmpty {
            resultIDs = []
            filteredCount = 0
            totalCount = 0
            loadState = .emptyLibrary
            lastPublishedKey = key
            return
        }

        // Keep previous results visible while recomputing unless we have nothing yet.
        switch loadState {
        case .ready, .emptySearch, .emptyFilters:
            break
        case .idle, .loading, .emptyLibrary, .failed:
            loadState = .loading
        }

        queryTask = Task { [weak self] in
            do {
                let result = try await service.execute(
                    entries: snapshotEntries,
                    documents: snapshotDocs,
                    query: query
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else { return }
                    self.publish(result: result, key: key)
                }
            } catch is CancellationError {
                // Superseded.
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else { return }
                    self.loadState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Publish one query after a related set of search/filter mutations.
    private func updateQueryState(_ update: () -> Void) {
        isBatchingQueryChanges = true
        update()
        isBatchingQueryChanges = false
        scheduleQuery(force: true)
    }

    private func publish(result: WorkoutLibraryQueryResult, key: QueryCacheKey) {
        resultIDs = result.matchingIDs
        totalCount = result.totalCount
        filteredCount = result.filteredCount
        lastPublishedKey = key

        if result.totalCount == 0 {
            loadState = .emptyLibrary
        } else if result.filteredCount == 0 {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                loadState = .emptySearch(query: trimmed)
            } else {
                loadState = .emptyFilters
            }
        } else {
            loadState = .ready
        }

        // Drop stale table selection when the row left the result set.
        if let selection = tableSelection, !result.matchingIDs.contains(selection) {
            tableSelection = nil
        }
    }

    /// Cache key covering IDs, metadata revision, favourites, and full query.
    struct QueryCacheKey: Hashable {
        struct EntryRevision: Hashable {
            let id: UUID
            let nameNotesRevision: String
            let isFavorite: Bool
            let manifestIndex: Int
        }

        let revisions: [EntryRevision]
        let searchText: String
        let filter: WorkoutLibraryFilter
        let sort: WorkoutLibrarySort
        let nowHour: Int

        init(entries: [WorkoutLibraryEntry], favoriteIDs: Set<UUID>, query: WorkoutLibraryQuery) {
            self.revisions = entries.map {
                EntryRevision(
                    id: $0.id,
                    nameNotesRevision: $0.nameNotesRevision,
                    isFavorite: $0.isFavorite,
                    manifestIndex: $0.manifestIndex
                )
            }
            self.searchText = query.searchText
            self.filter = query.filter
            self.sort = query.sort
            // Floor relative filters to the hour for stable cache keys.
            self.nowHour = Int(query.now.timeIntervalSince1970 / 3600)
            _ = favoriteIDs
        }
    }
}
