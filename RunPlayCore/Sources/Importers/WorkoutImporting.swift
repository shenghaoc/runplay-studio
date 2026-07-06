import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Protocol for workout file importers.
public protocol WorkoutImporting {
    /// The file formats this importer supports.
    var supportedExtensions: [String] { get }

    /// Import a workout from a file URL.
    func importWorkout(from url: URL) throws -> RunWorkout
}

/// Errors that can occur during workout import.
public enum WorkoutImportError: Error, LocalizedError {
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
            return "Parsing error: \(detail)"
        case .missingData(let detail):
            return "Missing data: \(detail)"
        case .unsupportedFormat(let ext):
            return "Unsupported format: .\(ext)"
        }
    }
}
