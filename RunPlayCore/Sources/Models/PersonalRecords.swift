import Foundation

/// One personal-record category tracked across the library.
///
/// The seven pace categories are fixed-distance windows computed by the
/// segment-detection engine; `longestRun` and `biggestAscent` are whole-run
/// values derived from stored summaries. Categories are persisted with the
/// workout snapshot only for the seven window cases (as
/// `PersonalRecordWindow.category`); the whole-run cases exist so the
/// aggregated table and accessibility summaries can treat all rows uniformly.
public enum PersonalRecordCategory: String, Codable, Hashable, CaseIterable, Sendable {
    case fastest400m
    case fastest1km
    case fastest1mile
    case fastest5km
    case fastest10km
    case fastestHalfMarathon
    case fastestMarathon
    case longestRun
    case biggestAscent

    public var displayName: String {
        switch self {
        case .fastest400m: return "Fastest 400 m"
        case .fastest1km: return "Fastest 1 km"
        case .fastest1mile: return "Fastest 1 Mile"
        case .fastest5km: return "Fastest 5 km"
        case .fastest10km: return "Fastest 10 km"
        case .fastestHalfMarathon: return "Fastest Half Marathon"
        case .fastestMarathon: return "Fastest Marathon"
        case .longestRun: return "Longest Run"
        case .biggestAscent: return "Biggest Single-Run Ascent"
        }
    }

    /// Nominal window length for the pace categories, matching the engine
    /// constants exactly. `nil` for the whole-run categories.
    public var nominalWindowDistanceMeters: Double? {
        switch self {
        case .fastest400m: return 400
        case .fastest1km: return 1_000
        case .fastest1mile: return RunPlaySegmentDetectorBridge.personalRecordOneMileMeters
        case .fastest5km: return RunPlaySegmentDetectorBridge.personalRecordFiveKmMeters
        case .fastest10km: return RunPlaySegmentDetectorBridge.personalRecordTenKmMeters
        case .fastestHalfMarathon: return RunPlaySegmentDetectorBridge.personalRecordHalfMarathonMeters
        case .fastestMarathon: return RunPlaySegmentDetectorBridge.personalRecordMarathonMeters
        case .longestRun, .biggestAscent: return nil
        }
    }

    /// Whether records for this category come from a fixed-distance window.
    public var isPaceWindow: Bool {
        nominalWindowDistanceMeters != nil
    }

    /// Whether this window is one of the long personal-record lengths that
    /// have no original segment-highlight counterpart (1 mile and up). Those
    /// surface in the Segments panel alongside the detected highlights; the
    /// 400 m and 1 km windows already exist as segment kinds.
    public var isLongRecordWindow: Bool {
        switch self {
        case .fastest1mile, .fastest5km, .fastest10km,
             .fastestHalfMarathon, .fastestMarathon:
            return true
        case .fastest400m, .fastest1km, .longestRun, .biggestAscent:
            return false
        }
    }
}

/// The best fixed-distance window of one category within one workout.
///
/// Stored in the workout snapshot at analysis time. Pause semantics match
/// segment highlights exactly: the window continues in cumulative distance
/// (it may span a recording gap geographically separated by a pause), and
/// `activeSeconds`/`paceSecondsPerKilometer` exclude paused time.
public struct PersonalRecordWindow: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let category: PersonalRecordCategory
    public let startDistanceMeters: Double
    public let endDistanceMeters: Double
    public let startElapsedSeconds: Double
    public let endElapsedSeconds: Double
    /// Active duration of the window; pause time inside it is excluded.
    public let activeSeconds: Double
    /// Active pace in seconds per kilometre over the window.
    public let paceSecondsPerKilometer: Double
    public let averageHeartRateBPM: Double?
    public let sourcePointRange: Range<Int>

    public init(
        id: UUID = UUID(),
        category: PersonalRecordCategory,
        startDistanceMeters: Double,
        endDistanceMeters: Double,
        startElapsedSeconds: Double,
        endElapsedSeconds: Double,
        activeSeconds: Double,
        paceSecondsPerKilometer: Double,
        averageHeartRateBPM: Double?,
        sourcePointRange: Range<Int>
    ) {
        self.id = id
        self.category = category
        self.startDistanceMeters = startDistanceMeters
        self.endDistanceMeters = endDistanceMeters
        self.startElapsedSeconds = startElapsedSeconds
        self.endElapsedSeconds = endElapsedSeconds
        self.activeSeconds = activeSeconds
        self.paceSecondsPerKilometer = paceSecondsPerKilometer
        self.averageHeartRateBPM = averageHeartRateBPM
        self.sourcePointRange = sourcePointRange
    }
}

/// Per-workout personal-record computation result, persisted with the
/// workout snapshot.
///
/// A non-`nil` value on `RunWorkout` is the marker that record computation
/// has run for that workout: `windows` is legitimately empty for runs shorter
/// than every window. Absence (`nil`) means the snapshot predates record
/// computation and the one-off library backfill still has work to do.
/// `analysisVersion` is intentionally not bumped for this field; existing
/// libraries pick it up through the explicit backfill instead of a silent
/// load-time re-analysis.
public struct WorkoutPersonalRecords: Codable, Hashable, Sendable {
    public let windows: [PersonalRecordWindow]

    public init(windows: [PersonalRecordWindow]) {
        self.windows = windows
    }

    public func window(for category: PersonalRecordCategory) -> PersonalRecordWindow? {
        windows.first { $0.category == category }
    }
}
