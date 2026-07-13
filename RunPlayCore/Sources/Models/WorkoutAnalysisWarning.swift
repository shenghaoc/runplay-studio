import Foundation

/// Non-fatal source validation warnings retained with an analyzed workout.
public enum WorkoutAnalysisWarning: String, Codable, Hashable, Sendable {
    case sourceElapsedTimeMismatch = "The FIT session elapsed time differs from the recorded route; route timestamps were used."
    case sourceActiveTimeMismatch = "The FIT session timer time differs from the recorded route; route segments were used."

    public var message: String { rawValue }
}
