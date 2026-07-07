import Foundation

/// A pair of workouts selected for comparison.
public struct ComparisonPair {
    public let primary: RunWorkout
    public let comparison: RunWorkout

    public init(primary: RunWorkout, comparison: RunWorkout) {
        self.primary = primary
        self.comparison = comparison
    }
}

/// Summary of differences between two workouts.
public struct WorkoutComparisonSummary {
    public let primaryTitle: String
    public let comparisonTitle: String

    // Distance
    public let primaryDistanceMeters: Double
    public let comparisonDistanceMeters: Double
    public let distanceDeltaMeters: Double

    // Duration
    public let primaryDurationSeconds: Double
    public let comparisonDurationSeconds: Double
    public let durationDeltaSeconds: Double

    // Pace
    public let primaryPaceSecondsPerKm: Double
    public let comparisonPaceSecondsPerKm: Double
    public let paceDeltaSecondsPerKm: Double

    // Elevation
    public let primaryElevationGainMeters: Double
    public let comparisonElevationGainMeters: Double
    public let elevationGainDeltaMeters: Double

    // Heart rate (optional)
    public let primaryAvgHR: Double?
    public let comparisonAvgHR: Double?
    public let avgHRDelta: Double?
    public let primaryMaxHR: Double?
    public let comparisonMaxHR: Double?
    public let maxHRDelta: Double?

    // Point counts
    public let primaryPointCount: Int
    public let comparisonPointCount: Int

    // Warnings
    public let warnings: [ComparisonWarning]

    public var distanceDeltaFormatted: String {
        let km = distanceDeltaMeters / 1000
        if abs(km) < 0.005 {
            return "0.00 km even"
        }
        return String(format: "%+.2f km %@", km, km > 0 ? "longer" : "shorter")
    }

    public var durationDeltaFormatted: String {
        formatTimeDelta(durationDeltaSeconds, suffix: nil, positiveLabel: "slower", negativeLabel: "faster")
    }

    public var paceDeltaFormatted: String {
        formatTimeDelta(paceDeltaSecondsPerKm, suffix: "/km", positiveLabel: "slower", negativeLabel: "faster")
    }

    public var elevationGainDeltaFormatted: String {
        if abs(elevationGainDeltaMeters) < 0.5 {
            return "0 m even"
        }
        return String(format: "%+.0f m %@", elevationGainDeltaMeters, elevationGainDeltaMeters > 0 ? "more gain" : "less gain")
    }

    public var avgHRDeltaFormatted: String? {
        formatHeartRateDelta(avgHRDelta)
    }

    public var maxHRDeltaFormatted: String? {
        formatHeartRateDelta(maxHRDelta)
    }

    public var winner: ComparisonResult {
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
public enum ComparisonResult {
    case primary
    case comparison
    case tie
    case unavailable

    public var label: String {
        switch self {
        case .primary: return "Primary faster"
        case .comparison: return "Comparison faster"
        case .tie: return "About the same"
        case .unavailable: return "N/A"
        }
    }
}

/// Comparison of a single split between two workouts.
public struct SplitComparison: Identifiable {
    public let id = UUID()
    public let splitIndex: Int
    public let primarySplit: RunSplit?
    public let comparisonSplit: RunSplit?
    public let durationDeltaSeconds: Double?
    public let paceDeltaSecondsPerKm: Double?
    public let winner: ComparisonResult

    public var formattedDurationDelta: String {
        guard let delta = durationDeltaSeconds else { return "—" }
        return Self.formatTimeDelta(delta, suffix: nil)
    }

    public var formattedPaceDelta: String {
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
public struct ComparisonMetricPoint: Identifiable {
    public let id = UUID()
    public let distanceMeters: Double
    public let primaryPace: Double?
    public let comparisonPace: Double?
    public let paceDelta: Double?
    public let primaryElevation: Double?
    public let comparisonElevation: Double?
    public let primaryHR: Double?
    public let comparisonHR: Double?

    public var distanceKm: Double { distanceMeters / 1000 }
}

/// Metrics at a user-selected distance along a comparison route pair.
public struct ComparisonDistanceMetrics {
    public let selectedDistanceMeters: Double
    public let primaryElapsedSeconds: Double?
    public let comparisonElapsedSeconds: Double?
    public let timeDeltaSeconds: Double?
    public let primaryPaceSecondsPerKm: Double?
    public let comparisonPaceSecondsPerKm: Double?
    public let paceDeltaSecondsPerKm: Double?
    public let primaryScenePoint: RouteScenePoint?
    public let comparisonScenePoint: RouteScenePoint?

    public init(
        selectedDistanceMeters: Double,
        primaryElapsedSeconds: Double?,
        comparisonElapsedSeconds: Double?,
        timeDeltaSeconds: Double?,
        primaryPaceSecondsPerKm: Double?,
        comparisonPaceSecondsPerKm: Double?,
        paceDeltaSecondsPerKm: Double?,
        primaryScenePoint: RouteScenePoint?,
        comparisonScenePoint: RouteScenePoint?
    ) {
        self.selectedDistanceMeters = selectedDistanceMeters
        self.primaryElapsedSeconds = primaryElapsedSeconds
        self.comparisonElapsedSeconds = comparisonElapsedSeconds
        self.timeDeltaSeconds = timeDeltaSeconds
        self.primaryPaceSecondsPerKm = primaryPaceSecondsPerKm
        self.comparisonPaceSecondsPerKm = comparisonPaceSecondsPerKm
        self.paceDeltaSecondsPerKm = paceDeltaSecondsPerKm
        self.primaryScenePoint = primaryScenePoint
        self.comparisonScenePoint = comparisonScenePoint
    }

    public var selectedDistanceFormatted: String {
        String(format: "%.2f km", selectedDistanceMeters / 1000)
    }

    public var primaryElapsedFormatted: String {
        formatElapsed(primaryElapsedSeconds)
    }

    public var comparisonElapsedFormatted: String {
        formatElapsed(comparisonElapsedSeconds)
    }

    public var timeDeltaFormatted: String {
        formatTimeDelta(timeDeltaSeconds, suffix: nil, positiveLabel: "slower", negativeLabel: "faster")
    }

    public var primaryPaceFormatted: String {
        formatPace(primaryPaceSecondsPerKm)
    }

    public var comparisonPaceFormatted: String {
        formatPace(comparisonPaceSecondsPerKm)
    }

    public var paceDeltaFormatted: String {
        formatTimeDelta(paceDeltaSecondsPerKm, suffix: "/km", positiveLabel: "slower", negativeLabel: "faster")
    }

    private func formatElapsed(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatPace(_ pace: Double?) -> String {
        guard let pace, pace.isFinite, pace > 0 else { return "--:-- /km" }
        let mins = Int(pace) / 60
        let secs = Int(pace) % 60
        return String(format: "%d:%02d /km", mins, secs)
    }

    private func formatTimeDelta(_ delta: Double?, suffix: String?, positiveLabel: String, negativeLabel: String) -> String {
        let suffixText = suffix.map { " \($0)" } ?? ""
        guard let delta, delta.isFinite else { return "N/A" }
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
}

/// Warning about a comparison.
public enum ComparisonWarning: String, CaseIterable {
    case differentDistances = "Runs have significantly different distances"
    case insufficientOverlap = "Insufficient distance overlap for comparison"
    case differentRouteShape = "Routes differ; comparison uses distance alignment"
    case missingHeartRate = "One or both runs lack heart rate data"
    case missingElevation = "One or both runs lack elevation data"
    case tooFewPoints = "One or both runs have very few data points"

    public var icon: String {
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
