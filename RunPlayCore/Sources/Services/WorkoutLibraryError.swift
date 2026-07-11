import Foundation

/// Errors that can occur during workout library operations.
public enum WorkoutLibraryError: Error, LocalizedError, Equatable {
    /// The manifest file is missing or unreadable.
    case manifestMissing(String)
    /// The manifest data is corrupted or has an unsupported schema version.
    case manifestCorrupted(String)
    /// A workout file referenced by the manifest is missing.
    case workoutFileMissing(UUID)
    /// A workout file is corrupted and cannot be decoded.
    case workoutCorrupted(UUID, String)
    /// A file write failed.
    case writeFailed(String)
    /// The schema version is not supported by this app.
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing(let detail):
            return "Library manifest missing: \(detail)"
        case .manifestCorrupted(let detail):
            return "Library manifest corrupted: \(detail)"
        case .workoutFileMissing(let id):
            return "Workout file missing for ID: \(id)"
        case .workoutCorrupted(let id, let detail):
            return "Workout \(id) corrupted: \(detail)"
        case .writeFailed(let detail):
            return "Write failed: \(detail)"
        case .unsupportedSchemaVersion(let v):
            return "Unsupported library schema version: \(v)"
        }
    }
}
