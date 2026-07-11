import Foundation

/// Protocol for persisting workouts to a local library.
///
/// All implementations must be platform-neutral (no SwiftUI, AppKit, etc.)
/// so tests can run on Linux and in CI without macOS frameworks.
public protocol WorkoutLibraryStoring {
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
}
