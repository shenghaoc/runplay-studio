import Foundation

/// Imports workouts from TCX (Training Center XML) files.
///
/// This is a scaffold implementation. Full TCX parsing will be added in a future phase.
struct TCXImporter: WorkoutImporting {
    var supportedExtensions: [String] { ["tcx"] }

    func importWorkout(from url: URL) throws -> RunWorkout {
        throw WorkoutImportError.unsupportedFormat("TCX import not yet implemented")
    }
}
