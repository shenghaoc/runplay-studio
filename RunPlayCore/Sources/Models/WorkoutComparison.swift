import Foundation

public struct ComparisonPair: Sendable {
    public let primary: RunWorkout
    public let comparison: RunWorkout

    public init(primary: RunWorkout, comparison: RunWorkout) {
        self.primary = primary
        self.comparison = comparison
    }
}

/// Summary differences with explicit elapsed, active, and paused clocks.
public struct WorkoutComparisonSummary: Sendable {
    public let primaryTitle: String
    public let comparisonTitle: String

    public let primaryDistanceMeters: Double
    public let comparisonDistanceMeters: Double
    public let distanceDeltaMeters: Double

    public let primaryElapsedSeconds: Double
    public let comparisonElapsedSeconds: Double
    public let elapsedTimeDeltaSeconds: Double
    public let primaryActiveSeconds: Double
    public let comparisonActiveSeconds: Double
    public let activeTimeDeltaSeconds: Double
    public let primaryPausedSeconds: Double
    public let comparisonPausedSeconds: Double
    public let pausedTimeDeltaSeconds: Double
    public let primaryMovingSeconds: Double
    public let comparisonMovingSeconds: Double
    public let movingTimeDeltaSeconds: Double
    public let primaryStoppedSeconds: Double
    public let comparisonStoppedSeconds: Double
    public let stoppedTimeDeltaSeconds: Double
    public let primaryMovingPaceSecondsPerKm: Double
    public let comparisonMovingPaceSecondsPerKm: Double
    public let movingPaceDeltaSecondsPerKm: Double

    /// Source-compatible pace fields use active time.
    public let primaryPaceSecondsPerKm: Double
    public let comparisonPaceSecondsPerKm: Double
    public let paceDeltaSecondsPerKm: Double
    public let primaryElapsedPaceSecondsPerKm: Double
    public let comparisonElapsedPaceSecondsPerKm: Double
    public let elapsedPaceDeltaSecondsPerKm: Double

    public let primaryElevationGainMeters: Double?
    public let comparisonElevationGainMeters: Double?
    public let elevationGainDeltaMeters: Double?
    public let primaryAvgHR: Double?
    public let comparisonAvgHR: Double?
    public let avgHRDelta: Double?
    public let primaryMaxHR: Double?
    public let comparisonMaxHR: Double?
    public let maxHRDelta: Double?
    public let primaryPointCount: Int
    public let comparisonPointCount: Int
    public let warnings: [ComparisonWarning]

    /// Compatibility aliases. Duration now always means true elapsed time.
    public var primaryDurationSeconds: Double { primaryElapsedSeconds }
    public var comparisonDurationSeconds: Double { comparisonElapsedSeconds }
    public var durationDeltaSeconds: Double { elapsedTimeDeltaSeconds }

    public var distanceDeltaFormatted: String {
        guard distanceDeltaMeters.isFinite else { return "N/A" }
        let kilometers = distanceDeltaMeters / 1000
        if abs(kilometers) < 0.005 { return "0.00 km even" }
        return String(
            format: "%+.2f km %@",
            kilometers,
            kilometers > 0 ? "longer" : "shorter"
        )
    }

    public var elapsedTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            elapsedTimeDeltaSeconds,
            positiveLabel: NSLocalizedString("longer", comment: "Comparison duration delta"),
            negativeLabel: NSLocalizedString("shorter", comment: "Comparison duration delta")
        )
    }

    public var activeTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            activeTimeDeltaSeconds,
            positiveLabel: NSLocalizedString("longer", comment: "Comparison duration delta"),
            negativeLabel: NSLocalizedString("shorter", comment: "Comparison duration delta")
        )
    }

    public var pausedTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            pausedTimeDeltaSeconds,
            positiveLabel: "more paused",
            negativeLabel: "less paused"
        )
    }

    public var movingTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            movingTimeDeltaSeconds,
            positiveLabel: NSLocalizedString("more moving", comment: "Comparison moving-time delta"),
            negativeLabel: NSLocalizedString("less moving", comment: "Comparison moving-time delta")
        )
    }

    public var stoppedTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            stoppedTimeDeltaSeconds,
            positiveLabel: NSLocalizedString("more stopped", comment: "Comparison stopped-time delta"),
            negativeLabel: NSLocalizedString("less stopped", comment: "Comparison stopped-time delta")
        )
    }

    public var movingPaceDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(movingPaceDeltaSecondsPerKm, suffix: "/km")
    }

    public var durationDeltaFormatted: String { elapsedTimeDeltaFormatted }

    public var paceDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(paceDeltaSecondsPerKm, suffix: "/km")
    }

    public var elapsedPaceDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(elapsedPaceDeltaSecondsPerKm, suffix: "/km")
    }

    public var elevationGainDeltaFormatted: String {
        guard let elevationGainDeltaMeters, elevationGainDeltaMeters.isFinite else { return "N/A" }
        if abs(elevationGainDeltaMeters) < 0.5 { return "0 m even" }
        return String(
            format: "%+.0f m %@",
            elevationGainDeltaMeters,
            elevationGainDeltaMeters > 0 ? "higher" : "lower"
        )
    }

    public var avgHRDeltaFormatted: String? { Self.formatHeartRateDelta(avgHRDelta) }
    public var maxHRDeltaFormatted: String? { Self.formatHeartRateDelta(maxHRDelta) }

    /// Winner is determined only by active pace.
    public var winner: ComparisonResult {
        guard primaryPaceSecondsPerKm.isFinite,
              comparisonPaceSecondsPerKm.isFinite,
              primaryPaceSecondsPerKm > 0,
              comparisonPaceSecondsPerKm > 0,
              paceDeltaSecondsPerKm.isFinite
        else {
            return .unavailable
        }
        if abs(paceDeltaSecondsPerKm) < 5 { return .tie }
        return paceDeltaSecondsPerKm > 0 ? .comparison : .primary
    }

    private static func formatHeartRateDelta(_ delta: Double?) -> String? {
        guard let delta, delta.isFinite else { return nil }
        if abs(delta) < 0.5 { return "0 bpm even" }
        return String(format: "%+.0f bpm %@", delta, delta > 0 ? "higher" : "lower")
    }
}

