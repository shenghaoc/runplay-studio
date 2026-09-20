import Foundation

/// One calendar day of aggregated training load.
///
/// `contribution` carries the distinction the chart depends on: a day whose
/// runs all lack usable heart rate is **zero-contribution**, not a zero-load
/// rest day. The model integrates it as zero either way, but the UI must
/// never present invented load as if it were measured, and the spoken
/// summaries disclose it.
public struct TrainingLoadDay: Equatable, Hashable, Sendable {
    public enum Contribution: Equatable, Hashable, Sendable {
        /// At least one run contributed a measured load.
        case hrDay
        /// Runs exist, but none carries a measured load — non-contributing
        /// to the model by default.
        case noHRData
        /// No runs at all — a true zero.
        case restDay
    }

    /// Local day start in the day's own bucketing zone.
    public let date: Date
    public let measuredLoad: Double
    public let estimatedLoad: Double
    public let contribution: Contribution
    public let runCount: Int

    public init(
        date: Date,
        measuredLoad: Double,
        estimatedLoad: Double,
        contribution: Contribution,
        runCount: Int
    ) {
        self.date = date
        self.measuredLoad = measuredLoad
        self.estimatedLoad = estimatedLoad
        self.contribution = contribution
        self.runCount = runCount
    }
}

/// One day's fitness, fatigue, and form.
public struct FitnessFatigueDay: Equatable, Hashable, Sendable {
    public let date: Date
    /// Fitness (chronic training load).
    public let ctl: Double
    /// Fatigue (acute training load).
    public let atl: Double

    /// Form: same-day fitness minus fatigue.
    public var tsb: Double { ctl - atl }

    public init(date: Date, ctl: Double, atl: Double) {
        self.date = date
        self.ctl = ctl
        self.atl = atl
    }
}

/// The daily load series plus the model derived from it.
public struct FitnessFatigueSeries: Equatable, Hashable, Sendable {
    public let loadDays: [TrainingLoadDay]
    /// Aligned index-for-index with `loadDays`.
    public let modelDays: [FitnessFatigueDay]
    /// Measured days ÷ days with runs across the series, or `nil` when no
    /// day carries a run. The trustworthiness disclosure for the curve.
    public let hrCoverageFraction: Double?
    public let includesEstimatedLoads: Bool

    public init(
        loadDays: [TrainingLoadDay],
        modelDays: [FitnessFatigueDay],
        hrCoverageFraction: Double?,
        includesEstimatedLoads: Bool
    ) {
        self.loadDays = loadDays
        self.modelDays = modelDays
        self.hrCoverageFraction = hrCoverageFraction
        self.includesEstimatedLoads = includesEstimatedLoads
    }
}

/// Daily aggregation and the Banister-style fitness/fatigue/form model.
///
/// The rollup is per-day scalar work over stored snapshots — deliberately
/// Swift, per the engine ownership split. The model is the standard
/// first-order daily recursion `state_d = state_{d-1} + (load_d −
/// state_{d-1}) / τ` with fitness/fatigue time constants (defaults 42 and 7
/// days) and form as the same-day difference. Estimated loads are excluded
/// from the model by default: a fitness/fatigue curve is only meaningful
/// over comparable inputs, and invented values — even conservative ones —
/// bias the model in the direction that matters to someone training.
public enum TrainingLoadRollup {
    public static let defaultCTLTimeConstantDays: Double = 42
    public static let defaultATLTimeConstantDays: Double = 7

    /// Safety ceiling on the enumerated day span, matching the Trends
    /// rendered-period cap. The span is truncated from the oldest end.
    public static let maximumModeledDays = 5_000

    /// Local day start for a workout start instant, honouring the recorded
    /// UTC offset exactly like Trends bucketing.
    ///
    /// The bucketing resolves the run's local calendar date where it was
    /// recorded, then re-resolves that date in the fallback (display) zone —
    /// so every day key shares one axis while a run recorded abroad near
    /// midnight still lands on its local day. This accepts the same
    /// mixed-zone display edge Trends documents: a nominal day here can
    /// differ from the display-zone day containing the same instant.
    public static func dayStart(
        for date: Date,
        recordedUTCOffsetSeconds: Int?,
        fallbackTimeZone: TimeZone
    ) -> Date {
        let zone = WorkoutTrendsAggregator.bucketingTimeZone(
            recordedUTCOffsetSeconds: recordedUTCOffsetSeconds,
            fallback: fallbackTimeZone
        )
        var recordedCalendar = Calendar(identifier: .iso8601)
        recordedCalendar.timeZone = zone
        let components = recordedCalendar.dateComponents([.year, .month, .day], from: date)
        var displayCalendar = Calendar(identifier: .iso8601)
        displayCalendar.timeZone = fallbackTimeZone
        return displayCalendar.date(from: components) ?? displayCalendar.startOfDay(for: date)
    }

