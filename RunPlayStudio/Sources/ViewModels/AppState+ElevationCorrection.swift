import Foundation
import RunPlayCore
import RunPlayPlatform

/// Whether the chosen DEM tile folder is open for reading.
enum DEMFolderStatus: Equatable {
    case notChosen
    case ready
    /// Chosen but not openable now: moved, deleted, or on an unmounted volume.
    case unavailable(String)
}

/// Settings-scene progress for the library-wide elevation pass.
enum DEMCorrectionPassState: Equatable {
    case idle
    case running(completedCount: Int, totalCount: Int, currentWorkoutName: String)
    /// The pass ended; the message totals what it did.
    case finished(String)
}

/// DEM elevation correction: the tile folder, correcting new imports, the
/// manual library pass, and refreshing everything that shows elevation.
extension AppState {
    // MARK: - Tile folder

    /// Opens the folder saved in the settings, if any. Called at start and
    /// whenever the folder or its zoom changes. A refreshed bookmark (the
    /// folder moved) is saved back so the next launch opens it directly.
    func openDEMTileFolder() {
        demFolderAccess = nil
        guard let folder = demTileSettings.folder else {
            demFolderStatus = .notChosen
            return
        }
        do {
            let access = try DEMTileFolderAccess(folder: folder)
            demFolderAccess = access
            demFolderStatus = .ready
            if let refreshed = access.refreshedBookmark {
                var settings = demTileSettings
                settings.folder?.bookmark = refreshed
                saveDEMTileSettings(settings)
            }
        } catch {
            demFolderStatus = .unavailable(
                "The tile folder “\(folder.displayName)” could not be opened. If it moved, choose it again."
            )
        }
    }

    /// Adopts a folder chosen in Settings: scans it for Terrarium tiles, saves
    /// it, and opens it. Returns a message to show when it cannot be used.
    @discardableResult
    func chooseDEMTileFolder(at url: URL) -> String? {
        let described: DEMTileFolder?
        do {
            described = try DEMTileFolderAccess.describeFolder(at: url)
        } catch {
            return "RunPlay Studio could not keep access to that folder."
        }
        guard let folder = described else {
            return "No Terrarium PNG tiles were found. The folder should hold z/x/y.png tiles, such as 13/4265/2903.png."
        }
        var settings = demTileSettings
        settings.folder = folder
        saveDEMTileSettings(settings)
        openDEMTileFolder()
        return nil
    }

    /// Stops using the tile folder. Corrections already made stay until a
    /// run's elevation is corrected again or set back to recorded altitude.
    func forgetDEMTileFolder() {
        var settings = demTileSettings
        settings.folder = nil
        saveDEMTileSettings(settings)
        openDEMTileFolder()
    }

    /// Reads the folder at another of its zooms. Returns a message when that
    /// zoom has no readable tile.
    @discardableResult
    func setDEMTileZoom(_ zoom: Int) -> String? {
        guard var folder = demTileSettings.folder, zoom != folder.zoom,
              folder.availableZooms.contains(zoom),
              let access = demFolderAccess
        else {
            return nil
        }
        guard let tileSize = TerrariumTileDirectory.tileSize(in: access.directory.rootURL, zoom: zoom) else {
            return "No readable Terrarium tile was found at zoom \(zoom)."
        }
        folder.zoom = zoom
        folder.tileSize = tileSize
        var settings = demTileSettings
        settings.folder = folder
        saveDEMTileSettings(settings)
        openDEMTileFolder()
        return nil
    }

    func setDEMCorrectsNewImports(_ correctsNewImports: Bool) {
        var settings = demTileSettings
        settings.correctsNewImports = correctsNewImports
        saveDEMTileSettings(settings)
    }

    private func saveDEMTileSettings(_ settings: DEMTileSettings) {
        demTileSettings = settings
        guard let demSettingsStore else { return }
        do {
            try demSettingsStore.save(settings)
        } catch {
            errorMessage = "Elevation settings could not be saved: \(error.localizedDescription)"
            showingError = true
        }
    }

    // MARK: - New imports

    /// The correction new imports get; `nil` without a folder, with "Correct
    /// new imports" off, or while the folder cannot be opened.
    var demImportCorrection: DEMImportElevationCorrection? {
        guard demTileSettings.correctsImports, let access = demFolderAccess else { return nil }
        return DEMImportElevationCorrection(source: access.directory)
    }

