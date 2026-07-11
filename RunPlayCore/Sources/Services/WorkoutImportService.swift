import Foundation

/// Protocol for asynchronous workout import.
///
/// Parsing is performed off the caller's actor, so large files do not
/// block the main thread.
public protocol WorkoutImportServicing: Sendable {
    func importWorkout(from url: URL) async throws -> RunWorkout
}

/// Actor-based import service that moves file parsing off the main actor.
///
/// The underlying parsers (GPX, TCX, FIT, JSON) remain internally synchronous.
/// The actor ensures they never execute on `@MainActor`.
public actor WorkoutImportService: WorkoutImportServicing {

    public init() {}

    /// Parse a workout file off the main actor.
    ///
    /// - Parameter url: Local file URL to import.
    /// - Returns: The parsed `RunWorkout`.
    /// - Throws: `WorkoutImportError` or `WorkoutLibraryError` on failure.
    public func importWorkout(from url: URL) async throws -> RunWorkout {
        try WorkoutImporterFactory.importWorkout(from: url)
    }
}
