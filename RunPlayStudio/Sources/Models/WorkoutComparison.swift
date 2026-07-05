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
        if abs(km) < 0.005 {
            return "0.00 km even"
        }
        return String(format: "%+.2f km %@", km, km > 0 ? "longer" : "shorter")
    }

    var durationDeltaFormatted: String {
        formatTimeDelta(durationDeltaSeconds, suffix: nil, positiveLabel: "slower", negativeLabel: "faster")
    }

    var paceDeltaFormatted: String {
        formatTimeDelta(paceDeltaSecondsPerKm, suffix: "/km", positiveLabel: "slower", negativeLabel: "faster")
    }

    var elevationGainDeltaFormatted: String {
        if abs(elevationGainDeltaMeters) < 0.5 {
            return "0 m even"
        }
        return String(format: "%+.0f m %@", elevationGainDeltaMeters, elevationGainDeltaMeters > 0 ? "more gain" : "less gain")
    }

    var avgHRDeltaFormatted: String? {
        formatHeartRateDelta(avgHRDelta)
    }

    var maxHRDeltaFormatted: String? {
        formatHeartRateDelta(maxHRDelta)
    }

    var winner: ComparisonResult {
        let paceDiff = paceDeltaSecondsPerKm
        if abs(paceDiff) < 5 {
            return .tie
        }
        return paceDiff > 0 ? .comparison : .primary
    }

    private func formatTimeDelta(
        _ delta: Double,
        suffix: String?,
        positiveLabel: String,
        negativeLabel: String
    ) -> String {
        let suffixText = suffix.map { " \($0)" } ?? ""
        guard delta.isFinite else { return "N/A" }
        if abs(delta) < 0.5 {
            return "0:00\(suffixText) even"
        }

        let rounded = Int(abs(delta).rounded())
        let minutes = rounded / 60
        let seconds = rounded % 60
        let sign = delta > 0 ? "+" : "-"
        let label = delta > 0 ? positiveLabel : negativeLabel
        return "\(sign)\(minutes):\(String(format: "%02d", seconds))\(suffixText) \(label)"
    }

    private func formatHeartRateDelta(_ delta: Double?) -> String? {
        guard let delta, delta.isFinite else { return nil }
        if abs(delta) < 0.5 {
            return "0 bpm even"
        }
        return String(format: "%+.0f bpm %@", delta, delta > 0 ? "higher" : "lower")
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
        return Self.formatTimeDelta(delta, suffix: nil)
    }

    var formattedPaceDelta: String {
        guard let delta = paceDeltaSecondsPerKm else { return "—" }
        return Self.formatTimeDelta(delta, suffix: "/km")
    }

    private static func formatTimeDelta(_ delta: Double, suffix: String?) -> String {
        let suffixText = suffix.map { " \($0)" } ?? ""
        guard delta.isFinite else { return "N/A" }
        if abs(delta) < 0.5 {
            return "0:00\(suffixText) even"
        }

        let rounded = Int(abs(delta).rounded())
        let minutes = rounded / 60
        let seconds = rounded % 60
        let sign = delta > 0 ? "+" : "-"
        let label = delta > 0 ? "slower" : "faster"
        return "\(sign)\(minutes):\(String(format: "%02d", seconds))\(suffixText) \(label)"
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
    case differentRouteShape = "Routes differ; comparison uses distance alignment"
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
