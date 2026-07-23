import Foundation

/// Errors from library query execution.
public enum WorkoutLibraryQueryError: Error, LocalizedError, Equatable, Sendable {
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Library query was cancelled."
        }
    }
}

/// Protocol for injectable filtering/sorting of lightweight library entries.
public protocol WorkoutLibraryQuerying: Sendable {
    func execute(
        entries: [WorkoutLibraryEntry],
        documents: [UUID: WorkoutLibrarySearchDocument],
        query: WorkoutLibraryQuery
    ) async throws -> WorkoutLibraryQueryResult
}

/// Deterministic, cancellable library query service.
///
/// Filtering is linear in entry count; sorting is `O(n log n)`. Route-point
/// arrays are never accessed — only precomputed entry fields and search documents.
public struct WorkoutLibraryQueryService: WorkoutLibraryQuerying, Sendable {
    /// Optional instrumentation hook for tests (counts entry visits).
    public let onEntryVisit: (@Sendable (WorkoutLibraryEntry) -> Void)?

    public init(onEntryVisit: (@Sendable (WorkoutLibraryEntry) -> Void)? = nil) {
        self.onEntryVisit = onEntryVisit
    }

    public func execute(
        entries: [WorkoutLibraryEntry],
        documents: [UUID: WorkoutLibrarySearchDocument],
        query: WorkoutLibraryQuery
    ) async throws -> WorkoutLibraryQueryResult {
        try Task.checkCancellation()

        let searchTerms = WorkoutLibrarySearchTerms.parse(query.searchText)
        let dateBounds = Self.resolveDateBounds(
            filter: query.filter.date,
            now: query.now,
            calendar: query.calendar
        )

        var filtered: [WorkoutLibraryEntry] = []
        filtered.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            if index % 256 == 0 {
                try Task.checkCancellation()
            }
            onEntryVisit?(entry)

            guard Self.matchesFilters(
                entry: entry,
                filter: query.filter,
                dateBounds: dateBounds,
                calendar: query.calendar
            ) else {
                continue
            }

            if !searchTerms.isEmpty {
                let document = documents[entry.id]
                    ?? WorkoutLibrarySearchDocument.make(from: entry, calendar: query.calendar)
                guard searchTerms.matches(document) else { continue }
            }

            filtered.append(entry)
        }

        try Task.checkCancellation()

        let sorted = Self.sort(filtered, by: query.sort)
        try Task.checkCancellation()

