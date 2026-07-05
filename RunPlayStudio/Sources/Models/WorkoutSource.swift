import Foundation

/// The source format of a workout file.
enum WorkoutSource: String, Codable, CaseIterable {
    case json
    case gpx
    case tcx
    case fit
    case healthKit
    case strava
    case garmin
    case unknown

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .gpx: return "GPX"
        case .tcx: return "TCX"
        case .fit: return "FIT"
        case .healthKit: return "Apple Health"
        case .strava: return "Strava"
        case .garmin: return "Garmin"
        case .unknown: return "Unknown"
        }
    }
}
