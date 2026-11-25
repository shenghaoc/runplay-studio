import Foundation

// MARK: - Saved query

/// Persistent All Runs query without transient execution state.
///
/// Relative date filters are resolved when the collection is opened by
/// injecting `now` and `Calendar` into a runtime `WorkoutLibraryQuery`.
public struct WorkoutLibrarySavedQuery: Codable, Hashable, Sendable {
    public var searchText: String
    public var filter: WorkoutLibraryFilter
    public var sort: WorkoutLibrarySort

    /// Generous bound for persisted free-text search length.
    public static let maxSearchTextScalars = 500

    public init(
        searchText: String = "",
        filter: WorkoutLibraryFilter = .default,
        sort: WorkoutLibrarySort = .dateNewest
    ) {
        self.searchText = searchText
        self.filter = filter
        self.sort = sort
    }

    /// Build a runtime query with injected clock and calendar.
    public func makeRuntimeQuery(now: Date, calendar: Calendar) -> WorkoutLibraryQuery {
        WorkoutLibraryQuery(
            searchText: searchText,
            filter: filter,
            sort: sort,
            now: now,
            calendar: calendar
        )
    }

    /// Capture the current All Runs state (no clock/calendar).
    public static func capture(
        searchText: String,
        filter: WorkoutLibraryFilter,
        sort: WorkoutLibrarySort
    ) -> WorkoutLibrarySavedQuery {
        WorkoutLibrarySavedQuery(
            searchText: searchText,
            filter: filter,
            sort: sort
        )
    }

    private enum CodingKeys: String, CodingKey {
        case searchText
        case filter
        case sort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchText = try container.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        filter = try container.decodeIfPresent(WorkoutLibraryFilter.self, forKey: .filter) ?? .default
        // Unknown future sort strings fall back to dateNewest.
        if let raw = try container.decodeIfPresent(String.self, forKey: .sort),
           let decoded = WorkoutLibrarySort(rawValue: raw) {
            sort = decoded
        } else {
            sort = .dateNewest
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(searchText, forKey: .searchText)
        try container.encode(filter, forKey: .filter)
        try container.encode(sort.rawValue, forKey: .sort)
    }
}

// MARK: - Smart collection

/// Saved dynamic All Runs query. Membership is never persisted as workout IDs.
public struct WorkoutSmartCollection: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var query: WorkoutLibrarySavedQuery

    public init(
        id: UUID = UUID(),
        name: String,
        query: WorkoutLibrarySavedQuery
    ) {
        self.id = id
        self.name = name
        self.query = query
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case query
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        query = try container.decodeIfPresent(WorkoutLibrarySavedQuery.self, forKey: .query)
            ?? WorkoutLibrarySavedQuery()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(query, forKey: .query)
    }
}

// MARK: - Policy

/// Central limits and validation for smart collections.
public struct WorkoutSmartCollectionPolicy: Hashable, Sendable {
    public static let `default` = WorkoutSmartCollectionPolicy()

    public let maxCollections: Int
    public let maxNameScalars: Int

    public init(maxCollections: Int = 100, maxNameScalars: Int = 80) {
        self.maxCollections = maxCollections
        self.maxNameScalars = maxNameScalars
    }

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case emptyName
        case containsNUL
        case containsLineBreak
        case nameTooLong(limit: Int)
        case duplicateName(String)
        case collectionLimitReached(limit: Int)
        case searchTextTooLong(limit: Int)
        case unknownCollection(UUID)
        case duplicateCollectionID(UUID)

