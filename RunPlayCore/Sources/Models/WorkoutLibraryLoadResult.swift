import Foundation

/// Result of reading the persisted workout library before UI state is applied.
public enum WorkoutLibraryLoadResult: Sendable {
    /// No persisted library exists. `errorMessage` carries any recovery warning.
    case demos(errorMessage: String?)
    /// A valid library was loaded.
    case workouts(
        [RunWorkout],
        selectedWorkoutID: UUID?,
        favoriteWorkoutIDs: Set<UUID>,
        warning: String?
    )
}
