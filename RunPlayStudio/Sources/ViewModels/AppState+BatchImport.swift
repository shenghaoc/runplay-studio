import Foundation
import RunPlayCore
import RunPlayPlatform
import SwiftUI

// Batch import (Strava archive + multi-session FIT) lives here so AppState.swift
// stays focused on library/workspace state. Members used by these flows are
// module-internal so this extension can own the lifecycle helpers.

extension AppState {

    // MARK: - Strava Archive Import

    /// Begin scanning a user-selected Strava bulk-export ZIP.
    func beginArchiveImport(from url: URL) {
        // Mutual exclusion with multi-session FIT review / import (same as
        // `importWorkout` guarding `archiveSession`).
        guard operationState == .idle,
              archiveSession == nil,
              fitSessionImportSession == nil
        else { return }
        guard let archiveService, storeActor != nil else {
            errorMessage = "Archive import is unavailable in this session."
            showingError = true
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        let filename = url.lastPathComponent
        operationState = .scanningArchive(filename: filename)

        archiveTask?.cancel()
        archiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let existing = self.workouts
                let result = try await archiveService.scanArchive(
                    at: url,
                    existingWorkouts: existing
                ) { _ in }
                guard !Task.isCancelled else {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    self.operationState = .idle
                    return
                }
                if !result.isRecognizedStravaExport {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    self.operationState = .idle
                    self.errorMessage = result.rejectionMessage
                        ?? "This ZIP does not appear to be a supported Strava bulk export."
                    self.showingError = true
                    self.announcementPolicy.handle(
                        .importFailed(message: self.errorMessage ?? "Unsupported archive.")
                    )
                    return
                }
                self.archiveSession = ArchiveImportSession(
                    archiveURL: url,
                    scanResult: result,
                    securityScoped: accessing
                )
                self.operationState = .idle
            } catch is CancellationError {
                if accessing { url.stopAccessingSecurityScopedResource() }
                self.operationState = .idle
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                self.operationState = .idle
                self.errorMessage = error.localizedDescription
                self.showingError = true
                self.announcementPolicy.handle(
                    .importFailed(message: error.localizedDescription)
                )
            }
        }
    }

    /// Import currently selected archive candidates.
    func confirmArchiveImport() {
        guard let session = archiveSession,
              let archiveService,
              let storeActor,
              session.phase == .reviewing,
              !session.selectedIDs.isEmpty else { return }

        operationState = .importingArchive
        session.phase = .importing
        session.progress = WorkoutBatchImportProgress(
            phase: .importing,
            totalCount: session.selectedIDs.count
        )

        let selection = WorkoutBatchImportSelection(
            selectedCandidateIDs: Array(session.selectedIDs),
            candidates: session.scanResult.candidates
        )
        let archiveURL = session.archiveURL
        let existing = workouts
        let completedName = session.archiveName

        archiveTask?.cancel()
        archiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await archiveService.importCandidates(
                    selection,
                    from: archiveURL,
                    existingWorkouts: existing,
                    storeActor: storeActor
                ) { progress in
                    await MainActor.run {
                        self.archiveSession?.progress = progress
                    }
                }

                await self.finishBatchSheetImport(
                    wasCancelled: report.wasCancelled,
                    commitFailed: report.commitFailed,
                    importedCount: report.importedCount,
                    errorMessage: report.errorMessage,
                    completedName: completedName,
                    commitFailedFallback: "Could not save imported workouts.",
                    // Cancel during import keeps the sheet and announces here
                    // once (review-phase cancel announces in cancelBatchSheet).
                    announceQuietCancel: true,
                    storeActor: storeActor,
                    applyReport: { message in
                        session.report = report
                        session.phase = .report
                        if let message { session.errorMessage = message }
                    },
                    dismissSession: { self.archiveSession = nil },
                    onLoadFailure: { message in session.errorMessage = message }
                )
            } catch is CancellationError {
                self.finishBatchSheetTaskCancellation(
                    announce: true,
                    dismissSession: { self.archiveSession = nil }
                )
            } catch {
                self.finishBatchSheetTaskError(
                    message: error.localizedDescription,
                    applyReport: {
                        session.report = WorkoutBatchImportReport(
                            commitFailed: true,
                            errorMessage: error.localizedDescription
                        )
                        session.phase = .report
                        session.errorMessage = error.localizedDescription
                    }
                )
            }
        }
    }

    /// Cancel an in-progress archive scan or import.
    func cancelArchiveImport() {
        cancelBatchSheet(
            task: &archiveTask,
            phase: archiveSession.map {
                switch $0.phase {
                case .reviewing: return .reviewing
                case .importing: return .importing
                case .report: return .report
                }
            },
            dismissSession: { archiveSession = nil }
        )
    }

    /// Dismiss the archive sheet after a completed report.
    func dismissArchiveSession() {
        archiveSession = nil
        operationState = .idle
    }

    /// Open the most recently imported workout from the archive report.
    func viewMostRecentImportedRun() {
        guard let report = archiveSession?.report,
              let id = report.selectedWorkoutID,
              let workout = workouts.first(where: { $0.id == id }) else {
            dismissArchiveSession()
            return
        }
        dismissArchiveSession()
        selectWorkout(workout, persistSelection: true)
    }

    /// Open personal heatmap after archive import.
    func openHeatmapAfterArchiveImport() {
        dismissArchiveSession()
        showPersonalHeatmap()
    }


    // MARK: - Multi-session FIT import

    /// Scan a FIT file and, when it holds several sessions, open the review
    /// sheet instead of importing directly.
    ///
    /// - Returns: `true` when the caller must stop, either because the review
    ///   sheet is now presented or because the scan was cancelled or rejected
    ///   the file outright. `false` means "continue with the direct import",
    ///   which also produces the canonical parse-error message for a container
    ///   the FIT parser cannot read at all.
    func presentFITSessionReviewIfNeeded(from url: URL) async -> Bool {
        guard let fitSessionService else { return false }

        let filename = url.lastPathComponent
        operationState = .scanningFITFile(filename: filename)
        let existing = workouts

        do {
            let result = try await fitSessionService.scanFITFile(
                at: url,
                existingWorkouts: existing
            ) { _ in }
            try Task.checkCancellation()

            guard result.routing == .review else {
                // Legacy sessionless files and ordinary one-session files keep
                // the existing direct-import flow — no sheet.
                operationState = .idle
                return false
            }

            // The sheet owns security-scoped access for its whole lifetime.
            let accessing = url.startAccessingSecurityScopedResource()
            fitSessionImportSession = FITSessionImportSession(
                fileURL: url,
                scanResult: result,
                securityScoped: accessing
            )
            operationState = .idle
            return true
        } catch is CancellationError {
            operationState = .idle
            announcementPolicy.handle(.importCancelled)
            return true
        } catch let error as FITSessionImportError {
            operationState = .idle
            errorMessage = error.localizedDescription
            showingError = true
            announcementPolicy.handle(.importFailed(message: error.localizedDescription))
            return true
        } catch {
            // Parsing problems fall through so the single-file importer reports
            // them with its established wording.
            operationState = .idle
            return false
        }
    }

    /// Import the sessions currently selected in the FIT review sheet.
    func confirmFITSessionImport() {
        guard let session = fitSessionImportSession,
              let fitSessionService,
              let storeActor,
              session.phase == .reviewing,
              !session.selectedIDs.isEmpty
        else {
            return
        }

        operationState = .importingFITSessions
        session.phase = .importing
        session.progress = WorkoutBatchImportProgress(
            phase: .importing,
            totalCount: session.selectedIDs.count
        )

        let selection = session.makeSelection()
        let fileURL = session.fileURL
        let existing = workouts
        let completedName = session.fileName

        fitImportTask?.cancel()
        fitImportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await fitSessionService.importSessions(
                    selection,
                    from: fileURL,
                    existingWorkouts: existing,
                    storeActor: storeActor
                ) { progress in
                    await MainActor.run {
                        self.fitSessionImportSession?.progress = progress
                    }
                }

                await self.finishBatchSheetImport(
                    wasCancelled: report.wasCancelled,
                    commitFailed: report.commitFailed,
                    importedCount: report.importedCount,
                    errorMessage: report.errorMessage,
                    completedName: completedName,
                    commitFailedFallback: "Could not save the imported sessions.",
                    // Cancel during import does not announce in
                    // `cancelFITSessionImport`; the task completion does.
                    announceQuietCancel: true,
                    storeActor: storeActor,
                    applyReport: { message in
                        session.report = report
                        session.phase = .report
                        if let message { session.errorMessage = message }
                    },
                    dismissSession: { self.fitSessionImportSession = nil },
                    onLoadFailure: { message in session.errorMessage = message }
                )
            } catch is CancellationError {
                self.finishBatchSheetTaskCancellation(
                    announce: true,
                    dismissSession: { self.fitSessionImportSession = nil }
                )
            } catch {
                self.finishBatchSheetTaskError(
                    message: error.localizedDescription,
                    applyReport: {
                        session.report = FITSessionBatchImportReport(
                            commitFailed: true,
                            errorMessage: error.localizedDescription
                        )
                        session.phase = .report
                        session.errorMessage = error.localizedDescription
                    }
                )
            }
        }
    }

    /// Cancel an in-progress FIT session import, or dismiss the review sheet.
    ///
    /// During `.importing`, only requests cooperative cancellation and keeps
    /// the sheet until the task returns a cancelled (or committed) report so
    /// the user always sees a structured outcome. Announcement happens once on
    /// task completion, not here.
    func cancelFITSessionImport() {
        cancelBatchSheet(
            task: &fitImportTask,
            phase: fitSessionImportSession.map {
                switch $0.phase {
                case .reviewing: return .reviewing
                case .importing: return .importing
                case .report: return .report
                }
            },
            dismissSession: { fitSessionImportSession = nil }
        )
    }

    /// Dismiss the FIT sheet after a completed report.
    func dismissFITSessionImport() {
        fitSessionImportSession = nil
        operationState = .idle
    }

    /// Open the newest imported session from the FIT report.
    func viewMostRecentFITImportedRun() {
        guard let report = fitSessionImportSession?.report,
              let id = report.selectedWorkoutID,
              let workout = workouts.first(where: { $0.id == id })
        else {
            dismissFITSessionImport()
            return
        }
        dismissFITSessionImport()
        selectWorkout(workout, persistSelection: true)
    }

    /// Open All Runs after a FIT session import.
    func showAllRunsAfterFITImport() {
        dismissFITSessionImport()
        showWorkoutLibrary(restoreManualQuery: true)
    }

    // MARK: - Shared batch-sheet lifecycle

    /// UI phases shared by Strava archive and multi-session FIT sheets.
    private enum BatchSheetPhase {
        case reviewing
        case importing
        case report
    }

    /// Shared cancel semantics for archive and FIT review sheets.
    ///
    /// During `.importing`, only requests cooperative cancellation and keeps
    /// the sheet until the task returns a structured report. Announcement for
    /// that path happens on task completion (when `announceQuietCancel` is set
    /// on the finish helper). Review-phase cancel dismisses immediately.
    private func cancelBatchSheet(
        task: inout Task<Void, Never>?,
        phase: BatchSheetPhase?,
        dismissSession: () -> Void
    ) {
        task?.cancel()
        task = nil
        switch phase {
        case .importing:
            break
        case .report:
            break
        case .reviewing, nil:
            dismissSession()
            operationState = .idle
            announcementPolicy.handle(.importCancelled)
        }
    }

    /// Shared post-import sheet finish path for archive and FIT batch reports.
    private func finishBatchSheetImport(
        wasCancelled: Bool,
        commitFailed: Bool,
        importedCount: Int,
        errorMessage: String?,
        completedName: String,
        commitFailedFallback: String,
        announceQuietCancel: Bool,
        storeActor: WorkoutLibraryStoreActor,
        applyReport: (_ errorMessage: String?) -> Void,
        dismissSession: () -> Void,
        onLoadFailure: (String) -> Void
    ) async {
        // Cancellation that committed nothing simply closes the sheet.
        if wasCancelled, importedCount == 0, !commitFailed {
            operationState = .idle
            dismissSession()
            if announceQuietCancel {
                announcementPolicy.handle(.importCancelled)
            }
            return
        }

        if commitFailed {
            operationState = .idle
            let message = errorMessage ?? commitFailedFallback
            applyReport(message)
            announcementPolicy.handle(.importFailed(message: message))
            return
        }

        if importedCount > 0 {
            await reloadLibraryAfterBatchCommit(
                storeActor: storeActor,
                onLoadFailure: onLoadFailure
            )
        }

        applyReport(nil)
        operationState = .idle
        if importedCount > 0 {
            announcementPolicy.handle(.importCompleted(name: completedName))
        }
    }

    private func finishBatchSheetTaskCancellation(
        announce: Bool,
        dismissSession: () -> Void
    ) {
        operationState = .idle
        dismissSession()
        if announce {
            announcementPolicy.handle(.importCancelled)
        }
    }

    private func finishBatchSheetTaskError(
        message: String,
        applyReport: () -> Void
    ) {
        operationState = .idle
        applyReport()
        announcementPolicy.handle(.importFailed(message: message))
    }

    /// Reload the authoritative post-commit library state.
    ///
    /// Shared by the archive and FIT batch flows so both surface exactly the
    /// same library, selection, and heatmap behaviour after a commit.
    private func reloadLibraryAfterBatchCommit(
        storeActor: WorkoutLibraryStoreActor,
        onLoadFailure: (String) -> Void
    ) async {
        switch await storeActor.loadLibrary() {
        case .workouts(let loaded, let selectedID, let favoriteIDs, let organization, _):
            analysisContextCache.removeAll()
            workouts = loaded
            favoriteWorkoutIDs = favoriteIDs
            tags = organization.tags
            smartCollections = organization.smartCollections
            libraryWorkoutIDs = Set(loaded.map(\.id))
            hasPersistedLibrary = true
            workoutLibrary.replaceLibrary(
                workouts: loaded,
                favoriteIDs: favoriteIDs,
                organization: organization
            )
            let selected = selectedID.flatMap { id in loaded.first(where: { $0.id == id }) }
                ?? loaded.first
            selectWorkout(selected, persistSelection: false)
            if workspaceMode == .personalHeatmap {
                personalHeatmap.refresh(workouts: loaded)
            }
            requestSessionSave()
        case .demos(let message, let organization, let manifestPresent):
            // Unexpected after a successful commit; fall back without wiping
            // user organisation.
            tags = organization.tags
            smartCollections = organization.smartCollections
            hasPersistedLibrary = manifestPresent
            if let message {
                onLoadFailure(message)
            }
        }
    }
}
