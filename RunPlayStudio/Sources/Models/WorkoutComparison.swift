import Foundation

/// A pair of workouts selected for comparison.
struct ComparisonPair {
    let primary: RunWorkout
    let comparison: RunWorkout
}

/// Summary of differences between two workouts.
struct WorkoutComparisonSummary {
    let primaryTitle: String
    let comparisonTitle: String

    // Distance
    let primaryDistanceMeters: Double
    let comparisonDistanceMeters: Double
    let distanceDeltaMeters: Double

    // Duration
    let primaryDurationSeconds: Double
    let comparisonDurationSeconds: Double
    let durationDeltaSeconds: Double

    // Pace
    let primaryPaceSecondsPerKm: Double
    let comparisonPaceSecondsPerKm: Double
    let paceDeltaSecondsPerKm: Double

    // Elevation
    let primaryElevationGainMeters: Double
    let comparisonElevationGainMeters: Double
    let elevationGainDeltaMeters: Double

    // Heart rate (optional)
    let primaryAvgHR: Double?
    let comparisonAvgHR: Double?
    let avgHRDelta: Double?
    let primaryMaxHR: Double?
    let comparisonMaxHR: Double?
    let maxHRDelta: Double?

    // Point counts
    let primaryPointCount: Int
    let comparisonPointCount: Int

    // Warnings
    let warnings: [ComparisonWarning]

    var distanceDeltaFormatted: String {
        let km = distanceDeltaMeters / 1000
        return String(format: "%+.2f km", km)
    }

    var durationDeltaFormatted: String {
        let mins = durationDeltaSeconds / 60
        return String(format: "%+.1f min", mins)
    }

    var paceDeltaFormatted: String {
        let delta = paceDeltaSecondsPerKm
        let mins = Int(abs(delta)) / 60
        let secs = Int(abs(delta)) % 60
        let sign = delta >= 0 ? "+" : "-"
        return "\(sign)\(mins):\(String(format: "%02d", secs)) /km"
    }

    var winner: ComparisonResult {
        let paceDiff = paceDeltaSecondsPerKm
        if abs(paceDiff) < 5 {
            return .tie
        }
        return paceDiff > 0 ? .comparison : .primary
    }
}

/// Result of a comparison.
enum ComparisonResult {
    case primary
    case comparison
    case tie
    case unavailable

    var label: String {
        switch self {
        case .primary: return "Primary faster"
        case .comparison: return "Comparison faster"
        case .tie: return "About the same"
        case .unavailable: return "N/A"
        }
    }
}

/// Comparison of a single split between two workouts.
struct SplitComparison: Identifiable {
    let id = UUID()
    let splitIndex: Int
    let primarySplit: RunSplit?
    let comparisonSplit: RunSplit?
    let durationDeltaSeconds: Double?
    let paceDeltaSecondsPerKm: Double?
    let winner: ComparisonResult

    var formattedDurationDelta: String {
        guard let delta = durationDeltaSeconds else { return "—" }
        let mins = Int(abs(delta)) / 60
        let secs = Int(abs(delta)) % 60
        let sign = delta >= 0 ? "+" : "-"
        return "\(sign)\(mins):\(String(format: "%02d", secs))"
    }

    var formattedPaceDelta: String {
        guard let delta = paceDeltaSecondsPerKm else { return "—" }
        let mins = Int(abs(delta)) / 60
        let secs = Int(abs(delta)) % 60
        let sign = delta >= 0 ? "+" : "-"
        return "\(sign)\(mins):\(String(format: "%02d", secs))"
    }
}

/// A point in the pace comparison series over distance.
struct ComparisonMetricPoint: Identifiable {
    let id = UUID()
    let distanceMeters: Double
    let primaryPace: Double?
    let comparisonPace: Double?
    let paceDelta: Double?
    let primaryElevation: Double?
    let comparisonElevation: Double?
    let primaryHR: Double?
    let comparisonHR: Double?

    var distanceKm: Double { distanceMeters / 1000 }
}

/// Warning about a comparison.
enum ComparisonWarning: String, CaseIterable {
    case differentDistances = "Runs have significantly different distances"
    case insufficientOverlap = "Insufficient distance overlap for comparison"
    case differentRouteShape = "Routes may cover different paths"
    case missingHeartRate = "One or both runs lack heart rate data"
    case missingElevation = "One or both runs lack elevation data"
    case tooFewPoints = "One or both runs have very few data points"

    var icon: String {
        switch self {
        case .differentDistances: return "ruler"
        case .insufficientOverlap: return "exclamationmark.triangle"
        case .differentRouteShape: return "map"
        case .missingHeartRate: return "heart"
        case .missingElevation: return "mountain.2"
        case .tooFewPoints: return "chart.dots.scatterplot"
        }
    }
}