public enum ComparisonResult: Sendable {
    case primary
    case comparison
    case tie
    case unavailable

    public var label: String {
        switch self {
        case .primary: return "Selected run faster"
        case .comparison: return "Compared run faster"
        case .tie: return "About the same"
        case .unavailable: return "N/A"
        }
    }
}

public struct SplitComparison: Identifiable, Sendable {
    public let id = UUID()
    public let splitIndex: Int
    public let primarySplit: RunSplit?
    public let comparisonSplit: RunSplit?
    public let elapsedDurationDeltaSeconds: Double?
    public let activeDurationDeltaSeconds: Double?
    public let movingDurationDeltaSeconds: Double?
    public let stoppedDurationDeltaSeconds: Double?
    public let paceDeltaSecondsPerKm: Double?
    public let winner: ComparisonResult

    public var durationDeltaSeconds: Double? { elapsedDurationDeltaSeconds }

    public var formattedDurationDelta: String {
        DisplayFormatter.formatSignedDurationDelta(
            elapsedDurationDeltaSeconds,
            positiveLabel: NSLocalizedString("longer", comment: "Comparison duration delta"),
            negativeLabel: NSLocalizedString("shorter", comment: "Comparison duration delta")
        )
    }

    public var formattedElapsedDurationDelta: String { formattedDurationDelta }

    public var formattedActiveDurationDelta: String {
        DisplayFormatter.formatSignedDurationDelta(
            activeDurationDeltaSeconds,
            positiveLabel: NSLocalizedString("longer", comment: "Comparison duration delta"),
            negativeLabel: NSLocalizedString("shorter", comment: "Comparison duration delta")
        )
    }

    public var formattedMovingDurationDelta: String {
        DisplayFormatter.formatSignedDurationDelta(
            movingDurationDeltaSeconds,
            positiveLabel: NSLocalizedString("longer", comment: "Comparison duration delta"),
            negativeLabel: NSLocalizedString("shorter", comment: "Comparison duration delta")
        )
    }

    public var formattedStoppedDurationDelta: String {
        DisplayFormatter.formatSignedDurationDelta(
            stoppedDurationDeltaSeconds,
            positiveLabel: NSLocalizedString("longer", comment: "Comparison duration delta"),
            negativeLabel: NSLocalizedString("shorter", comment: "Comparison duration delta")
        )
    }

    public var formattedPaceDelta: String {
        DisplayFormatter.formatSignedDurationDelta(paceDeltaSecondsPerKm, suffix: "/km")
    }
}

/// Ordinal recorded-lap comparison. Does not claim route alignment.
public struct RecordedLapComparison: Identifiable, Sendable {
    public let id = UUID()
    public let lapIndex: Int
    public let primaryLap: RecordedLap?
    public let comparisonLap: RecordedLap?
    public let distanceDeltaMeters: Double?
    public let elapsedDurationDeltaSeconds: Double?
    public let activeDurationDeltaSeconds: Double?
    public let movingDurationDeltaSeconds: Double?
    public let stoppedDurationDeltaSeconds: Double?
    public let activePaceDeltaSecondsPerKm: Double?
    public let movingPaceDeltaSecondsPerKm: Double?
    public let averageHRDelta: Double?
    public let elevationGainDeltaMeters: Double?
    public let winner: ComparisonResult
    public let caveats: [String]

