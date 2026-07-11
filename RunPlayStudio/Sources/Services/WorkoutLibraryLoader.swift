import Foundation
import RunPlayCore

/// Result of reading the persisted workout library before UI state is applied.
enum WorkoutLibraryLoadResult: Sendable {
    case demos(errorMessage: String?)
    case workouts([RunWorkout], selectedWorkoutID: UUID?, warning: String?)
}

/// Performs synchronous library reads and recovery away from the main actor.
struct WorkoutLibraryLoader {
    static func load(from store: WorkoutLibraryStoring) -> WorkoutLibraryLoadResult {
        do {
            let manifest = try store.loadManifest()
            guard !manifest.workoutIDs.isEmpty else {
                if manifest.selectedWorkoutID != nil {
                    var repaired = manifest
                    repaired.selectedWorkoutID = nil
                    do {
                        try store.saveManifest(repaired)
                    } catch {
                        return .demos(errorMessage: "Could not repair the empty library selection: \(error.localizedDescription)")
                    }
                }
                return .demos(errorMessage: nil)
            }

            var loaded: [RunWorkout] = []
            var validIDs: [UUID] = []
            var warnings: [String] = []

            for id in manifest.workoutIDs {
                do {
                    loaded.append(try store.loadWorkout(id: id))
                    validIDs.append(id)
                } catch let error as WorkoutLibraryError {
                    switch error {
                    case .workoutFileMissing:
                        warnings.append("Workout \(id.uuidString.prefix(8))… file missing — skipped")
                    case .workoutCorrupted:
                        warnings.append("Workout \(id.uuidString.prefix(8))… corrupted — skipped")
                    default:
                        warnings.append("Workout \(id.uuidString.prefix(8))… error: \(error.localizedDescription)")
                    }
                } catch {
                    warnings.append("Workout \(id.uuidString.prefix(8))… unexpected error: \(error.localizedDescription)")
                }
            }

            guard !loaded.isEmpty else {
                let warning = warnings.isEmpty
                    ? nil
                    : "Library recovery:\n" + warnings.joined(separator: "\n")
                return .demos(errorMessage: warning)
            }

            let selectedWorkoutID = manifest.selectedWorkoutID.flatMap { selectedID in
                validIDs.contains(selectedID) ? selectedID : nil
            } ?? validIDs.first

            if validIDs != manifest.workoutIDs || selectedWorkoutID != manifest.selectedWorkoutID {
                var repaired = manifest
                repaired.workoutIDs = validIDs
                repaired.selectedWorkoutID = selectedWorkoutID
                do {
                    try store.saveManifest(repaired)
                } catch {
                    warnings.append("Could not repair library manifest: \(error.localizedDescription)")
                }
            }

            let warning = warnings.isEmpty
                ? nil
                : "Some workouts could not be loaded:\n" + warnings.joined(separator: "\n")
            return .workouts(loaded, selectedWorkoutID: selectedWorkoutID, warning: warning)
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                return .demos(errorMessage: nil)
            }
            return .demos(errorMessage: "Failed to load library: \(error.localizedDescription)")
        } catch {
            return .demos(errorMessage: "Unexpected error loading library: \(error.localizedDescription)")
        }
    }
}
