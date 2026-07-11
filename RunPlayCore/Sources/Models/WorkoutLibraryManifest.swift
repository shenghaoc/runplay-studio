import Foundation

/// Versioned manifest for the workout library.
///
/// The manifest tracks which workouts exist and their display order,
/// plus the last-selected workout for session restoration.
public struct WorkoutLibraryManifest: Codable, Equatable {
    /// Current schema version. Bump when the on-disk format changes.
    public static let currentVersion = 1

    /// Schema version of this manifest.
    public var version: Int

    /// Ordered workout IDs (defines display order in the sidebar).
    public var workoutIDs: [UUID]

    /// Last-selected workout ID, if any.
    public var selectedWorkoutID: UUID?

    public init(
        version: Int = WorkoutLibraryManifest.currentVersion,
        workoutIDs: [UUID] = [],
        selectedWorkoutID: UUID? = nil
    ) {
        self.version = version
        self.workoutIDs = workoutIDs
        self.selectedWorkoutID = selectedWorkoutID
    }
}
