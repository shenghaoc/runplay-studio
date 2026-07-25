import Foundation

/// File-backed implementation of `WorkoutLibraryStoring`.
///
/// Layout on disk:
/// ```
/// <library-root>/
///   manifest.json
///   workouts/
///     <workout-uuid>.json
/// ```
///
/// All writes use `Data.write(to:options:.atomic)` which performs
/// atomic replacement internally, so a crash mid-write never leaves
/// a half-written destination file.
///
/// Note: All I/O is synchronous. The library stores small JSON files
/// (typically a few KB each), so this is acceptable for the current
/// use case. If large datasets or frequent concurrent access arise,
/// consider moving to async I/O with structured concurrency.
public final class FileWorkoutLibraryStore: WorkoutLibraryStoring, @unchecked Sendable {

    private let rootURL: URL
    private let workoutsDirectory: URL
    private let manifestURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Create a store rooted at the given directory.
    ///
    /// - Parameters:
    ///   - rootURL: Directory that will contain `manifest.json` and `workouts/`.
    ///   - fileManager: Injectable for testing.
    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.workoutsDirectory = rootURL.appendingPathComponent("workouts", isDirectory: true)
        self.manifestURL = rootURL.appendingPathComponent("manifest.json")
        self.fileManager = fileManager

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Directory Setup

    /// Ensure the root and workouts directories exist.
    public func ensureDirectoriesExist() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workoutsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Manifest

    public func loadManifest() throws -> WorkoutLibraryManifest {
        guard manifestURL.isFileURL else {
            throw WorkoutLibraryError.manifestCorrupted("Only local file URLs are supported")
        }

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw WorkoutLibraryError.manifestMissing("No manifest at \(manifestURL.path)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw WorkoutLibraryError.manifestCorrupted("Cannot read manifest: \(error.localizedDescription)")
        }

        let manifest: WorkoutLibraryManifest
        do {
            manifest = try decoder.decode(WorkoutLibraryManifest.self, from: data)
        } catch {
            throw WorkoutLibraryError.manifestCorrupted("Cannot decode manifest: \(error.localizedDescription)")
        }

        guard WorkoutLibraryManifest.isSupportedSchemaVersion(manifest.version) else {
            throw WorkoutLibraryError.unsupportedSchemaVersion(manifest.version)
        }

        var migrated = manifest
        migrated.upgradeSchemaVersionIfNeeded()
        // Keep dangling favourite IDs visible to WorkoutLibraryStoreActor so
        // library recovery can remove and atomically persist them. Saves
        // always sanitize favourites before writing the manifest.
        return migrated
    }

    public func saveManifest(_ manifest: WorkoutLibraryManifest) throws {
        try ensureDirectoriesExist()

        var toSave = manifest
        toSave.migrateToCurrentVersionIfNeeded()

        let data: Data
        do {
            data = try encoder.encode(toSave)
        } catch {
            throw WorkoutLibraryError.writeFailed("Cannot encode manifest: \(error.localizedDescription)")
        }

        try atomicWrite(data, to: manifestURL)
    }

    // MARK: - Workout Files

    public func loadWorkout(id: UUID) throws -> RunWorkout {
        let url = workoutURL(for: id)

        guard url.isFileURL else {
            throw WorkoutLibraryError.workoutCorrupted(id, "Only local file URLs are supported")
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkoutLibraryError.workoutFileMissing(id)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WorkoutLibraryError.workoutCorrupted(id, "Cannot read file: \(error.localizedDescription)")
        }

        do {
            return try decoder.decode(RunWorkout.self, from: data)
        } catch {
            throw WorkoutLibraryError.workoutCorrupted(id, "Cannot decode: \(error.localizedDescription)")
        }
    }

    public func saveWorkout(_ workout: RunWorkout) throws {
        try ensureDirectoriesExist()

        let data: Data
        do {
            data = try encoder.encode(workout)
        } catch {
            throw WorkoutLibraryError.writeFailed("Cannot encode workout \(workout.id): \(error.localizedDescription)")
        }

        let url = workoutURL(for: workout.id)
        try atomicWrite(data, to: url)
    }

