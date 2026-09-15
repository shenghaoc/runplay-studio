import Foundation

/// Resolved scope for one Trends aggregation pass.
public struct WorkoutTrendsScopeResolution: Hashable, Sendable {
    /// Workouts in scope, or `nil` for the entire library.
    public let matchingWorkoutIDs: Set<UUID>?

    public init(matchingWorkoutIDs: Set<UUID>?) {
        self.matchingWorkoutIDs = matchingWorkoutIDs
    }
}

/// Resolves a Trends scope to a workout ID set over lightweight entries.
///
/// Scoping reuses the All Runs query machinery — search text, filters, tags,
/// favourites, and relative dates behave identically to the All Runs table.
/// Smart collections never persist membership; they resolve live against the
/// current entries and documents.
public enum WorkoutTrendsScopeResolver {
    /// Executes the scope's query through the supplied service.
    ///
    /// Unknown smart-collection IDs and a missing current query degrade to the
    /// entire library rather than an empty scope, so a stale persisted scope
    /// can never blank the Trends workspace.
    public static func resolve(
        scope: WorkoutTrendsScope,
        entries: [WorkoutLibraryEntry],
        documents: [UUID: WorkoutLibrarySearchDocument],
        smartCollections: [WorkoutSmartCollection],
        currentQuery: WorkoutLibraryQuery?,
        now: Date,
        calendar: Calendar,
        service: WorkoutLibraryQuerying = WorkoutLibraryQueryService()
    ) async throws -> WorkoutTrendsScopeResolution {
        switch scope {
        case .entireLibrary:
            return WorkoutTrendsScopeResolution(matchingWorkoutIDs: nil)
        case .currentLibraryFilter:
            guard let currentQuery else {
                return WorkoutTrendsScopeResolution(matchingWorkoutIDs: nil)
            }
            return try await resolve(
                query: currentQuery,
                entries: entries,
                documents: documents,
                service: service
            )
        case .smartCollection(let collectionID):
            guard let collection = smartCollections.first(where: { $0.id == collectionID }) else {
                return WorkoutTrendsScopeResolution(matchingWorkoutIDs: nil)
            }
            let query = collection.query.makeRuntimeQuery(now: now, calendar: calendar)
            return try await resolve(
                query: query,
                entries: entries,
                documents: documents,
                service: service
            )
        }
    }

    private static func resolve(
        query: WorkoutLibraryQuery,
        entries: [WorkoutLibraryEntry],
        documents: [UUID: WorkoutLibrarySearchDocument],
        service: WorkoutLibraryQuerying
    ) async throws -> WorkoutTrendsScopeResolution {
        let result = try await service.execute(
            entries: entries,
            documents: documents,
            query: query
        )
        return WorkoutTrendsScopeResolution(matchingWorkoutIDs: Set(result.matchingIDs))
    }
}