    public var formattedDistanceDelta: String {
        guard let distanceDeltaMeters, distanceDeltaMeters.isFinite else { return "N/A" }
        let kilometers = distanceDeltaMeters / 1000
        if abs(kilometers) < 0.005 { return "0.00 km even" }
        return String(format: "%+.2f km", kilometers)
    }

    public var formattedActivePaceDelta: String {
        DisplayFormatter.formatSignedDurationDelta(activePaceDeltaSecondsPerKm, suffix: "/km")
    }

    public var formattedMovingPaceDelta: String {
        DisplayFormatter.formatSignedDurationDelta(movingPaceDeltaSecondsPerKm, suffix: "/km")
    }
}

public struct ComparisonMetricPoint: Identifiable, Sendable {
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

/// Metrics at one cumulative distance, using first-arrival (`rangeEnd`) time
/// when a stop and resume share the exact same distance.
public struct ComparisonDistanceMetrics: Sendable {
    public let selectedDistanceMeters: Double
    public let primaryElapsedSeconds: Double?
    public let comparisonElapsedSeconds: Double?
    /// Compatibility alias for elapsed-time delta.
    public let timeDeltaSeconds: Double?
    public let primaryActiveSeconds: Double?
    public let comparisonActiveSeconds: Double?
    public let activeTimeDeltaSeconds: Double?
    public let primaryMovingSeconds: Double?
    public let comparisonMovingSeconds: Double?
    public let movingTimeDeltaSeconds: Double?
    public let primaryStoppedSeconds: Double?
    public let comparisonStoppedSeconds: Double?
    public let stoppedTimeDeltaSeconds: Double?
    public let primaryPaceSecondsPerKm: Double?
    public let comparisonPaceSecondsPerKm: Double?
    public let paceDeltaSecondsPerKm: Double?
    public let primaryScenePoint: RouteScenePoint?
    public let comparisonScenePoint: RouteScenePoint?

    public var elapsedTimeDeltaSeconds: Double? { timeDeltaSeconds }

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
        self.init(
            selectedDistanceMeters: selectedDistanceMeters,
            primaryElapsedSeconds: primaryElapsedSeconds,
            comparisonElapsedSeconds: comparisonElapsedSeconds,
            timeDeltaSeconds: timeDeltaSeconds,
            primaryPaceSecondsPerKm: primaryPaceSecondsPerKm,
            comparisonPaceSecondsPerKm: comparisonPaceSecondsPerKm,
            paceDeltaSecondsPerKm: paceDeltaSecondsPerKm,
            primaryActiveSeconds: nil,
            comparisonActiveSeconds: nil,
            activeTimeDeltaSeconds: nil,
            primaryMovingSeconds: nil,
            comparisonMovingSeconds: nil,
            movingTimeDeltaSeconds: nil,
            primaryStoppedSeconds: nil,
            comparisonStoppedSeconds: nil,
            stoppedTimeDeltaSeconds: nil,
            primaryScenePoint: primaryScenePoint,
            comparisonScenePoint: comparisonScenePoint
        )
    }

    public init(
        selectedDistanceMeters: Double,
        primaryElapsedSeconds: Double?,
        comparisonElapsedSeconds: Double?,
        timeDeltaSeconds: Double?,
        primaryPaceSecondsPerKm: Double?,
        comparisonPaceSecondsPerKm: Double?,
        paceDeltaSecondsPerKm: Double?,
        primaryActiveSeconds: Double?,
        comparisonActiveSeconds: Double? = nil,
        activeTimeDeltaSeconds: Double? = nil,
        primaryMovingSeconds: Double? = nil,
        comparisonMovingSeconds: Double? = nil,
        movingTimeDeltaSeconds: Double? = nil,
        primaryStoppedSeconds: Double? = nil,
        comparisonStoppedSeconds: Double? = nil,
        stoppedTimeDeltaSeconds: Double? = nil,
        primaryScenePoint: RouteScenePoint?,
        comparisonScenePoint: RouteScenePoint?
    ) {
        self.selectedDistanceMeters = Self.nonNegativeFinite(selectedDistanceMeters)
        self.primaryElapsedSeconds = Self.nonNegativeFiniteOptional(primaryElapsedSeconds)
        self.comparisonElapsedSeconds = Self.nonNegativeFiniteOptional(comparisonElapsedSeconds)
        self.timeDeltaSeconds = Self.finiteOptional(timeDeltaSeconds)
        self.primaryActiveSeconds = Self.nonNegativeFiniteOptional(primaryActiveSeconds)
        self.comparisonActiveSeconds = Self.nonNegativeFiniteOptional(comparisonActiveSeconds)
        self.activeTimeDeltaSeconds = Self.finiteOptional(activeTimeDeltaSeconds)
        self.primaryMovingSeconds = Self.nonNegativeFiniteOptional(primaryMovingSeconds)
        self.comparisonMovingSeconds = Self.nonNegativeFiniteOptional(comparisonMovingSeconds)
        self.movingTimeDeltaSeconds = Self.finiteOptional(movingTimeDeltaSeconds)
        self.primaryStoppedSeconds = Self.nonNegativeFiniteOptional(primaryStoppedSeconds)
        self.comparisonStoppedSeconds = Self.nonNegativeFiniteOptional(comparisonStoppedSeconds)
        self.stoppedTimeDeltaSeconds = Self.finiteOptional(stoppedTimeDeltaSeconds)
        self.primaryPaceSecondsPerKm = Self.positiveFiniteOptional(primaryPaceSecondsPerKm)
        self.comparisonPaceSecondsPerKm = Self.positiveFiniteOptional(comparisonPaceSecondsPerKm)
        self.paceDeltaSecondsPerKm = Self.finiteOptional(paceDeltaSecondsPerKm)
        self.primaryScenePoint = primaryScenePoint
        self.comparisonScenePoint = comparisonScenePoint
    }

