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
public final class FileWorkoutLibraryStore: WorkoutLibraryStoring {

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

        guard manifest.version == WorkoutLibraryManifest.currentVersion else {
            throw WorkoutLibraryError.unsupportedSchemaVersion(manifest.version)
        }

        return manifest
    }

    public func saveManifest(_ manifest: WorkoutLibraryManifest) throws {
        try ensureDirectoriesExist()

        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw WorkoutLibraryError.writeFailed("Cannot encode manifest: \(error.localizedDescription)")
        }

        try atomicWrite(data, to: manifestURL)
    }

    // MARK: - Workout Files

    public func loadWorkout(id: UUID) throws -> RunWorkout {
        let url = workoutURL(for: id)

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
