import Foundation

/// Protocol for persisting workouts to a local library.
///
/// All implementations must be platform-neutral (no SwiftUI, AppKit, etc.)
/// so tests can run on Linux and in CI without macOS frameworks.
public protocol WorkoutLibraryStoring: Sendable {
    /// Load the persisted library manifest.
    func loadManifest() throws -> WorkoutLibraryManifest

    /// Save (or overwrite) the manifest atomically.
    func saveManifest(_ manifest: WorkoutLibraryManifest) throws

    /// Load a single persisted workout by ID.
    func loadWorkout(id: UUID) throws -> RunWorkout

    /// Persist a complete workout snapshot.
    func saveWorkout(_ workout: RunWorkout) throws

    /// Delete a persisted workout file.
    func deleteWorkout(id: UUID) throws

    /// Whether a persisted workout file exists for the given ID.
    func workoutExists(id: UUID) -> Bool

    // MARK: - Batch staging (optional; default no-ops for simple mocks)

    /// Root of the library (for staging paths). Default implementations may throw.
    var libraryRootURL: URL { get }

    /// Stage a workout snapshot under a private batch directory (not visible in library).
    func stageWorkout(_ workout: RunWorkout, batchID: UUID) throws

    /// Load a previously staged workout.
    func loadStagedWorkout(id: UUID, batchID: UUID) throws -> RunWorkout

    /// Move staged snapshots to final workout paths (does not update manifest).
    func promoteStagedWorkouts(ids: [UUID], batchID: UUID) throws

    /// Remove a staging directory for a batch.
    func removeStaging(batchID: UUID) throws

    /// Remove all stale staging directories (startup recovery).
    func cleanupStaleStaging() throws

    /// Remove final workout files that are not referenced by the manifest (orphan cleanup).
    func cleanupUnreferencedWorkoutFiles(referencedIDs: Set<UUID>) throws
}

extension WorkoutLibraryStoring {
    public var libraryRootURL: URL {
        fatalError("libraryRootURL not implemented")
    }

    public func stageWorkout(_ workout: RunWorkout, batchID: UUID) throws {
        throw WorkoutLibraryError.writeFailed("Batch staging is not supported by this store")
    }

    public func loadStagedWorkout(id: UUID, batchID: UUID) throws -> RunWorkout {
        throw WorkoutLibraryError.workoutFileMissing(id)
    }

    public func promoteStagedWorkouts(ids: [UUID], batchID: UUID) throws {
        throw WorkoutLibraryError.writeFailed("Batch promote is not supported by this store")
    }

    public func removeStaging(batchID: UUID) throws {}

    public func cleanupStaleStaging() throws {}

    public func cleanupUnreferencedWorkoutFiles(referencedIDs: Set<UUID>) throws {}
}
