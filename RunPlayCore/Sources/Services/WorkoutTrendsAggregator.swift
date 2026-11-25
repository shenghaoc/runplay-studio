import Foundation

/// How weeks are delimited for weekly Trends buckets: the first weekday and
/// the minimum number of days a year's first week must contain.
///
/// ISO 8601 (Monday, four days) is the default. The app passes the user's
/// convention — the locale's (CLDR week data), or the first weekday chosen in
/// System Settings — so weeks start on Sunday in the United States and in
/// Chinese locales and on Monday in most of Europe.
public struct WorkoutTrendsWeekConvention: Hashable, Sendable {
    /// 1 is Sunday, 2 is Monday, … 7 is Saturday (`Calendar.firstWeekday`).
    public let firstWeekday: Int
    /// 1…7 (`Calendar.minimumDaysInFirstWeek`).
    public let minimumDaysInFirstWeek: Int

    public init(firstWeekday: Int, minimumDaysInFirstWeek: Int) {
        self.firstWeekday = min(max(firstWeekday, 1), 7)
        self.minimumDaysInFirstWeek = min(max(minimumDaysInFirstWeek, 1), 7)
    }

    /// ISO 8601 weeks: Monday start, first week holds at least four days.
    public static let iso8601 = WorkoutTrendsWeekConvention(firstWeekday: 2, minimumDaysInFirstWeek: 4)

    /// The convention a calendar already carries — `Calendar.autoupdatingCurrent`
    /// in the app, which includes the user's first-weekday preference.
    public init(calendar: Calendar) {
        self.init(
            firstWeekday: calendar.firstWeekday,
            minimumDaysInFirstWeek: calendar.minimumDaysInFirstWeek
        )
    }

    /// The Gregorian calendar the buckets use, in `timeZone`.
    func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = self == .iso8601
            ? Calendar(identifier: .iso8601)
            : Calendar(identifier: .gregorian)
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        calendar.timeZone = timeZone
        return calendar
    }
}

/// Deterministic bucketing of Trends summary rows.
///
/// Bucketing rules:
///
/// - Each run belongs to exactly one period: the period containing its
///   canonical start **local date**. A run crossing midnight or a week
///   boundary counts entirely in its start period.
/// - The local date is resolved in the run's recorded UTC offset when the
///   source format carried one; otherwise in the caller's fallback zone.
/// - Weeks follow a `WorkoutTrendsWeekConvention` — ISO 8601 by default
///   (Monday start; the key's year is the week-date year), the user's
///   locale convention in the app. Months and years use Gregorian
///   boundaries under every convention.
/// - Month-count ranges include whole periods only: the anchor instant
///   `now - N months` (display zone) resolves to its period and periods with a
///   nominal key at or after that anchor's key are included. `allTime` starts
///   at the earliest row's period.
///
/// Trends state is active time, not elapsed: pauses never contribute to
/// totals, pace, or heart-rate weighting.
public enum WorkoutTrendsAggregator {
    /// Defensive bound on the enumerated window so a decades-long weekly
    /// library cannot generate an unbounded axis. The window is clamped by
    /// dropping the oldest periods, and the enumeration itself never exceeds
    /// this many steps.
    public static let maximumRenderedPeriods = 5_000

    /// The zone a row buckets in: its recorded offset when present, else the
    /// caller's fallback (the system zone in the app).
    public static func bucketingTimeZone(
        recordedUTCOffsetSeconds: Int?,
        fallback: TimeZone
    ) -> TimeZone {
        guard let offset = recordedUTCOffsetSeconds, offset >= -86_400, offset <= 86_400 else {
            return fallback
        }
        return TimeZone(secondsFromGMT: offset) ?? fallback
    }

    /// Nominal period key for an instant in a zone.
    public static func periodKey(
        for date: Date,
        period: WorkoutTrendsPeriod,
        timeZone: TimeZone,
        weekConvention: WorkoutTrendsWeekConvention = .iso8601
    ) -> WorkoutTrendsPeriodKey {
        let calendar = weekConvention.calendar(in: timeZone)
        switch period {
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return WorkoutTrendsPeriodKey(
                kind: .week,
                year: components.yearForWeekOfYear ?? calendar.component(.yearForWeekOfYear, from: date),
                ordinal: components.weekOfYear ?? calendar.component(.weekOfYear, from: date)
            )
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return WorkoutTrendsPeriodKey(
                kind: .month,
                year: components.year ?? calendar.component(.year, from: date),
                ordinal: components.month ?? calendar.component(.month, from: date)
            )
        case .year:
            return WorkoutTrendsPeriodKey(
                kind: .year,
                year: calendar.component(.year, from: date),
                ordinal: 1
            )
        }
    }

