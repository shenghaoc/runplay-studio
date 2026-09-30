import Foundation
import RunPlayCore
import RunPlayPlatform

/// Apple Health export review and import.
///
/// The third batch sheet, using the same seams as the other two: a scan owned by
/// `RunPlayPlatform`, a review owned by `RunPlayStudio`, and
/// `beginBatchImport` / `stageWorkout` / `commitBatchImport` for persistence.
/// Nothing here adds a second way for a workout to reach the library, and
/// cancellation is cooperative — the sheet asks, the service stops between
/// candidates, and a pass that does not commit is rolled back.
extension AppState {

    /// The importer for the configured reader, or nil when the sheet is
    /// unavailable. The service is stateless beyond the reader it borrows, so it
    /// is derived per pass rather than stored a second time.
    var appleHealthImportService: AppleHealthImportService? {
        appleHealthArchiveService.map(AppleHealthImportService.init(archiveService:))
    }

    /// Begin scanning a user-selected Apple Health `export.zip`.
    ///
    /// The whole document is read before anything is offered, so a corrupt or
    /// foreign ZIP is refused with an error instead of opening a sheet that
    /// could not be acted on.
    func beginAppleHealthImport(from url: URL) {
        // Mutual exclusion with the other batch sheets and with single-file
        // import: they all take the library's batch lock, and two reviews at
        // once would let a user commit one while cancelling the other.
        guard operationState == .idle,
              appleHealthSession == nil,
              archiveSession == nil,
              fitSessionImportSession == nil
        else { return }
        guard let scanService = appleHealthArchiveService, storeActor != nil else {
            errorMessage = "Apple Health import is unavailable in this session."
            showingError = true
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        let filename = url.lastPathComponent
        // The operation-state vocabulary is deliberately unchanged: this is an
        // archive scan, and the sheet owns its own wording. Adding cases here
        // would touch every switch over the state for no user-visible gain.
        operationState = .scanningArchive(filename: filename)

        appleHealthTask?.cancel()
        appleHealthTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanService.scan(
                    archiveAt: url,
                    existingLibraryRuns: AppleHealthLibraryRunWindow.windows(for: self.workouts)
                )
                guard !Task.isCancelled else {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    self.operationState = .idle
                    return
                }
                self.presentAppleHealthReview(result, archiveURL: url, securityScoped: accessing)
                self.operationState = .idle
            } catch is CancellationError {
                if accessing { url.stopAccessingSecurityScopedResource() }
                self.operationState = .idle
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                self.operationState = .idle
                self.errorMessage = error.localizedDescription
                self.showingError = true
                self.announcementPolicy.handle(.importFailed(message: error.localizedDescription))
            }
        }
    }

    /// Present a finished scan as a review.
    ///
    /// Split from the scan so the sheet's selection rules can be exercised
    /// without a ZIP: this is the seam the scan path uses in production and the
    /// one tests hand a scan result to directly.
    func presentAppleHealthReview(
        _ result: AppleHealthArchiveScanResult,
        archiveURL: URL,
        securityScoped: Bool
    ) {
        appleHealthSession = AppleHealthImportSession(
            archiveURL: archiveURL,
            scanResult: result,
            securityScoped: securityScoped
        )
    }

    /// Import the candidates currently checked in the review sheet.
    func confirmAppleHealthImport() {
        guard let session = appleHealthSession,
              let importService = appleHealthImportService,
              let storeActor,
              session.phase == .reviewing,
              !session.selectedIDs.isEmpty
        else { return }

        // Export order, not selection order: the review lists the export's own
        // order, and the library should receive the batch the same way round.
        let selection = session.candidates.filter { session.selectedIDs.contains($0.id) }
        let archiveURL = session.archiveURL
        let scan = session.scanResult
        let completedName = session.archiveName
        let existing = workouts

        operationState = .importingArchive
        session.phase = .importing
        session.progress = AppleHealthImportProgress(phase: .importing, totalCount: selection.count)

        appleHealthTask?.cancel()
        appleHealthTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await importService.importSelection(
                    selection,
                    from: scan,
                    archiveAt: archiveURL,
                    existingWorkouts: existing,
                    storeActor: storeActor,
                    progress: { progress in
                        await MainActor.run { self.appleHealthSession?.progress = progress }
                    },
                    // The Cancel button cancels this task, so the service's own
                    // probe is the task's own state. Passing it explicitly lets
                    // the loop stop between candidates even when an actor hop
                    // delays the next cooperative check.
                    isCancelled: { Task.isCancelled }
                )

                await self.finishBatchSheetImport(
                    wasCancelled: report.wasCancelled,
                    commitFailed: report.commitFailed,
                    importedCount: report.importedCount,
                    errorMessage: report.errorMessage,
                    completedName: completedName,
                    commitFailedFallback: "Could not save the imported workouts.",
                    announceQuietCancel: true,
                    storeActor: storeActor,
                    applyReport: { message in
                        session.report = report
                        session.phase = .report
                        if let message { session.errorMessage = message }
                    },
                    dismissSession: { self.appleHealthSession = nil },
                    onLoadFailure: { message in session.errorMessage = message }
                )
            } catch is CancellationError {
                // Cancelled before anything was staged. The service rolls back
                // on every path that does not commit, so the library is intact
                // and there is nothing to report.
                self.finishBatchSheetTaskCancellation(
                    announce: true,
                    dismissSession: { self.appleHealthSession = nil }
                )
            } catch {
                // An unexpected throw is still reported as a failed import, and
                // it still carries the scan's own loss counts: a report showing
                // zero dropped workouts here would understate what the export
                // held.
                self.finishBatchSheetTaskError(
                    message: error.localizedDescription,
                    applyReport: {
                        session.report = AppleHealthImportReport(
                            commitFailed: true,
                            errorMessage: error.localizedDescription,
                            droppedWorkoutCount: scan.report.droppedWorkoutCount,
                            unmatchedRouteReferenceCount: scan.report.unmatchedRouteReferenceCount,
                            excludedWorkoutsByActivityType: scan.report.excludedWorkoutsByActivityType
                        )
                        session.phase = .report
                        session.errorMessage = error.localizedDescription
                    }
                )
            }
        }
    }

    /// Cancel an in-progress Apple Health scan or import, or close the review.
    func cancelAppleHealthImport() {
        cancelBatchSheet(
            task: &appleHealthTask,
            phase: appleHealthSession.map {
                switch $0.phase {
                case .reviewing: return .reviewing
                case .importing: return .importing
                case .report: return .report
                }
            },
            dismissSession: { appleHealthSession = nil }
        )
    }

    /// Dismiss the Apple Health sheet after a completed report.
    func dismissAppleHealthSession() {
        appleHealthSession = nil
        operationState = .idle
    }

    /// Open the most recently imported workout from the Apple Health report.
    func viewMostRecentAppleHealthImportedRun() {
        guard let report = appleHealthSession?.report,
              let id = report.selectedWorkoutID,
              let workout = workouts.first(where: { $0.id == id }) else {
            dismissAppleHealthSession()
            return
        }
        dismissAppleHealthSession()
        selectWorkout(workout, persistSelection: true)
    }
}
