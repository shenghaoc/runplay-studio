import Foundation

/// Non-fatal source validation warnings retained with an analyzed workout.
public enum WorkoutAnalysisWarning: String, Codable, Hashable, Sendable {
    case sourceElapsedTimeMismatch = "The FIT session elapsed time differs from the recorded route; route timestamps were used."
    case sourceActiveTimeMismatch = "The FIT session timer time differs from the recorded route; route segments were used."
    case coordinateOutliersRemoved = "Obvious isolated GPS outliers were removed from route analysis."
    case implicitRouteGapIntroduced = "A disconnected GPS relocation was treated as a recording gap."
    case altitudeOutliersIgnored = "Unreliable altitude spikes were ignored in elevation analysis."
    case insufficientReliableElevation = "There is not enough reliable altitude data for elevation analysis."
    case movementEstimatedStoppedTime = "Stopped time is estimated from GPS movement patterns and may differ from user-perceived stops."
    case movementLowReliability = "Movement detection has low reliability due to sparse or irregular GPS data."
    case recordedLapsMalformedSkipped = "Some source-recorded laps were incomplete or malformed and were skipped."
    case recordedLapSourceTotalsMismatch = "Source-reported lap totals differ materially from route-derived values; route-derived metrics were used."
    case recordedLapsRequireReimport = "This saved workout was imported before recorded laps were preserved. Reimport the original FIT or TCX file to recover device laps."

    /// The warning in the app's language. `rawValue` is the persisted English
    /// identity and never changes; display text reads this instead.
    public var message: String {
        switch self {
        case .sourceElapsedTimeMismatch:
            return coreLocalized("The FIT session elapsed time differs from the recorded route; route timestamps were used.")
        case .sourceActiveTimeMismatch:
            return coreLocalized("The FIT session timer time differs from the recorded route; route segments were used.")
        case .coordinateOutliersRemoved:
            return coreLocalized("Obvious isolated GPS outliers were removed from route analysis.")
        case .implicitRouteGapIntroduced:
            return coreLocalized("A disconnected GPS relocation was treated as a recording gap.")
        case .altitudeOutliersIgnored:
            return coreLocalized("Unreliable altitude spikes were ignored in elevation analysis.")
        case .insufficientReliableElevation:
            return coreLocalized("There is not enough reliable altitude data for elevation analysis.")
        case .movementEstimatedStoppedTime:
            return coreLocalized("Stopped time is estimated from GPS movement patterns and may differ from user-perceived stops.")
        case .movementLowReliability:
            return coreLocalized("Movement detection has low reliability due to sparse or irregular GPS data.")
        case .recordedLapsMalformedSkipped:
            return coreLocalized("Some source-recorded laps were incomplete or malformed and were skipped.")
        case .recordedLapSourceTotalsMismatch:
            return coreLocalized("Source-reported lap totals differ materially from route-derived values; route-derived metrics were used.")
        case .recordedLapsRequireReimport:
            return coreLocalized("This saved workout was imported before recorded laps were preserved. Reimport the original FIT or TCX file to recover device laps.")
        }
    }

    public var isRouteQualityWarning: Bool {
        switch self {
        case .sourceElapsedTimeMismatch, .sourceActiveTimeMismatch:
            return false
        case .coordinateOutliersRemoved, .implicitRouteGapIntroduced,
             .altitudeOutliersIgnored, .insufficientReliableElevation:
            return true
        case .movementEstimatedStoppedTime, .movementLowReliability:
            return false
        case .recordedLapsMalformedSkipped, .recordedLapSourceTotalsMismatch, .recordedLapsRequireReimport:
            return false
        }
    }
}
