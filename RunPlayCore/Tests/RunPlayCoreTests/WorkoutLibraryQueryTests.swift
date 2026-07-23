import XCTest
@testable import RunPlayCore

final class WorkoutLibraryQueryTests: XCTestCase {

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private let now = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00 UTC

    // MARK: - Helpers

    private func makeEntry(
        id: UUID = UUID(),
        index: Int = 0,
        favorite: Bool = false,
        name: String? = "Run",
        notes: String? = nil,
        displayName: String? = nil,
        activityType: String = "running",
        device: String? = nil,
        source: WorkoutSource = .gpx,
        provider: WorkoutImportProvider? = nil,
        filename: String? = nil,
        start: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        distance: Double = 5_000,
        pace: Double = 300,
        elapsed: Double = 1_800,
        hasHR: Bool = false,
        hasElev: Bool = false,
        hasLaps: Bool = false
    ) -> WorkoutLibraryEntry {
        let resolvedDisplay = displayName ?? name ?? "Untitled Run"
        return WorkoutLibraryEntry(
            id: id,
            manifestIndex: index,
            isFavorite: favorite,
            displayName: resolvedDisplay,
            metadataName: name,
            notes: notes,
            activityType: activityType,
            deviceName: device,
            source: source,
            importProvider: provider,
            originalFilename: filename,
            startDate: start,
            totalDistanceMeters: distance,
            activePaceSecondsPerKilometer: pace,
            totalElapsedSeconds: elapsed,
            hasHeartRate: hasHR,
            hasCorrectedElevation: hasElev,
            hasRecordedLaps: hasLaps,
            nameNotesRevision: "\(name ?? "")|\(notes ?? "")"
        )
    }

    private func query(
        text: String = "",
        filter: WorkoutLibraryFilter = .default,
        sort: WorkoutLibrarySort = .libraryOrder
    ) -> WorkoutLibraryQuery {
        WorkoutLibraryQuery(
            searchText: text,
            filter: filter,
            sort: sort,
            now: now,
            calendar: calendar
        )
    }

