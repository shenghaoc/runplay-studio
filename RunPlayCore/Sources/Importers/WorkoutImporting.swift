import Foundation

/// Protocol for workout file importers.
public protocol WorkoutImporting: Sendable {
    /// The file formats this importer supports.
    var supportedExtensions: [String] { get }

    /// Import a workout from a file URL.
    func importWorkout(from url: URL) throws -> RunWorkout

    /// Import a workout from in-memory activity bytes.
    ///
    /// Default implementation loads nothing from disk. Concrete importers
    /// should parse `input.data` with the same logic as the URL path.
    func importWorkout(from input: WorkoutImportInput) throws -> RunWorkout
}

extension WorkoutImporting {
    public func importWorkout(from input: WorkoutImportInput) throws -> RunWorkout {
        throw WorkoutImportError.unsupportedFormat(input.fileExtension)
    }
}

extension WorkoutImporting {
    /// Validates that a URL is a local file URL and that the file exists.
    /// Call at the top of `importWorkout(from:)` to enforce SSRF prevention.
    public func validateLocalFile(_ url: URL) throws {
        guard url.isFileURL else {
            throw WorkoutImportError.invalidFormat("Only local file URLs are supported")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkoutImportError.fileNotFound(url)
        }
    }
}

/// Errors that can occur during workout import.
public enum WorkoutImportError: Error, LocalizedError, Sendable {
    case fileNotFound(URL)
    case invalidFormat(String)
    case parsingError(String)
    case missingData(String)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .invalidFormat(let detail):
            return "Invalid file format: \(detail)"
        case .parsingError(let detail):
            return "Import error: \(detail)"
        case .missingData(let detail):
            return "Missing data: \(detail)"
        case .unsupportedFormat(let ext):
            return "Unsupported format: .\(ext)"
        }
    }
}
