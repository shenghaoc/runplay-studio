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
    /// A referenced route group ID is not in the library.
    case routeGroupNotFound(UUID)
    /// Route group validation or mutation failed.
    case invalidRouteGroup(String)

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
        case .routeGroupNotFound(let id):
            return "Route group \(id) is not in the library"
        case .invalidRouteGroup(let detail):
            return detail
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

    /// Deterministic test seam for the representative loader used by
    /// `assignRouteGroups`: when non-`nil`, awaited inside the loader after
    /// each representative snapshot load, opening the pass's suspension
    /// window so tests can interleave other actor work (a delete) before
    /// the manifest write. Production never sets it; internal so it is not
    /// part of the public API.
    private var routeGroupRepresentativeLoaderSuspension: (@Sendable () async -> Void)?

    /// Installs the representative-loader suspension test seam. Internal
    /// test access to the stored property above; production never calls it.
    func setRouteGroupRepresentativeLoaderSuspension(_ hook: (@Sendable () async -> Void)?) {
        routeGroupRepresentativeLoaderSuspension = hook
    }

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
                // Empty library still shows demos, but keep user-defined tags and
                // smart collections. Only drop assignments (no workouts) plus
                // selection/favourites that cannot apply without library rows.
                var repaired = manifest
                let hadAssignments = !repaired.tagAssignments.isEmpty
                let hadSelectionOrFavorites = repaired.selectedWorkoutID != nil
                    || !repaired.favoriteWorkoutIDs.isEmpty
                repaired.selectedWorkoutID = nil
                repaired.favoriteWorkoutIDs = []
                repaired.tagAssignments = []
                repaired.routeGroups = []
                repaired.routeGroupAssignments = []
                let organizationReport = repaired.repairOrganization()
                repaired.upgradeSchemaVersionIfNeeded()
                let needsPersist = hadAssignments
                    || hadSelectionOrFavorites
                    || !organizationReport.isEmpty
                    || repaired.version != manifest.version
                    || repaired.tags != manifest.tags
                    || repaired.smartCollections != manifest.smartCollections
                if needsPersist {
                    do {
                        try store.saveManifest(repaired)
                    } catch {
                        return .demos(
                            errorMessage: "Could not repair the empty library manifest: \(error.localizedDescription)",
                            organization: WorkoutLibraryOrganizationSnapshot(
                                tags: repaired.tags,
                                smartCollections: repaired.smartCollections
                            ),
                            manifestPresent: true
                        )
                    }
                }
                return .demos(
                    errorMessage: nil,
                    organization: WorkoutLibraryOrganizationSnapshot(
                        tags: repaired.tags,
                        tagAssignments: [],
                        smartCollections: repaired.smartCollections
                    ),
                    manifestPresent: true
                )
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
                || workingManifest.routeGroups != manifest.routeGroups
                || workingManifest.routeGroupAssignments != manifest.routeGroupAssignments
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
                // All workout files missing/corrupt — keep organisation for an
                // empty persisted library rather than wiping tags/collections.
                return .demos(
                    errorMessage: warning,
                    organization: WorkoutLibraryOrganizationSnapshot(
                        tags: workingManifest.tags,
                        tagAssignments: workingManifest.tagAssignments,
                        smartCollections: workingManifest.smartCollections
                    ),
                    manifestPresent: true
                )
            }

            let organization = WorkoutLibraryOrganizationSnapshot(
                tags: workingManifest.tags,
                tagAssignments: workingManifest.tagAssignments,
                smartCollections: workingManifest.smartCollections,
                routeGroups: workingManifest.routeGroups,
                routeGroupAssignments: workingManifest.routeGroupAssignments
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
        // Drop the deleted workout's route-group record and repair the group
        // it left (representative pin/summary and empty-group removal).
        if let removedAssignment = manifest.routeGroupAssignment(forWorkoutID: id),
           let removedGroupID = removedAssignment.groupID,
           let groupIndex = manifest.routeGroups.firstIndex(where: { $0.id == removedGroupID }) {
            manifest.routeGroupAssignments.removeAll { $0.workoutID == id }
            let remainingMemberIDs = manifest.routeGroupMemberIDs(groupID: removedGroupID)
            if remainingMemberIDs.isEmpty {
                manifest.routeGroups.remove(at: groupIndex)
            } else {
                if manifest.routeGroups[groupIndex].pinnedRepresentativeWorkoutID == id {
                    manifest.routeGroups[groupIndex].pinnedRepresentativeWorkoutID = nil
                }
                if manifest.routeGroups[groupIndex].representativeSummary?.workoutID == id {
                    manifest.routeGroups[groupIndex].representativeSummary = bestSummary(
                        amongWorkoutIDs: remainingMemberIDs,
                        in: manifest
                    )
                }
            }
            manifest.sortRouteGroupAssignmentsDeterministically()
        }
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

    // MARK: - Personal records backfill

    /// One backfill step, reported after each workout so callers can apply
    /// updated snapshots incrementally.
    public struct PersonalRecordsBackfillUpdate: Sendable, Equatable {
        public let completedCount: Int
        public let totalCount: Int
        public let currentWorkoutName: String
        /// The freshly computed snapshot to apply in memory, or `nil` when
        /// this workout already carried records and was only counted.
        public let computedWorkout: RunWorkout?

        public init(
            completedCount: Int,
            totalCount: Int,
            currentWorkoutName: String,
            computedWorkout: RunWorkout?
        ) {
            self.completedCount = completedCount
            self.totalCount = totalCount
            self.currentWorkoutName = currentWorkoutName
            self.computedWorkout = computedWorkout
        }
    }

    /// Final totals for one backfill pass.
    public struct PersonalRecordsBackfillResult: Sendable, Equatable {
        public let computedCount: Int
        public let skippedCount: Int
        /// Workouts an engine contract failure left without records. A
        /// cancelled pass never adds to this: cancellation ends the pass and
        /// returns the partial totals.
        public let failedCount: Int
        public let saveFailureCount: Int

        public init(
            computedCount: Int,
            skippedCount: Int,
            failedCount: Int,
            saveFailureCount: Int
        ) {
            self.computedCount = computedCount
            self.skippedCount = skippedCount
            self.failedCount = failedCount
            self.saveFailureCount = saveFailureCount
        }
    }

    /// Compute and persist personal-record windows for every library workout
    /// whose snapshot predates record computation.
    ///
    /// This is the one-off migration for existing libraries: new imports and
    /// re-analyzed snapshots already carry records from the analysis pass, so
    /// workouts with a non-`nil` `personalRecords` value are skipped and the
    /// pass is idempotent. Progress is cooperative: the calling task's
    /// cancellation is checked before every workout and again inside each
    /// detection, and either one ends the pass early and returns the partial
    /// totals rather than throwing. Cancellation is never counted as a
    /// failure — the interrupted workout simply keeps its unset marker, and
    /// every workout already saved stays saved, so the pass resumes. The loop
    /// yields between workouts so other library operations are never starved.
    /// It never runs during library load; callers trigger it explicitly (the
    /// Records workspace starts it on first open).
    public func backfillPersonalRecords(
        policy: RouteQualityPolicy = .runningDefault,
        progress: (@Sendable (PersonalRecordsBackfillUpdate) -> Void)? = nil
    ) async -> PersonalRecordsBackfillResult {
        let workoutIDs = (try? loadOrCreateManifest())?.workoutIDs ?? []
        var computed = 0
        var skipped = 0
        var failed = 0
        var saveFailures = 0

        for (index, workoutID) in workoutIDs.enumerated() {
            if Task.isCancelled { break }

            // Yield so concurrent library operations interleave with a long
            // backfill instead of waiting for the whole pass.
            await Task.yield()
            if Task.isCancelled { break }

            guard var workout = try? store.loadWorkout(id: workoutID) else {
                failed += 1
                continue
            }
            let name = workout.displayName
            if workout.personalRecords != nil {
                skipped += 1
                progress?(PersonalRecordsBackfillUpdate(
                    completedCount: index + 1,
                    totalCount: workoutIDs.count,
                    currentWorkoutName: name,
                    computedWorkout: nil
                ))
                continue
            }

            let elevationProfile = ElevationProfile(
                routePoints: workout.routePoints,
                policy: policy
            )
            let context = WorkoutAnalysisContext(
                routePoints: workout.routePoints,
                elevationProfile: elevationProfile
            )
            do {
                let detection = try SegmentDetector.detectSegmentsAndPersonalRecords(
                    from: workout,
                    context: context,
                    policy: policy,
                    isCancelled: { Task.isCancelled }
                )
                workout.personalRecords = WorkoutPersonalRecords(
                    windows: detection.records
                )
            } catch is CancellationError {
                // Not a failure: the marker stays unset so the next pass
                // recomputes this workout, and everything already saved
                // stays saved.
                break
            } catch {
                // An engine contract failure: leave this workout's marker
                // unset so a later pass retries it.
                failed += 1
                continue
            }

            do {
                try store.saveWorkout(workout)
            } catch {
                // Keep the in-memory update applicable but disclose that the
                // disk snapshot is still missing records; the next launch's
                // backfill retries it.
                saveFailures += 1
            }
            computed += 1
            progress?(PersonalRecordsBackfillUpdate(
                completedCount: index + 1,
                totalCount: workoutIDs.count,
                currentWorkoutName: name,
                computedWorkout: workout
            ))
        }

        return PersonalRecordsBackfillResult(
            computedCount: computed,
            skippedCount: skipped,
            failedCount: failed,
            saveFailureCount: saveFailures
        )
    }

    // MARK: - Training load backfill

    /// One training-load backfill step, reported after each workout so
    /// callers can apply updated snapshots incrementally.
    public struct TrainingLoadBackfillUpdate: Sendable, Equatable {
        public let completedCount: Int
        public let totalCount: Int
        public let currentWorkoutName: String
        /// The freshly computed snapshot to apply in memory, or `nil` when
        /// this workout already carried a current load and was only counted.
        public let computedWorkout: RunWorkout?

        public init(
            completedCount: Int,
            totalCount: Int,
            currentWorkoutName: String,
            computedWorkout: RunWorkout?
        ) {
            self.completedCount = completedCount
            self.totalCount = totalCount
            self.currentWorkoutName = currentWorkoutName
            self.computedWorkout = computedWorkout
        }
    }

    /// Final totals for one training-load backfill pass.
    public struct TrainingLoadBackfillResult: Sendable, Equatable {
        public let computedCount: Int
        public let skippedCount: Int
        /// Workouts a compute failure left with their previous (or absent)
        /// load. A cancelled pass never adds to this.
        public let failedCount: Int
        public let saveFailureCount: Int

        public init(
            computedCount: Int,
            skippedCount: Int,
            failedCount: Int,
            saveFailureCount: Int
        ) {
            self.computedCount = computedCount
            self.skippedCount = skippedCount
            self.failedCount = failedCount
            self.saveFailureCount = saveFailureCount
        }
    }

    /// Compute and persist the heart-rate training load for every library
    /// workout whose snapshot is missing one or carries a stale profile.
    ///
    /// One rule covers both targets: a snapshot is current when its stored
    /// `trainingLoad.profile` equals `profile`; absence and a profile
    /// mismatch both mean recompute. New imports and re-analyzed snapshots
    /// already carry a load from the analysis pass (computed with the
    /// analyzer's profile), so after a profile change those loads are stale
    /// by exactly this rule and the pass corrects them. It is idempotent,
    /// cooperative — the calling task's cancellation is checked before every
    /// workout and inside each compute — and yields between workouts so
    /// library operations interleave. Cancellation is never counted as a
    /// failure: completed snapshots stay saved, the interrupted workout
    /// keeps its previous marker, and the pass resumes. It never runs during
    /// library load; callers trigger it explicitly.
    public func backfillTrainingLoad(
        profile: AthleteProfile,
        referenceYear: Int = Calendar.current.component(.year, from: Date()),
        progress: (@Sendable (TrainingLoadBackfillUpdate) -> Void)? = nil
    ) async -> TrainingLoadBackfillResult {
        let workoutIDs = (try? loadOrCreateManifest())?.workoutIDs ?? []
        var computed = 0
        var skipped = 0
        var failed = 0
        var saveFailures = 0

        for (index, workoutID) in workoutIDs.enumerated() {
            if Task.isCancelled { break }

            await Task.yield()
            if Task.isCancelled { break }

            guard var workout = try? store.loadWorkout(id: workoutID) else {
                failed += 1
                continue
            }
            let name = workout.displayName
            if workout.trainingLoad?.isCurrent(for: profile) == true {
                skipped += 1
                progress?(TrainingLoadBackfillUpdate(
                    completedCount: index + 1,
                    totalCount: workoutIDs.count,
                    currentWorkoutName: name,
                    computedWorkout: nil
                ))
                continue
            }

            do {
                let load = try TrainingLoadCalculator.compute(
                    routePoints: workout.routePoints,
                    activeSeconds: workout.summary.totalActiveSeconds,
                    averageSpeedMetersPerSecond: workout.summary.averageSpeedMetersPerSecond > 0
                        ? workout.summary.averageSpeedMetersPerSecond
                        : nil,
                    profile: profile,
                    referenceYear: referenceYear,
                    isCancelled: { Task.isCancelled }
                )
                workout.trainingLoad = load
            } catch is CancellationError {
                // Not a failure: the previous marker stays, everything
                // already saved stays, and the next pass resumes here.
                break
            } catch {
                // Leave the previous (or absent) load so a later pass
                // retries this workout.
                failed += 1
                continue
            }

            do {
                try store.saveWorkout(workout)
            } catch {
                // Keep the in-memory update applicable but disclose that
                // the disk snapshot is still stale; the next pass retries.
                saveFailures += 1
            }
            computed += 1
            progress?(TrainingLoadBackfillUpdate(
                completedCount: index + 1,
                totalCount: workoutIDs.count,
                currentWorkoutName: name,
                computedWorkout: workout
            ))
        }

        return TrainingLoadBackfillResult(
            computedCount: computed,
            skippedCount: skipped,
            failedCount: failed,
            saveFailureCount: saveFailures
        )
    }

    // MARK: - Route groups

    /// Read-only organization snapshot of the persisted manifest. Returns
    /// `nil` when no manifest exists (bundled demos).
    public func organizationSnapshot() -> WorkoutLibraryOrganizationSnapshot? {
        guard let manifest = try? store.loadManifest() else {
            return nil
        }
        return WorkoutLibraryOrganizationSnapshot(
            tags: manifest.tags,
            tagAssignments: manifest.tagAssignments,
            smartCollections: manifest.smartCollections,
            routeGroups: manifest.routeGroups,
            routeGroupAssignments: manifest.routeGroupAssignments
        )
    }


    /// Final totals for one incremental route-group assignment pass.
    ///
    /// `groups` and `assignments` mirror the manifest state the pass
    /// persisted, after merging into the re-read snapshot. The counts
    /// describe the pass itself, not the write: a workout the pass matched
    /// or could not load may have left the library — or had its record
    /// re-decided — while the pass was suspended, in which case no record
    /// is written for it but it is still counted.
    public struct RouteGroupAssignmentPassResult: Sendable, Equatable {
        /// Complete group list after the pass.
        public let groups: [WorkoutRouteGroup]
        /// Complete assignment list after the pass (not just the new ones).
        public let assignments: [WorkoutRouteGroupAssignment]
        /// New workouts that joined an existing group (pass computation;
        /// not all may have been persisted — see the type discussion).
        public let joinedCount: Int
        /// New workouts that founded a new group (pass computation; not
        /// all may have been persisted — see the type discussion).
        public let createdCount: Int
        /// Workouts that could not be loaded in the pass's pre-await scan
        /// and stay unassigned.
        public let failedCount: Int

        public init(
            groups: [WorkoutRouteGroup],
            assignments: [WorkoutRouteGroupAssignment],
            joinedCount: Int,
            createdCount: Int,
            failedCount: Int
        ) {
            self.groups = groups
            self.assignments = assignments
            self.joinedCount = joinedCount
            self.createdCount = createdCount
            self.failedCount = failedCount
        }
    }

    /// Final totals for one full route-group re-cluster pass.
    public struct RouteGroupReclusterPassResult: Sendable, Equatable {
        public let groups: [WorkoutRouteGroup]
        public let assignments: [WorkoutRouteGroupAssignment]
        /// Workouts included in the pass.
        public let workoutCount: Int
        /// Workouts that could not be loaded and stay unassigned.
        public let failedCount: Int

        public init(
            groups: [WorkoutRouteGroup],
            assignments: [WorkoutRouteGroupAssignment],
            workoutCount: Int,
            failedCount: Int
        ) {
            self.groups = groups
            self.assignments = assignments
            self.workoutCount = workoutCount
            self.failedCount = failedCount
        }
    }

    /// Incrementally assigns recently imported workouts to route groups,
    /// matching each only against existing groups' effective representatives.
    ///
    /// The pass is the post-import durability hook: workouts without an
    /// assignment record (the nil marker) are picked up here, and records
    /// produced by the current algorithm version are skipped, so re-running
    /// the pass is idempotent. The manifest is written once at the end of
    /// the pass — a cancelled or crashed pass leaves every one of its
    /// workouts unassigned, and the next pass retries them. The write merges
    /// the pass's route-group output into a re-read manifest snapshot, so
    /// changes committed while the pass was suspended survive it: deletes,
    /// manual decisions (rename, re-pin, merge, deliberate removal), and
    /// groups written by an overlapping pass win over the pass's staler
    /// computation, and a group another writer removed inside the window is
    /// not resurrected — a workout the pass matched into it falls back to
    /// the backlog marker and is re-assigned by the next pass. Cancellation
    /// is cooperative (task cancellation is checked between workouts and
    /// inside matching) and surfaces as `CancellationError`.
    public func assignRouteGroups(
        for workoutIDs: [UUID],
        policy: RouteGroupingPolicy = .default,
        progress: (@Sendable (RouteGroupingPassProgress) -> Void)? = nil
    ) async throws -> RouteGroupAssignmentPassResult {
        try Task.checkCancellation()
        let manifest = try loadOrCreateManifest()
        let representativeLoaderSuspension = routeGroupRepresentativeLoaderSuspension

        // Skip workouts that already carry a current-version record; the
        // pass only ever touches the nil-marker backlog and fresh imports.
        var failed = 0
        var newWorkouts: [RunWorkout] = []
        for workoutID in workoutIDs {
            if Task.isCancelled { throw CancellationError() }
            guard manifest.workoutIDs.contains(workoutID) else {
                failed += 1
                continue
            }
            if let existing = manifest.routeGroupAssignment(forWorkoutID: workoutID),
               existing.algorithmVersion == policy.algorithmVersion {
                continue
            }
            guard let workout = try? store.loadWorkout(id: workoutID) else {
                failed += 1
                continue
            }
            newWorkouts.append(workout)
        }
        guard !newWorkouts.isEmpty else {
            return RouteGroupAssignmentPassResult(
                groups: manifest.routeGroups,
                assignments: manifest.routeGroupAssignments,
                joinedCount: 0,
                createdCount: 0,
                failedCount: failed
            )
        }

        let service = RouteGroupingService()
        let result = try await service.assign(
            newWorkouts: newWorkouts,
            existingGroups: manifest.routeGroups,
            policy: policy,
            progress: progress,
            isCancelled: { Task.isCancelled },
            representativeLoader: { [store, representativeLoaderSuspension] workoutID in
                let workout = try store.loadWorkout(id: workoutID)
                await representativeLoaderSuspension?()
                return workout
            }
        )

        // The matching pass ran outside actor isolation and may have
        // suspended; other actor work — a delete, a manual route-group
        // mutator, or another overlapping assignment pass — can have
        // committed a newer manifest inside that window. Writing the
        // pre-await copy back would clobber it, so merge the pass's
        // route-group output into a re-read snapshot instead. The re-read
        // group list is the base and the pass's groups are upserted by id,
        // so groups only another writer created survive. For a group the
        // pass saw, the re-read copy's user intent wins — the name, the
        // stored derived name, and the pin (with the pin's summary, a
        // consistent pair) come from it —
        // while the pass's own derived summary is deliberately kept for
        // unpinned groups: it was computed over the same membership, and
        // the reconcile step below repairs it if it points at a non-member.
        // A record already re-decided at the current version — a deliberate
        // removal's evaluated-nil marker, a merge's moved members, another
        // pass's write — is not overwritten by the pass's staler
        // computation.
        var current = try loadOrCreateManifest()
        let survivingIDs = Set(current.workoutIDs)
        let currentGroupIDs = Set(current.routeGroups.map(\.id))
        let passGroupsByID = Dictionary(
            result.groups.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        current.routeGroups = current.routeGroups.map { fresh in
            guard var passGroup = passGroupsByID[fresh.id] else { return fresh }
            passGroup.name = fresh.name
            passGroup.derivedName = fresh.derivedName
            passGroup.pinnedRepresentativeWorkoutID = fresh.pinnedRepresentativeWorkoutID
            if fresh.pinnedRepresentativeWorkoutID != nil {
                passGroup.representativeSummary = fresh.representativeSummary
            }
            return passGroup
        }
        // Only groups the pass created (absent pre-await too) keep the
        // pass's copy as their sole description. A group that existed
        // pre-await and is gone from the re-read copy was removed by
        // another writer inside the window — a merge moved its members
        // away, or it emptied out — and must not be resurrected: a workout
        // the pass matched into it keeps a record referencing the missing
        // group, which `migrateToCurrentVersionIfNeeded()` drops to record
        // absence — the backlog marker — so the next pass re-matches it.
        let preAwaitGroupIDs = Set(manifest.routeGroups.map(\.id))
        var appendedGroupIDs = Set<UUID>()
        for group in result.groups
        where !currentGroupIDs.contains(group.id) && !preAwaitGroupIDs.contains(group.id) {
            guard appendedGroupIDs.insert(group.id).inserted else { continue }
            current.routeGroups.append(group)
        }
        for assignment in result.assignments {
            guard survivingIDs.contains(assignment.workoutID) else { continue }
            if let freshRecord = current.routeGroupAssignment(forWorkoutID: assignment.workoutID),
               freshRecord.algorithmVersion == policy.algorithmVersion {
                continue
            }
            current.setRouteGroupAssignment(assignment)
        }
        reconcileTransplantedRouteGroups(in: &current)
        current.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(current)

        return RouteGroupAssignmentPassResult(
            groups: current.routeGroups,
            assignments: current.routeGroupAssignments,
            joinedCount: result.joinedCount,
            createdCount: result.createdCount,
            failedCount: failed
        )
    }

    /// Backfills route-group assignment for every library workout whose
    /// record is missing or produced by an older algorithm version.
    ///
    /// This is the one-off migration for existing libraries (schema v4 adds
    /// no records on decode); new imports instead go through
    /// `assignRouteGroups(for:)` right after their commit. Idempotent by the
    /// same record-version rule.
    public func backfillRouteGroupAssignments(
        policy: RouteGroupingPolicy = .default,
        progress: (@Sendable (RouteGroupingPassProgress) -> Void)? = nil
    ) async throws -> RouteGroupAssignmentPassResult {
        try Task.checkCancellation()
        let manifest = try loadOrCreateManifest()
        let pendingIDs = manifest.workoutIDs.filter { workoutID in
            if let existing = manifest.routeGroupAssignment(forWorkoutID: workoutID) {
                return existing.algorithmVersion != policy.algorithmVersion
            }
            return true
        }
        return try await assignRouteGroups(
            for: pendingIDs,
            policy: policy,
            progress: progress
        )
    }

    /// Recomputes every route group from scratch in one transactional pass.
    ///
    /// Workouts are processed chronologically against effective
    /// representatives — the same greedy rule as incremental assignment.
    /// User names and pinned representatives carry over when the referenced
    /// workout still clusters into a group; deliberate removals are
    /// recomputed. The manifest is replaced with one atomic write only when
    /// the whole pass completes: a cancelled or failed re-cluster leaves the
    /// previous groups untouched.
    public func reclusterRouteGroups(
        policy: RouteGroupingPolicy = .default,
        progress: (@Sendable (RouteGroupingPassProgress) -> Void)? = nil
    ) async throws -> RouteGroupReclusterPassResult {
        try Task.checkCancellation()
        var manifest = try loadOrCreateManifest()

        var workouts: [RunWorkout] = []
        var failed = 0
        for workoutID in manifest.workoutIDs {
            if Task.isCancelled { throw CancellationError() }
            if let workout = try? store.loadWorkout(id: workoutID) {
                workouts.append(workout)
            } else {
                failed += 1
            }
        }

        let service = RouteGroupingService()
        let result = try service.recluster(
            workouts: workouts,
            previousGroups: manifest.routeGroups,
            previousAssignments: manifest.routeGroupAssignments,
            policy: policy,
            progress: progress,
            isCancelled: { Task.isCancelled }
        )

        manifest.routeGroups = result.groups
        manifest.routeGroupAssignments = result.assignments
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)

        return RouteGroupReclusterPassResult(
            groups: manifest.routeGroups,
            assignments: manifest.routeGroupAssignments,
            workoutCount: workouts.count,
            failedCount: failed
        )
    }

    /// Renames a route group. `nil` returns the group to its derived
    /// default name.
    public func renameRouteGroup(id: UUID, name: String?) throws {
        var manifest = try loadOrCreateManifest()
        guard let index = manifest.routeGroups.firstIndex(where: { $0.id == id }) else {
            throw WorkoutLibraryStoreError.routeGroupNotFound(id)
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        manifest.routeGroups[index].name = trimmed.isEmpty ? nil : String(trimmed.prefix(120))
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    /// Merges one route group into another. Members move to the target
    /// group; the target keeps its own name and pin, and its derived
    /// representative only changes when the source's outranks it.
    public func mergeRouteGroups(sourceID: UUID, into targetID: UUID) throws {
        var manifest = try loadOrCreateManifest()
        guard sourceID != targetID else {
            throw WorkoutLibraryStoreError.invalidRouteGroup("Cannot merge a route into itself.")
        }
        guard let sourceIndex = manifest.routeGroups.firstIndex(where: { $0.id == sourceID }) else {
            throw WorkoutLibraryStoreError.routeGroupNotFound(sourceID)
        }
        guard let targetIndex = manifest.routeGroups.firstIndex(where: { $0.id == targetID }) else {
            throw WorkoutLibraryStoreError.routeGroupNotFound(targetID)
        }

        for index in manifest.routeGroupAssignments.indices {
            if manifest.routeGroupAssignments[index].groupID == sourceID {
                manifest.routeGroupAssignments[index] = WorkoutRouteGroupAssignment(
                    workoutID: manifest.routeGroupAssignments[index].workoutID,
                    groupID: targetID,
                    algorithmVersion: manifest.routeGroupAssignments[index].algorithmVersion
                )
            }
        }
        let sourceSummary = manifest.routeGroups[sourceIndex].representativeSummary
        if manifest.routeGroups[targetIndex].pinnedRepresentativeWorkoutID == nil,
           let sourceSummary,
           let targetSummary = manifest.routeGroups[targetIndex].representativeSummary,
           sourceSummary.ranksAbove(targetSummary) {
            manifest.routeGroups[targetIndex].representativeSummary = sourceSummary
        }
        manifest.routeGroups.remove(at: sourceIndex)
        manifest.sortRouteGroupAssignmentsDeterministically()
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    /// Removes one workout from its route group. The workout's record keeps
    /// a `nil` group ID — evaluated and deliberately ungrouped — so no later
    /// incremental pass silently re-adds it (only a full re-cluster
    /// recomputes removals). An emptied group is removed.
    public func removeWorkoutFromRouteGroup(workoutID: UUID) throws {
        var manifest = try loadOrCreateManifest()
        guard let assignment = manifest.routeGroupAssignment(forWorkoutID: workoutID),
              let groupID = assignment.groupID,
              let groupIndex = manifest.routeGroups.firstIndex(where: { $0.id == groupID })
        else {
            return
        }

        manifest.setRouteGroupAssignment(WorkoutRouteGroupAssignment(
            workoutID: workoutID,
            groupID: nil,
            algorithmVersion: RouteGroupingPolicy.default.algorithmVersion
        ))

        // Repair the group's cached representative when the removed workout
        // was it, by rescanning the remaining members' snapshots. Bounded by
        // one group's membership; a manual action can afford it.
        let remainingMemberIDs = manifest.routeGroupMemberIDs(groupID: groupID)
        if remainingMemberIDs.isEmpty {
            manifest.routeGroups.remove(at: groupIndex)
        } else {
            if manifest.routeGroups[groupIndex].pinnedRepresentativeWorkoutID == workoutID {
                manifest.routeGroups[groupIndex].pinnedRepresentativeWorkoutID = nil
            }
            let needsNewRepresentative =
                manifest.routeGroups[groupIndex].representativeSummary?.workoutID == workoutID
                || manifest.routeGroups[groupIndex].representativeSummary == nil
            if needsNewRepresentative, let replacement = bestSummary(
                amongWorkoutIDs: remainingMemberIDs,
                in: manifest
            ) {
                manifest.routeGroups[groupIndex].representativeSummary = replacement
            }
        }

        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    /// Pins one member as the group's representative. The pin overrides the
    /// derived rule until a re-cluster whose recomputed groups no longer
    /// contain the pinned workout.
    public func pinRouteGroupRepresentative(groupID: UUID, workoutID: UUID) throws {
        var manifest = try loadOrCreateManifest()
        guard let groupIndex = manifest.routeGroups.firstIndex(where: { $0.id == groupID }) else {
            throw WorkoutLibraryStoreError.routeGroupNotFound(groupID)
        }
        guard manifest.routeGroupID(forWorkoutID: workoutID) == groupID else {
            throw WorkoutLibraryStoreError.invalidRouteGroup(
                "Only a member of the route can be its representative."
            )
        }
        guard let workout = try? store.loadWorkout(id: workoutID) else {
            throw WorkoutLibraryStoreError.workoutNotInLibrary(workoutID)
        }

        manifest.routeGroups[groupIndex].pinnedRepresentativeWorkoutID = workoutID
        manifest.routeGroups[groupIndex].representativeSummary = WorkoutRouteGroupSummary(
            workoutID: workoutID,
            startDate: WorkoutLibraryEntry.canonicalStartDate(for: workout),
            facts: RouteGroupingRouteFacts(workout: workout)
        )
        manifest.migrateToCurrentVersionIfNeeded()
        try store.saveManifest(manifest)
    }

    /// Reconciles route-group state transplanted from an assignment pass
    /// that ran across a suspension against the manifest's final
    /// assignment set: records of workouts that left the library are
    /// dropped, a group with no members left is removed, and a pin or
    /// cached representative summary referencing a workout that is not a
    /// member — deleted, or deliberately ungrouped while the pass was
    /// suspended — is repaired with `bestSummary` over the surviving
    /// members, the same primitives `deleteWorkout`'s repair path uses.
    private func reconcileTransplantedRouteGroups(
        in manifest: inout WorkoutLibraryManifest
    ) {
        let presentIDs = Set(manifest.workoutIDs)
        manifest.routeGroupAssignments.removeAll { !presentIDs.contains($0.workoutID) }
        var memberSetsByGroupID: [UUID: Set<UUID>] = [:]
        memberSetsByGroupID.reserveCapacity(manifest.routeGroups.count)
        for assignment in manifest.routeGroupAssignments {
            guard let groupID = assignment.groupID else { continue }
            memberSetsByGroupID[groupID, default: []].insert(assignment.workoutID)
        }
        var survivingGroups: [WorkoutRouteGroup] = []
        survivingGroups.reserveCapacity(manifest.routeGroups.count)
        for group in manifest.routeGroups {
            guard let members = memberSetsByGroupID[group.id], !members.isEmpty else { continue }
            var reconciled = group
            if let pinned = reconciled.pinnedRepresentativeWorkoutID,
               !members.contains(pinned) {
                reconciled.pinnedRepresentativeWorkoutID = nil
            }
            if let summary = reconciled.representativeSummary,
               !members.contains(summary.workoutID) {
                reconciled.representativeSummary = bestSummary(
                    amongWorkoutIDs: manifest.workoutIDs.filter { members.contains($0) },
                    in: manifest
                )
            }
            survivingGroups.append(reconciled)
        }
        manifest.routeGroups = survivingGroups
        manifest.sortRouteGroupAssignmentsDeterministically()
    }

    /// Derives the best representative summary among the given member IDs by
    /// loading their snapshots. Returns `nil` when none can be loaded.
    private func bestSummary(
        amongWorkoutIDs workoutIDs: [UUID],
        in manifest: WorkoutLibraryManifest
    ) -> WorkoutRouteGroupSummary? {
        var best: WorkoutRouteGroupSummary?
        for workoutID in workoutIDs {
            guard let workout = try? store.loadWorkout(id: workoutID) else { continue }
            let summary = WorkoutRouteGroupSummary(
                workoutID: workoutID,
                startDate: WorkoutLibraryEntry.canonicalStartDate(for: workout),
                facts: RouteGroupingRouteFacts(workout: workout)
            )
            if best == nil || summary.ranksAbove(best!) {
                best = summary
            }
        }
        return best
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
        let normalized: WorkoutTagPolicy.NormalizedName
        do {
            try policy.validateCanCreate(existingCount: manifest.tags.count)
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
        let normalized: WorkoutSmartCollectionPolicy.NormalizedName
        do {
            try policy.validateCanCreate(existingCount: manifest.smartCollections.count)
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
        // Mutations operate on the same repaired shape that loadLibrary
        // publishes. This prevents malformed duplicate IDs from reaching the
        // reorder dictionaries and keeps dangling organisation references from
        // being carried into a later write.
        manifest.migrateToCurrentVersionIfNeeded()
        return manifest
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