    private func run(
        _ entries: [WorkoutLibraryEntry],
        query: WorkoutLibraryQuery
    ) async throws -> WorkoutLibraryQueryResult {
        let docs = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, WorkoutLibrarySearchDocument.make(from: $0, calendar: calendar))
        })
        return try await WorkoutLibraryQueryService().execute(
            entries: entries,
            documents: docs,
            query: query
        )
    }

    // MARK: - Search

    func testEmptySearchMatchesAll() async throws {
        let entries = [makeEntry(index: 0), makeEntry(index: 1)]
        let result = try await run(entries, query: query(text: ""))
        XCTAssertEqual(result.filteredCount, 2)
    }

    func testWhitespaceOnlySearchMatchesAll() async throws {
        let entries = [makeEntry()]
        let result = try await run(entries, query: query(text: "   \t  "))
        XCTAssertEqual(result.filteredCount, 1)
    }

    func testCaseInsensitiveSearch() async throws {
        let a = makeEntry(name: "Morning Park")
        let b = makeEntry(name: "Evening Track")
        let result = try await run([a, b], query: query(text: "MORNING"))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testDiacriticInsensitiveSearch() async throws {
        let a = makeEntry(name: "Café Run")
        let result = try await run([a], query: query(text: "cafe"))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testChineseNameSearch() async throws {
        let a = makeEntry(name: "晨跑公园")
        let b = makeEntry(name: "Evening")
        let result = try await run([a, b], query: query(text: "晨跑"))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testQuotedPhraseSearch() async throws {
        let a = makeEntry(name: "Marina Bay Loop")
        let b = makeEntry(name: "Marina", notes: "Bay is far")
        let result = try await run([a, b], query: query(text: "\"Marina Bay\""))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testMultiTermANDAcrossFields() async throws {
        let a = makeEntry(name: "Morning", notes: "park loop")
        let b = makeEntry(name: "Morning Track")
        let result = try await run([a, b], query: query(text: "morning park"))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testSourceAndYearSearch() async throws {
        let a = makeEntry(
            name: "Long Run",
            source: .fit,
            start: Date(timeIntervalSince1970: 1_735_689_600) // 2025
        )
        let b = makeEntry(
            name: "Long Run",
            source: .gpx,
            start: Date(timeIntervalSince1970: 1_609_459_200) // 2021
        )
        let result = try await run([a, b], query: query(text: "2025 fit"))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testStravaProviderSearchableButNotSourceFilter() async throws {
        let a = makeEntry(source: .fit, provider: .stravaBulkExport, filename: "activity.fit")
        let result = try await run([a], query: query(text: "strava"))
        XCTAssertEqual(result.matchingIDs, [a.id])

        let filtered = try await run(
            [a],
            query: query(filter: WorkoutLibraryFilter(source: .fit))
        )
        XCTAssertEqual(filtered.matchingIDs, [a.id])
    }

    func testOriginalFilenameSearch() async throws {
        let a = makeEntry(filename: "race_day.gpx")
        let result = try await run([a], query: query(text: "race_day"))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testNotesSearch() async throws {
        let a = makeEntry(name: "Run", notes: "felt strong on hills")
        let result = try await run([a], query: query(text: "hills"))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testDeviceSearch() async throws {
        let a = makeEntry(device: "Forerunner 955")
        let result = try await run([a], query: query(text: "forerunner"))
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    // MARK: - Filters

    func testFavoritesOnlyFilter() async throws {
        let a = makeEntry(favorite: true)
        let b = makeEntry(favorite: false)
        let result = try await run(
            [a, b],
            query: query(filter: WorkoutLibraryFilter(favorite: .favoritesOnly))
        )
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testSourceFilters() async throws {
        let gpx = makeEntry(source: .gpx)
        let tcx = makeEntry(source: .tcx)
        let fit = makeEntry(source: .fit)
        let json = makeEntry(source: .json)
        let all = [gpx, tcx, fit, json]
        for (filter, expected) in [
            (WorkoutLibrarySourceFilter.gpx, gpx.id),
            (.tcx, tcx.id),
            (.fit, fit.id),
            (.json, json.id)
        ] as [(WorkoutLibrarySourceFilter, UUID)] {
            let result = try await run(all, query: query(filter: WorkoutLibraryFilter(source: filter)))
            XCTAssertEqual(result.matchingIDs, [expected], "Failed for \(filter)")
        }
    }

    func testDataFilters() async throws {
        let a = makeEntry(hasHR: true, hasElev: false, hasLaps: false)
        let b = makeEntry(hasHR: false, hasElev: true, hasLaps: false)
        let c = makeEntry(hasHR: false, hasElev: false, hasLaps: true)
        let all = [a, b, c]

        var result = try await run(all, query: query(filter: WorkoutLibraryFilter(
            data: WorkoutLibraryDataFilters(requiresHeartRate: true)
        )))
        XCTAssertEqual(result.matchingIDs, [a.id])

        result = try await run(all, query: query(filter: WorkoutLibraryFilter(
            data: WorkoutLibraryDataFilters(requiresCorrectedElevation: true)
        )))
        XCTAssertEqual(result.matchingIDs, [b.id])

        result = try await run(all, query: query(filter: WorkoutLibraryFilter(
            data: WorkoutLibraryDataFilters(requiresRecordedLaps: true)
        )))
        XCTAssertEqual(result.matchingIDs, [c.id])
    }

    func testLast30DaysFilterUsesInjectedNow() async throws {
        let recent = makeEntry(start: now.addingTimeInterval(-10 * 86_400))
        let old = makeEntry(start: now.addingTimeInterval(-60 * 86_400))
        let missing = makeEntry(start: nil)
        let result = try await run(
            [recent, old, missing],
            query: query(filter: WorkoutLibraryFilter(date: .last30Days))
        )
        XCTAssertEqual(result.matchingIDs, [recent.id])
    }

    func testCurrentYearFilter() async throws {
        let inYear = makeEntry(start: Date(timeIntervalSince1970: 1_740_000_000)) // 2025-ish
        let prior = makeEntry(start: Date(timeIntervalSince1970: 1_700_000_000)) // 2023
        let result = try await run(
            [inYear, prior],
            query: query(filter: WorkoutLibraryFilter(date: .currentCalendarYear))
        )
        XCTAssertEqual(result.matchingIDs, [inYear.id])
    }

    func testCustomRangeFilter() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let mid = Date(timeIntervalSince1970: 1_700_086_400)
        let end = Date(timeIntervalSince1970: 1_700_172_800)
        let a = makeEntry(start: mid)
        let b = makeEntry(start: Date(timeIntervalSince1970: 1_600_000_000))
        let result = try await run(
            [a, b],
            query: query(filter: WorkoutLibraryFilter(date: .custom(start: start, end: end)))
        )
        XCTAssertEqual(result.matchingIDs, [a.id])
    }

    func testCustomRangeIncludesFullEndCalendarDay() async throws {
        // End date is start-of-day (date-picker style); evening workouts that day must match.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let endDay = cal.date(from: DateComponents(year: 2024, month: 1, day: 10))!
        let eveningOnEnd = cal.date(from: DateComponents(year: 2024, month: 1, day: 10, hour: 21))!
        let nextMorning = cal.date(from: DateComponents(year: 2024, month: 1, day: 11, hour: 1))!
        let included = makeEntry(start: eveningOnEnd)
        let excluded = makeEntry(start: nextMorning)
        let q = WorkoutLibraryQuery(
            searchText: "",
            filter: WorkoutLibraryFilter(date: .custom(start: start, end: endDay)),
            sort: .libraryOrder,
            now: now,
            calendar: cal
        )
        let result = try await run([included, excluded], query: q)
        XCTAssertEqual(result.matchingIDs, [included.id])
    }

    // MARK: - Sort

    func testDateNewestAndOldest() async throws {
        let older = makeEntry(index: 0, start: Date(timeIntervalSince1970: 1_000))
        let newer = makeEntry(index: 1, start: Date(timeIntervalSince1970: 2_000))
        let missing = makeEntry(index: 2, start: nil)

        var result = try await run([older, newer, missing], query: query(sort: .dateNewest))
        XCTAssertEqual(result.matchingIDs, [newer.id, older.id, missing.id])

        result = try await run([older, newer, missing], query: query(sort: .dateOldest))
        XCTAssertEqual(result.matchingIDs, [older.id, newer.id, missing.id])
    }

    func testNameSortUsesDisplayFallback() async throws {
        let a = makeEntry(index: 0, name: "Alpha")
        let b = makeEntry(index: 1, name: "Bravo")
        let result = try await run([b, a], query: query(sort: .nameAZ))
        XCTAssertEqual(result.matchingIDs, [a.id, b.id])
    }

    func testDistanceSort() async throws {
        let short = makeEntry(index: 0, distance: 1_000)
        let long = makeEntry(index: 1, distance: 10_000)
        let result = try await run([short, long], query: query(sort: .distanceLongest))
        XCTAssertEqual(result.matchingIDs, [long.id, short.id])
    }

    func testPaceSortPutsInvalidAfterValid() async throws {
        let fast = makeEntry(index: 0, pace: 250)
        let slow = makeEntry(index: 1, pace: 400)
        let invalid = makeEntry(index: 2, pace: 0)
        let result = try await run([invalid, slow, fast], query: query(sort: .paceFastest))
        XCTAssertEqual(result.matchingIDs, [fast.id, slow.id, invalid.id])
    }

    func testLibraryOrderPreserved() async throws {
        let a = makeEntry(index: 0)
        let b = makeEntry(index: 1)
        let c = makeEntry(index: 2)
        let result = try await run([c, a, b], query: query(sort: .libraryOrder))
        XCTAssertEqual(result.matchingIDs, [a.id, b.id, c.id])
    }

    func testEqualValuesUseDeterministicTieBreak() async throws {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let a = makeEntry(id: id2, index: 5, distance: 5_000)
        let b = makeEntry(id: id1, index: 3, distance: 5_000)
        let result = try await run([a, b], query: query(sort: .distanceLongest))
        // Equal distance → lower manifest index first, then UUID.
        XCTAssertEqual(result.matchingIDs, [b.id, a.id])
    }

    func testSortComparatorTransitivitySample() {
        var entries: [WorkoutLibraryEntry] = []
        entries.reserveCapacity(20)
        for i in 0..<20 {
            let start: Date? = (i % 3 == 0) ? nil : Date(timeIntervalSince1970: Double(i * 1000))
            let distance = Double((i * 37) % 11) * 100
            let pace: Double = (i % 4 == 0) ? 0 : Double(200 + i)
            entries.append(makeEntry(index: i, start: start, distance: distance, pace: pace))
        }
        for sort in WorkoutLibrarySort.allCases {
            let sorted = WorkoutLibraryQueryService.sort(entries, by: sort)
            XCTAssertEqual(sorted.count, entries.count)
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    let ordered = WorkoutLibraryQueryService.compare(sorted[i], sorted[j], by: sort)
                    XCTAssertTrue(ordered || sorted[i].id == sorted[j].id, "Order violated for \(sort) at \(i),\(j)")
                }
            }
        }
    }

    // MARK: - Performance / large library

    func testTenThousandEntriesQueryWithoutRouteAccess() async throws {
        var entries: [WorkoutLibraryEntry] = []
        entries.reserveCapacity(10_000)
        let sources: [WorkoutSource] = [.gpx, .tcx, .fit, .json]
        for i in 0..<10_000 {
            let name: String
            if i % 7 == 0 {
                name = "Long name \(String(repeating: "x", count: 80)) \(i)"
            } else {
                name = "Run \(i)"
            }
            let notes: String? = (i % 11 == 0) ? String(repeating: "note ", count: 40) : nil
            let start: Date? = (i % 13 == 0)
                ? nil
                : Date(timeIntervalSince1970: Double(1_700_000_000 + i * 3600))
            let pace: Double = (i % 17 == 0) ? 0 : Double(240 + (i % 120))
            entries.append(makeEntry(
                index: i,
                favorite: i % 50 == 0,
                name: name,
                notes: notes,
                source: sources[i % 4],
                start: start,
                distance: Double(1_000 + (i % 100) * 100),
                pace: pace,
                hasHR: i % 5 == 0,
                hasElev: i % 6 == 0,
                hasLaps: i % 9 == 0
            ))
        }

        final class VisitCounter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func inc() {
                lock.lock(); count += 1; lock.unlock()
            }
        }
        let visits = VisitCounter()
        let service = WorkoutLibraryQueryService { _ in
            visits.inc()
        }
        let docs = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, WorkoutLibrarySearchDocument.make(from: $0, calendar: calendar))
        })

        let result = try await service.execute(
            entries: entries,
            documents: docs,
            query: query(
                text: "run",
                filter: WorkoutLibraryFilter(
                    favorite: .all,
                    date: .allTime,
                    source: .gpx,
                    data: WorkoutLibraryDataFilters(requiresHeartRate: true)
                ),
                sort: .dateNewest
            )
        )

        XCTAssertEqual(visits.count, 10_000)
        XCTAssertEqual(result.totalCount, 10_000)
        XCTAssertLessThan(result.filteredCount, result.totalCount)
        // Deterministic re-run.
        let result2 = try await service.execute(
            entries: entries,
            documents: docs,
            query: query(
                text: "run",
                filter: WorkoutLibraryFilter(
                    source: .gpx,
                    data: WorkoutLibraryDataFilters(requiresHeartRate: true)
                ),
                sort: .dateNewest
            )
        )
        XCTAssertEqual(result.matchingIDs, result2.matchingIDs)
    }

    func testQueryCancellation() async {
        let entries = (0..<5_000).map { makeEntry(index: $0) }
        let cal = calendar
        let clock = now
        let docs = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, WorkoutLibrarySearchDocument.make(from: $0, calendar: cal))
        })
        let service = WorkoutLibraryQueryService()
        let q = WorkoutLibraryQuery(
            searchText: "",
            filter: .default,
            sort: .nameAZ,
            now: clock,
            calendar: cal
        )
        let task = Task {
            try await service.execute(
                entries: entries,
                documents: docs,
                query: q
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            // May complete before cancel is observed; both outcomes are valid.
        } catch is CancellationError {
            // Expected when cancel wins.
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Search terms parser

    func testSearchTermsParseQuotedAndUnquoted() {
        let terms = WorkoutLibrarySearchTerms.parse("  morning \"Marina Bay\" park  ")
        XCTAssertEqual(terms.terms, ["morning", "marina bay", "park"])
    }

    // MARK: - Sidebar policy

    func testSidebarBoundsNoDuplicatesAndSelectedOverflow() {
        let favorites = (0..<10).map { i in
            RunWorkout(
                metadata: WorkoutMetadata(name: "Fav \(i)", startDate: Date(timeIntervalSince1970: Double(i))),
                summary: RunSummary(totalDistanceMeters: 1000)
            )
        }
        let recents = (0..<15).map { i in
            RunWorkout(
                metadata: WorkoutMetadata(
                    name: "Recent \(i)",
                    startDate: Date(timeIntervalSince1970: 1_000_000 + Double(i))
                ),
                summary: RunSummary(totalDistanceMeters: 1000)
            )
        }
        let old = RunWorkout(
            metadata: WorkoutMetadata(name: "Old", startDate: Date(timeIntervalSince1970: 100)),
            summary: RunSummary(totalDistanceMeters: 1000)
        )
        let workouts = favorites + recents + [old]
        let favoriteIDs = Set(favorites.map(\.id))

        let sections = WorkoutLibrarySidebarPolicy.sidebarSections(
            workouts: workouts,
            favoriteIDs: favoriteIDs,
            selectedWorkoutID: old.id
        )
        XCTAssertEqual(sections.favorites.count, WorkoutLibrarySidebarPolicy.favoriteCap)
        XCTAssertEqual(sections.recent.count, WorkoutLibrarySidebarPolicy.recentCap)
        XCTAssertEqual(sections.selectedOverflow?.id, old.id)

        let shown = Set(sections.favorites.map(\.id)).union(sections.recent.map(\.id))
        XCTAssertTrue(shown.isDisjoint(with: [old.id]) || sections.selectedOverflow == nil)
        XCTAssertTrue(Set(sections.favorites.map(\.id)).isDisjoint(with: Set(sections.recent.map(\.id))))
    }

    func testSidebarRecentExcludesFavoritesBeyondFavoriteCap() {
        let favorites = (0..<(WorkoutLibrarySidebarPolicy.favoriteCap + 2)).map { index in
            RunWorkout(
                metadata: WorkoutMetadata(
                    name: "Fav \(index)",
                    startDate: Date(timeIntervalSince1970: 2_000 + Double(index))
                ),
                summary: RunSummary(totalDistanceMeters: 1000)
            )
        }
        let nonFavorites = (0..<2).map { index in
            RunWorkout(
                metadata: WorkoutMetadata(
                    name: "Recent \(index)",
                    startDate: Date(timeIntervalSince1970: 1_000 + Double(index))
                ),
                summary: RunSummary(totalDistanceMeters: 1000)
            )
        }
        let favoriteIDs = Set(favorites.map(\.id))

        let sections = WorkoutLibrarySidebarPolicy.sidebarSections(
            workouts: favorites + nonFavorites,
            favoriteIDs: favoriteIDs,
            selectedWorkoutID: nil
        )

        XCTAssertEqual(sections.favorites.count, WorkoutLibrarySidebarPolicy.favoriteCap)
        XCTAssertEqual(Set(sections.recent.map(\.id)), Set(nonFavorites.map(\.id)))
        XCTAssertTrue(Set(sections.recent.map(\.id)).isDisjoint(with: favoriteIDs))
    }

    // MARK: - Metadata policy

    func testMetadataPolicyTrimsAndRejectsOverLimit() throws {
        let policy = WorkoutMetadataEditingPolicy.default
        let normalized = try policy.normalize(name: "  Hello  ", notes: "  line1\nline2  ")
        XCTAssertEqual(normalized.name, "Hello")
        XCTAssertEqual(normalized.notes, "line1\nline2")

        XCTAssertNil(try policy.normalize(name: "   ", notes: "").name)
        XCTAssertNil(try policy.normalize(name: "   ", notes: "").notes)

        XCTAssertThrowsError(try policy.normalize(name: String(repeating: "a", count: 201), notes: nil))
        XCTAssertThrowsError(try policy.normalize(name: "ok", notes: "a\0b"))
    }
}
