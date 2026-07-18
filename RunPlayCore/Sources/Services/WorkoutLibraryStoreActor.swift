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

    /// Create a store actor backed by the given storage implementation.
    ///
    /// - Parameter store: The low-level storage implementation (injectable for testing).
    public init(store: WorkoutLibraryStoring) {
        self.store = store
    }

    // MARK: - Load Library

    /// Load the persisted workout library with recovery for missing/corrupt files.
    ///
    /// This replaces the synchronous `WorkoutLibraryLoader` with actor-isolated logic.
    public func loadLibrary() -> WorkoutLibraryLoadResult {
        recoverStaleState()
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
                    var workout = try store.loadWorkout(id: id)
                    validIDs.append(id)

                    var upgraded = false
                    if workout.normalizationVersion < RunWorkout.currentNormalizationVersion {
                        let distancePolicy: RouteDistancePolicy
                        switch workout.routeDistanceSource {
                        case .coordinateDerived:
                            distancePolicy = .computeFromCoordinates
                        case .deviceSupplied:
                            distancePolicy = .useSuppliedDistancesWhenValid
                        case .mixed:
                            let suppliedSegments = Set(
                                workout.routeDistanceProvenance.segmentSources.enumerated().compactMap {
                                    $0.element == .deviceSupplied ? $0.offset : nil
                                }
                            )
                            distancePolicy = suppliedSegments.isEmpty
                                ? .useSuppliedDistancesPerSegment
                                : .useSuppliedDistancesForSegments(suppliedSegments)
                        case .legacyUnknown:
                            distancePolicy = RouteQualityProcessor.legacyDistancePolicy(
                                for: workout.routePoints,
                                source: workout.source
                            )
                        }

                        do {
                            try WorkoutAnalyzer().normalizeAndAnalyze(
                                &workout,
                                distancePolicy: distancePolicy,
                                // Library loading is synchronous and recovery-oriented.
                                // Interactive imports use the cancellable default.
                                isCancelled: { false }
                            )
                            upgraded = true
                        } catch {
                            // A decoded workout remains usable even if quality
                            // processing fails. Keep it visible and retry later.
                            warnings.append(
                                "Workout \(id.uuidString.prefix(8))… route quality could not be upgraded: "
                                    + error.localizedDescription
                            )
                        }
                    } else if workout.normalizationVersion <= RunWorkout.currentNormalizationVersion,
                              workout.analysisVersion < RunWorkout.currentAnalysisVersion {
                        WorkoutAnalyzer().reanalyzePreservingRoutePoints(&workout)
                        upgraded = true
                    }
                    loaded.append(workout)

                    if upgraded {
                        // FileWorkoutLibraryStore replaces each snapshot
                        // atomically. A failed rewrite leaves the original
                        // legacy file intact and the upgraded workout visible
                        // in memory; migration is retried on the next launch.
                        do {
                            try store.saveWorkout(workout)
                        } catch {
                            warnings.append(
                                "Workout \(id.uuidString.prefix(8))… was upgraded in memory "
                                    + "but could not be saved: \(error.localizedDescription)"
                            )
                        }
                    }
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
                : "Library warnings:\n" + warnings.joined(separator: "\n")
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
        try Task.checkCancellation()
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

    /// Persist the selected workout ID.
    ///
    /// Actor serialization guarantees that concurrent selection writes
    /// execute in FIFO order, so the last enqueued write always wins.
    ///
    /// If no manifest exists (e.g. bundled demos), this is a silent no-op
    /// because demos are intentionally not in the user library.
    public func setSelectedWorkoutID(_ id: UUID?) throws {
        var manifest: WorkoutLibraryManifest
        do {
            manifest = try store.loadManifest()
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                return // Bundled demos have no persisted selection.
            }
            throw error
        }
        manifest.selectedWorkoutID = id
        try store.saveManifest(manifest)
    }

    // MARK: - Batch Import

    private struct ActiveBatch {
        let token: WorkoutLibraryBatchToken
        var stagedIDs: [UUID]
        /// Snapshot of library IDs at batch start; commit re-validates against the live manifest.
        let knownLibraryIDs: Set<UUID>
    }

    private var activeBatch: ActiveBatch?

    /// Remove stale staging left by crashed imports. Safe to call at startup.
    public func recoverStaleState() {
        do {
            try store.cleanupStaleStaging()
        } catch {
            // Best-effort startup recovery.
        }
        // Orphan final files not in manifest.
        do {
            let manifest = try store.loadManifest()
            try store.cleanupUnreferencedWorkoutFiles(referencedIDs: Set(manifest.workoutIDs))
        } catch {
            // Missing manifest is fine.
        }
    }

    /// Begin a staged batch import transaction.
    public func beginBatchImport() throws -> WorkoutLibraryBatchToken {
        try Task.checkCancellation()
        if activeBatch != nil {
            throw WorkoutLibraryError.writeFailed("A batch import is already in progress")
        }
        var knownLibraryIDs = Set<UUID>()
        do {
            knownLibraryIDs = Set(try store.loadManifest().workoutIDs)
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                knownLibraryIDs = []
            } else {
                throw error
            }
        }
        let token = WorkoutLibraryBatchToken()
        activeBatch = ActiveBatch(token: token, stagedIDs: [], knownLibraryIDs: knownLibraryIDs)
        return token
    }

    /// Stage a normalized workout snapshot. Does not modify the manifest.
    public func stageWorkout(_ workout: RunWorkout, in batch: WorkoutLibraryBatchToken) throws {
        try Task.checkCancellation()
        guard var active = activeBatch, active.token == batch else {
            throw WorkoutLibraryError.writeFailed("Invalid or inactive batch token")
        }
        // Reject duplicate IDs within the batch and against the library snapshot
        // captured at beginBatchImport. commitBatchImport re-validates against
        // the live manifest before promote.
        if active.stagedIDs.contains(workout.id) || active.knownLibraryIDs.contains(workout.id) {
            throw WorkoutLibraryStoreError.duplicateWorkoutID(workout.id)
        }

        try store.stageWorkout(workout, batchID: batch.id)
        active.stagedIDs.append(workout.id)
        activeBatch = active
    }

    /// Atomically commit all staged workouts in this batch.
    ///
    /// - Parameters:
    ///   - batch: Token from `beginBatchImport`.
    ///   - selectedWorkoutID: Preferred selection after commit (must be staged or existing).
    /// - Returns: Ordered staged IDs that were committed.
    @discardableResult
    public func commitBatchImport(
        _ batch: WorkoutLibraryBatchToken,
        selectedWorkoutID: UUID?
    ) throws -> [UUID] {
        try Task.checkCancellation()
        guard let active = activeBatch, active.token == batch else {
            throw WorkoutLibraryError.writeFailed("Invalid or inactive batch token")
        }
        let stagedIDs = active.stagedIDs
        if stagedIDs.isEmpty {
            try store.removeStaging(batchID: batch.id)
            activeBatch = nil
            return []
        }

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

        // Validate no staged ID is already in the library.
        for id in stagedIDs {
            if manifest.workoutIDs.contains(id) {
                try? store.removeStaging(batchID: batch.id)
                activeBatch = nil
                throw WorkoutLibraryStoreError.duplicateWorkoutID(id)
            }
        }

        // Promote staged files to final paths.
        do {
            try store.promoteStagedWorkouts(ids: stagedIDs, batchID: batch.id)
        } catch {
            try? store.removeStaging(batchID: batch.id)
            activeBatch = nil
            throw error
        }

        var updated = manifest
        updated.workoutIDs.append(contentsOf: stagedIDs)
        if let selectedWorkoutID {
            if updated.workoutIDs.contains(selectedWorkoutID) {
                updated.selectedWorkoutID = selectedWorkoutID
            }
        }

        do {
            try store.saveManifest(updated)
        } catch {
            // Rollback: delete every newly moved snapshot; preserve original manifest.
            for id in stagedIDs {
                try? store.deleteWorkout(id: id)
            }
            try? store.removeStaging(batchID: batch.id)
            activeBatch = nil
            throw error
        }

        try? store.removeStaging(batchID: batch.id)
        activeBatch = nil
        return stagedIDs
    }

    /// Discard staging for a batch without modifying the library.
    public func rollbackBatchImport(_ batch: WorkoutLibraryBatchToken) {
        guard let active = activeBatch, active.token == batch else {
            // Still try to remove staging dir if present.
            try? store.removeStaging(batchID: batch.id)
            return
        }
        try? store.removeStaging(batchID: batch.id)
        activeBatch = nil
    }

    /// Whether a batch import is currently active.
    public var hasActiveBatch: Bool {
        activeBatch != nil
    }
}
