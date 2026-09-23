import Foundation
import RunPlayCore

/// Watch-folder import execution on AppState.
///
/// The coordinator owns detection, settling, ledgering, and the recent-
/// imports panel; this extension owns the actual import through the same
/// pipeline a manual single-file import uses. It deliberately never sets
/// `operationState`, `errorMessage`, or `showingError`: watch-folder
/// results surface non-modally, and errors never spam alerts.
extension AppState {

    /// Import one settled watch-folder file through the existing pipeline.
    ///
    /// Behaviour by outcome:
    /// - Parse/persist success: training-load restamp, `addWorkout`, library
    ///   refresh, per-folder default tag, exactly the manual path minus the
    ///   modal state and selection change.
    /// - Multi-session FIT: returns `.awaitingReview` without importing; the
    ///   coordinator queues the file and the banner offers the existing
    ///   review sheet.
    /// - Duplicate workout identity: skipped, matching the manual path's
    ///   behaviour through `addWorkout`'s replace-by-id semantics — but the
    ///   watch path records a skip instead of silently replacing.
    /// - Any failure: a structured failed record and no alert. Speech is owned
    ///   by the coordinator, which announces one aggregate result per scan
    ///   pass — this extension deliberately never announces per file.
    func performWatchFolderImport(
        from url: URL,
        configuration: WatchFolderConfiguration
    ) async -> WatchFolderExecutionResult {
        guard let importService, let storeActor else {
            return .failed("Watch-folder import is unavailable in this session.")
        }

        // Multi-session FIT containers need the review sheet; queue them
        // instead of blocking on a modal from a background scan.
        if url.pathExtension.lowercased() == "fit",
           await watchFolderFITNeedsReview(at: url) {
            return .awaitingReview
        }

        let filename = url.lastPathComponent
        do {
            var workout = try await importService.importWorkout(from: url)
            try Task.checkCancellation()
            workout = try await Self.correctImportedElevation(of: workout, with: demImportCorrection)
            try Task.checkCancellation()
            workout.trainingLoad = try recomputeTrainingLoad(
                for: workout,
                profile: athleteProfile
            )
            try await storeActor.addWorkout(workout, select: false)
            try Task.checkCancellation()
            analysisContextCache.removeValue(forKey: workout.id)

            if !hasPersistedLibrary || libraryWorkoutIDs.isEmpty {
                analysisContextCache.removeAll()
                workouts = [workout]
                libraryWorkoutIDs = [workout.id]
            } else if let existingIndex = workouts.firstIndex(where: { $0.id == workout.id }) {
                workouts[existingIndex] = workout
                libraryWorkoutIDs.insert(workout.id)
            } else {
                workouts.append(workout)
                libraryWorkoutIDs.insert(workout.id)
            }
            hasPersistedLibrary = true
            bumpPersonalRecordsLibraryRevision()
            workoutLibrary.replaceLibrary(
                workouts: workouts,
                favoriteIDs: favoriteWorkoutIDs,
                organization: currentOrganizationSnapshot()
            )
            startRouteGroupAssignment(for: [workout.id])
            requestSessionSave()

            if !configuration.defaultTagName.isEmpty {
                await applyWatchFolderTag(
                    name: configuration.defaultTagName,
                    workoutID: workout.id
                )
            }
            return .imported(detail: workout.demElevationCorrection?.importSummary(
                recordedAltitudeSensor: workout.recordedAltitudeSensor
            ))
        } catch is CancellationError {
            return .failed("Import was cancelled.")
        } catch let error as WorkoutImportError {
            return .failed(Self.watchFolderFailureMessage(for: error, filename: filename))
        } catch {
            return .failed("Imported but could not save to your library. \(error.localizedDescription)")
        }
    }

    /// Whether a FIT container requires the multi-session review sheet.
    ///
    /// Uses the existing scan service read-only; a scan failure means the
    /// direct importer should report the parse error, so it reads as "no
    /// review needed".
    private func watchFolderFITNeedsReview(at url: URL) async -> Bool {
        guard let fitSessionService else { return false }
        guard let result = try? await fitSessionService.scanFITFile(
                at: url,
                existingWorkouts: workouts,
                progress: { _ in }
        ) else {
            return false
        }
        return result.routing == .review
    }

    /// Apply (creating once) the folder's default tag to a fresh import.
    private func applyWatchFolderTag(name: String, workoutID: UUID) async {
        guard let storeActor, hasPersistedLibrary else { return }
        do {
            let tag: WorkoutTag
            if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                tag = existing
            } else {
                tag = try await storeActor.createTag(name: name, color: .default)
                tags.append(tag)
            }
            try await storeActor.setTags(
                Set([tag.id]),
                forWorkoutID: workoutID
            )
            workoutLibrary.applyWorkoutTagChange(
                workoutID: workoutID,
                tagIDs: Set([tag.id])
            )
            requestSessionSave()
        } catch {
            // Tag failure never fails the import itself; the workout is
            // already durable. The panel row stays "imported".
        }
    }

    /// Parse-level wording is shared with the manual import path so the two
    /// cannot drift; only the two cases whose meaning depends on *how* the file
    /// was reached are worded here, because "the selected file" and "import a
    /// file instead" are both wrong for a file that arrived by itself.
    private static func watchFolderFailureMessage(
        for error: WorkoutImportError,
        filename: String
    ) -> String {
        if let shared = AppState.parseLevelImportErrorMessage(for: error, filename: filename) {
            return shared
        }
        switch error {
        case .unsupportedFormat(let ext):
            return "'\(filename)' uses the .\(ext) format, which isn't supported. Watch folders import GPX, TCX, FIT, and JSON files."
        case .fileNotFound:
            return "'\(filename)' disappeared before it could be imported."
        case .parsingError, .missingData, .invalidFormat:
            // Unreachable: handled by the shared helper above.
            return "'\(filename)' could not be imported."
        }
    }

    /// Present the existing multi-session FIT review sheet for a queued
    /// watch-folder file (banner "Review…" action). Returns true when the
    /// sheet was presented.
    @discardableResult
    func presentWatchFolderFITReview(for url: URL) async -> Bool {
        await presentFITSessionReviewIfNeeded(from: url)
    }
}
