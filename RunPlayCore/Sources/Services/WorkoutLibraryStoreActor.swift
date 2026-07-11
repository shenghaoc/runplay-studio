import Foundation

/// Errors specific to actor-level library operations.
public enum WorkoutLibraryStoreError: Error, LocalizedError, Equatable {
    /// The workout ID already exists in the manifest.
    case duplicateWorkoutID(UUID)
    /// The manifest was committed but the workout file could not be deleted.
    case orphanedFile(UUID, underlyingError: String)

    public var errorDescription: String? {
        switch self {
        case .duplicateWorkoutID(let id):
            return "Workout \(id) already exists in the library"
        case .orphanedFile(let id, let detail):
            return "Workout \(id) was removed from the library, but its file could not be deleted: \(detail)"
        }
    }
}

/// Actor that provides high-level transactional workout library operations.
///
/// All file I/O and manifest coordination is serialized through this actor.
/// The underlying `WorkoutLibraryStoring` implementation is never accessed
/// directly from outside.
public actor WorkoutLibraryStoreActor {

    private let store: WorkoutLibraryStoring
    private let fileManager: FileManager
    private var selectionSequence: UInt64 = 0

    /// Create a store actor backed by the given storage implementation.
    ///
    /// - Parameters:
    ///   - store: The low-level storage implementation (injectable for testing).
    ///   - fileManager: Injectable for testing.
    public init(store: WorkoutLibraryStoring, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    // MARK: - Load Library

    /// Load the persisted workout library with recovery for missing/corrupt files.
    ///
    /// This replaces the synchronous `WorkoutLibraryLoader` with actor-isolated logic.
    public func loadLibrary() -> WorkoutLibraryLoadResult {
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

    // MARK: - Add Workout

    /// Persist a workout with transactional rollback.
    ///
    /// 1. Load or create the manifest.
    /// 2. Guard against duplicate ID (idempotent no-op if already present).
    /// 3. Save the workout file.
    /// 4. Append the ID and optionally update selection.
    /// 5. Save the manifest.
    /// 6. Roll back the workout file if the manifest write fails.
    public func addWorkout(_ workout: RunWorkout, select: Bool) throws {
        var manifest: WorkoutLibraryManifest
        do {
            manifest = try store.loadManifest()
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                manifest = WorkoutLibraryManifest()
            } else {
                throw error
            }
        }

        // Idempotent: if the ID is already in the manifest, skip.
        guard !manifest.workoutIDs.contains(workout.id) else {
            return
        }

        try store.saveWorkout(workout)

        manifest.workoutIDs.append(workout.id)
        if select {
            manifest.selectedWorkoutID = workout.id
        }

        do {
            try store.saveManifest(manifest)
        } catch {
            // Rollback: remove the workout file we just wrote.
            do {
                try store.deleteWorkout(id: workout.id)
            } catch let cleanupError {
                throw WorkoutLibraryError.writeFailed(
                    "Could not update the manifest (\(error.localizedDescription)); "
                    + "cleanup of the saved workout also failed (\(cleanupError.localizedDescription))"
                )
            }
            throw error
        }
    }

    // MARK: - Delete Workout

    /// Result of a delete operation.
    public enum DeleteResult: Sendable {
        /// The workout was in the manifest and was the selected workout.
        case deletedSelected
        /// The workout was in the manifest but was not the selected workout.
        case deletedNonSelected
        /// The workout was not in the manifest (e.g. a bundled demo).
        case notInManifest
    }

    /// Delete a workout with transactional manifest update.
    ///
    /// 1. Load manifest, confirm the ID exists.
    /// 2. Remove the ID and optionally update selection.
    /// 3. Save the manifest.
    /// 4. Delete the workout file.
    /// 5. If file deletion fails after manifest commit, throw an orphaned-file error.
    @discardableResult
    public func deleteWorkout(id: UUID, newSelectedID: UUID?) throws -> DeleteResult {
        var manifest: WorkoutLibraryManifest
        do {
            manifest = try store.loadManifest()
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                // No manifest means this is a bundled demo — nothing to persist.
                return .notInManifest
            }
            throw error
        }

        guard manifest.workoutIDs.contains(id) else {
            return .notInManifest
        }

        let wasSelected = manifest.selectedWorkoutID == id
        manifest.workoutIDs.removeAll { $0 == id }
        if wasSelected {
            manifest.selectedWorkoutID = newSelectedID
        }

        try store.saveManifest(manifest)

        do {
            try store.deleteWorkout(id: id)
        } catch {
            // Manifest already committed. The file is orphaned.
            throw WorkoutLibraryStoreError.orphanedFile(
                id,
                underlyingError: error.localizedDescription
            )
        }

        return wasSelected ? .deletedSelected : .deletedNonSelected
    }

    // MARK: - Selection

    /// Persist the selected workout ID with last-write-wins semantics.
    ///
    /// Uses a monotonic counter so that a stale request never overwrites a newer one.
    public func setSelectedWorkoutID(_ id: UUID?) throws {
        selectionSequence &+= 1
        let mySequence = selectionSequence

        var manifest = try store.loadManifest()
        manifest.selectedWorkoutID = id

        // Only write if this is still the latest request.
        guard selectionSequence == mySequence else {
            return
        }

        try store.saveManifest(manifest)
    }
}