        return WorkoutLibraryQueryResult(
            matchingIDs: sorted.map(\.id),
            totalCount: entries.count,
            filteredCount: sorted.count,
            query: query
        )
    }

    // MARK: - Date bounds

    public struct DateBounds: Hashable, Sendable {
        public let start: Date?
        public let end: Date?
        /// When true, `end` is exclusive (`date < end`); otherwise inclusive (`date <= end`).
        public let endExclusive: Bool
        /// When true, entries without a date are included (All Time / empty custom).
        public let includeMissingDates: Bool

        public init(
            start: Date?,
            end: Date?,
            endExclusive: Bool = false,
            includeMissingDates: Bool
        ) {
            self.start = start
            self.end = end
            self.endExclusive = endExclusive
            self.includeMissingDates = includeMissingDates
        }
    }

    public static func resolveDateBounds(
        filter: WorkoutLibraryDateFilter,
        now: Date,
        calendar: Calendar
    ) -> DateBounds {
        switch filter {
        case .allTime:
            return DateBounds(start: nil, end: nil, includeMissingDates: true)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return DateBounds(start: start, end: now, endExclusive: false, includeMissingDates: false)
        case .last90Days:
            let start = calendar.date(byAdding: .day, value: -90, to: now) ?? now
            return DateBounds(start: start, end: now, endExclusive: false, includeMissingDates: false)
        case .currentCalendarYear:
            let comps = calendar.dateComponents([.year], from: now)
            let start = calendar.date(from: DateComponents(year: comps.year, month: 1, day: 1))
            let end = calendar.date(from: DateComponents(year: (comps.year ?? 0) + 1, month: 1, day: 1))
            return DateBounds(start: start, end: end, endExclusive: true, includeMissingDates: false)
        case .custom(let start, let end):
            if start == nil, end == nil {
                return DateBounds(start: nil, end: nil, includeMissingDates: true)
            }
            // Date pickers typically yield start-of-day values. Normalize so the
            // selected end calendar day is fully inclusive.
            let normalizedStart = start.map { calendar.startOfDay(for: $0) }
            let normalizedEndExclusive: Date? = end.flatMap { endDate in
                let startOfEndDay = calendar.startOfDay(for: endDate)
                return calendar.date(byAdding: .day, value: 1, to: startOfEndDay)
            }
            return DateBounds(
                start: normalizedStart,
                end: normalizedEndExclusive,
                endExclusive: true,
                includeMissingDates: false
            )
        }
    }

    // MARK: - Filters

    public static func matchesFilters(
        entry: WorkoutLibraryEntry,
        filter: WorkoutLibraryFilter,
        dateBounds: DateBounds,
        calendar: Calendar
    ) -> Bool {
        _ = calendar
        if filter.favorite == .favoritesOnly, !entry.isFavorite {
            return false
        }

        if let source = filter.source.matchingSource, entry.source != source {
            return false
        }

        if filter.data.requiresHeartRate, !entry.hasHeartRate {
            return false
        }
        if filter.data.requiresCorrectedElevation, !entry.hasCorrectedElevation {
            return false
        }
        if filter.data.requiresRecordedLaps, !entry.hasRecordedLaps {
            return false
        }

        // Date filter
        if dateBounds.start == nil, dateBounds.end == nil, dateBounds.includeMissingDates {
            return true
        }
        guard let date = entry.startDate else {
            return dateBounds.includeMissingDates
        }
        if let start = dateBounds.start, date < start {
            return false
        }
        if let end = dateBounds.end {
            if dateBounds.endExclusive {
                if date >= end { return false }
            } else if date > end {
                return false
            }
        }
        return true
    }

    // MARK: - Sort

    public static func sort(
        _ entries: [WorkoutLibraryEntry],
        by sort: WorkoutLibrarySort
    ) -> [WorkoutLibraryEntry] {
        entries.sorted { lhs, rhs in
            compare(lhs, rhs, by: sort)
        }
    }

    /// Strict weak ordering comparator with deterministic UUID tie-breakers.
    public static func compare(
        _ lhs: WorkoutLibraryEntry,
        _ rhs: WorkoutLibraryEntry,
        by sort: WorkoutLibrarySort
    ) -> Bool {
        switch sort {
        case .libraryOrder:
            if lhs.manifestIndex != rhs.manifestIndex {
                return lhs.manifestIndex < rhs.manifestIndex
            }
            return lhs.id.uuidString < rhs.id.uuidString

        case .dateNewest:
            return compareOptionalDate(lhs.startDate, rhs.startDate, ascending: false, lhs: lhs, rhs: rhs)
        case .dateOldest:
            return compareOptionalDate(lhs.startDate, rhs.startDate, ascending: true, lhs: lhs, rhs: rhs)

        case .nameAZ:
            return compareName(lhs, rhs, ascending: true)
        case .nameZA:
            return compareName(lhs, rhs, ascending: false)

        case .distanceLongest:
            return compareFinite(
                lhs.totalDistanceMeters,
                rhs.totalDistanceMeters,
                ascending: false,
                lhs: lhs,
                rhs: rhs
            )
        case .distanceShortest:
            return compareFinite(
                lhs.totalDistanceMeters,
                rhs.totalDistanceMeters,
                ascending: true,
                lhs: lhs,
                rhs: rhs
            )

        case .paceFastest:
            return comparePace(lhs, rhs, ascending: true)
        case .paceSlowest:
            return comparePace(lhs, rhs, ascending: false)

        case .elapsedLongest:
            return compareFinite(
                lhs.totalElapsedSeconds,
                rhs.totalElapsedSeconds,
                ascending: false,
                lhs: lhs,
                rhs: rhs
            )
        case .elapsedShortest:
            return compareFinite(
                lhs.totalElapsedSeconds,
                rhs.totalElapsedSeconds,
                ascending: true,
                lhs: lhs,
                rhs: rhs
            )
        }
    }

    private static func compareOptionalDate(
        _ a: Date?,
        _ b: Date?,
        ascending: Bool,
        lhs: WorkoutLibraryEntry,
        rhs: WorkoutLibraryEntry
    ) -> Bool {
        switch (a, b) {
        case let (l?, r?):
            if l != r {
                return ascending ? l < r : l > r
            }
            return tieBreak(lhs, rhs)
        case (_?, nil):
            // Missing dates sort after valid dates.
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return tieBreak(lhs, rhs)
        }
    }

    private static func compareName(
        _ lhs: WorkoutLibraryEntry,
        _ rhs: WorkoutLibraryEntry,
        ascending: Bool
    ) -> Bool {
        let left = lhs.displayName
        let right = rhs.displayName
        let order = left.localizedStandardCompare(right)
        if order != .orderedSame {
            if ascending {
                return order == .orderedAscending
            }
            return order == .orderedDescending
        }
        return tieBreak(lhs, rhs)
    }

    private static func comparePace(
        _ lhs: WorkoutLibraryEntry,
        _ rhs: WorkoutLibraryEntry,
        ascending: Bool
    ) -> Bool {
        let leftValid = isValidPace(lhs.activePaceSecondsPerKilometer)
        let rightValid = isValidPace(rhs.activePaceSecondsPerKilometer)
        switch (leftValid, rightValid) {
        case (true, true):
            if lhs.activePaceSecondsPerKilometer != rhs.activePaceSecondsPerKilometer {
                return ascending
                    ? lhs.activePaceSecondsPerKilometer < rhs.activePaceSecondsPerKilometer
                    : lhs.activePaceSecondsPerKilometer > rhs.activePaceSecondsPerKilometer
            }
            return tieBreak(lhs, rhs)
        case (true, false):
            return true
        case (false, true):
            return false
        case (false, false):
            return tieBreak(lhs, rhs)
        }
    }

    private static func isValidPace(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    private static func compareFinite(
        _ a: Double,
        _ b: Double,
        ascending: Bool,
        lhs: WorkoutLibraryEntry,
        rhs: WorkoutLibraryEntry
    ) -> Bool {
        let leftValid = a.isFinite
        let rightValid = b.isFinite
        switch (leftValid, rightValid) {
        case (true, true):
            if a != b {
                return ascending ? a < b : a > b
            }
            return tieBreak(lhs, rhs)
        case (true, false):
            return true
        case (false, true):
            return false
        case (false, false):
            return tieBreak(lhs, rhs)
        }
    }

    private static func tieBreak(_ lhs: WorkoutLibraryEntry, _ rhs: WorkoutLibraryEntry) -> Bool {
        if lhs.manifestIndex != rhs.manifestIndex {
            return lhs.manifestIndex < rhs.manifestIndex
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - Sidebar bounds

/// Centralized limits for compact sidebar sections.
public enum WorkoutLibrarySidebarPolicy: Sendable {
    public static let favoriteCap = 8
    public static let recentCap = 10

    /// Favourites (manifest order), recent non-favourites (date desc), optional selected overflow.
    public static func sidebarSections(
        workouts: [RunWorkout],
        favoriteIDs: Set<UUID>,
        selectedWorkoutID: UUID?
    ) -> (
        favorites: [RunWorkout],
        recent: [RunWorkout],
        selectedOverflow: RunWorkout?
    ) {
        let favoriteOrder = workouts.filter { favoriteIDs.contains($0.id) }
        let favorites = Array(favoriteOrder.prefix(favoriteCap))
        let favoriteShown = Set(favorites.map(\.id))

        let recentCandidates = workouts
            .filter { !favoriteIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let ld = WorkoutLibraryEntry.canonicalStartDate(for: lhs)
                let rd = WorkoutLibraryEntry.canonicalStartDate(for: rhs)
                switch (ld, rd) {
                case let (l?, r?):
                    if l != r { return l > r }
                    return lhs.id.uuidString < rhs.id.uuidString
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
        let recent = Array(recentCandidates.prefix(recentCap))
        let recentShown = Set(recent.map(\.id))

        var selectedOverflow: RunWorkout?
        if let selectedWorkoutID,
           let selected = workouts.first(where: { $0.id == selectedWorkoutID }),
           !favoriteShown.contains(selectedWorkoutID),
           !recentShown.contains(selectedWorkoutID) {
            selectedOverflow = selected
        }

        return (favorites, recent, selectedOverflow)
    }

    public static func hasMoreFavorites(favoriteCount: Int) -> Bool {
        favoriteCount > favoriteCap
    }
}