    public var selectedDistanceFormatted: String {
        DisplayFormatter.formatDistanceKm(selectedDistanceMeters)
    }
    public var primaryElapsedFormatted: String { DisplayFormatter.formatElapsed(primaryElapsedSeconds) }
    public var comparisonElapsedFormatted: String { DisplayFormatter.formatElapsed(comparisonElapsedSeconds) }
    public var primaryActiveFormatted: String { DisplayFormatter.formatElapsed(primaryActiveSeconds) }
    public var comparisonActiveFormatted: String { DisplayFormatter.formatElapsed(comparisonActiveSeconds) }
    public var primaryMovingFormatted: String { DisplayFormatter.formatElapsed(primaryMovingSeconds) }
    public var comparisonMovingFormatted: String { DisplayFormatter.formatElapsed(comparisonMovingSeconds) }
    public var primaryStoppedFormatted: String { DisplayFormatter.formatElapsed(primaryStoppedSeconds) }
    public var comparisonStoppedFormatted: String { DisplayFormatter.formatElapsed(comparisonStoppedSeconds) }
    public var timeDeltaFormatted: String { elapsedTimeDeltaFormatted }
    public var elapsedTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            elapsedTimeDeltaSeconds,
            positiveLabel: "longer",
            negativeLabel: "shorter"
        )
    }
    public var activeTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            activeTimeDeltaSeconds,
            positiveLabel: "longer",
            negativeLabel: "shorter"
        )
    }
    public var movingTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            movingTimeDeltaSeconds,
            positiveLabel: "more moving",
            negativeLabel: "less moving"
        )
    }
    public var stoppedTimeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            stoppedTimeDeltaSeconds,
            positiveLabel: "more stopped",
            negativeLabel: "less stopped"
        )
    }
    public var primaryPaceFormatted: String { DisplayFormatter.formatPace(primaryPaceSecondsPerKm) }
    public var comparisonPaceFormatted: String { DisplayFormatter.formatPace(comparisonPaceSecondsPerKm) }
    public var paceDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(paceDeltaSecondsPerKm, suffix: "/km")
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
    private static func finiteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
    private static func nonNegativeFiniteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    private static func positiveFiniteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

public enum ComparisonWarning: String, CaseIterable, Sendable {
    case differentDistances = "Runs have significantly different distances"
    case insufficientOverlap = "Not enough overlapping distance to compare"
    case differentRouteShape = "Routes differ; comparison based on distance"
    case differentPauseDurations = "Runs contain different pause durations; active and elapsed comparisons may differ"
    case missingHeartRate = "One or both runs lack heart rate data"
    case missingElevation = "One or both runs lack elevation data"
    case tooFewPoints = "One or both runs have very few data points"
    case movementEstimated = "Stopped time is estimated from GPS; comparisons involving stopped time are approximate"
    case movementEstimateReliabilityDiffers = "One run used a conservative moving-time fallback; moving-time comparisons are approximate"

    public var icon: String {
        switch self {
        case .differentDistances: return "ruler"
        case .insufficientOverlap: return "exclamationmark.triangle"
        case .differentRouteShape: return "map"
        case .differentPauseDurations: return "pause.circle"
        case .missingHeartRate: return "heart"
        case .missingElevation: return "mountain.2"
        case .tooFewPoints: return "chart.dots.scatterplot"
        case .movementEstimated: return "figure.walk.motion"
        case .movementEstimateReliabilityDiffers: return "exclamationmark.triangle"
        }
    }
}
