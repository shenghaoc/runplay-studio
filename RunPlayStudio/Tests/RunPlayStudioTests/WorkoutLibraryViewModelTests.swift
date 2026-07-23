import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class WorkoutLibraryViewModelTests: XCTestCase {

    private struct ControllableQueryService: WorkoutLibraryQuerying {
        let handler: @Sendable (
            [WorkoutLibraryEntry],
            [UUID: WorkoutLibrarySearchDocument],
            WorkoutLibraryQuery
        ) async throws -> WorkoutLibraryQueryResult

        func execute(
            entries: [WorkoutLibraryEntry],
            documents: [UUID: WorkoutLibrarySearchDocument],
            query: WorkoutLibraryQuery
        ) async throws -> WorkoutLibraryQueryResult {
            try await handler(entries, documents, query)
        }
    }

    private func makeWorkout(
        id: UUID = UUID(),
        name: String,
        notes: String? = nil,
        start: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> RunWorkout {
        RunWorkout(
            id: id,
            metadata: WorkoutMetadata(name: name, notes: notes, startDate: start),
            source: .gpx,
            summary: RunSummary(totalDistanceMeters: 5_000, totalElapsedSeconds: 1_800)
        )
    }

    func testReplaceLibraryBuildsEntriesAndReadyState() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "Alpha")
        let b = makeWorkout(name: "Bravo")
        vm.replaceLibrary(workouts: [a, b], favoriteIDs: [a.id])

        // Allow async query to publish.
        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(vm.totalCount, 2)
        XCTAssertEqual(vm.entries.count, 2)
        XCTAssertTrue(vm.entries.first?.isFavorite == true)
        XCTAssertEqual(vm.loadState, .ready)
        XCTAssertEqual(Set(vm.resultIDs), [a.id, b.id])
    }

    func testSearchUpdateFiltersResults() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "Morning Park")
        let b = makeWorkout(name: "Track")
        vm.replaceLibrary(workouts: [a, b], favoriteIDs: [])

        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        vm.searchText = "park"
        for _ in 0..<50 {
            if vm.filteredCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(vm.resultIDs, [a.id])
    }

    func testEmptySearchState() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "Only")
        vm.replaceLibrary(workouts: [a], favoriteIDs: [])
        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        vm.searchText = "zzzz-no-match"
        for _ in 0..<50 {
            if case .emptySearch = vm.loadState { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        if case .emptySearch(let q) = vm.loadState {
            XCTAssertEqual(q, "zzzz-no-match")
        } else {
            XCTFail("Expected emptySearch, got \(vm.loadState)")
        }
    }

    func testEmptyLibraryState() {
        let vm = WorkoutLibraryViewModel()
        vm.replaceLibrary(workouts: [], favoriteIDs: [])
        XCTAssertEqual(vm.loadState, .emptyLibrary)
        XCTAssertEqual(vm.totalCount, 0)
    }

    func testSmartCollectionManualQueryRestorationAndModified() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "Race Day")
        let b = makeWorkout(name: "Easy Jog")
        let tag = WorkoutTag(name: "Race", color: .red)
        let collection = WorkoutSmartCollection(
            name: "Races",
            query: WorkoutLibrarySavedQuery(
                searchText: "race",
                filter: WorkoutLibraryFilter(
                    tags: .selected(tagIDs: [tag.id], match: .any)
                ),
                sort: .nameAZ
            )
        )
        let org = WorkoutLibraryOrganizationSnapshot(
            tags: [tag],
            tagAssignments: [WorkoutTagAssignment(workoutID: a.id, tagIDs: [tag.id])],
            smartCollections: [collection]
        )
        vm.replaceLibrary(workouts: [a, b], favoriteIDs: [], organization: org)

        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        vm.searchText = "jog"
        for _ in 0..<50 {
            if vm.filteredCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.resultIDs, [b.id])

        vm.openSmartCollection(id: collection.id)
        for _ in 0..<50 {
            if vm.searchText == "race" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.searchText, "race")
        XCTAssertEqual(vm.sort, .nameAZ)
        if case .smartCollection(let id, false) = vm.queryContext {
            XCTAssertEqual(id, collection.id)
        } else {
            XCTFail("Expected unmodified collection context")
        }

        vm.sourceFilter = .fit
        if case .smartCollection(_, true) = vm.queryContext {
            // modified
        } else {
            XCTFail("Expected modified collection")
        }

        vm.revertActiveCollection()
        if case .smartCollection(_, false) = vm.queryContext {
            XCTAssertEqual(vm.sourceFilter, .all)
        } else {
            XCTFail("Expected unmodified after revert")
        }

        vm.returnToManualQuery()
        XCTAssertEqual(vm.queryContext, .manual)
        XCTAssertEqual(vm.searchText, "jog")
    }

    func testBulkTagChangeTriggersSingleReadyState() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        let tag = WorkoutTag(name: "Easy", color: .green)
        vm.replaceLibrary(
            workouts: [a, b],
            favoriteIDs: [],
            organization: WorkoutLibraryOrganizationSnapshot(tags: [tag])
        )
        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        vm.applyBulkWorkoutTagChange(changes: [
            a.id: [tag.id],
            b.id: [tag.id],
        ])
        for _ in 0..<50 {
            if vm.entry(for: a.id)?.tagIDs.contains(tag.id) == true { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.entry(for: a.id)?.tagNames, ["Easy"])
        XCTAssertEqual(vm.entry(for: b.id)?.tagNames, ["Easy"])
    }

    func testTableSelectionIsSetAndRepairedOnFilter() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "Alpha")
        let b = makeWorkout(name: "Bravo")
        vm.replaceLibrary(workouts: [a, b], favoriteIDs: [])
        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        vm.tableSelection = [a.id, b.id]
        vm.searchText = "Alpha"
        for _ in 0..<50 {
            if vm.filteredCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.tableSelection, [a.id])
    }

    func testTagRenameUpdatesSearchDocument() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "Morning")
        let tag = WorkoutTag(name: "Race", color: .red)
        vm.replaceLibrary(
            workouts: [a],
            favoriteIDs: [],
            organization: WorkoutLibraryOrganizationSnapshot(
                tags: [tag],
                tagAssignments: [WorkoutTagAssignment(workoutID: a.id, tagIDs: [tag.id])]
            )
        )
        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        var renamed = tag
        renamed.name = "Competition"
        vm.applyTagDefinitions([renamed])
        vm.searchText = "competition"
        for _ in 0..<50 {
            if vm.filteredCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.resultIDs, [a.id])
    }

    func testStaleResultSuppression() async {
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var allowSecond = false
            private var firstWaiting: CheckedContinuation<Void, Never>?

            func waitUntilReleased() async {
                await withCheckedContinuation { cont in
                    lock.lock()
                    if allowSecond {
                        lock.unlock()
                        cont.resume()
                    } else {
                        firstWaiting = cont
                        lock.unlock()
                    }
                }
            }

            func release() {
                lock.lock()
                allowSecond = true
                let waiting = firstWaiting
                firstWaiting = nil
                lock.unlock()
                waiting?.resume()
            }
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let gate = Gate()
        let counter = Counter()
        let service = ControllableQueryService { entries, _, query in
            let count = counter.increment()
            if count == 1 {
                await gate.waitUntilReleased()
            }
            return WorkoutLibraryQueryResult(
                matchingIDs: entries.map(\.id),
                totalCount: entries.count,
                filteredCount: entries.count,
                query: query
            )
        }

        let vm = WorkoutLibraryViewModel(queryService: service)
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        vm.replaceLibrary(workouts: [a], favoriteIDs: [])
        // Immediately supersede.
        vm.replaceLibrary(workouts: [a, b], favoriteIDs: [])
        gate.release()

        for _ in 0..<50 {
            if vm.totalCount == 2, vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(vm.totalCount, 2)
        XCTAssertEqual(Set(vm.resultIDs), [a.id, b.id])
    }

    func testFavoriteUpdateReindexes() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "A")
        vm.replaceLibrary(workouts: [a], favoriteIDs: [])
        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        vm.applyFavoriteChange(workoutID: a.id, isFavorite: true)
        for _ in 0..<50 {
            if vm.entries.first?.isFavorite == true { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(vm.entries.first?.isFavorite == true)

        vm.favoriteFilter = .favoritesOnly
        for _ in 0..<50 {
            if vm.filteredCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.resultIDs, [a.id])
    }

    func testShowAllFavoritesClearsPriorSearchAndFilters() async {
        let vm = WorkoutLibraryViewModel()
        let favorite = makeWorkout(name: "Favourite")
        let other = makeWorkout(name: "Other")
        vm.replaceLibrary(workouts: [favorite, other], favoriteIDs: [favorite.id])
        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        vm.searchText = "does-not-match"
        vm.sourceFilter = .fit
        vm.dateFilter = .last30Days
        vm.dataFilters = WorkoutLibraryDataFilters(requiresHeartRate: true)

        vm.showAllFavorites()

        for _ in 0..<50 {
            if vm.resultIDs == [favorite.id] { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(vm.searchText, "")
        XCTAssertEqual(vm.favoriteFilter, .favoritesOnly)
        XCTAssertEqual(vm.sourceFilter, .all)
        XCTAssertEqual(vm.dateFilter, .allTime)
        XCTAssertEqual(vm.dataFilters, .none)
        XCTAssertEqual(vm.resultIDs, [favorite.id])
    }

    func testMetadataRenameInvalidatesSearchDocument() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "Original")
        vm.replaceLibrary(workouts: [a], favoriteIDs: [])
        for _ in 0..<50 {
            if vm.loadState == .ready { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        var updated = a
        updated.metadata.name = "Renamed Unique"
        vm.applyWorkoutUpdate(updated)

        vm.searchText = "Unique"
        for _ in 0..<50 {
            if vm.filteredCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.resultIDs, [a.id])
    }

    func testDeletionRemovesEntry() async {
        let vm = WorkoutLibraryViewModel()
        let a = makeWorkout(name: "A")
        let b = makeWorkout(name: "B")
        vm.replaceLibrary(workouts: [a, b], favoriteIDs: [a.id])
        for _ in 0..<50 {
            if vm.totalCount == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        vm.removeWorkout(id: a.id)
        for _ in 0..<50 {
            if vm.totalCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.totalCount, 1)
        XCTAssertEqual(vm.resultIDs, [b.id])
        XCTAssertFalse(vm.favoriteIDs.contains(a.id))
    }
}