    /// Corrects one freshly imported workout off the main actor. A correction
    /// that cannot finish returns the workout as imported.
    nonisolated static func correctImportedElevation(
        of workout: RunWorkout,
        with correction: DEMImportElevationCorrection?
    ) async throws -> RunWorkout {
        guard let correction else { return workout }
        let task = Task.detached(priority: .userInitiated) { () throws -> RunWorkout in
            var corrected = workout
            try correction.apply(to: &corrected, isCancelled: { Task.isCancelled })
            return corrected
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Library pass

    /// Library runs not yet corrected with the current tile set; opted-out
    /// runs are not counted.
    var demUncorrectedCount: Int {
        guard let tileSet = demTileSettings.tileSet else { return 0 }
        return workouts.count { workout in
            guard libraryWorkoutIDs.contains(workout.id) else { return false }
            guard let record = workout.demElevationCorrection else { return true }
            return record.outcome != .optedOut && record.tileSet != tileSet
        }
    }

    /// Corrects every library run a pass could change. Explicit and
    /// user-triggered only; runs over the resumable store-actor pass, applies
    /// each corrected run in memory as it arrives, and refreshes the views
    /// that show elevation once at the end.
    func correctLibraryElevation() {
        guard demCorrectionTask == nil,
              let storeActor,
              hasPersistedLibrary,
              let access = demFolderAccess
        else {
            return
        }
        demCorrectionPassState = .running(completedCount: 0, totalCount: workouts.count, currentWorkoutName: "")
        // The pass fills the inbox synchronously, so draining it once more at
        // the end applies every corrected run however the hops are ordered.
        let inbox = ElevationPassInbox()
        let source = access.directory
        demCorrectionTask = Task { [weak self] in
            let result = await storeActor.correctElevation(using: source) { update in
                inbox.push(update)
                Task { @MainActor in self?.drainElevationPassInbox(inbox) }
            }
            self?.finishDEMCorrectionPass(result, inbox: inbox)
        }
    }

    /// Stops the pass; corrected runs stay saved and the next pass resumes.
    func cancelDEMCorrectionPass() {
        demCorrectionTask?.cancel()
    }

    private func drainElevationPassInbox(_ inbox: ElevationPassInbox) {
        let drained = inbox.drain()
        if let progress = drained.progress, demCorrectionTask != nil {
            demCorrectionPassState = .running(
                completedCount: progress.completedCount,
                totalCount: progress.totalCount,
                currentWorkoutName: progress.currentWorkoutName ?? ""
            )
        }
        for corrected in drained.workouts {
            if let index = workouts.firstIndex(where: { $0.id == corrected.id }) {
                workouts[index] = corrected
            }
            analysisContextCache.removeValue(forKey: corrected.id)
        }
    }

    private func finishDEMCorrectionPass(
        _ result: WorkoutLibraryStoreActor.DEMElevationPassResult,
        inbox: ElevationPassInbox
    ) {
        drainElevationPassInbox(inbox)
        demCorrectionTask = nil
        let correctedIDs = inbox.correctedIDs
        applyElevationChanges(workouts.filter { correctedIDs.contains($0.id) })
        let summary = Self.demCorrectionPassSummary(result)
        demCorrectionPassState = .finished(summary)
        announcementPolicy.handle(.elevationCorrectionFinished(summary: summary))
    }

    static func demCorrectionPassSummary(_ result: WorkoutLibraryStoreActor.DEMElevationPassResult) -> String {
        func runs(_ count: Int) -> String { "\(count) run\(count == 1 ? "" : "s")" }
        var sentences = ["Corrected \(runs(result.correctedCount)); \(runs(result.skippedCount)) needed no change."]
        if result.failedCount > 0 {
            sentences.append("\(runs(result.failedCount)) could not be corrected and keep their previous elevation.")
        }
        if result.saveFailureCount > 0 {
            sentences.append("\(runs(result.saveFailureCount)) could not be saved; the next pass retries them.")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Refreshing elevation

    /// Applies runs whose elevation changed — a correction written or removed
    /// — to everything that shows elevation: the library and its entries, the
    /// selected and comparison runs (keeping the replay position), and cached
    /// analysis contexts. Trends refreshes now only while it is on screen; its
    /// cache keys on each run's ascent and descent, so it recomputes when it
    /// next opens.
    func applyElevationChanges(_ changed: [RunWorkout]) {
        guard !changed.isEmpty else { return }
        for workout in changed {
            if let index = workouts.firstIndex(where: { $0.id == workout.id }) {
                workouts[index] = workout
            }
            analysisContextCache.removeValue(forKey: workout.id)
            if comparisonWorkout?.id == workout.id {
                comparisonWorkout = workout
            }
        }
        if let selectedID = selectedWorkout?.id,
           let updated = changed.last(where: { $0.id == selectedID }) {
            let replay = replayController.state
            selectedWorkout = updated
            detectedSegments = updated.segments
            selectedSegment = nil
            replayController.restore(
                workout: updated,
                elapsedSeconds: replay.currentTime,
                playbackSpeed: replay.playbackSpeed
            )
        }
        workoutLibrary.replaceLibrary(
            workouts: workouts,
            favoriteIDs: favoriteWorkoutIDs,
            organization: currentOrganizationSnapshot()
        )
        if workspaceMode == .trends {
            refreshTrends()
        }
        requestSessionSave()
    }
}

/// Corrected runs and progress handed from the store-actor pass to the main
/// actor. Drained as updates arrive, so the library never holds two copies
/// of many runs at once.
final class ElevationPassInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [RunWorkout] = []
    private var latest: WorkoutLibraryStoreActor.DEMElevationPassUpdate?
    private var corrected: Set<UUID> = []

    func push(_ update: WorkoutLibraryStoreActor.DEMElevationPassUpdate) {
        lock.withLock {
            if let workout = update.correctedWorkout {
                pending.append(workout)
                corrected.insert(workout.id)
            }
            latest = WorkoutLibraryStoreActor.DEMElevationPassUpdate(
                completedCount: update.completedCount,
                totalCount: update.totalCount,
                currentWorkoutName: update.currentWorkoutName,
                correctedWorkout: nil
            )
        }
    }

    func drain() -> (progress: WorkoutLibraryStoreActor.DEMElevationPassUpdate?, workouts: [RunWorkout]) {
        lock.withLock {
            defer { pending = [] }
            return (latest, pending)
        }
    }

    /// Every run corrected so far, drained or not.
    var correctedIDs: Set<UUID> {
        lock.withLock { corrected }
    }
}
