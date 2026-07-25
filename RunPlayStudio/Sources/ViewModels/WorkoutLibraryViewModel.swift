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

/// Whether All Runs is showing the manual query or a smart collection.
public enum WorkoutLibraryQueryContext: Equatable, Hashable, Sendable {
    case manual
    case smartCollection(id: UUID, isModified: Bool)
}

/// Session-only snapshot of the ordinary All Runs query.
private struct ManualQuerySnapshot: Equatable {
    var searchText: String
    var sort: WorkoutLibrarySort
    var favoriteFilter: WorkoutLibraryFavoriteFilter
    var sourceFilter: WorkoutLibrarySourceFilter
    var dateFilter: WorkoutLibraryDateFilter
    var customDateStart: Date
    var customDateEnd: Date
    var dataFilters: WorkoutLibraryDataFilters
    var tagFilter: WorkoutLibraryTagFilter
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
    @Published private(set) var tags: [WorkoutTag] = []
    @Published private(set) var smartCollections: [WorkoutSmartCollection] = []
    @Published private(set) var queryContext: WorkoutLibraryQueryContext = .manual

    @Published var searchText: String = "" {
        didSet { handleQueryMutation() }
    }
    @Published var sort: WorkoutLibrarySort = .dateNewest {
        didSet { handleQueryMutation() }
    }
    @Published var favoriteFilter: WorkoutLibraryFavoriteFilter = .all {
        didSet { handleQueryMutation() }
    }
    @Published var sourceFilter: WorkoutLibrarySourceFilter = .all {
        didSet { handleQueryMutation() }
    }
    @Published var dateFilter: WorkoutLibraryDateFilter = .allTime {
        didSet { handleQueryMutation() }
    }
    @Published var customDateStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() {
        didSet { handleQueryMutation() }
    }
    @Published var customDateEnd: Date = Date() {
        didSet { handleQueryMutation() }
    }
    @Published var dataFilters: WorkoutLibraryDataFilters = .none {
        didSet { handleQueryMutation() }
    }
    @Published var tagFilter: WorkoutLibraryTagFilter = .anyTags {
        didSet { handleQueryMutation() }
    }

    /// Multi-select table selection (Command/Shift-click).
    @Published var tableSelection: Set<UUID> = []
    @Published var editorError: String?