    public func deleteWorkout(id: UUID) throws {
        let url = workoutURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw WorkoutLibraryError.writeFailed("Cannot delete workout \(id): \(error.localizedDescription)")
        }
    }

    public func workoutExists(id: UUID) -> Bool {
        fileManager.fileExists(atPath: workoutURL(for: id).path)
    }

    // MARK: - Helpers

    private func workoutURL(for id: UUID) -> URL {
        workoutsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Write data atomically using Foundation's built-in `.atomic` option.
    private func atomicWrite(_ data: Data, to destination: URL) throws {
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw WorkoutLibraryError.writeFailed("Cannot write to \(destination.path): \(error.localizedDescription)")
        }
    }
}

// MARK: - Batch Staging

extension FileWorkoutLibraryStore {
    public var libraryRootURL: URL { rootURL }

    private var stagingRoot: URL {
        rootURL.appendingPathComponent(".staging", isDirectory: true)
    }

    private func stagingDirectory(batchID: UUID) -> URL {
        stagingRoot.appendingPathComponent(batchID.uuidString, isDirectory: true)
    }

    private func stagedWorkoutURL(id: UUID, batchID: UUID) -> URL {
        stagingDirectory(batchID: batchID).appendingPathComponent("\(id.uuidString).json")
    }

    public func stageWorkout(_ workout: RunWorkout, batchID: UUID) throws {
        let dir = stagingDirectory(batchID: batchID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let data: Data
        do {
            data = try encoder.encode(workout)
        } catch {
            throw WorkoutLibraryError.writeFailed(
                "Cannot encode staged workout \(workout.id): \(error.localizedDescription)"
            )
        }
        try atomicWrite(data, to: stagedWorkoutURL(id: workout.id, batchID: batchID))
    }

    public func loadStagedWorkout(id: UUID, batchID: UUID) throws -> RunWorkout {
        let url = stagedWorkoutURL(id: id, batchID: batchID)
        guard url.isFileURL else {
            throw WorkoutLibraryError.workoutCorrupted(id, "Only local file URLs are supported")
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkoutLibraryError.workoutFileMissing(id)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WorkoutLibraryError.workoutCorrupted(id, "Cannot read staged file: \(error.localizedDescription)")
        }
        do {
            return try decoder.decode(RunWorkout.self, from: data)
        } catch {
            throw WorkoutLibraryError.workoutCorrupted(id, "Cannot decode staged file: \(error.localizedDescription)")
        }
    }

    public func promoteStagedWorkouts(ids: [UUID], batchID: UUID) throws {
        try ensureDirectoriesExist()
        var moved: [UUID] = []
        do {
            for id in ids {
                let source = stagedWorkoutURL(id: id, batchID: batchID)
                let dest = workoutURL(for: id)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw WorkoutLibraryError.workoutFileMissing(id)
                }
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.moveItem(at: source, to: dest)
                moved.append(id)
            }
        } catch {
            // Best-effort rollback of moved files for this promote call.
            for id in moved {
                let dest = workoutURL(for: id)
                let source = stagedWorkoutURL(id: id, batchID: batchID)
                if fileManager.fileExists(atPath: dest.path) {
                    try? fileManager.moveItem(at: dest, to: source)
                }
            }
            if let libraryError = error as? WorkoutLibraryError {
                throw libraryError
            }
            throw WorkoutLibraryError.writeFailed("Promote failed: \(error.localizedDescription)")
        }
    }

    public func removeStaging(batchID: UUID) throws {
        let dir = stagingDirectory(batchID: batchID)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        do {
            try fileManager.removeItem(at: dir)
        } catch {
            throw WorkoutLibraryError.writeFailed(
                "Cannot remove staging \(batchID): \(error.localizedDescription)"
            )
        }
        // Remove empty .staging root when possible.
        if let contents = try? fileManager.contentsOfDirectory(atPath: stagingRoot.path),
           contents.isEmpty {
            try? fileManager.removeItem(at: stagingRoot)
        }
    }

    public func cleanupStaleStaging() throws {
        guard fileManager.fileExists(atPath: stagingRoot.path) else { return }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw WorkoutLibraryError.writeFailed(
                "Cannot list staging root: \(error.localizedDescription)"
            )
        }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
        try? fileManager.removeItem(at: stagingRoot)
    }

    public func cleanupUnreferencedWorkoutFiles(referencedIDs: Set<UUID>) throws {
        guard fileManager.fileExists(atPath: workoutsDirectory.path) else { return }
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: workoutsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw WorkoutLibraryError.writeFailed(
                "Cannot list workouts directory: \(error.localizedDescription)"
            )
        }
        for file in files where file.pathExtension.lowercased() == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name) else { continue }
            if !referencedIDs.contains(id) {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