    /// Absolute interval of a nominal key in a zone.
    public static func periodBounds(
        for key: WorkoutTrendsPeriodKey,
        timeZone: TimeZone,
        weekConvention: WorkoutTrendsWeekConvention = .iso8601
    ) -> (start: Date, end: Date) {
        let calendar = weekConvention.calendar(in: timeZone)
        var components = DateComponents()
        switch key.kind {
        case .week:
            components.yearForWeekOfYear = key.year
            components.weekOfYear = key.ordinal
        case .month:
            components.year = key.year
            components.month = key.ordinal
            components.day = 1
        case .year:
            components.year = key.year
            components.month = 1
            components.day = 1
        }
        let start = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let unit: Calendar.Component
        switch key.kind {
        case .week: unit = .weekOfYear
        case .month: unit = .month
        case .year: unit = .year
        }
        // The period's own interval, not the start plus one unit: a period
        // whose first midnight daylight saving skips starts at 01:00, and one
        // unit later is 01:00 on a day that starts at 00:00.
        let end = calendar.dateInterval(of: unit, for: start)?.end ?? start
        return (start, end)
    }

    /// Earliest included key for a month-count range (the anchor's whole
    /// period), or `nil` for all time.
    public static func anchorKey(
        now: Date,
        period: WorkoutTrendsPeriod,
        range: WorkoutTrendsRange,
        timeZone: TimeZone,
        weekConvention: WorkoutTrendsWeekConvention = .iso8601
    ) -> WorkoutTrendsPeriodKey? {
        guard let monthCount = range.monthCount else { return nil }
        let calendar = weekConvention.calendar(in: timeZone)
        let anchorDate = calendar.date(byAdding: .month, value: -monthCount, to: now) ?? now
        return periodKey(for: anchorDate, period: period, timeZone: timeZone, weekConvention: weekConvention)
    }

    /// Buckets rows into a contiguous period series.
    ///
    /// Rows outside the displayed window — before the range anchor, older than
    /// the render cap, or more than one period ahead of `now` — are counted in
    /// `outOfWindowRunCount` rather than shown, so they are disclosed and
    /// never silently dropped.
    public static func aggregate(
        rows: [WorkoutTrendsSummaryRow],
        period: WorkoutTrendsPeriod,
        range: WorkoutTrendsRange,
        now: Date,
        displayTimeZone: TimeZone,
        fallbackBucketingTimeZone: TimeZone,
        weekConvention: WorkoutTrendsWeekConvention = .iso8601
    ) -> WorkoutTrendsAggregation {
        let currentKey = periodKey(
            for: now,
            period: period,
            timeZone: displayTimeZone,
            weekConvention: weekConvention
        )
        let anchor = anchorKey(
            now: now,
            period: period,
            range: range,
            timeZone: displayTimeZone,
            weekConvention: weekConvention
        )

        var accumulators: [WorkoutTrendsPeriodKey: TrendAccumulator] = [:]
        accumulators.reserveCapacity(rows.count)

        var minimumKey: WorkoutTrendsPeriodKey?
        var outOfWindow = 0

        for row in rows {
            let zone = bucketingTimeZone(
                recordedUTCOffsetSeconds: row.recordedUTCOffsetSeconds,
                fallback: fallbackBucketingTimeZone
            )
            let key = periodKey(for: row.startDate, period: period, timeZone: zone, weekConvention: weekConvention)
            if let anchor, key < anchor {
                outOfWindow += 1
                continue
            }
            if let earliest = minimumKey {
                if key < earliest {
                    minimumKey = key
                }
            } else {
                minimumKey = key
            }
            var accumulator = accumulators[key] ?? TrendAccumulator()
            accumulator.add(row)
            accumulators[key] = accumulator
        }

        let (windowStart, windowEnd) = windowBounds(
            newestRowKey: accumulators.keys.max(),
            currentKey: currentKey,
            anchor: anchor,
            minimumKey: minimumKey,
            weekConvention: weekConvention
        )
        let keys = windowKeys(from: windowStart, to: windowEnd, weekConvention: weekConvention)

        let buckets = keys.map { key -> WorkoutTrendsPeriodBucket in
            let accumulator = accumulators[key]
            let totals = accumulator ?? TrendAccumulator()
            return WorkoutTrendsPeriodBucket(
                id: key,
                runCount: accumulator?.runCount ?? 0,
                totalDistanceMeters: totals.distance,
                totalActiveSeconds: totals.active,
                meanActivePaceSecondsPerKilometer: totals.meanActivePace,
                meanHeartRateBPM: totals.meanHeartRate,
                heartRateContributingRuns: accumulator?.heartRateContributors ?? 0,
                totalAscentMeters: totals.totalAscent,
                ascentContributingRuns: accumulator?.ascentContributors ?? 0
            )
        }

        var includedRunCount = 0
        let includedKeys = Set(keys)
        for key in keys {
            includedRunCount += accumulators[key]?.runCount ?? 0
        }
        for (key, accumulator) in accumulators where !includedKeys.contains(key) {
            outOfWindow += accumulator.runCount
        }

        var window = TrendAccumulator()
        for key in keys {
            guard let accumulator = accumulators[key] else { continue }
            window.merge(accumulator)
        }

        return WorkoutTrendsAggregation(
            period: period,
            range: range,
            buckets: buckets,
            includedRunCount: includedRunCount,
            outOfWindowRunCount: outOfWindow,
            currentPeriodKey: includedKeys.contains(currentKey) ? currentKey : nil,
            windowStartKey: keys.first,
            totalDistanceMeters: window.distance,
            totalActiveSeconds: window.active,
            meanActivePaceSecondsPerKilometer: window.meanActivePace,
            meanHeartRateBPM: window.meanHeartRate,
            heartRateContributingRuns: window.heartRateContributors,
            totalAscentMeters: window.totalAscent,
            ascentContributingRuns: window.ascentContributors
        )
    }

