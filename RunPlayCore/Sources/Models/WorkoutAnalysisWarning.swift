import Foundation

/// Non-fatal source validation warnings retained with an analyzed workout.
public enum WorkoutAnalysisWarning: String, Codable, Hashable, Sendable {
    case sourceElapsedTimeMismatch = "The FIT session elapsed time differs from the recorded route; route timestamps were used."
    case sourceActiveTimeMismatch = "The FIT session timer time differs from the recorded route; route segments were used."
    case coordinateOutliersRemoved = "Obvious isolated GPS outliers were removed from route analysis."
    case implicitRouteGapIntroduced = "A disconnected GPS relocation was treated as a recording gap."
    case altitudeOutliersIgnored = "Unreliable altitude spikes were ignored in elevation analysis."
    case insufficientReliableElevation = "There is not enough reliable altitude data for elevation analysis."

    public var message: String { rawValue }

    public var isRouteQualityWarning: Bool {
        switch self {
        case .sourceElapsedTimeMismatch, .sourceActiveTimeMismatch:
            return false
        case .coordinateOutliersRemoved, .implicitRouteGapIntroduced,
             .altitudeOutliersIgnored, .insufficientReliableElevation:
            return true
        }
    }
}