    /// Build the contiguous daily load series from per-workout snapshots.
    ///
    /// Days run from the earliest to the latest contributing day with rest
    /// days filled in; the span is truncated from the oldest end at
    /// `maximumModeledDays`. Runs without a snapshot still occupy their day
    /// as `noHRData` (or join a mixed day) so an un-backfilled library shows
    /// honest gaps rather than fake rest days.
    public static func dailyLoadDays(
        contributions: [(date: Date, recordedUTCOffsetSeconds: Int?, load: TrainingLoadSnapshot?)],
        fallbackTimeZone: TimeZone
    ) -> [TrainingLoadDay] {
        guard !contributions.isEmpty else { return [] }

        var byDayStart: [Date: (measured: Double, estimated: Double, runs: Int, hasLoad: Bool)] = [:]
        for contribution in contributions {
            let start = dayStart(
                for: contribution.date,
                recordedUTCOffsetSeconds: contribution.recordedUTCOffsetSeconds,
                fallbackTimeZone: fallbackTimeZone
            )
            var day = byDayStart[start] ?? (0, 0, 0, false)
            if let load = contribution.load {
                day.hasLoad = true
                switch load.kind {
                case .measured: day.measured += load.banisterTRIMP
                case .estimated: day.estimated += load.banisterTRIMP
                }
            }
            day.runs += 1
            byDayStart[start] = day
        }

        let sortedStarts = byDayStart.keys.sorted()
        guard let first = sortedStarts.first, let last = sortedStarts.last else { return [] }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = fallbackTimeZone

        // Enumerate backwards so the cap drops the oldest days, never the
        // newest, without materializing the unbounded range first.
        var days: [TrainingLoadDay] = []
        var current = last
        while days.count < maximumModeledDays {
            if let day = byDayStart[current] {
                let contribution: TrainingLoadDay.Contribution = day.measured > 0
                    ? .hrDay
                    : (day.runs > 0 ? .noHRData : .restDay)
                days.append(TrainingLoadDay(
                    date: current,
                    measuredLoad: day.measured,
                    estimatedLoad: day.estimated,
                    contribution: contribution,
                    runCount: day.runs
                ))
            } else {
                days.append(TrainingLoadDay(
                    date: current,
                    measuredLoad: 0,
                    estimatedLoad: 0,
                    contribution: .restDay,
                    runCount: 0
                ))
            }
            if current <= first { break }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: current) else { break }
            current = previous
        }
        days.reverse()
        return days
    }

    /// Run the fitness/fatigue recursion over a contiguous daily series.
    ///
    /// Days whose contribution is `noHRData` integrate as zero unless
    /// `includeEstimatedLoads` opts them in — zero-contribution, never a
    /// silently invented value. Time constants are clamped to at least one
    /// day.
    public static func fitnessFatigue(
        over days: [TrainingLoadDay],
        ctlTimeConstantDays: Double,
        atlTimeConstantDays: Double,
        includeEstimatedLoads: Bool
    ) -> [FitnessFatigueDay] {
        let ctlTau = max(1, ctlTimeConstantDays)
        let atlTau = max(1, atlTimeConstantDays)
        var result: [FitnessFatigueDay] = []
        result.reserveCapacity(days.count)

        var ctl = 0.0
        var atl = 0.0
        for day in days {
            var load = day.measuredLoad
            if includeEstimatedLoads {
                load += day.estimatedLoad
            }
            ctl += (load - ctl) / ctlTau
            atl += (load - atl) / atlTau
            result.append(FitnessFatigueDay(date: day.date, ctl: ctl, atl: atl))
        }
        return result
    }

    /// Convenience: daily series plus model plus the coverage disclosure.
    public static func series(
        contributions: [(date: Date, recordedUTCOffsetSeconds: Int?, load: TrainingLoadSnapshot?)],
        fallbackTimeZone: TimeZone,
        ctlTimeConstantDays: Double = defaultCTLTimeConstantDays,
        atlTimeConstantDays: Double = defaultATLTimeConstantDays,
        includeEstimatedLoads: Bool = false
    ) -> FitnessFatigueSeries {
        let days = dailyLoadDays(
            contributions: contributions,
            fallbackTimeZone: fallbackTimeZone
        )
        let model = fitnessFatigue(
            over: days,
            ctlTimeConstantDays: ctlTimeConstantDays,
            atlTimeConstantDays: atlTimeConstantDays,
            includeEstimatedLoads: includeEstimatedLoads
        )
        let runDays = days.filter { $0.runCount > 0 }
        let hrDays = runDays.filter { $0.contribution == .hrDay }
        let coverage: Double? = runDays.isEmpty
            ? nil
            : Double(hrDays.count) / Double(runDays.count)
        return FitnessFatigueSeries(
            loadDays: days,
            modelDays: model,
            hrCoverageFraction: coverage,
            includesEstimatedLoads: includeEstimatedLoads
        )
    }
}
