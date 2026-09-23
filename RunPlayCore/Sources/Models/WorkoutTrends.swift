import Foundation

/// Aggregation granularity for the Trends workspace.
public enum WorkoutTrendsPeriod: String, Codable, CaseIterable, Sendable, Hashable {
    /// ISO 8601 week (Monday start, ISO week-date year).
    case week
    /// Calendar month.
    case month
    /// Calendar year.
    case year
}

/// Display window for the Trends workspace.
///
/// Month-count ranges snap to whole periods: the anchor instant
/// `now - N months` resolves to its period under the current granularity and
/// every period with a nominal key at or after that anchor's key is included,
/// so the leading period is never partial. `allTime` has no cutoff.
public enum WorkoutTrendsRange: String, Codable, CaseIterable, Sendable, Hashable {
    case last3Months
    case last6Months
    case last12Months
    case allTime

    /// Number of trailing months the window covers, or `nil` for all time.
    public var monthCount: Int? {
        switch self {
        case .last3Months: return 3
        case .last6Months: return 6
        case .last12Months: return 12
        case .allTime: return nil
        }
    }
}

/// Which workouts the Trends workspace aggregates.
public enum WorkoutTrendsScope: Hashable, Sendable {
    /// Every workout in the library.
    case entireLibrary
    /// The All Runs view's current query (manual filters or the active smart
    /// collection, including any modified working query).
    case currentLibraryFilter
    /// A saved smart collection, resolved against the live library.
    case smartCollection(UUID)

    /// Stable raw kind used by session persistence.
    public var sessionKindRawValue: String {
        switch self {
        case .entireLibrary: return "entireLibrary"
        case .currentLibraryFilter: return "currentLibraryFilter"
        case .smartCollection: return "smartCollection"
        }
    }

    /// Restores a scope from persisted raw values; unknown kinds fall back to
    /// the entire library.
    public static func make(sessionKindRawValue: String, collectionID: UUID?) -> WorkoutTrendsScope {
        switch sessionKindRawValue {
        case "currentLibraryFilter":
            return .currentLibraryFilter
        case "smartCollection":
            if let collectionID {
                return .smartCollection(collectionID)
            }
            return .entireLibrary
        default:
            return .entireLibrary
        }
    }
}

/// Nominal identity of one aggregation period.
///
/// For weeks, `year` is the ISO week-date year and `ordinal` is the ISO week
/// number, so 29 December can belong to week 1 of the next year and 1 January
/// to week 52 or 53 of the previous year. Keys are only meaningfully compared
/// within one `kind`; ordering across kinds is by declared case for totality.
public struct WorkoutTrendsPeriodKey: Hashable, Comparable, Codable, Sendable {
    public let kind: WorkoutTrendsPeriod
    public let year: Int
    public let ordinal: Int

    public init(kind: WorkoutTrendsPeriod, year: Int, ordinal: Int) {
        self.kind = kind
        self.year = year
        self.ordinal = ordinal
    }

    public static func < (lhs: WorkoutTrendsPeriodKey, rhs: WorkoutTrendsPeriodKey) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.year != rhs.year {
            return lhs.year < rhs.year
        }
        return lhs.ordinal < rhs.ordinal
    }
}

/// One workout's contribution to Trends aggregation.
///
/// Derived purely from the stored workout snapshot's metadata and summary —
/// never from route points — so building rows for the whole library is linear
/// in workout count. Undated workouts cannot be bucketed and are excluded
/// (counted separately by the view model).
public struct WorkoutTrendsSummaryRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Canonical start date (`metadata.startDate` else first route point).
    public let startDate: Date
    /// UTC offset literally encoded in the source timestamps, when the format
    /// carried one. Bucketing uses the recorded local date; `nil` falls back
    /// to the caller's zone.
    public let recordedUTCOffsetSeconds: Int?
    public let distanceMeters: Double
    public let activeSeconds: Double
    /// Positive finite summary average, or `nil` when no heart rate exists.
    public let averageHeartRateBPM: Double?
    /// Corrected ascent when the analysis produced a meaningful profile, else
    /// the persisted raw adjacent-delta ascent; `nil` when neither exists.
    public let ascentMeters: Double?

    public init(
        id: UUID,
        startDate: Date,
        recordedUTCOffsetSeconds: Int?,
        distanceMeters: Double,
        activeSeconds: Double,
        averageHeartRateBPM: Double?,
        ascentMeters: Double?
    ) {
        self.id = id
        self.startDate = startDate
        self.recordedUTCOffsetSeconds = recordedUTCOffsetSeconds
        self.distanceMeters = distanceMeters
        self.activeSeconds = activeSeconds
        self.averageHeartRateBPM = averageHeartRateBPM
        self.ascentMeters = ascentMeters
    }

    /// Builds a row from a stored snapshot. Returns `nil` for undated workouts.
    public static func make(from workout: RunWorkout) -> WorkoutTrendsSummaryRow? {
        guard let startDate = WorkoutLibraryEntry.canonicalStartDate(for: workout) else {
            return nil
        }
        let summary = workout.summary
        let heartRate: Double?
        if let average = summary.averageHeartRateBPM, average.isFinite, average > 0 {
            heartRate = average
        } else {
            heartRate = nil
        }
        // Corrected elevation availability mirrors the All Runs table signal
        // (summary metrics only, plus DEM correction; see
        // `RunWorkout.hasCorrectedElevationTotals`).
        let ascent: Double?
        if workout.hasCorrectedElevationTotals {
            ascent = summary.elevationGainMeters
        } else if let raw = summary.rawElevationGainMeters {
            ascent = raw
        } else {
            ascent = nil
        }
        return WorkoutTrendsSummaryRow(
            id: workout.id,
            startDate: startDate,
            recordedUTCOffsetSeconds: workout.metadata.recordedUTCOffsetSeconds,
            distanceMeters: summary.totalDistanceMeters,
            activeSeconds: summary.totalActiveSeconds,
            averageHeartRateBPM: heartRate,
            ascentMeters: ascent
        )
    }
}

