import Foundation

// MARK: - Sort

/// Deterministic library sort modes for All Runs.
public enum WorkoutLibrarySort: String, CaseIterable, Codable, Hashable, Sendable {
    case dateNewest
    case dateOldest
    case nameAZ
    case nameZA
    case distanceLongest
    case distanceShortest
    case paceFastest
    case paceSlowest
    case elapsedLongest
    case elapsedShortest
    case libraryOrder

    public var displayName: String {
        switch self {
        case .dateNewest: return "Date — Newest First"
        case .dateOldest: return "Date — Oldest First"
        case .nameAZ: return "Name — A to Z"
        case .nameZA: return "Name — Z to A"
        case .distanceLongest: return "Distance — Longest First"
        case .distanceShortest: return "Distance — Shortest First"
        case .paceFastest: return "Active Pace — Fastest First"
        case .paceSlowest: return "Active Pace — Slowest First"
        case .elapsedLongest: return "Elapsed Time — Longest First"
        case .elapsedShortest: return "Elapsed Time — Shortest First"
        case .libraryOrder: return "Library Order"
        }
    }
}

// MARK: - Date filter

public enum WorkoutLibraryDateFilter: Hashable, Sendable, Codable {
    case allTime
    case last30Days
    case last90Days
    case currentCalendarYear
    case custom(start: Date?, end: Date?)

    public var displayName: String {
        switch self {
        case .allTime: return "All Time"
        case .last30Days: return "Last 30 Days"
        case .last90Days: return "Last 90 Days"
        case .currentCalendarYear: return "Current Calendar Year"
        case .custom: return "Custom Date Range"
        }
    }
}

// MARK: - Favourite filter

public enum WorkoutLibraryFavoriteFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case favoritesOnly

    public var displayName: String {
        switch self {
        case .all: return "All Workouts"
        case .favoritesOnly: return "Favourites Only"
        }
    }
}

// MARK: - Source filter

/// Route-file format filter. Strava is searchable as a provider, not a source chip.
public enum WorkoutLibrarySourceFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case gpx
    case tcx
    case fit
    case json

    public var displayName: String {
        switch self {
        case .all: return "All Sources"
        case .gpx: return "GPX"
        case .tcx: return "TCX"
        case .fit: return "FIT"
        case .json: return "JSON"
        }
    }

    public var matchingSource: WorkoutSource? {
        switch self {
        case .all: return nil
        case .gpx: return .gpx
        case .tcx: return .tcx
        case .fit: return .fit
        case .json: return .json
        }
    }
}

// MARK: - Data filters

public struct WorkoutLibraryDataFilters: Hashable, Sendable, Codable {
    public var requiresHeartRate: Bool
    public var requiresCorrectedElevation: Bool
    public var requiresRecordedLaps: Bool

    public init(
        requiresHeartRate: Bool = false,
        requiresCorrectedElevation: Bool = false,
        requiresRecordedLaps: Bool = false
    ) {
        self.requiresHeartRate = requiresHeartRate
        self.requiresCorrectedElevation = requiresCorrectedElevation
        self.requiresRecordedLaps = requiresRecordedLaps
    }

    public static let none = WorkoutLibraryDataFilters()

    public var isActive: Bool {
        requiresHeartRate || requiresCorrectedElevation || requiresRecordedLaps
    }

    public var activeCount: Int {
        [requiresHeartRate, requiresCorrectedElevation, requiresRecordedLaps]
            .filter { $0 }
            .count
    }
}

// MARK: - Tag filters

/// Whether selected tags require any-of or all-of matching.
public enum WorkoutLibraryTagMatchMode: String, Codable, Hashable, Sendable {
    case any
    case all
}

/// Tag restriction combined with other library filters via AND.
public enum WorkoutLibraryTagFilter: Hashable, Sendable {
    /// No tag restriction.
    case anyTags
    /// Workouts with zero assigned tags.
    case untaggedOnly
    /// Workouts matching the selected tag IDs.
    ///
    /// An empty `tagIDs` set behaves as ``anyTags`` (no restriction).
    case selected(tagIDs: Set<UUID>, match: WorkoutLibraryTagMatchMode)

    public static let `default` = WorkoutLibraryTagFilter.anyTags

