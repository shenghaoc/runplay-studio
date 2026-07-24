import XCTest
@testable import RunPlayCore

final class WorkoutTagStoreActorTests: XCTestCase {
    private var tempRoot: URL!
    private var actor: WorkoutLibraryStoreActor!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagActor-\(UUID().uuidString)", isDirectory: true)
        let store = FileWorkoutLibraryStore(rootURL: tempRoot)
        try store.ensureDirectoriesExist()
        actor = WorkoutLibraryStoreActor(store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        actor = nil
        tempRoot = nil
    }

    private func makeWorkout(name: String = "Seed") -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return RunWorkout(
            id: UUID(),
            metadata: WorkoutMetadata(name: name, startDate: start),
            source: .json,
            routePoints: [
                RoutePoint(
                    timestamp: start,
                    latitude: 37,
                    longitude: -122,
                    altitudeMeters: 10,
                    distanceFromStartMeters: 0,
                    elapsedSeconds: 0
                )
            ],
            summary: RunSummary(totalDistanceMeters: 1000, totalElapsedSeconds: 300)
        )
    }

    private func seedWorkout() async throws -> RunWorkout {
        let workout = makeWorkout()
        try await actor.addWorkout(workout, select: true)
        return workout
    }

    func testCreateRenameRecolorDeleteTag() async throws {
        let workout = try await seedWorkout()
        let tag = try await actor.createTag(name: "Race", color: .red)
        XCTAssertEqual(tag.name, "Race")

        let renamed = try await actor.updateTag(id: tag.id, name: "Race Day", color: .orange)
        XCTAssertEqual(renamed.id, tag.id)
        XCTAssertEqual(renamed.name, "Race Day")
        XCTAssertEqual(renamed.color, .orange)

        try await actor.setTags([tag.id], forWorkoutID: workout.id)
        try await actor.deleteTag(id: tag.id)

        let loaded = await actor.loadLibrary()
        guard case .workouts(_, _, _, let org, _) = loaded else {
            return XCTFail("expected workouts")
        }
        XCTAssertTrue(org.tags.isEmpty)
        XCTAssertTrue(org.tagAssignments.isEmpty)
    }

    func testDuplicateNameRejected() async throws {
        _ = try await seedWorkout()
        _ = try await actor.createTag(name: "Easy", color: .green)
        do {
            _ = try await actor.createTag(name: "easy", color: .blue)
            XCTFail("expected duplicate failure")
        } catch let error as WorkoutLibraryStoreError {
            if case .invalidTag = error {
                // ok
            } else {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testCreateLimitsUseStoreErrorSurface() async throws {
        _ = try await seedWorkout()

        do {
            _ = try await actor.createTag(
                name: "Too Many",
                color: .blue,
                policy: WorkoutTagPolicy(maxTags: 0)
            )
            XCTFail("expected tag limit failure")
        } catch let error as WorkoutLibraryStoreError {
            guard case .invalidTag = error else {
                return XCTFail("unexpected " + String(describing: error))
            }
        }

        do {
            _ = try await actor.createSmartCollection(
                name: "Too Many Collections",
                query: WorkoutLibrarySavedQuery(),
                policy: WorkoutSmartCollectionPolicy(maxCollections: 0)
            )
            XCTFail("expected collection limit failure")
        } catch let error as WorkoutLibraryStoreError {
            guard case .invalidSmartCollection = error else {
                return XCTFail("unexpected " + String(describing: error))
            }
        }
    }

    func testBulkUpdateTagsOneWrite() async throws {
        let a = try await seedWorkout()
        let b = makeWorkout(name: "B")
        try await actor.addWorkout(b, select: false)
        let tag = try await actor.createTag(name: "Marathon", color: .purple)

        try await actor.updateTags(
            workoutIDs: [a.id, b.id],
            addTagIDs: [tag.id],
            removeTagIDs: []
        )

        let loaded = await actor.loadLibrary()
        guard case .workouts(_, _, _, let org, _) = loaded else {
            return XCTFail("expected workouts")
        }
        XCTAssertEqual(org.tagAssignments.count, 2)
        XCTAssertTrue(org.tagAssignments.allSatisfy { $0.tagIDSet == [tag.id] })
    }

    func testDeleteWorkoutRemovesAssignment() async throws {
        let workout = try await seedWorkout()
        let tag = try await actor.createTag(name: "Travel", color: .cyan)
        try await actor.setTags([tag.id], forWorkoutID: workout.id)
        _ = try await actor.deleteWorkout(id: workout.id, newSelectedID: nil)

        let store = FileWorkoutLibraryStore(rootURL: tempRoot)
        let manifest = try store.loadManifest()
        XCTAssertTrue(manifest.tagAssignments.isEmpty)
        XCTAssertEqual(manifest.tags.count, 1)
    }

    func testSmartCollectionCRUDAndRelativeDate() async throws {
        _ = try await seedWorkout()
        let query = WorkoutLibrarySavedQuery(
            searchText: "",
            filter: WorkoutLibraryFilter(date: .last30Days),
            sort: .dateNewest
        )
        let collection = try await actor.createSmartCollection(name: "Recent", query: query)
        XCTAssertEqual(collection.query.filter.date, .last30Days)

        let updated = try await actor.updateSmartCollection(
            id: collection.id,
            name: "Last 30",
            query: query
        )
        XCTAssertEqual(updated.id, collection.id)
        XCTAssertEqual(updated.name, "Last 30")

        try await actor.deleteSmartCollection(id: collection.id)
        let loaded = await actor.loadLibrary()
        guard case .workouts(_, _, _, let org, _) = loaded else {
            return XCTFail("expected workouts")
        }
        XCTAssertTrue(org.smartCollections.isEmpty)
    }

    func testDeleteTagRepairsCollectionFilter() async throws {
        _ = try await seedWorkout()
        let tag = try await actor.createTag(name: "Race", color: .red)
        let query = WorkoutLibrarySavedQuery(
            filter: WorkoutLibraryFilter(tags: .selected(tagIDs: [tag.id], match: .any))
        )
        _ = try await actor.createSmartCollection(name: "Races", query: query)
        try await actor.deleteTag(id: tag.id)

        let loaded = await actor.loadLibrary()
        guard case .workouts(_, _, _, let org, _) = loaded else {
            return XCTFail("expected workouts")
        }
        XCTAssertEqual(org.smartCollections.count, 1)
        if case .anyTags = org.smartCollections[0].query.filter.tags {
            // ok
        } else {
            XCTFail("expected anyTags after tag deletion")
        }
    }

    func testMissingWorkoutTagAssignmentFails() async throws {
        _ = try await seedWorkout()
        let tag = try await actor.createTag(name: "X", color: .gray)
        do {
            try await actor.setTags([tag.id], forWorkoutID: UUID())
            XCTFail("expected missing workout")
        } catch let error as WorkoutLibraryStoreError {
            if case .workoutNotInLibrary = error {
                // ok
            } else {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testImportPreservesTags() async throws {
        let workout = try await seedWorkout()
        let tag = try await actor.createTag(name: "Keep", color: .blue)
        try await actor.setTags([tag.id], forWorkoutID: workout.id)
        let collection = try await actor.createSmartCollection(
            name: "All",
            query: WorkoutLibrarySavedQuery()
        )

        let extra = makeWorkout(name: "Extra")
        try await actor.addWorkout(extra, select: false)

        let loaded = await actor.loadLibrary()
        guard case .workouts(let workouts, _, _, let org, _) = loaded else {
            return XCTFail("expected workouts")
        }
        XCTAssertEqual(workouts.count, 2)
        XCTAssertEqual(org.tags.map(\.id), [tag.id])
        XCTAssertEqual(org.tagAssignments.count, 1)
        XCTAssertEqual(org.smartCollections.map(\.id), [collection.id])
    }

    func testReorderTags() async throws {
        _ = try await seedWorkout()
        let a = try await actor.createTag(name: "A", color: .blue)
        let b = try await actor.createTag(name: "B", color: .green)
        try await actor.reorderTags([b.id, a.id])
        let loaded = await actor.loadLibrary()
        guard case .workouts(_, _, _, let org, _) = loaded else {
            return XCTFail("expected workouts")
        }
        XCTAssertEqual(org.tags.map(\.id), [b.id, a.id])
    }
}