    /// The running totals of one period, or of the whole window.
    private struct TrendAccumulator {
        var runCount = 0
        var distance: Double = 0
        var active: Double = 0
        var heartRateWeightedSum: Double = 0
        var heartRateWeight: Double = 0
        var heartRateSimpleSum: Double = 0
        var heartRateSimpleCount = 0
        var heartRateContributors = 0
        var ascent: Double = 0
        var ascentContributors = 0

        mutating func add(_ row: WorkoutTrendsSummaryRow) {
            runCount += 1
            distance += max(0, row.distanceMeters)
            active += max(0, row.activeSeconds)
            if let heartRate = row.averageHeartRateBPM {
                let weight = max(0, row.activeSeconds)
                heartRateWeightedSum += heartRate * weight
                heartRateWeight += weight
                heartRateSimpleSum += heartRate
                heartRateSimpleCount += 1
                heartRateContributors += 1
            }
            if let ascent = row.ascentMeters {
                self.ascent += max(0, ascent)
                ascentContributors += 1
            }
        }

        /// Adds another period's totals; the run count is not part of the window totals.
        mutating func merge(_ other: TrendAccumulator) {
            distance += other.distance
            active += other.active
            heartRateWeightedSum += other.heartRateWeightedSum
            heartRateWeight += other.heartRateWeight
            heartRateSimpleSum += other.heartRateSimpleSum
            heartRateSimpleCount += other.heartRateSimpleCount
            heartRateContributors += other.heartRateContributors
            ascent += other.ascent
            ascentContributors += other.ascentContributors
        }

        /// Active seconds per kilometre, when both are positive and finite.
        var meanActivePace: Double? {
            let kilometres = distance / 1_000
            if kilometres > 0, active > 0, (active / kilometres).isFinite {
                return active / kilometres
            }
            return nil
        }

        /// The active-time weighted mean heart rate, or the plain mean when no
        /// contributing run has active time; nil without a contributor.
        var meanHeartRate: Double? {
            if heartRateContributors > 0 {
                if heartRateWeight > 0 {
                    return heartRateWeightedSum / heartRateWeight
                } else {
                    return heartRateSimpleSum / Double(heartRateSimpleCount)
                }
            }
            return nil
        }

        var totalAscent: Double? {
            ascentContributors > 0 ? ascent : nil
        }
    }

