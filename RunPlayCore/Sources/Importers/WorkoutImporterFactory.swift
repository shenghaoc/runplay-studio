import Foundation

/// Factory for creating workout importers based on file extension.
public struct WorkoutImporterFactory {

    public init() {}
    private static let importers: [WorkoutImporting] = [
        JSONWorkoutImporter(),
        GPXImporter(),
        TCXImporter(),
        FITImporter()
    ]

    /// Get the appropriate importer for a file URL.
    public static func importer(for url: URL) throws -> WorkoutImporting {
        let ext = url.pathExtension.lowercased()
        return try importer(forExtension: ext)
    }

    /// Get the appropriate importer for a file extension (no leading dot).
    public static func importer(forExtension ext: String) throws -> WorkoutImporting {
        let normalized = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let importer = importers.first(where: { $0.supportedExtensions.contains(normalized) }) else {
            throw WorkoutImportError.unsupportedFormat(normalized)
        }
        return importer
    }

    /// All supported file extensions.
    public static var supportedExtensions: [String] {
        importers.flatMap { $0.supportedExtensions }
    }

    /// Import a workout from any supported file format (local URL path).
    public static func importWorkout(from url: URL) throws -> RunWorkout {
        let importer = try self.importer(for: url)
        var workout = try importer.importWorkout(from: url)
        if workout.importProvenance == nil {
            workout.importProvenance = WorkoutImportProvenance(
                provider: .singleFile,
                originalFilename: url.lastPathComponent
            )
        }
        return workout
    }

    /// Import a workout from in-memory activity bytes.
    ///
    /// Used by archive import so entries are never written to arbitrary temp files
    /// solely to reuse URL APIs. Does not access the filesystem.
    public static func importWorkout(from input: WorkoutImportInput) throws -> RunWorkout {
        let importer = try self.importer(forExtension: input.fileExtension)
        var workout = try importer.importWorkout(from: input)
        if let provenance = input.provenance {
            workout.importProvenance = provenance
        } else if workout.importProvenance == nil {
            workout.importProvenance = WorkoutImportProvenance(
                provider: .singleFile,
                originalFilename: input.suggestedName
            )
        }
        return workout
    }
}