/// Aggregated metrics for one period.
///
/// Distance, active time, and run count are true sums (zero in empty periods).
/// Pace, heart rate, and ascent are `nil` — rendered as gaps, never zeros —
/// when no contributing run carries the metric; mixed periods aggregate the
/// runs that do, with contributor counts exposed so sparse periods are not
/// misread as trends.
public struct WorkoutTrendsPeriodBucket: Identifiable, Hashable, Sendable {
    public let id: WorkoutTrendsPeriodKey
    public let runCount: Int
    public let totalDistanceMeters: Double
    public let totalActiveSeconds: Double
    /// Total active seconds per total kilometre, or `nil` without distance and
    /// active time. This is the time-weighted aggregate pace, not a mean of
    /// per-run paces.
    public let meanActivePaceSecondsPerKilometer: Double?
    /// Active-time-weighted mean of run average heart rates, or `nil` when no
    /// run in the period carries heart rate.
    public let meanHeartRateBPM: Double?
    /// Runs contributing to `meanHeartRateBPM` (out of `runCount`).
    public let heartRateContributingRuns: Int
    /// Sum of per-run ascent over runs that carry elevation data, or `nil`
    /// when none does.
    public let totalAscentMeters: Double?
    /// Runs contributing to `totalAscentMeters` (out of `runCount`).
    public let ascentContributingRuns: Int

    public init(
        id: WorkoutTrendsPeriodKey,
        runCount: Int,
        totalDistanceMeters: Double,
        totalActiveSeconds: Double,
        meanActivePaceSecondsPerKilometer: Double?,
        meanHeartRateBPM: Double?,
        heartRateContributingRuns: Int,
        totalAscentMeters: Double?,
        ascentContributingRuns: Int
    ) {
        self.id = id
        self.runCount = runCount
        self.totalDistanceMeters = totalDistanceMeters
        self.totalActiveSeconds = totalActiveSeconds
        self.meanActivePaceSecondsPerKilometer = meanActivePaceSecondsPerKilometer
        self.meanHeartRateBPM = meanHeartRateBPM
        self.heartRateContributingRuns = heartRateContributingRuns
        self.totalAscentMeters = totalAscentMeters
        self.ascentContributingRuns = ascentContributingRuns
    }
}

/// The complete Trends result for one period, range, and row set.
public struct WorkoutTrendsAggregation: Hashable, Sendable {
    public let period: WorkoutTrendsPeriod
    public let range: WorkoutTrendsRange
    /// Ascending by nominal key. Contiguous across the whole window, including
    /// empty periods (run count zero, pace/HR/ascent `nil`).
    public let buckets: [WorkoutTrendsPeriodBucket]
    /// Rows bucketed into the returned periods.
    public let includedRunCount: Int
    /// Rows whose period falls outside the displayed window: before the range
    /// anchor, older than the render cap, or more than one period ahead of
    /// `now`.
    public let outOfWindowRunCount: Int
    /// Key of the period containing `now` in the display zone, when any
    /// bucket exists.
    public let currentPeriodKey: WorkoutTrendsPeriodKey?
    /// Earliest included nominal key (the snapped anchor for month-count
    /// ranges, or the first row's period for all time).
    public let windowStartKey: WorkoutTrendsPeriodKey?
    /// Totals over the displayed window, computed from rows with the same
    /// weighting rules as the per-period buckets.
    public let totalDistanceMeters: Double
    public let totalActiveSeconds: Double
    public let meanActivePaceSecondsPerKilometer: Double?
    public let meanHeartRateBPM: Double?
    public let heartRateContributingRuns: Int
    public let totalAscentMeters: Double?
    public let ascentContributingRuns: Int
}