    private var documents: [UUID: WorkoutLibrarySearchDocument] = [:]
    private var entryByID: [UUID: WorkoutLibraryEntry] = [:]
    private var tagAssignmentsByWorkout: [UUID: Set<UUID>] = [:]
    private var queryTask: Task<Void, Never>?
    private var queryGeneration: UInt64 = 0
    private var lastPublishedKey: QueryCacheKey?
    private var isBatchingQueryChanges = false
    private var isApplyingSavedQuery = false
    private var manualQuerySnapshot: ManualQuerySnapshot?
    private let queryService: any WorkoutLibraryQuerying
    private let calendar: Calendar
    private let announcementPolicy: AccessibilityAnnouncementPolicy
    /// Injected clock for relative filters (tests).
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
        queryTask?.cancel()
    }

    // MARK: - Library revisions

    /// Replace the full library used by All Runs (import, load, batch commit).
    func replaceLibrary(
        workouts: [RunWorkout],
        favoriteIDs: Set<UUID>,
        organization: WorkoutLibraryOrganizationSnapshot = .empty
    ) {
        self.favoriteIDs = favoriteIDs
        applyOrganizationSnapshot(organization, schedule: false)
        rebuildEntries(from: workouts)
        // Re-apply active collection query if still present.
        if case .smartCollection(let id, _) = queryContext {
            if let collection = smartCollections.first(where: { $0.id == id }) {
                if case .smartCollection(_, true) = queryContext {
                    // Keep modified working query; only refresh results.
                    scheduleQuery(force: true)
                } else {
                    applySavedQuery(collection.query, markUnmodifiedCollectionID: id)
                }
                return
            } else {
                // Collection deleted externally — return to manual without clobbering snapshot.
                queryContext = .manual
            }
        }
        scheduleQuery(force: true)
    }

    /// Apply a single workout mutation (metadata) without full rebuild of unrelated documents.
    func applyWorkoutUpdate(_ workout: RunWorkout) {
        guard let index = entries.firstIndex(where: { $0.id == workout.id }) else {
            return
        }
        let tagIDs = tagAssignmentsByWorkout[workout.id] ?? []
        let entry = WorkoutLibraryEntry.make(
            from: workout,
            manifestIndex: entries[index].manifestIndex,
            isFavorite: favoriteIDs.contains(workout.id),
            tagIDs: tagIDs,
            tagsByID: tagsByID
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
            let updated = entries[index].withFavorite(isFavorite)
            entries[index] = updated
            entryByID[updated.id] = updated
        }
        scheduleQuery(force: true)
    }

    func applyTagDefinitions(_ tags: [WorkoutTag]) {
        let oldByID = tagsByID
        self.tags = tags
        let newByID = tagsByID

        // Rebuild documents only for workouts whose assigned tag names changed.
        var affected: Set<UUID> = []
        for (workoutID, tagIDs) in tagAssignmentsByWorkout {
            for tagID in tagIDs {
                let oldName = oldByID[tagID]?.name
                let newName = newByID[tagID]?.name
                if oldName != newName {
                    affected.insert(workoutID)
                    break
                }
            }
        }
        if !affected.isEmpty {
            rebuildTagsOnEntries(workoutIDs: affected)
        }
        // Color-only changes do not need a query rerun for text search.
        let namesChanged = affected.isEmpty == false
        if namesChanged {
            scheduleQuery(force: true)
        } else {
            objectWillChange.send()
        }
    }

    func applyWorkoutTagChange(workoutID: UUID, tagIDs: Set<UUID>) {
        if tagIDs.isEmpty {
            tagAssignmentsByWorkout.removeValue(forKey: workoutID)
        } else {
            tagAssignmentsByWorkout[workoutID] = tagIDs
        }
        rebuildTagsOnEntries(workoutIDs: [workoutID])
        scheduleQuery(force: true)
    }

    func applyBulkWorkoutTagChange(changes: [UUID: Set<UUID>]) {
        guard !changes.isEmpty else { return }
        for (workoutID, tagIDs) in changes {
            if tagIDs.isEmpty {
                tagAssignmentsByWorkout.removeValue(forKey: workoutID)
            } else {
                tagAssignmentsByWorkout[workoutID] = tagIDs
            }
        }
        rebuildTagsOnEntries(workoutIDs: Set(changes.keys))
        scheduleQuery(force: true)
    }

    func applySmartCollectionChange(_ collections: [WorkoutSmartCollection]) {
        smartCollections = collections
        if case .smartCollection(let id, let modified) = queryContext {
            if let collection = collections.first(where: { $0.id == id }) {
                if !modified {
                    // Name-only or external update while unmodified: re-sync query.
                    applySavedQuery(collection.query, markUnmodifiedCollectionID: id)
                } else {
                    objectWillChange.send()
                }
            } else {
                // Collection deleted — leave current working filters as manual.
                queryContext = .manual
                manualQuerySnapshot = nil
            }
        } else {
            objectWillChange.send()
        }
    }

    func applyOrganizationSnapshot(
        _ organization: WorkoutLibraryOrganizationSnapshot,
        schedule: Bool = true
    ) {
        tags = organization.tags
        smartCollections = organization.smartCollections
        tagAssignmentsByWorkout = organization.tagIDsByWorkout
        if schedule {
            // Entries may already exist (e.g. live organisation-only update).
            rebuildTagsOnEntries(workoutIDs: Set(entries.map(\.id)))
            scheduleQuery(force: true)
        }
    }

    func removeWorkout(id: UUID) {
        favoriteIDs.remove(id)
        tagAssignmentsByWorkout.removeValue(forKey: id)
        entries.removeAll { $0.id == id }
        entryByID.removeValue(forKey: id)
        documents.removeValue(forKey: id)
        for i in entries.indices {
            if entries[i].manifestIndex != i {
                let updated = entries[i].withManifestIndex(i)
                entries[i] = updated
                entryByID[updated.id] = updated
            }
        }
        tableSelection.remove(id)
        scheduleQuery(force: true)
    }

    func entry(for id: UUID) -> WorkoutLibraryEntry? {
        entryByID[id]
    }

    var tagsByID: [UUID: WorkoutTag] {
        Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
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

    var activeSmartCollection: WorkoutSmartCollection? {
        guard case .smartCollection(let id, _) = queryContext else { return nil }
        return smartCollections.first { $0.id == id }
    }

    var isCollectionModified: Bool {
        if case .smartCollection(_, true) = queryContext { return true }
        return false
    }

    /// Persisted library workouts in the current table selection (excludes demos).
    func persistedSelectedWorkoutIDs(libraryIDs: Set<UUID>) -> Set<UUID> {
        tableSelection.intersection(libraryIDs)
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
            tagFilter = .anyTags
        }
    }

    func clearSearchAndFilters() {
        updateQueryState {
            searchText = ""
            favoriteFilter = .all
            sourceFilter = .all
            dateFilter = .allTime
            dataFilters = .none
            tagFilter = .anyTags
        }
    }

    /// Show the complete favourites collection from the sidebar overflow action.
    func showAllFavorites() {
        // Favourites destination is a manual All Runs query.
        if case .smartCollection = queryContext {
            returnToManualQuery(clearSnapshot: true)
        }
        updateQueryState {
            searchText = ""
            favoriteFilter = .favoritesOnly
            sourceFilter = .all
            dateFilter = .allTime
            dataFilters = .none
            tagFilter = .anyTags
        }
    }

    func retryQuery() {
        scheduleQuery(force: true)
    }

    // MARK: - Smart collection navigation

    /// Open a smart collection from the sidebar or manager.
    func openSmartCollection(id: UUID) {
        guard let collection = smartCollections.first(where: { $0.id == id }) else { return }
        if case .manual = queryContext {
            manualQuerySnapshot = captureManualSnapshot()
        } else if case .smartCollection(let currentID, _) = queryContext, currentID != id {
            // Switching collections does not overwrite the stashed manual query.
        }
        applySavedQuery(collection.query, markUnmodifiedCollectionID: id)
    }

    /// Return to ordinary All Runs, restoring the stashed manual query when present.
    ///
    /// When `clearSnapshot` is true (normal All Runs exit from a collection), the
    /// snapshot is consumed so a later All Runs selection cannot overwrite live
    /// manual edits with a stale stash.
    func returnToManualQuery(clearSnapshot: Bool = false) {
        queryContext = .manual
        if let snapshot = manualQuerySnapshot {
            applySnapshot(snapshot)
        } else {
            scheduleQuery(force: true)
        }
        if clearSnapshot {
            manualQuerySnapshot = nil
        }
    }

    /// Restore the saved query of the active collection.
    func revertActiveCollection() {
        guard case .smartCollection(let id, true) = queryContext,
              let collection = smartCollections.first(where: { $0.id == id }) else {
            return
        }
        applySavedQuery(collection.query, markUnmodifiedCollectionID: id)
    }

    /// Capture the current working query as a saved query.
    func currentSavedQuery() -> WorkoutLibrarySavedQuery {
        WorkoutLibrarySavedQuery.capture(
            searchText: searchText,
            filter: currentFilter,
            sort: sort
        )
    }

    /// Capture the ordinary All Runs query even while a smart collection is
    /// active. Result IDs, counts, selection, and query caches are excluded.
    func sessionManualQuery() -> WorkoutLibrarySavedQuery {
        guard let manualQuerySnapshot else {
            return currentSavedQuery()
        }
        return WorkoutLibrarySavedQuery.capture(
            searchText: manualQuerySnapshot.searchText,
            filter: WorkoutLibraryFilter(
                favorite: manualQuerySnapshot.favoriteFilter,
                date: manualQuerySnapshot.dateFilter,
                source: manualQuerySnapshot.sourceFilter,
                data: manualQuerySnapshot.dataFilters,
                tags: manualQuerySnapshot.tagFilter
            ),
            sort: manualQuerySnapshot.sort
        )
    }

    /// Apply session-only All Runs and smart-collection state after the
    /// manifest has been loaded. Missing collections are intentionally treated
    /// as manual All Runs by the caller/validator.
    func restoreSessionState(
        manualQuery: WorkoutLibrarySavedQuery,
        activeSmartCollectionID: UUID?,
        activeSmartCollectionModified: Bool,
        modifiedWorkingQuery: WorkoutLibrarySavedQuery?
    ) {
        let manualSnapshot = makeManualSnapshot(from: manualQuery)
        guard let activeSmartCollectionID,
              smartCollections.contains(where: { $0.id == activeSmartCollectionID }) else {
            manualQuerySnapshot = nil
            queryContext = .manual
            applySnapshot(manualSnapshot)
            return
        }

        manualQuerySnapshot = manualSnapshot
        if activeSmartCollectionModified, let modifiedWorkingQuery {
            applySavedQuery(
                modifiedWorkingQuery,
                markUnmodifiedCollectionID: activeSmartCollectionID,
                isModified: true
            )
        } else if let collection = smartCollections.first(where: { $0.id == activeSmartCollectionID }) {
            applySavedQuery(collection.query, markUnmodifiedCollectionID: collection.id)
        } else {
            // Defensive fallback for a collection removed between validation
            // and application.
            manualQuerySnapshot = nil
            queryContext = .manual
            applySnapshot(manualSnapshot)
        }
    }

    /// After a successful Update Collection persistence, mark unmodified and sync.
    func markActiveCollectionUpdated(_ collection: WorkoutSmartCollection) {
        if let index = smartCollections.firstIndex(where: { $0.id == collection.id }) {
            smartCollections[index] = collection
        } else {
            smartCollections.append(collection)
        }
        queryContext = .smartCollection(id: collection.id, isModified: false)
    }

    /// After creating a collection from the current query, open it unmodified.
    func didCreateSmartCollection(_ collection: WorkoutSmartCollection) {
        if let index = smartCollections.firstIndex(where: { $0.id == collection.id }) {
            smartCollections[index] = collection
        } else {
            smartCollections.append(collection)
        }
        // Stash the pre-collection manual working query once, then pin this
        // collection as the active (unmodified) context. Filters already match
        // the saved query because creation captured `currentSavedQuery()`.
        if case .manual = queryContext {
            manualQuerySnapshot = captureManualSnapshot()
        }
        queryContext = .smartCollection(id: collection.id, isModified: false)
    }

    func didDeleteSmartCollection(id: UUID) {
        smartCollections.removeAll { $0.id == id }
        if case .smartCollection(let activeID, _) = queryContext, activeID == id {
            // Keep working filters as the new manual query.
            queryContext = .manual
            manualQuerySnapshot = nil
        }
    }

    // MARK: - Private

    var currentFilter: WorkoutLibraryFilter {
        // Keep the optional bounds captured by a saved query. The date picker
        // state is only a UI editing aid; rebuilding every custom filter from
        // it would turn a one-sided persisted range into a two-sided range.
        let date = dateFilter
        return WorkoutLibraryFilter(
            favorite: favoriteFilter,
            date: date,
            source: sourceFilter,
            data: dataFilters,
            tags: tagFilter
        )
    }

    private func captureManualSnapshot() -> ManualQuerySnapshot {
        ManualQuerySnapshot(
            searchText: searchText,
            sort: sort,
            favoriteFilter: favoriteFilter,
            sourceFilter: sourceFilter,
            dateFilter: dateFilter,
            customDateStart: customDateStart,
            customDateEnd: customDateEnd,
            dataFilters: dataFilters,
            tagFilter: tagFilter
        )
    }

    private func applySnapshot(_ snapshot: ManualQuerySnapshot) {
        updateQueryState {
            searchText = snapshot.searchText
            sort = snapshot.sort
            favoriteFilter = snapshot.favoriteFilter
            sourceFilter = snapshot.sourceFilter
            dateFilter = snapshot.dateFilter
            customDateStart = snapshot.customDateStart
            customDateEnd = snapshot.customDateEnd
            dataFilters = snapshot.dataFilters
            tagFilter = snapshot.tagFilter
        }
    }

    private func makeManualSnapshot(from query: WorkoutLibrarySavedQuery) -> ManualQuerySnapshot {
        let customBounds: (Date, Date) = {
            if case .custom(let start, let end) = query.filter.date {
                return (
                    start ?? customDateStart,
                    end ?? customDateEnd
                )
            }
            return (customDateStart, customDateEnd)
        }()
        return ManualQuerySnapshot(
            searchText: query.searchText,
            sort: query.sort,
            favoriteFilter: query.filter.favorite,
            sourceFilter: query.filter.source,
            dateFilter: query.filter.date,
            customDateStart: customBounds.0,
            customDateEnd: customBounds.1,
            dataFilters: query.filter.data,
            tagFilter: query.filter.tags
        )
    }

    private func applySavedQuery(
        _ query: WorkoutLibrarySavedQuery,
        markUnmodifiedCollectionID id: UUID,
        isModified: Bool = false
    ) {
        isApplyingSavedQuery = true
        isBatchingQueryChanges = true
        searchText = query.searchText
        sort = query.sort
        favoriteFilter = query.filter.favorite
        sourceFilter = query.filter.source
        dataFilters = query.filter.data
        tagFilter = query.filter.tags
        switch query.filter.date {
        case .custom(let start, let end):
            dateFilter = .custom(start: start, end: end)
            if let start { customDateStart = start }
            if let end { customDateEnd = end }
        default:
            dateFilter = query.filter.date
        }
        queryContext = .smartCollection(id: id, isModified: isModified)
        isBatchingQueryChanges = false
        isApplyingSavedQuery = false
        scheduleQuery(force: true)
    }

    private func handleQueryMutation() {
        guard !isBatchingQueryChanges else { return }
        if !isApplyingSavedQuery, case .smartCollection(let id, false) = queryContext {
            queryContext = .smartCollection(id: id, isModified: true)
        }
        scheduleQuery()
    }

    private func rebuildEntries(from workouts: [RunWorkout]) {
        var built: [WorkoutLibraryEntry] = []
        built.reserveCapacity(workouts.count)
        var docs: [UUID: WorkoutLibrarySearchDocument] = [:]
        var byID: [UUID: WorkoutLibraryEntry] = [:]
        let tagMap = tagsByID
        for (index, workout) in workouts.enumerated() {
            let tagIDs = tagAssignmentsByWorkout[workout.id] ?? []
            let entry = WorkoutLibraryEntry.make(
                from: workout,
                manifestIndex: index,
                isFavorite: favoriteIDs.contains(workout.id),
                tagIDs: tagIDs,
                tagsByID: tagMap
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

    private func rebuildTagsOnEntries(workoutIDs: Set<UUID>) {
        let tagMap = tagsByID
        for id in workoutIDs {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
            let tagIDs = tagAssignmentsByWorkout[id] ?? []
            let names = WorkoutLibraryEntry.orderedTagNames(tagIDs: tagIDs, tagsByID: tagMap)
            let updated = entries[index].withTags(tagIDs: tagIDs, tagNames: names)
            entries[index] = updated
            entryByID[id] = updated
            documents[id] = WorkoutLibrarySearchDocument.make(from: updated, calendar: calendar)
        }
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
            query: query,
            context: queryContext
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
            tableSelection = []
            announcementPolicy.handle(.queryResultPublished(count: 0))
            return
        }

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
        if !isApplyingSavedQuery, case .smartCollection(let id, false) = queryContext {
            queryContext = .smartCollection(id: id, isModified: true)
        }
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

        // Drop stale table selection when rows leave the result set.
        let matching = Set(result.matchingIDs)
        tableSelection = tableSelection.intersection(matching)
        announcementPolicy.handle(
            .queryResultPublished(count: result.filteredCount)
        )
    }

    /// Cache key covering IDs, metadata/tag revisions, favourites, and full query.
    struct QueryCacheKey: Hashable {
        struct EntryRevision: Hashable {
            let id: UUID
            let nameNotesRevision: String
            let tagRevision: String
            let isFavorite: Bool
            let manifestIndex: Int
        }

        let revisions: [EntryRevision]
        let searchText: String
        let filter: WorkoutLibraryFilter
        let sort: WorkoutLibrarySort
        let nowHour: Int
        let context: WorkoutLibraryQueryContext

        init(
            entries: [WorkoutLibraryEntry],
            query: WorkoutLibraryQuery,
            context: WorkoutLibraryQueryContext
        ) {
            self.revisions = entries.map {
                EntryRevision(
                    id: $0.id,
                    nameNotesRevision: $0.nameNotesRevision,
                    tagRevision: $0.tagRevision,
                    isFavorite: $0.isFavorite,
                    manifestIndex: $0.manifestIndex
                )
            }
            self.searchText = query.searchText
            self.filter = query.filter
            self.sort = query.sort
            self.nowHour = Int(query.now.timeIntervalSince1970 / 3600)
            self.context = context
        }
    }
}
