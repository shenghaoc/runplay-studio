import Foundation

/// Imports workouts from FIT (Flexible and Interoperable Data Transfer) files.
///
/// This is a placeholder implementation. FIT is a binary format that requires
/// a dedicated parser. Will be implemented in a future phase.
struct FITImporter: WorkoutImporting {
    var supportedExtensions: [String] { ["fit"] }

    func importWorkout(from url: URL) throws -> RunWorkout {
        throw WorkoutImportError.unsupportedFormat("FIT import not yet implemented")
    }
}
