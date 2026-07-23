import Foundation

/// Errors specific to actor-level library operations.
public enum WorkoutLibraryStoreError: Error, LocalizedError, Equatable {
    /// The workout ID already exists in the manifest.
    case duplicateWorkoutID(UUID)
    /// The manifest was committed but the workout file could not be deleted.
    case orphanedFile(UUID, underlyingError: String)
    /// The workout ID is not present in the library manifest.
    case workoutNotInLibrary(UUID)
    /// Metadata validation failed.
    case invalidMetadata(String)
    /// Tag validation or mutation failed.
    case invalidTag(String)
    /// Smart collection validation or mutation failed.
    case invalidSmartCollection(String)
    /// A referenced tag ID is not in the library.
    case tagNotFound(UUID)
    /// A referenced smart collection ID is not in the library.
    case smartCollectionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .duplicateWorkoutID(let id):
            return "Workout \(id) already exists in the library"
        case .orphanedFile(let id, let detail):
            return "Workout \(id) was removed from the library, but its file could not be deleted: \(detail)"
        case .workoutNotInLibrary(let id):
            return "Workout \(id) is not in the library"
        case .invalidMetadata(let detail):
            return detail
        case .invalidTag(let detail):
            return detail
        case .invalidSmartCollection(let detail):
            return detail
        case .tagNotFound(let id):
            return "Tag \(id) is not in the library"
        case .smartCollectionNotFound(let id):
            return "Smart collection \(id) is not in the library"
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
                let organizationNonEmpty = !manifest.tags.isEmpty
                    || !manifest.tagAssignments.isEmpty
                    || !manifest.smartCollections.isEmpty
                let manifestNeedsRepair = manifest.selectedWorkoutID != nil
                    || !manifest.favoriteWorkoutIDs.isEmpty
                    || organizationNonEmpty
                    || manifest.version != WorkoutLibraryManifest.currentVersion
                if manifestNeedsRepair {
                    var repaired = manifest
                    repaired.selectedWorkoutID = nil
                    repaired.favoriteWorkoutIDs = []
                    repaired.tags = []
                    repaired.tagAssignments = []
                    repaired.smartCollections = []
                    repaired.migrateToCurrentVersionIfNeeded()
                    do {
                        try store.saveManifest(repaired)
                    } catch {
                        return .demos(errorMessage: "Could not repair the empty library manifest: \(error.localizedDescription)")
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

            let selectedWorkoutID = manifest.selectedWorkoutID.flatMap { selectedID in
                validIDs.contains(selectedID) ? selectedID : nil
            } ?? validIDs.first

            let validIDSet = Set(validIDs)
            var favoriteIDs = manifest.favoriteWorkoutIDs.intersection(validIDSet)
            let favoritesNeedRepair = favoriteIDs != manifest.favoriteWorkoutIDs

            var workingManifest = manifest
            workingManifest.workoutIDs = validIDs
            workingManifest.selectedWorkoutID = selectedWorkoutID
            workingManifest.favoriteWorkoutIDs = favoriteIDs
            let organizationReport = workingManifest.repairOrganization()
            workingManifest.upgradeSchemaVersionIfNeeded()
            if workingManifest.version == WorkoutLibraryManifest.currentVersion {
                workingManifest.sanitizeFavorites()
            }

            let organizationChanged =
                workingManifest.tags != manifest.tags
                || workingManifest.tagAssignments != manifest.tagAssignments
                || workingManifest.smartCollections != manifest.smartCollections
            let manifestNeedsRepair = validIDs != manifest.workoutIDs
                || selectedWorkoutID != manifest.selectedWorkoutID
                || favoritesNeedRepair
                || organizationChanged
                || manifest.version != WorkoutLibraryManifest.currentVersion

            if !organizationReport.warnings.isEmpty {
                warnings.append(contentsOf: organizationReport.warnings)
            }

            if manifestNeedsRepair {
                do {
                    try store.saveManifest(workingManifest)
                    favoriteIDs = workingManifest.favoriteWorkoutIDs
                } catch {
                    warnings.append("Could not repair library manifest: \(error.localizedDescription)")
                }
            }

            guard !loaded.isEmpty else {
                let warning = warnings.isEmpty
                    ? nil
                    : "Library recovery:\n" + warnings.joined(separator: "\n")
                return .demos(errorMessage: warning)
            }

            let organization = WorkoutLibraryOrganizationSnapshot(
                tags: workingManifest.tags,
                tagAssignments: workingManifest.tagAssignments,
                smartCollections: workingManifest.smartCollections
            )
            let warning = warnings.isEmpty
                ? nil
                : "Library warnings:\n" + warnings.joined(separator: "\n")
            return .workouts(
                loaded,
                selectedWorkoutID: selectedWorkoutID,
                favoriteWorkoutIDs: favoriteIDs,
                organization: organization,
                warning: warning
            )
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
        manifest.favoriteWorkoutIDs.remove(id)
        manifest.removeTagAssignment(forWorkoutID: id)
        if wasSelected {
            manifest.selectedWorkoutID = newSelectedID
        }
        manifest.migrateToCurrentVersionIfNeeded()

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
        /// Deterministic stage order for commit.
        var stagedIDs: [UUID]
        /// O(1) membership for within-batch duplicate detection.
        var stagedIDSet: Set<UUID>
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
        activeBatch = ActiveBatch(
            token: token,
            stagedIDs: [],
            stagedIDSet: [],
            knownLibraryIDs: knownLibraryIDs
        )
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
        if active.stagedIDSet.contains(workout.id) || active.knownLibraryIDs.contains(workout.id) {
            throw WorkoutLibraryStoreError.duplicateWorkoutID(workout.id)
        }

        try store.stageWorkout(workout, batchID: batch.id)
        active.stagedIDs.append(workout.id)
        active.stagedIDSet.insert(workout.id)
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

    // MARK: - Favourites

    /// Set or clear the favourite marker for a library workout.
    ///
    /// Idempotent for repeated same-value requests. Persists one atomic
    /// manifest update. Does not rewrite workout snapshots.
    public func setFavorite(_ isFavorite: Bool, workoutID: UUID) throws {
        try Task.checkCancellation()
        var manifest: WorkoutLibraryManifest
        do {
            manifest = try store.loadManifest()
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                throw WorkoutLibraryStoreError.workoutNotInLibrary(workoutID)
            }
            throw error
        }

        guard manifest.workoutIDs.contains(workoutID) else {
            throw WorkoutLibraryStoreError.workoutNotInLibrary(workoutID)
        }

        let currentlyFavorite = manifest.favoriteWorkoutIDs.contains(workoutID)
        if currentlyFavorite == isFavorite {
            return
        }

        if isFavorite {
            manifest.favoriteWorkoutIDs.insert(workoutID)
        } else {
            manifest.favoriteWorkoutIDs.remove(workoutID)
        }
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    // MARK: - Metadata

    /// Update only editable name/notes for a library workout.
    ///
    /// Sequence: validate membership → normalize metadata → load snapshot →
    /// save snapshot atomically → return updated workout. Does not rerun
    /// normalization or analysis.
    public func updateWorkoutMetadata(
        workoutID: UUID,
        name: String?,
        notes: String?,
        policy: WorkoutMetadataEditingPolicy = .default
    ) throws -> RunWorkout {
        try Task.checkCancellation()
        var manifest: WorkoutLibraryManifest
        do {
            manifest = try store.loadManifest()
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                throw WorkoutLibraryStoreError.workoutNotInLibrary(workoutID)
            }
            throw error
        }

        guard manifest.workoutIDs.contains(workoutID) else {
            throw WorkoutLibraryStoreError.workoutNotInLibrary(workoutID)
        }

        let normalized: WorkoutMetadataEditingPolicy.NormalizedMetadata
        do {
            normalized = try policy.normalize(name: name, notes: notes)
        } catch let error as WorkoutMetadataEditingPolicy.ValidationError {
            throw WorkoutLibraryStoreError.invalidMetadata(error.localizedDescription)
        }

        var workout = try store.loadWorkout(id: workoutID)
        if workout.metadata.name == normalized.name, workout.metadata.notes == normalized.notes {
            return workout
        }

        workout.metadata.name = normalized.name
        workout.metadata.notes = normalized.notes
        try store.saveWorkout(workout)
        return workout
    }

    // MARK: - Tags

    /// Create a user-defined tag and persist one atomic manifest update.
    public func createTag(
        name: String,
        color: WorkoutTagColor,
        policy: WorkoutTagPolicy = .default
    ) throws -> WorkoutTag {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        try policy.validateCanCreate(existingCount: manifest.tags.count)
        let normalized: WorkoutTagPolicy.NormalizedName
        do {
            normalized = try policy.normalizeName(name)
            try policy.validateUniqueName(normalized, existing: manifest.tags)
        } catch let error as WorkoutTagPolicy.ValidationError {
            throw WorkoutLibraryStoreError.invalidTag(error.localizedDescription)
        }

        let tag = WorkoutTag(name: normalized.display, color: color)
        manifest.tags.append(tag)
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
        return tag
    }

    /// Rename and/or recolor a tag. ID is stable. Idempotent for equivalent values.
    public func updateTag(
        id: UUID,
        name: String,
        color: WorkoutTagColor,
        policy: WorkoutTagPolicy = .default
    ) throws -> WorkoutTag {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        guard let index = manifest.tags.firstIndex(where: { $0.id == id }) else {
            throw WorkoutLibraryStoreError.tagNotFound(id)
        }

        let normalized: WorkoutTagPolicy.NormalizedName
        do {
            normalized = try policy.normalizeName(name)
            try policy.validateUniqueName(normalized, existing: manifest.tags, excludingID: id)
        } catch let error as WorkoutTagPolicy.ValidationError {
            throw WorkoutLibraryStoreError.invalidTag(error.localizedDescription)
        }

        var tag = manifest.tags[index]
        if tag.name == normalized.display, tag.color == color {
            return tag
        }
        tag.name = normalized.display
        tag.color = color
        manifest.tags[index] = tag
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
        return tag
    }

    /// Delete a tag, removing assignments and saved-collection tag references.
    public func deleteTag(id: UUID) throws {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        guard manifest.tags.contains(where: { $0.id == id }) else {
            throw WorkoutLibraryStoreError.tagNotFound(id)
        }
        manifest.deleteTag(id: id)
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    /// Reorder tag definitions. `orderedIDs` must be a permutation of existing tag IDs.
    public func reorderTags(_ orderedIDs: [UUID]) throws {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        let currentIDs = manifest.tags.map(\.id)
        guard Set(orderedIDs) == Set(currentIDs), orderedIDs.count == currentIDs.count else {
            throw WorkoutLibraryStoreError.invalidTag("Tag reorder list must include every tag exactly once.")
        }
        if orderedIDs == currentIDs {
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: manifest.tags.map { ($0.id, $0) })
        manifest.tags = orderedIDs.compactMap { byID[$0] }
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    // MARK: - Tag assignments

    /// Replace the complete tag set for one library workout.
    public func setTags(
        _ tagIDs: Set<UUID>,
        forWorkoutID workoutID: UUID,
        policy: WorkoutTagPolicy = .default
    ) throws {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        guard manifest.workoutIDs.contains(workoutID) else {
            throw WorkoutLibraryStoreError.workoutNotInLibrary(workoutID)
        }

        let validTagIDs = Set(manifest.tags.map(\.id))
        guard tagIDs.isSubset(of: validTagIDs) else {
            if let missing = tagIDs.first(where: { !validTagIDs.contains($0) }) {
                throw WorkoutLibraryStoreError.tagNotFound(missing)
            }
            throw WorkoutLibraryStoreError.invalidTag("Unknown tag in assignment.")
        }
        do {
            try policy.validateAssignmentCount(tagIDs.count)
        } catch let error as WorkoutTagPolicy.ValidationError {
            throw WorkoutLibraryStoreError.invalidTag(error.localizedDescription)
        }

        let current = manifest.tagIDs(forWorkoutID: workoutID)
        if current == tagIDs {
            return
        }
        manifest.setTagIDs(tagIDs, forWorkoutID: workoutID)
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    /// Bulk add/remove tags across many workouts in one atomic manifest write.
    public func updateTags(
        workoutIDs: Set<UUID>,
        addTagIDs: Set<UUID>,
        removeTagIDs: Set<UUID>,
        policy: WorkoutTagPolicy = .default
    ) throws {
        try Task.checkCancellation()
        if workoutIDs.isEmpty || (addTagIDs.isEmpty && removeTagIDs.isEmpty) {
            return
        }

        var manifest = try loadOrCreateManifest()
        let libraryIDs = Set(manifest.workoutIDs)
        guard workoutIDs.isSubset(of: libraryIDs) else {
            if let missing = workoutIDs.first(where: { !libraryIDs.contains($0) }) {
                throw WorkoutLibraryStoreError.workoutNotInLibrary(missing)
            }
            throw WorkoutLibraryStoreError.invalidTag("Unknown workout in bulk tag update.")
        }

        let validTagIDs = Set(manifest.tags.map(\.id))
        let referenced = addTagIDs.union(removeTagIDs)
        guard referenced.isSubset(of: validTagIDs) else {
            if let missing = referenced.first(where: { !validTagIDs.contains($0) }) {
                throw WorkoutLibraryStoreError.tagNotFound(missing)
            }
            throw WorkoutLibraryStoreError.invalidTag("Unknown tag in bulk update.")
        }

        var changed = false
        for workoutID in workoutIDs {
            var next = manifest.tagIDs(forWorkoutID: workoutID)
            let before = next
            next.formUnion(addTagIDs)
            next.subtract(removeTagIDs)
            do {
                try policy.validateAssignmentCount(next.count)
            } catch let error as WorkoutTagPolicy.ValidationError {
                throw WorkoutLibraryStoreError.invalidTag(error.localizedDescription)
            }
            if next != before {
                manifest.setTagIDs(next, forWorkoutID: workoutID)
                changed = true
            }
        }

        if !changed {
            return
        }
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    // MARK: - Smart collections

    public func createSmartCollection(
        name: String,
        query: WorkoutLibrarySavedQuery,
        policy: WorkoutSmartCollectionPolicy = .default
    ) throws -> WorkoutSmartCollection {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        try policy.validateCanCreate(existingCount: manifest.smartCollections.count)
        let normalized: WorkoutSmartCollectionPolicy.NormalizedName
        do {
            normalized = try policy.normalizeName(name)
            try policy.validateUniqueName(normalized, existing: manifest.smartCollections)
            try policy.validateSavedQuery(query)
        } catch let error as WorkoutSmartCollectionPolicy.ValidationError {
            throw WorkoutLibraryStoreError.invalidSmartCollection(error.localizedDescription)
        }

        var sanitizedQuery = query
        sanitizedQuery.filter.tags = Self.sanitizeTagFilter(
            query.filter.tags,
            validTagIDs: Set(manifest.tags.map(\.id))
        )

        let collection = WorkoutSmartCollection(name: normalized.display, query: sanitizedQuery)
        manifest.smartCollections.append(collection)
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
        return collection
    }

    public func updateSmartCollection(
        id: UUID,
        name: String,
        query: WorkoutLibrarySavedQuery,
        policy: WorkoutSmartCollectionPolicy = .default
    ) throws -> WorkoutSmartCollection {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        guard let index = manifest.smartCollections.firstIndex(where: { $0.id == id }) else {
            throw WorkoutLibraryStoreError.smartCollectionNotFound(id)
        }

        let normalized: WorkoutSmartCollectionPolicy.NormalizedName
        do {
            normalized = try policy.normalizeName(name)
            try policy.validateUniqueName(
                normalized,
                existing: manifest.smartCollections,
                excludingID: id
            )
            try policy.validateSavedQuery(query)
        } catch let error as WorkoutSmartCollectionPolicy.ValidationError {
            throw WorkoutLibraryStoreError.invalidSmartCollection(error.localizedDescription)
        }

        var sanitizedQuery = query
        sanitizedQuery.filter.tags = Self.sanitizeTagFilter(
            query.filter.tags,
            validTagIDs: Set(manifest.tags.map(\.id))
        )

        var collection = manifest.smartCollections[index]
        if collection.name == normalized.display, collection.query == sanitizedQuery {
            return collection
        }
        collection.name = normalized.display
        collection.query = sanitizedQuery
        manifest.smartCollections[index] = collection
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
        return collection
    }

    public func deleteSmartCollection(id: UUID) throws {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        guard manifest.smartCollections.contains(where: { $0.id == id }) else {
            throw WorkoutLibraryStoreError.smartCollectionNotFound(id)
        }
        manifest.smartCollections.removeAll { $0.id == id }
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    public func reorderSmartCollections(_ orderedIDs: [UUID]) throws {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()
        let currentIDs = manifest.smartCollections.map(\.id)
        guard Set(orderedIDs) == Set(currentIDs), orderedIDs.count == currentIDs.count else {
            throw WorkoutLibraryStoreError.invalidSmartCollection(
                "Smart collection reorder list must include every collection exactly once."
            )
        }
        if orderedIDs == currentIDs {
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: manifest.smartCollections.map { ($0.id, $0) })
        manifest.smartCollections = orderedIDs.compactMap { byID[$0] }
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    // MARK: - Private helpers

    private func loadOrCreateManifest() throws -> WorkoutLibraryManifest {
        do {
            return try store.loadManifest()
        } catch let error as WorkoutLibraryError {
            if case .manifestMissing = error {
                return WorkoutLibraryManifest()
            }
            throw error
        }
    }

    private static func sanitizeTagFilter(
        _ filter: WorkoutLibraryTagFilter,
        validTagIDs: Set<UUID>
    ) -> WorkoutLibraryTagFilter {
        switch filter {
        case .anyTags, .untaggedOnly:
            return filter
        case .selected(let tagIDs, let match):
            let kept = tagIDs.intersection(validTagIDs)
            if kept.isEmpty {
                return .anyTags
            }
            return .selected(tagIDs: kept, match: match)
        }
    }
}