        public var errorDescription: String? {
            switch self {
            case .emptyName:
                return coreLocalized("Collection name cannot be empty.")
            case .containsNUL:
                return coreLocalized("Collection name contains an invalid character.")
            case .containsLineBreak:
                return coreLocalized("Collection name must be a single line.")
            case .nameTooLong(let limit):
                return coreLocalized("Collection name must be at most \(limit) characters.")
            case .duplicateName(let name):
                return coreLocalized("A collection named “\(name)” already exists.")
            case .collectionLimitReached(let limit):
                return coreLocalized("A library can have at most \(limit) smart collections.")
            case .searchTextTooLong(let limit):
                return coreLocalized("Search text must be at most \(limit) characters.")
            case .unknownCollection(let id):
                return coreLocalized("Unknown smart collection \(id.uuidString).")
            case .duplicateCollectionID(let id):
                return coreLocalized("Duplicate smart collection ID \(id.uuidString).")
            }
        }
    }

    public struct NormalizedName: Hashable, Sendable {
        public let display: String
        public let folded: String

        public init(display: String, folded: String) {
            self.display = display
            self.folded = folded
        }
    }

    public func normalizeName(_ raw: String) throws -> NormalizedName {
        if raw.unicodeScalars.contains(UnicodeScalar(0)) {
            throw ValidationError.containsNUL
        }
        if raw.contains(where: { $0.isNewline }) {
            throw ValidationError.containsLineBreak
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError.emptyName
        }
        if trimmed.unicodeScalars.count > maxNameScalars {
            throw ValidationError.nameTooLong(limit: maxNameScalars)
        }
        return NormalizedName(
            display: trimmed,
            folded: WorkoutOrganizationNameFolding.fold(trimmed)
        )
    }

    public func validateUniqueName(
        _ normalized: NormalizedName,
        existing: [WorkoutSmartCollection],
        excludingID: UUID? = nil
    ) throws {
        for collection in existing {
            if collection.id == excludingID { continue }
            if WorkoutOrganizationNameFolding.fold(collection.name) == normalized.folded {
                throw ValidationError.duplicateName(collection.name)
            }
        }
    }

    public func validateCanCreate(existingCount: Int) throws {
        if existingCount >= maxCollections {
            throw ValidationError.collectionLimitReached(limit: maxCollections)
        }
    }

    public func validateSavedQuery(_ query: WorkoutLibrarySavedQuery) throws {
        if query.searchText.unicodeScalars.count > WorkoutLibrarySavedQuery.maxSearchTextScalars {
            throw ValidationError.searchTextTooLong(limit: WorkoutLibrarySavedQuery.maxSearchTextScalars)
        }
    }
}

// MARK: - Query summary

/// Human-readable summary of a saved query for management UI.
public enum WorkoutSmartCollectionQuerySummary: Sendable {
    public static func make(
        query: WorkoutLibrarySavedQuery,
        tagsByID: [UUID: WorkoutTag]
    ) -> String {
        var parts: [String] = []

        let trimmedSearch = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            parts.append(coreLocalized("Search: “\(trimmedSearch)”"))
        }

        if query.filter.favorite == .favoritesOnly {
            parts.append(coreLocalized("Favourites"))
        }

        if let date = dateSummary(query.filter.date) {
            parts.append(date)
        }

        if query.filter.source != .all {
            parts.append(query.filter.source.displayName)
        }

        parts.append(contentsOf: dataSummaries(query.filter.data))

        if let tags = tagSummary(query.filter.tags, tagsByID: tagsByID) {
            parts.append(tags)
        }

        if query.sort != .dateNewest {
            parts.append(query.sort.displayName)
        } else if parts.isEmpty {
            parts.append(query.sort.displayName)
        }

        return parts.joined(separator: " · ")
    }

    private static func dateSummary(_ date: WorkoutLibraryDateFilter) -> String? {
        switch date {
        case .allTime:
            return nil
        case .last30Days, .last90Days, .currentCalendarYear:
            return date.displayName
        case .custom(let start, let end):
            if start != nil || end != nil {
                return coreLocalized("Custom Date Range")
            }
            return nil
        }
    }

    private static func dataSummaries(_ data: WorkoutLibraryDataFilters) -> [String] {
        var parts: [String] = []
        if data.requiresHeartRate {
            parts.append(coreLocalized("Has Heart Rate"))
        }
        if data.requiresCorrectedElevation {
            parts.append(coreLocalized("Has Corrected Elevation"))
        }
        if data.requiresRecordedLaps {
            parts.append(coreLocalized("Has Recorded Laps"))
        }
        return parts
    }

    private static func tagSummary(_ tags: WorkoutLibraryTagFilter, tagsByID: [UUID: WorkoutTag]) -> String? {
        switch tags {
        case .anyTags:
            return nil
        case .untaggedOnly:
            return coreLocalized("Untagged")
        case .selected(let tagIDs, let match):
            let names = tagIDs
                .compactMap { tagsByID[$0]?.name }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if !names.isEmpty {
                let joined = names.joined(separator: ", ")
                switch match {
                case .any:
                    return coreLocalized("Tag: \(joined)")
                case .all:
                    return coreLocalized("Tags (all): \(joined)")
                }
            }
            return nil
        }
    }
}
