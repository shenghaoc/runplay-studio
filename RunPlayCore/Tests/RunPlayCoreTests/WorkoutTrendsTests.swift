import XCTest
@testable import RunPlayCore

final class WorkoutTrendsTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let tokyo = TimeZone(secondsFromGMT: 32_400)!
    private let newYork = TimeZone(identifier: "America/New_York")!

    // MARK: - Helpers

    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    private func row(
        _ startDate: Date,
        id: UUID = UUID(),
        offset: Int? = nil,
        distance: Double = 10_000,
        active: Double = 3_600,
        heartRate: Double? = nil,
        ascent: Double? = nil
    ) -> WorkoutTrendsSummaryRow {
        WorkoutTrendsSummaryRow(
            id: id,
            startDate: startDate,
            recordedUTCOffsetSeconds: offset,
            distanceMeters: distance,
            activeSeconds: active,
            averageHeartRateBPM: heartRate,
            ascentMeters: ascent
        )
    }

    private func key(_ kind: WorkoutTrendsPeriod, _ year: Int, _ ordinal: Int) -> WorkoutTrendsPeriodKey {
        WorkoutTrendsPeriodKey(kind: kind, year: year, ordinal: ordinal)
    }

    // MARK: - ISO week bucketing

    func testWeekKeysFollowISOWeekDateYear() {
        // 1 January 2027 is a Friday and belongs to ISO week 2026-W53.
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: utcDate(2027, 1, 1), period: .week, timeZone: utc),
            key(.week, 2026, 53)
        )
        // 1 January 2023 is a Sunday and belongs to 2022-W52.
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: utcDate(2023, 1, 1), period: .week, timeZone: utc),
            key(.week, 2022, 52)
        )
        // 1 January 2026 is a Thursday and starts 2026-W01.
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: utcDate(2026, 1, 1), period: .week, timeZone: utc),
            key(.week, 2026, 1)
        )
        // 28 December 2026 is a Monday and starts 2026-W53.
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: utcDate(2026, 12, 28), period: .week, timeZone: utc),
            key(.week, 2026, 53)
        )
        // Sunday ends its week; Monday starts the next one.
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: utcDate(2026, 9, 13), period: .week, timeZone: utc),
            key(.week, 2026, 37)
        )
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: utcDate(2026, 9, 14), period: .week, timeZone: utc),
            key(.week, 2026, 38)
        )
    }

    func testMonthAndYearKeys() {
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: utcDate(2026, 9, 30, 23, 59, 59), period: .month, timeZone: utc),
            key(.month, 2026, 9)
        )
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: utcDate(2026, 1, 1, 0, 0, 0), period: .year, timeZone: utc),
            key(.year, 2026, 1)
        )
    }

    func testPeriodBoundsAreHalfOpenPeriodIntervals() {
        let month = WorkoutTrendsAggregator.periodBounds(for: key(.month, 2026, 9), timeZone: utc)
        XCTAssertEqual(month.start, utcDate(2026, 9, 1, 0))
        XCTAssertEqual(month.end, utcDate(2026, 10, 1, 0))

        let week = WorkoutTrendsAggregator.periodBounds(for: key(.week, 2026, 38), timeZone: utc)
        XCTAssertEqual(week.start, utcDate(2026, 9, 14, 0))
        XCTAssertEqual(week.end, utcDate(2026, 9, 21, 0))

        let year = WorkoutTrendsAggregator.periodBounds(for: key(.year, 2026, 1), timeZone: utc)
        XCTAssertEqual(year.start, utcDate(2026, 1, 1, 0))
        XCTAssertEqual(year.end, utcDate(2027, 1, 1, 0))
    }

    func testNextKeyRollsOverYearBoundaries() {
        XCTAssertEqual(
            WorkoutTrendsAggregator.nextKey(after: key(.week, 2026, 53)),
            key(.week, 2027, 1)
        )
        XCTAssertEqual(
            WorkoutTrendsAggregator.nextKey(after: key(.month, 2026, 12)),
            key(.month, 2027, 1)
        )
        XCTAssertEqual(
            WorkoutTrendsAggregator.nextKey(after: key(.year, 2026, 1)),
            key(.year, 2027, 1)
        )
    }

    // MARK: - Recorded-offset and DST bucketing

    func testRecordedOffsetBucketsLocalDateNotUTC() {
        // Same instant, Sunday 20:00 UTC: with +09:00 the local date is
        // Monday 15 September; with no recorded offset it stays 13 September.
        let instant = utcDate(2026, 9, 13, 20, 0, 0)
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(
                for: instant, period: .week,
                timeZone: WorkoutTrendsAggregator.bucketingTimeZone(recordedUTCOffsetSeconds: 32_400, fallback: utc)
            ),
            key(.week, 2026, 38)
        )
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(
                for: instant, period: .week,
                timeZone: WorkoutTrendsAggregator.bucketingTimeZone(recordedUTCOffsetSeconds: nil, fallback: utc)
            ),
            key(.week, 2026, 37)
        )
    }

    func testDSTSpringForwardUsesRecordedLocalDate() {
        // 23:30 on Sunday 8 March 2026, recorded as EDT (-04:00). The local
        // date is still 8 March (week 10); naive-UTC bucketing would land on
        // Monday 9 March (week 11).
        let localSundayEvening = utcDate(2026, 3, 9, 3, 30, 0) // 03:30Z == 23:30 EDT
        let zone = WorkoutTrendsAggregator.bucketingTimeZone(recordedUTCOffsetSeconds: -14_400, fallback: newYork)
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: localSundayEvening, period: .week, timeZone: zone),
            key(.week, 2026, 10)
        )
        // The pre-transition offset (-05:00) on Saturday evening is 7 March,
        // also week 10, one day earlier.
        let saturdayEvening = utcDate(2026, 3, 8, 4, 30, 0) // 04:30Z == 23:30 EST
        let estZone = WorkoutTrendsAggregator.bucketingTimeZone(recordedUTCOffsetSeconds: -18_000, fallback: newYork)
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: saturdayEvening, period: .month, timeZone: estZone),
            key(.month, 2026, 3)
        )
    }

    func testDSTFallBackUsesRecordedLocalDate() {
        // 23:30 on Sunday 1 November 2026 recorded as EST (-05:00) is still
        // 1 November locally (week 44); naive-UTC bucketing would land on
        // Monday 2 November (week 45). Both fold instants stay on 1 November.
        let lateSunday = utcDate(2026, 11, 2, 4, 30, 0) // 04:30Z == 23:30 EST
        let zone = WorkoutTrendsAggregator.bucketingTimeZone(recordedUTCOffsetSeconds: -18_000, fallback: newYork)
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: lateSunday, period: .week, timeZone: zone),
            key(.week, 2026, 44)
        )
        let earlySundayEDT = utcDate(2026, 11, 1, 5, 30, 0) // 05:30Z == 00:30 EDT
        let edtZone = WorkoutTrendsAggregator.bucketingTimeZone(recordedUTCOffsetSeconds: -14_400, fallback: newYork)
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: earlySundayEDT, period: .week, timeZone: edtZone),
            key(.week, 2026, 44)
        )
    }

    func testFallbackZoneIsDSTAwareNamedZone() {
        // FIT-style rows carry no offset; bucketing in America/New_York must
        // resolve local dates across both 2026 transitions correctly.
        let afterSpring = utcDate(2026, 3, 8, 6, 30, 0) // 01:30 EST, still 8 March
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: afterSpring, period: .month, timeZone: newYork),
            key(.month, 2026, 3)
        )
        let duringFall = utcDate(2026, 11, 1, 5, 30, 0) // 01:30 EDT fold, 1 November
        XCTAssertEqual(
            WorkoutTrendsAggregator.periodKey(for: duringFall, period: .month, timeZone: newYork),
            key(.month, 2026, 11)
        )
    }

    func testMidnightAndWeekBoundaryRunsBucketByStartDate() {
        let now = utcDate(2026, 9, 16)
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [
                row(utcDate(2026, 9, 12, 23, 30, 0)), // Saturday 23:30, crosses midnight
                row(utcDate(2026, 9, 13, 23, 30, 0)), // Sunday 23:30, crosses week boundary
                row(utcDate(2026, 9, 14, 0, 30, 0))   // Monday 00:30, next week
            ],
            period: .week,
            range: .allTime,
            now: now,
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(aggregation.buckets.map(\.id), [key(.week, 2026, 37), key(.week, 2026, 38)])
        XCTAssertEqual(aggregation.buckets.first?.runCount, 2)
        XCTAssertEqual(aggregation.buckets.last?.runCount, 1)
    }

    // MARK: - Range snapping

    func testMonthlyRangeSnapsToWholeMonths() {
        let now = utcDate(2026, 9, 14, 12)
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [
                row(utcDate(2026, 6, 2)),   // inside the snapped anchor month
                row(utcDate(2026, 2, 10)),  // before the anchor
                row(utcDate(2026, 9, 3))
            ],
            period: .month,
            range: .last3Months,
            now: now,
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(
            aggregation.buckets.map(\.id),
            [key(.month, 2026, 6), key(.month, 2026, 7), key(.month, 2026, 8), key(.month, 2026, 9)]
        )
        XCTAssertEqual(aggregation.windowStartKey, key(.month, 2026, 6))
        XCTAssertEqual(aggregation.outOfWindowRunCount, 1)
        XCTAssertEqual(aggregation.includedRunCount, 2)
        XCTAssertEqual(aggregation.currentPeriodKey, key(.month, 2026, 9))
    }

    func testWeeklyRangeSnapsToWholeWeeks() {
        let now = utcDate(2026, 9, 14, 12) // Monday
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [row(utcDate(2026, 6, 14))], // Sunday inside the anchor week (W24)
            period: .week,
            range: .last3Months,
            now: now,
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(aggregation.windowStartKey, key(.week, 2026, 24))
        XCTAssertEqual(aggregation.buckets.first?.runCount, 1)
        XCTAssertEqual(aggregation.buckets.last?.id, key(.week, 2026, 38))
    }

    func testTwelveMonthRangeAnchorsOneYearBack() {
        let now = utcDate(2026, 9, 14)
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [],
            period: .month,
            range: .last12Months,
            now: now,
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(aggregation.buckets.first?.id, key(.month, 2025, 9))
        XCTAssertEqual(aggregation.buckets.count, 13)
    }

    func testAllTimeStartsAtFirstRowPeriod() {
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [row(utcDate(2026, 9, 3)), row(utcDate(2024, 1, 15))],
            period: .month,
            range: .allTime,
            now: utcDate(2026, 9, 14),
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(aggregation.buckets.first?.id, key(.month, 2024, 1))
        XCTAssertEqual(aggregation.buckets.last?.id, key(.month, 2026, 9))
        // Every month between the two rows exists, empty ones included.
        XCTAssertEqual(aggregation.buckets.count, 33)
        let february2024 = aggregation.buckets.first(where: { $0.id == key(.month, 2024, 2) })
        XCTAssertEqual(february2024?.runCount, 0)
        XCTAssertEqual(february2024?.totalDistanceMeters, 0)
        XCTAssertNil(february2024?.meanActivePaceSecondsPerKilometer)
        XCTAssertNil(february2024?.meanHeartRateBPM)
        XCTAssertNil(february2024?.totalAscentMeters)
    }

    func testWindowCapDropsOldestPeriods() {
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [row(utcDate(1926, 1, 5)), row(utcDate(2026, 9, 3))],
            period: .week,
            range: .allTime,
            now: utcDate(2026, 9, 14),
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(aggregation.buckets.count, WorkoutTrendsAggregator.maximumRenderedPeriods)
        XCTAssertGreaterThan(aggregation.windowStartKey!, key(.week, 1926, 2))
        XCTAssertEqual(aggregation.outOfWindowRunCount, 1)
        XCTAssertEqual(aggregation.includedRunCount, 1)
    }

    // MARK: - Aggregation semantics

    func testWeightedPaceHeartRateAndContributorCounts() {
        let now = utcDate(2026, 9, 14)
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [
                row(utcDate(2026, 9, 2), distance: 10_000, active: 3_600, heartRate: 150, ascent: 200),
                row(utcDate(2026, 9, 10), distance: 5_000, active: 1_200, heartRate: 140, ascent: nil)
            ],
            period: .month,
            range: .allTime,
            now: now,
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(aggregation.buckets.count, 1)
        let bucket = aggregation.buckets[0]
        XCTAssertEqual(bucket.runCount, 2)
        XCTAssertEqual(bucket.totalDistanceMeters, 15_000)
        XCTAssertEqual(bucket.totalActiveSeconds, 4_800)
        // Total active seconds divided by total kilometres, not a mean of paces.
        XCTAssertEqual(bucket.meanActivePaceSecondsPerKilometer ?? 0, 320, accuracy: 1e-9)
        // Active-time-weighted heart rate: (150*3600 + 140*1200) / 4800 = 147.5.
        XCTAssertEqual(bucket.meanHeartRateBPM ?? 0, 147.5, accuracy: 1e-9)
        XCTAssertEqual(bucket.heartRateContributingRuns, 2)
        XCTAssertEqual(bucket.totalAscentMeters ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(bucket.ascentContributingRuns, 1)

        // Window totals match the single bucket.
        XCTAssertEqual(aggregation.totalDistanceMeters, 15_000)
        XCTAssertEqual(aggregation.totalActiveSeconds, 4_800)
        XCTAssertEqual(aggregation.meanActivePaceSecondsPerKilometer ?? 0, 320, accuracy: 1e-9)
        XCTAssertEqual(aggregation.meanHeartRateBPM ?? 0, 147.5, accuracy: 1e-9)
        XCTAssertEqual(aggregation.heartRateContributingRuns, 2)
        XCTAssertEqual(aggregation.totalAscentMeters ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(aggregation.ascentContributingRuns, 1)
    }

    func testZeroWeightHeartRateFallsBackToSimpleMean() {
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [
                row(utcDate(2026, 9, 2), distance: 0, active: 0, heartRate: 150),
                row(utcDate(2026, 9, 10), distance: 0, active: 0, heartRate: 130)
            ],
            period: .month,
            range: .allTime,
            now: utcDate(2026, 9, 14),
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        XCTAssertEqual(aggregation.buckets[0].meanHeartRateBPM ?? 0, 140, accuracy: 1e-9)
    }

    func testEmptyPeriodShowsZerosForTotalsAndGapsForOptionalMetrics() {
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [row(utcDate(2026, 9, 2), distance: 0, active: 0, heartRate: nil, ascent: nil)],
            period: .month,
            range: .allTime,
            now: utcDate(2026, 9, 14),
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        let bucket = aggregation.buckets[0]
        XCTAssertEqual(bucket.runCount, 1)
        XCTAssertEqual(bucket.totalDistanceMeters, 0)
        XCTAssertNil(bucket.meanActivePaceSecondsPerKilometer)
        XCTAssertNil(bucket.meanHeartRateBPM)
        XCTAssertNil(bucket.totalAscentMeters)
    }

    // MARK: - Summary rows

    private func summaryWorkout(
        startDate: Date?,
        gain: Double = 0,
        loss: Double = 0,
        rawGain: Double? = nil,
        heartRate: Double? = nil,
        offset: Int? = nil,
        routePoints: [RoutePoint] = []
    ) -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(startDate: startDate, recordedUTCOffsetSeconds: offset),
            routePoints: routePoints,
            summary: RunSummary(
                totalDistanceMeters: 10_000,
                totalElapsedSeconds: 4_000,
                totalActiveSeconds: 3_600,
                elevationGainMeters: gain,
                elevationLossMeters: loss,
                averageHeartRateBPM: heartRate,
                rawElevationGainMeters: rawGain
            )
        )
    }

    func testRowPrefersCorrectedAscentFallsBackToRaw() {
        let corrected = WorkoutTrendsSummaryRow.make(
            from: summaryWorkout(startDate: utcDate(2026, 9, 2), gain: 120, loss: 80, rawGain: 45)
        )
        XCTAssertEqual(corrected?.ascentMeters ?? 0, 120)

        let rawOnly = WorkoutTrendsSummaryRow.make(
            from: summaryWorkout(startDate: utcDate(2026, 9, 2), rawGain: 45)
        )
        XCTAssertEqual(rawOnly?.ascentMeters ?? 0, 45)

        let neither = WorkoutTrendsSummaryRow.make(
            from: summaryWorkout(startDate: utcDate(2026, 9, 2))
        )
        XCTAssertNil(neither?.ascentMeters)
    }

    func testRowFiltersHeartRateAndCarriesOffset() {
        let valid = WorkoutTrendsSummaryRow.make(
            from: summaryWorkout(startDate: utcDate(2026, 9, 2), heartRate: 152, offset: 32_400)
        )
        XCTAssertEqual(valid?.averageHeartRateBPM, 152)
        XCTAssertEqual(valid?.recordedUTCOffsetSeconds, 32_400)

        let zero = WorkoutTrendsSummaryRow.make(
            from: summaryWorkout(startDate: utcDate(2026, 9, 2), heartRate: 0)
        )
        XCTAssertNil(zero?.averageHeartRateBPM)
    }

    func testUndatedWorkoutProducesNoRow() {
        XCTAssertNil(WorkoutTrendsSummaryRow.make(from: summaryWorkout(startDate: nil)))
        // A route-point timestamp is a valid fallback date.
        let datedByPoint = summaryWorkout(
            startDate: nil,
            routePoints: [RoutePoint(
                timestamp: utcDate(2026, 9, 2, 8),
                latitude: 1.3,
                longitude: 103.8
            )]
        )
        XCTAssertEqual(WorkoutTrendsSummaryRow.make(from: datedByPoint)?.startDate, utcDate(2026, 9, 2, 8))
    }

    // MARK: - Scope resolution

    func testSmartCollectionScopeResolvesThroughQueryService() async throws {
        let taggedID = UUID()
        let untaggedID = UUID()
        let tag = WorkoutTag(id: taggedTagID, name: "Trail")
        func entry(_ id: UUID, tagIDs: Set<UUID>) -> WorkoutLibraryEntry {
            WorkoutLibraryEntry.make(
                from: summaryWorkout(startDate: utcDate(2026, 9, 2)).withID(id),
                manifestIndex: 0,
                isFavorite: false,
                tagIDs: tagIDs,
                tagsByID: [taggedTagID: tag]
            )
        }
        let entries = [
            entry(taggedID, tagIDs: [taggedTagID]),
            entry(untaggedID, tagIDs: [])
        ]
        let collection = WorkoutSmartCollection(
            name: "Trail runs",
            query: WorkoutLibrarySavedQuery(
                filter: WorkoutLibraryFilter(tags: .selected(tagIDs: [taggedTagID], match: .any))
            )
        )
        let resolution = try await WorkoutTrendsScopeResolver.resolve(
            scope: .smartCollection(collection.id),
            entries: entries,
            documents: [:],
            smartCollections: [collection],
            currentQuery: nil,
            now: utcDate(2026, 9, 14),
            calendar: Calendar(identifier: .gregorian)
        )
        XCTAssertEqual(resolution.matchingWorkoutIDs, [taggedID])

        let entire = try await WorkoutTrendsScopeResolver.resolve(
            scope: .entireLibrary,
            entries: entries,
            documents: [:],
            smartCollections: [],
            currentQuery: nil,
            now: utcDate(2026, 9, 14),
            calendar: Calendar(identifier: .gregorian)
        )
        XCTAssertNil(entire.matchingWorkoutIDs)

        // A stale collection ID degrades to the entire library, never empty.
        let stale = try await WorkoutTrendsScopeResolver.resolve(
            scope: .smartCollection(UUID()),
            entries: entries,
            documents: [:],
            smartCollections: [collection],
            currentQuery: nil,
            now: utcDate(2026, 9, 14),
            calendar: Calendar(identifier: .gregorian)
        )
        XCTAssertNil(stale.matchingWorkoutIDs)
    }

    func testCurrentFilterScopeUsesProvidedQuery() async throws {
        let old = UUID()
        let recent = UUID()
        let entries = [
            WorkoutLibraryEntry.make(
                from: summaryWorkout(startDate: utcDate(2020, 1, 2)).withID(old),
                manifestIndex: 0,
                isFavorite: false
            ),
            WorkoutLibraryEntry.make(
                from: summaryWorkout(startDate: utcDate(2026, 9, 2)).withID(recent),
                manifestIndex: 1,
                isFavorite: false
            )
        ]
        let query = WorkoutLibraryQuery(
            filter: WorkoutLibraryFilter(date: .last30Days),
            now: utcDate(2026, 9, 14),
            calendar: Calendar(identifier: .gregorian)
        )
        let resolution = try await WorkoutTrendsScopeResolver.resolve(
            scope: .currentLibraryFilter,
            entries: entries,
            documents: [:],
            smartCollections: [],
            currentQuery: query,
            now: query.now,
            calendar: query.calendar
        )
        XCTAssertEqual(resolution.matchingWorkoutIDs, [recent])

        // No current query degrades to the entire library.
        let fallback = try await WorkoutTrendsScopeResolver.resolve(
            scope: .currentLibraryFilter,
            entries: entries,
            documents: [:],
            smartCollections: [],
            currentQuery: nil,
            now: query.now,
            calendar: query.calendar
        )
        XCTAssertNil(fallback.matchingWorkoutIDs)
    }

    // MARK: - Accessibility summaries

    func testTrendsAccessibilitySummaryDisclosesContributors() {
        let aggregation = WorkoutTrendsAggregator.aggregate(
            rows: [
                row(utcDate(2026, 9, 2), heartRate: 150, ascent: 200),
                row(utcDate(2026, 9, 10))
            ],
            period: .month,
            range: .allTime,
            now: utcDate(2026, 9, 14),
            displayTimeZone: utc,
            fallbackBucketingTimeZone: utc
        )
        let summary = TrendsAccessibilitySummary(
            periodDescription: "month",
            rangeDescription: "all time",
            scopeDescription: "all workouts",
            includedRunCount: aggregation.includedRunCount,
            outOfWindowRunCount: aggregation.outOfWindowRunCount,
            undatedRunCount: 1,
            aggregation: aggregation
        )
        let spoken = summary.spokenSummary
        XCTAssertTrue(spoken.contains("1 of 2 runs"))
        XCTAssertTrue(spoken.contains("no date"))
        XCTAssertFalse(spoken.contains("No heart-rate data"))
    }

    func testTrendsChartSummaryCountsGapsAndPartialPeriods() {
        let heartRate = TrendsChartAccessibilitySummary(
            metricName: "Heart rate",
            unit: "bpm",
            periodDescription: "month",
            values: [148, nil, 151],
            contributorCounts: [2, 0, 1],
            runCounts: [2, 0, 2]
        )
        let spoken = heartRate.spokenSummary
        XCTAssertTrue(spoken.contains("2 of 3 periods"))
        XCTAssertTrue(spoken.contains("1 periods use runs that carry only part"))

        let empty = TrendsChartAccessibilitySummary(
            metricName: "Heart rate",
            unit: "bpm",
            periodDescription: "month",
            values: [nil, nil],
            contributorCounts: [0, 0],
            runCounts: [0, 0]
        )
        XCTAssertTrue(empty.spokenSummary.contains("No data"))
    }

    // MARK: - Offset scanner

    func testOffsetScannerVariants() {
        XCTAssertEqual(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00Z"), 0)
        XCTAssertEqual(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00z"), 0)
        XCTAssertEqual(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00+09:00"), 32_400)
        XCTAssertEqual(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00-05:00"), -18_000)
        XCTAssertEqual(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00.123+05:30"), 19_800)
        XCTAssertEqual(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00+0530"), 19_800)
        XCTAssertEqual(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00+05"), 18_000)
        XCTAssertNil(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00"))
        XCTAssertNil(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00+25:00"))
        XCTAssertNil(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14T08:30:00+09:70"))
        // A designator only exists after a time part. Without that test the
        // date separator itself reads as a sign: "2026-09-14" would be UTC-14.
        XCTAssertNil(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14"))
        XCTAssertNil(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09"))
        XCTAssertNil(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "2026-09-14Z"))
        XCTAssertNil(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: "14:30:00+09:00"))
        XCTAssertNil(WorkoutTimestampOffsetScanner.utcOffsetSeconds(inISO8601Text: ""))
    }

    // MARK: - Importer offset capture

    func testGPXImporterRecordsLiteralOffset() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test">
          <trk><name>Tokyo Run</name><trkseg>
            <trkpt lat="35.68" lon="139.77"><ele>10</ele><time>2026-09-14T08:30:00+09:00</time></trkpt>
            <trkpt lat="35.69" lon="139.78"><ele>12</ele><time>2026-09-14T08:31:00+09:00</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let importer = GPXImporter()
        let workout = try importer.importWorkout(
            data: Data(gpx.utf8),
            suggestedName: "Tokyo Run",
            maxRoutePointCount: 100
        )
        XCTAssertEqual(workout.metadata.recordedUTCOffsetSeconds, 32_400)
    }

    func testGPXImporterRecordsZeroForUTCDesignator() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test">
          <trk><trkseg>
            <trkpt lat="35.68" lon="139.77"><time>2026-09-14T08:30:00Z</time></trkpt>
            <trkpt lat="35.69" lon="139.78"><time>2026-09-14T08:31:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let workout = try GPXImporter().importWorkout(
            data: Data(gpx.utf8),
            suggestedName: "Run",
            maxRoutePointCount: 100
        )
        XCTAssertEqual(workout.metadata.recordedUTCOffsetSeconds, 0)
    }

    func testGPXImporterIgnoresDateOnlyTimestampText() throws {
        // A date-only <time> cannot become an instant, so its date separator
        // must not be mistaken for a "-14" zone designator: the offset comes
        // from the first timestamp that actually parsed.
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test">
          <trk><trkseg>
            <trkpt lat="35.68" lon="139.77"><time>2026-09-14</time></trkpt>
            <trkpt lat="35.69" lon="139.78"><time>2026-09-14T08:31:00Z</time></trkpt>
            <trkpt lat="35.70" lon="139.79"><time>2026-09-14T08:32:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let workout = try GPXImporter().importWorkout(
            data: Data(gpx.utf8),
            suggestedName: "Run",
            maxRoutePointCount: 100
        )
        XCTAssertEqual(workout.metadata.recordedUTCOffsetSeconds, 0)
    }

    func testGPXImporterTakesOffsetFromFirstParseableTimestamp() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test">
          <trk><trkseg>
            <trkpt lat="35.68" lon="139.77"><time>not-a-timestamp</time></trkpt>
            <trkpt lat="35.69" lon="139.78"><time>2026-09-14T08:31:00+09:00</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let workout = try GPXImporter().importWorkout(
            data: Data(gpx.utf8),
            suggestedName: "Run",
            maxRoutePointCount: 100
        )
        XCTAssertEqual(workout.metadata.recordedUTCOffsetSeconds, 32_400)
    }

    func testTCXImporterIgnoresUnparseableActivityID() throws {
        // The unparseable <Id> must not supply an offset; the first real
        // trackpoint time does.
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities><Activity Sport="Running">
            <Id>2026-09-14</Id>
            <Lap><Track>
              <Trackpoint><Time>2026-09-14T08:30:00+09:00</Time>
                <Position><LatitudeDegrees>35.68</LatitudeDegrees><LongitudeDegrees>139.77</LongitudeDegrees></Position>
              </Trackpoint>
              <Trackpoint><Time>2026-09-14T08:31:00+09:00</Time>
                <Position><LatitudeDegrees>35.69</LatitudeDegrees><LongitudeDegrees>139.78</LongitudeDegrees></Position>
              </Trackpoint>
            </Track></Lap>
          </Activity></Activities>
        </TrainingCenterDatabase>
        """
        let workout = try TCXImporter().importWorkout(
            data: Data(tcx.utf8),
            suggestedName: "Run",
            maxRoutePointCount: 100
        )
        XCTAssertEqual(workout.metadata.recordedUTCOffsetSeconds, 32_400)
    }

    func testTCXImporterRecordsLiteralOffset() throws {
        let tcx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities><Activity Sport="Running">
            <Id>2026-09-14T08:30:00+09:00</Id>
            <Lap StartTime="2026-09-14T08:30:00+09:00">
              <TotalTimeSeconds>60</TotalTimeSeconds>
              <Track>
                <Trackpoint>
                  <Time>2026-09-14T08:30:00+09:00</Time>
                  <Position><LatitudeDegrees>35.68</LatitudeDegrees><LongitudeDegrees>139.77</LongitudeDegrees></Position>
                  <AltitudeMeters>10</AltitudeMeters>
                </Trackpoint>
                <Trackpoint>
                  <Time>2026-09-14T08:31:00+09:00</Time>
                  <Position><LatitudeDegrees>35.69</LatitudeDegrees><LongitudeDegrees>139.78</LongitudeDegrees></Position>
                  <AltitudeMeters>12</AltitudeMeters>
                </Trackpoint>
              </Track>
            </Lap>
          </Activity></Activities>
        </TrainingCenterDatabase>
        """
        let workout = try TCXImporter().importWorkout(
            data: Data(tcx.utf8),
            suggestedName: "Tokyo Run",
            maxRoutePointCount: 100
        )
        XCTAssertEqual(workout.metadata.recordedUTCOffsetSeconds, 32_400)
    }

    func testJSONImporterRecordsLiteralOffset() throws {
        let json = """
        {
          "metadata": { "name": "Tokyo Run", "activityType": "running" },
          "routePoints": [
            { "timestamp": "2026-09-14T08:30:00+09:00", "latitude": 35.68, "longitude": 139.77, "altitudeMeters": 10, "elapsedSeconds": 0 },
            { "timestamp": "2026-09-14T08:31:00+09:00", "latitude": 35.69, "longitude": 139.78, "altitudeMeters": 12, "elapsedSeconds": 60 }
          ]
        }
        """
        let workout = try JSONWorkoutImporter().importWorkout(from: Data(json.utf8))
        XCTAssertEqual(workout.metadata.recordedUTCOffsetSeconds, 32_400)
    }

    func testJSONImporterKeepsExplicitMetadataOffset() throws {
        let json = """
        {
          "metadata": { "name": "Run", "activityType": "running", "recordedUTCOffsetSeconds": -18000 },
          "routePoints": [
            { "timestamp": "2026-09-14T08:30:00Z", "latitude": 35.68, "longitude": 139.77, "elapsedSeconds": 0 },
            { "timestamp": "2026-09-14T08:31:00Z", "latitude": 35.69, "longitude": 139.78, "elapsedSeconds": 60 }
          ]
        }
        """
        let workout = try JSONWorkoutImporter().importWorkout(from: Data(json.utf8))
        XCTAssertEqual(workout.metadata.recordedUTCOffsetSeconds, -18_000)
    }
}

// MARK: - Test helpers

private let taggedTagID = UUID()

private extension RunWorkout {
    func withID(_ id: UUID) -> RunWorkout {
        var copy = self
        copy = RunWorkout(
            id: id,
            metadata: metadata,
            source: source,
            routePoints: routePoints,
            splits: splits,
            recordedLaps: recordedLaps,
            summary: summary,
            segments: segments
        )
        return copy
    }
}