    public var isActive: Bool {
        switch self {
        case .anyTags:
            return false
        case .untaggedOnly:
            return true
        case .selected(let tagIDs, _):
            return !tagIDs.isEmpty
        }
    }

    public var activeFilterCount: Int {
        isActive ? 1 : 0
    }
}

extension WorkoutLibraryTagFilter: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case tagIDs
        case match
    }

    private enum FilterType: String, Codable {
        case anyTags
        case untaggedOnly
        case selected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? FilterType.anyTags.rawValue
        switch FilterType(rawValue: rawType) {
        case .untaggedOnly:
            self = .untaggedOnly
        case .selected:
            let ids = try container.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
            let matchRaw = try container.decodeIfPresent(String.self, forKey: .match)
                ?? WorkoutLibraryTagMatchMode.any.rawValue
            let match = WorkoutLibraryTagMatchMode(rawValue: matchRaw) ?? .any
            if ids.isEmpty {
                self = .anyTags
            } else {
                self = .selected(tagIDs: Set(ids), match: match)
            }
        case .anyTags, .none:
            self = .anyTags
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anyTags:
            try container.encode(FilterType.anyTags.rawValue, forKey: .type)
        case .untaggedOnly:
            try container.encode(FilterType.untaggedOnly.rawValue, forKey: .type)
        case .selected(let tagIDs, let match):
            if tagIDs.isEmpty {
                try container.encode(FilterType.anyTags.rawValue, forKey: .type)
            } else {
                try container.encode(FilterType.selected.rawValue, forKey: .type)
                let ordered = tagIDs.sorted {
                    $0.uuidString.localizedStandardCompare($1.uuidString) == .orderedAscending
                }
                try container.encode(ordered, forKey: .tagIDs)
                try container.encode(match.rawValue, forKey: .match)
            }
        }
    }
}

// MARK: - Filter aggregate

public struct WorkoutLibraryFilter: Hashable, Sendable, Codable {
    public var favorite: WorkoutLibraryFavoriteFilter
    public var date: WorkoutLibraryDateFilter
    public var source: WorkoutLibrarySourceFilter
    public var data: WorkoutLibraryDataFilters
    public var tags: WorkoutLibraryTagFilter

    public init(
        favorite: WorkoutLibraryFavoriteFilter = .all,
        date: WorkoutLibraryDateFilter = .allTime,
        source: WorkoutLibrarySourceFilter = .all,
        data: WorkoutLibraryDataFilters = .none,
        tags: WorkoutLibraryTagFilter = .anyTags
    ) {
        self.favorite = favorite
        self.date = date
        self.source = source
        self.data = data
        self.tags = tags
    }

    public static let `default` = WorkoutLibraryFilter()

    public var isDefault: Bool {
        favorite == .all
            && date == .allTime
            && source == .all
            && !data.isActive
            && !tags.isActive
    }

    public var activeFilterCount: Int {
        var count = 0
        if favorite != .all { count += 1 }
        if date != .allTime { count += 1 }
        if source != .all { count += 1 }
        count += data.activeCount
        count += tags.activeFilterCount
        return count
    }
}

// MARK: - Query

public struct WorkoutLibraryQuery: Hashable, Sendable {
    public var searchText: String
    public var filter: WorkoutLibraryFilter
    public var sort: WorkoutLibrarySort
    /// Injected clock for relative date filters. Do not call `Date()` in entry loops.
    public var now: Date
    public var calendar: Calendar

    public init(
        searchText: String = "",
        filter: WorkoutLibraryFilter = .default,
        sort: WorkoutLibrarySort = .dateNewest,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.searchText = searchText
        self.filter = filter
        self.sort = sort
        self.now = now
        self.calendar = calendar
    }
}

// MARK: - Result

public struct WorkoutLibraryQueryResult: Sendable, Equatable {
    public let matchingIDs: [UUID]
    public let totalCount: Int
    public let filteredCount: Int
    public let query: WorkoutLibraryQuery

    public init(
        matchingIDs: [UUID],
        totalCount: Int,
        filteredCount: Int,
        query: WorkoutLibraryQuery
    ) {
        self.matchingIDs = matchingIDs
        self.totalCount = totalCount
        self.filteredCount = filteredCount
        self.query = query
    }
}
