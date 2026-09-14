import Foundation

/// Deterministic bucketing of Trends summary rows.
///
/// Bucketing rules:
///
/// - Each run belongs to exactly one period: the period containing its
///   canonical start **local date**. A run crossing midnight or a week
///   boundary counts entirely in its start period.
/// - The local date is resolved in the run's recorded UTC offset when the
///   source format carried one; otherwise in the caller's fallback zone.
/// - Weeks are ISO 8601 (Monday start; the key's year is the ISO week-date
///   year). Months and years use Gregorian boundaries, which the ISO calendar
///   shares.
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
    /// dropping the oldest periods.
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
        timeZone: TimeZone
    ) -> WorkoutTrendsPeriodKey {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
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
        timeZone: TimeZone
    ) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
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
        let end = calendar.date(byAdding: unit, value: 1, to: start) ?? start
        return (start, end)
    }

    /// Earliest included key for a month-count range (the anchor's whole
    /// period), or `nil` for all time.
    public static func anchorKey(
        now: Date,
        period: WorkoutTrendsPeriod,
        range: WorkoutTrendsRange,
        timeZone: TimeZone
    ) -> WorkoutTrendsPeriodKey? {
        guard let monthCount = range.monthCount else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let anchorDate = calendar.date(byAdding: .month, value: -monthCount, to: now) ?? now
        return periodKey(for: anchorDate, period: period, timeZone: timeZone)
    }

    /// Buckets rows into a contiguous period series.
    ///
    /// Rows before the range anchor are counted in `outOfWindowRunCount`, not
    /// shown. Rows dated beyond the current period extend the window so
    /// clock-skewed or future-dated data is never silently dropped.
    public static func aggregate(
        rows: [WorkoutTrendsSummaryRow],
        period: WorkoutTrendsPeriod,
        range: WorkoutTrendsRange,
        now: Date,
        displayTimeZone: TimeZone,
        fallbackBucketingTimeZone: TimeZone
    ) -> WorkoutTrendsAggregation {
        let currentKey = periodKey(for: now, period: period, timeZone: displayTimeZone)
        let anchor = anchorKey(now: now, period: period, range: range, timeZone: displayTimeZone)

        struct Accumulator {
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
        }
        var accumulators: [WorkoutTrendsPeriodKey: Accumulator] = [:]
        accumulators.reserveCapacity(rows.count)

        var minimumKey: WorkoutTrendsPeriodKey?
        var outOfWindow = 0

        for row in rows {
            let zone = bucketingTimeZone(
                recordedUTCOffsetSeconds: row.recordedUTCOffsetSeconds,
                fallback: fallbackBucketingTimeZone
            )
            let key = periodKey(for: row.startDate, period: period, timeZone: zone)
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
            var accumulator = accumulators[key] ?? Accumulator()
            accumulator.runCount += 1
            accumulator.distance += max(0, row.distanceMeters)
            accumulator.active += max(0, row.activeSeconds)
            if let heartRate = row.averageHeartRateBPM {
                let weight = max(0, row.activeSeconds)
                accumulator.heartRateWeightedSum += heartRate * weight
                accumulator.heartRateWeight += weight
                accumulator.heartRateSimpleSum += heartRate
                accumulator.heartRateSimpleCount += 1
                accumulator.heartRateContributors += 1
            }
            if let ascent = row.ascentMeters {
                accumulator.ascent += max(0, ascent)
                accumulator.ascentContributors += 1
            }
            accumulators[key] = accumulator
        }

        // The window always includes the current period (an in-progress
        // trailing bar) and any future-dated rows; both extend past `now`.
        let windowEnd = max(currentKey, accumulators.keys.max() ?? currentKey)
        var windowStart = anchor ?? minimumKey ?? currentKey
        if windowStart > windowEnd {
            windowStart = windowEnd
        }

        // Enumerate the whole nominal span first (bounded by a hard iteration
        // cap), then clamp by dropping the oldest periods so the newest data
        // always stays visible.
        var keys: [WorkoutTrendsPeriodKey] = []
        var cursor = windowStart
        while cursor <= windowEnd && keys.count < 100 * maximumRenderedPeriods {
            keys.append(cursor)
            cursor = nextKey(after: cursor)
        }
        if keys.count > maximumRenderedPeriods {
            keys.removeFirst(keys.count - maximumRenderedPeriods)
        }

        let buckets = keys.map { key -> WorkoutTrendsPeriodBucket in
            let accumulator = accumulators[key]
            let distance = accumulator?.distance ?? 0
            let active = accumulator?.active ?? 0
            let kilometres = distance / 1_000
            let pace: Double?
            if kilometres > 0, active > 0, (active / kilometres).isFinite {
                pace = active / kilometres
            } else {
                pace = nil
            }
            let heartRate: Double?
            if let accumulator, accumulator.heartRateContributors > 0 {
                if accumulator.heartRateWeight > 0 {
                    heartRate = accumulator.heartRateWeightedSum / accumulator.heartRateWeight
                } else {
                    heartRate = accumulator.heartRateSimpleSum
                        / Double(accumulator.heartRateSimpleCount)
                }
            } else {
                heartRate = nil
            }
            let ascent: Double?
            if let accumulator, accumulator.ascentContributors > 0 {
                ascent = accumulator.ascent
            } else {
                ascent = nil
            }
            return WorkoutTrendsPeriodBucket(
                id: key,
                runCount: accumulator?.runCount ?? 0,
                totalDistanceMeters: distance,
                totalActiveSeconds: active,
                meanActivePaceSecondsPerKilometer: pace,
                meanHeartRateBPM: heartRate,
                heartRateContributingRuns: accumulator?.heartRateContributors ?? 0,
                totalAscentMeters: ascent,
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

        var windowDistance = 0.0
        var windowActive = 0.0
        var windowHeartRateWeightedSum = 0.0
        var windowHeartRateWeight = 0.0
        var windowHeartRateSimpleSum = 0.0
        var windowHeartRateSimpleCount = 0
        var windowHeartRateContributors = 0
        var windowAscent = 0.0
        var windowAscentContributors = 0
        for key in keys {
            guard let accumulator = accumulators[key] else { continue }
            windowDistance += accumulator.distance
            windowActive += accumulator.active
            windowHeartRateWeightedSum += accumulator.heartRateWeightedSum
            windowHeartRateWeight += accumulator.heartRateWeight
            windowHeartRateSimpleSum += accumulator.heartRateSimpleSum
            windowHeartRateSimpleCount += accumulator.heartRateSimpleCount
            windowHeartRateContributors += accumulator.heartRateContributors
            windowAscent += accumulator.ascent
            windowAscentContributors += accumulator.ascentContributors
        }
        let windowKilometres = windowDistance / 1_000
        let windowPace: Double?
        if windowKilometres > 0, windowActive > 0, (windowActive / windowKilometres).isFinite {
            windowPace = windowActive / windowKilometres
        } else {
            windowPace = nil
        }
        let windowHeartRate: Double?
        if windowHeartRateContributors > 0 {
            if windowHeartRateWeight > 0 {
                windowHeartRate = windowHeartRateWeightedSum / windowHeartRateWeight
            } else {
                windowHeartRate = windowHeartRateSimpleSum / Double(windowHeartRateSimpleCount)
            }
        } else {
            windowHeartRate = nil
        }

        return WorkoutTrendsAggregation(
            period: period,
            range: range,
            buckets: buckets,
            includedRunCount: includedRunCount,
            outOfWindowRunCount: outOfWindow,
            currentPeriodKey: keys.last == currentKey ? currentKey : nil,
            windowStartKey: keys.first,
            totalDistanceMeters: windowDistance,
            totalActiveSeconds: windowActive,
            meanActivePaceSecondsPerKilometer: windowPace,
            meanHeartRateBPM: windowHeartRate,
            heartRateContributingRuns: windowHeartRateContributors,
            totalAscentMeters: windowAscentContributors > 0 ? windowAscent : nil,
            ascentContributingRuns: windowAscentContributors
        )
    }

    /// The nominal key following `key` within its kind. Ascends by one unit;
    /// when addition overflows the component domain this returns `key` itself,
    /// which stops enumeration safely.
    static func nextKey(after key: WorkoutTrendsPeriodKey) -> WorkoutTrendsPeriodKey {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
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
        return periodKey(for: next, period: key.kind, timeZone: calendar.timeZone)
    }
}