    /// The window always includes the current period (an in-progress
    /// trailing bar), and extends at most one period past it. One period is
    /// exactly what a run recorded in a zone ahead of the display zone
    /// needs; beyond that a row is clock skew or a corrupt date, and
    /// letting it set the end would push the real data out of a capped
    /// window entirely. Such rows are counted in `outOfWindowRunCount`,
    /// never silently dropped.
    private static func windowBounds(
        newestRowKey: WorkoutTrendsPeriodKey?,
        currentKey: WorkoutTrendsPeriodKey,
        anchor: WorkoutTrendsPeriodKey?,
        minimumKey: WorkoutTrendsPeriodKey?,
        weekConvention: WorkoutTrendsWeekConvention
    ) -> (start: WorkoutTrendsPeriodKey, end: WorkoutTrendsPeriodKey) {
        let periodAfterCurrent = nextKey(after: currentKey, weekConvention: weekConvention)
        let windowEnd: WorkoutTrendsPeriodKey
        if let newestRowKey, newestRowKey > currentKey, newestRowKey <= periodAfterCurrent {
            windowEnd = newestRowKey
        } else {
            windowEnd = currentKey
        }
        var windowStart = anchor ?? minimumKey ?? currentKey
        // The current period is always in the window, even when every row is
        // dated ahead of it.
        windowStart = min(windowStart, currentKey)
        if windowStart > windowEnd {
            windowStart = windowEnd
        }
        return (windowStart, windowEnd)
    }

    /// Enumerate backwards from the newest period, stopping at the render
    /// cap, so the clamp drops the oldest periods without first building
    /// (or walking) a span that an ancient row could make enormous. Returns
    /// the keys oldest first.
    private static func windowKeys(
        from windowStart: WorkoutTrendsPeriodKey,
        to windowEnd: WorkoutTrendsPeriodKey,
        weekConvention: WorkoutTrendsWeekConvention
    ) -> [WorkoutTrendsPeriodKey] {
        var keys: [WorkoutTrendsPeriodKey] = []
        var cursor = windowEnd
        while keys.count < maximumRenderedPeriods {
            keys.append(cursor)
            if cursor <= windowStart { break }
            let previous = previousKey(before: cursor, weekConvention: weekConvention)
            // `previousKey` returns its argument when the component domain
            // cannot go lower; stop rather than repeat a key.
            if previous >= cursor { break }
            cursor = previous
        }
        keys.reverse()
        return keys
    }

    /// The nominal key following `key` within its kind. Ascends by one unit;
    /// when addition overflows the component domain this returns `key` itself,
    /// which stops enumeration safely.
    static func nextKey(
        after key: WorkoutTrendsPeriodKey,
        weekConvention: WorkoutTrendsWeekConvention = .iso8601
    ) -> WorkoutTrendsPeriodKey {
        let calendar = weekConvention.calendar(in: TimeZone(secondsFromGMT: 0)!)
        var components = DateComponents()
        switch key.kind {
        case .week:
            components.yearForWeekOfYear = key.year
            components.weekOfYear = key.ordinal
        case .month:
            components.year = key.year
            components.month = key.ordinal
            components.day = 1
        case .year:
            components.year = key.year
            components.month = 1
            components.day = 1
        }
        guard let start = calendar.date(from: components) else { return key }
        let unit: Calendar.Component
        switch key.kind {
        case .week: unit = .weekOfYear
        case .month: unit = .month
        case .year: unit = .year
        }
        guard let next = calendar.date(byAdding: unit, value: 1, to: start) else { return key }
        return periodKey(for: next, period: key.kind, timeZone: calendar.timeZone, weekConvention: weekConvention)
    }

    /// The nominal key preceding `key` within its kind. Descends by one unit;
    /// when subtraction leaves the component domain this returns `key` itself,
    /// which stops enumeration safely.
    static func previousKey(
        before key: WorkoutTrendsPeriodKey,
        weekConvention: WorkoutTrendsWeekConvention = .iso8601
    ) -> WorkoutTrendsPeriodKey {
        let calendar = weekConvention.calendar(in: TimeZone(secondsFromGMT: 0)!)
        var components = DateComponents()
        switch key.kind {
        case .week:
            components.yearForWeekOfYear = key.year
            components.weekOfYear = key.ordinal
        case .month:
            components.year = key.year
            components.month = key.ordinal
            components.day = 1
        case .year:
            components.year = key.year
            components.month = 1
            components.day = 1
        }
        let unit: Calendar.Component
        switch key.kind {
        case .week: unit = .weekOfYear
        case .month: unit = .month
        case .year: unit = .year
        }
        guard let start = calendar.date(from: components),
              let previous = calendar.date(byAdding: unit, value: -1, to: start)
        else { return key }
        return periodKey(for: previous, period: key.kind, timeZone: calendar.timeZone, weekConvention: weekConvention)
    }
}
