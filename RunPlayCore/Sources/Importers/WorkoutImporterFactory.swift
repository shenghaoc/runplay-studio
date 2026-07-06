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

        guard let importer = importers.first(where: { $0.supportedExtensions.contains(ext) }) else {
            throw WorkoutImportError.unsupportedFormat(ext)
        }

        return importer
    }

    /// All supported file extensions.
    public static var supportedExtensions: [String] {
        importers.flatMap { $0.supportedExtensions }
    }

    /// Import a workout from any supported file format.
    public static func importWorkout(from url: URL) throws -> RunWorkout {
        let importer = try self.importer(for: url)
        return try importer.importWorkout(from: url)
    }
}
