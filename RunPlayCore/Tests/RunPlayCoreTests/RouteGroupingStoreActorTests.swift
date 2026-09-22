import XCTest
@testable import RunPlayCore

/// Store-actor route-group passes and manual mutations over a real
/// file-backed library in a temp directory.
final class RouteGroupingStoreActorTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: FileWorkoutLibraryStore!
    private var actor: WorkoutLibraryStoreActor!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-grouping-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = FileWorkoutLibraryStore(rootURL: tempDirectory)
        actor = WorkoutLibraryStoreActor(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    /// A loop with a distinct base latitude so route families do not overlap.
    private func loopRuns(
        sideMeters: Double,
        count: Int,
        latitude: Double,
        firstDayOffset: Int = 0
    ) -> [RunWorkout] {
        (0..<count).map { index in
            let date = RouteGroupingFixtures.epoch.addingTimeInterval(
                Double(index + firstDayOffset) * 86_400
            )
            let points = RouteGroupingFixtures.squareLoop(sideMeters: sideMeters, date: date)
                .map { point in
                    RoutePoint(
                        timestamp: point.timestamp,
                        latitude: point.latitude + (latitude - RouteGroupingFixtures.baseLatitude),
                        longitude: point.longitude,
                        distanceFromStartMeters: point.distanceFromStartMeters,
                        elapsedSeconds: point.elapsedSeconds,
                        paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                        routeSegmentIndex: point.routeSegmentIndex
                    )
                }
            return RouteGroupingFixtures.workout(points: points, date: date)
        }
    }

    private func addAll(_ workouts: [RunWorkout]) async throws {
        for workout in workouts {
            try await actor.addWorkout(workout, select: false)
        }
    }

    // MARK: - Incremental assignment + backfill

    func testAssignRouteGroupsPersistsMembershipAndIsIdempotent() async throws {
        let runs = loopRuns(sideMeters: 1_250, count: 3, latitude: 37.0)
        try await addAll(runs)

        let first = try await actor.assignRouteGroups(for: runs.map(\.id))
        XCTAssertEqual(first.joinedCount, 2)
        XCTAssertEqual(first.createdCount, 1)
        XCTAssertEqual(first.groups.count, 1)

        // Re-running the pass with current-version records is a no-op.
        let second = try await actor.assignRouteGroups(for: runs.map(\.id))
        XCTAssertEqual(second.joinedCount, 0)
        XCTAssertEqual(second.createdCount, 0)
        XCTAssertEqual(second.groups.count, 1)
        XCTAssertEqual(second.assignments.count, 3)

        // The manifest on disk carries the records (nil marker durability).
        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups.count, 1)
        XCTAssertEqual(manifest.routeGroupAssignments.count, 3)
    }

    func testBackfillAssignsEverythingThenIdles() async throws {
        let familyA = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        let familyB = loopRuns(sideMeters: 900, count: 2, latitude: 38.5)
        try await addAll(familyA + familyB)

        let backfill = try await actor.backfillRouteGroupAssignments()
        XCTAssertEqual(backfill.groups.count, 2)
        XCTAssertEqual(backfill.assignments.count, 4)

        let again = try await actor.backfillRouteGroupAssignments()
        XCTAssertEqual(again.groups.count, 2)
        XCTAssertEqual(again.joinedCount + again.createdCount, 0)
    }

    // MARK: - Re-cluster

    func testReclusterReplacesGroupsAtomicallyAndCarriesNames() async throws {
        let runs = loopRuns(sideMeters: 1_250, count: 3, latitude: 37.0)
        try await addAll(runs)
        _ = try await actor.assignRouteGroups(for: runs.map(\.id))
        let oldGroup = try XCTUnwrap(try store.loadManifest().routeGroups.first)

        try await actor.renameRouteGroup(id: oldGroup.id, name: "Named Loop")
        let result = try await actor.reclusterRouteGroups()

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].name, "Named Loop", "user names survive re-cluster")
        XCTAssertEqual(result.workoutCount, 3)
    }

    // MARK: - Manual mutations

    func testRenameRouteGroup() async throws {
        let runs = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        try await addAll(runs)
        _ = try await actor.assignRouteGroups(for: runs.map(\.id))
        let group = try XCTUnwrap(try store.loadManifest().routeGroups.first)

        try await actor.renameRouteGroup(id: group.id, name: "  Morning Loop  ")
        var manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups[0].name, "Morning Loop")

        try await actor.renameRouteGroup(id: group.id, name: "   ")
        manifest = try store.loadManifest()
        XCTAssertNil(manifest.routeGroups[0].name, "blank returns to the derived default")
    }

    func testMergeRouteGroupsMovesMembers() async throws {
        let familyA = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        let familyB = loopRuns(sideMeters: 1_250, count: 2, latitude: 38.5)
        try await addAll(familyA + familyB)
        _ = try await actor.assignRouteGroups(for: (familyA + familyB).map(\.id))

        let manifestBefore = try store.loadManifest()
        XCTAssertEqual(manifestBefore.routeGroups.count, 2)
        let source = manifestBefore.routeGroups[0]
        let target = manifestBefore.routeGroups[1]

        try await actor.mergeRouteGroups(sourceID: source.id, into: target.id)

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups.count, 1)
        XCTAssertEqual(manifest.routeGroups[0].id, target.id)
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: target.id).count, 4)
        XCTAssertFalse(manifest.routeGroupAssignments.contains { $0.groupID == source.id })
    }

    func testRemoveWorkoutFromRouteGroupLeavesNilMarkerAndDropsEmptyGroup() async throws {
        let runs = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        try await addAll(runs)
        _ = try await actor.assignRouteGroups(for: runs.map(\.id))
        let groupID = try XCTUnwrap(try store.loadManifest().routeGroups.first?.id)

        // Remove one member: the group survives with one member.
        try await actor.removeWorkoutFromRouteGroup(workoutID: runs[1].id)
        var manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups.count, 1)
        XCTAssertNil(manifest.routeGroupID(forWorkoutID: runs[1].id))
        // The removal is an evaluated-nil record, not a pending absence:
        // the backfill (which only touches pending or stale records) must
        // not re-add the run. Its returned assignment list is the complete
        // manifest state, so assert the record itself stayed nil-grouped.
        let backfill = try await actor.backfillRouteGroupAssignments()
        XCTAssertEqual(backfill.joinedCount + backfill.createdCount, 0)
        XCTAssertNil(backfill.assignments.first { $0.workoutID == runs[1].id }?.groupID)

        // Remove the last member: the empty group disappears.
        try await actor.removeWorkoutFromRouteGroup(workoutID: runs[0].id)
        manifest = try store.loadManifest()
        XCTAssertTrue(manifest.routeGroups.isEmpty)
        XCTAssertNil(manifest.routeGroupID(forWorkoutID: runs[0].id))
        _ = groupID
    }

    func testPinRouteGroupRepresentative() async throws {
        let runs = loopRuns(sideMeters: 1_250, count: 3, latitude: 37.0)
        try await addAll(runs)
        _ = try await actor.assignRouteGroups(for: runs.map(\.id))
        let group = try XCTUnwrap(try store.loadManifest().routeGroups.first)

        try await actor.pinRouteGroupRepresentative(groupID: group.id, workoutID: runs[2].id)

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups[0].pinnedRepresentativeWorkoutID, runs[2].id)
        XCTAssertEqual(manifest.routeGroups[0].representativeSummary?.workoutID, runs[2].id)

        // Pinning a non-member is rejected.
        do {
            try await actor.pinRouteGroupRepresentative(
                groupID: group.id,
                workoutID: UUID()
            )
            XCTFail("expected invalidRouteGroup")
        } catch {
            // Expected.
        }
    }

    // MARK: - Deletion

    func testDeleteWorkoutRepairsRouteGroup() async throws {
        let runs = loopRuns(sideMeters: 1_250, count: 3, latitude: 37.0)
        try await addAll(runs)
        _ = try await actor.assignRouteGroups(for: runs.map(\.id))

        try await actor.deleteWorkout(id: runs[0].id, newSelectedID: nil)

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups.count, 1)
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: manifest.routeGroups[0].id).count, 2)
        XCTAssertNil(manifest.routeGroupAssignment(forWorkoutID: runs[0].id))

        // Deleting every member removes the group.
        try await actor.deleteWorkout(id: runs[1].id, newSelectedID: nil)
        try await actor.deleteWorkout(id: runs[2].id, newSelectedID: nil)
        let emptied = try store.loadManifest()
        XCTAssertTrue(emptied.routeGroups.isEmpty)
    }

    // MARK: - Deletion interleaved with an assignment pass

    /// Deterministic handshake for the assignment-pass representative-loader
    /// suspension seam. The loader parks in `suspendLoader()`; the test
    /// awaits `waitForLoaderSuspension()` (cancellation-aware), interleaves
    /// other actor work while the pass is parked, then unparks with
    /// `release()`. Loader calls after the release — or while an earlier
    /// call is still parked — run straight through, so extra representative
    /// lookups cannot deadlock the pass.
    private final class LoaderSuspensionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var parkedLoader: CheckedContinuation<Void, Never>?
        private var suspensionWaiter: CheckedContinuation<Bool, Never>?
        private var released = false
        private var parkedCount = 0

        /// Number of loader calls that actually parked (diagnostic).
        var parkCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return parkedCount
        }

        func suspendLoader() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released || parkedLoader != nil {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                parkedCount += 1
                parkedLoader = continuation
                let waiter = suspensionWaiter
                suspensionWaiter = nil
                lock.unlock()
                waiter?.resume(returning: true)
            }
        }

        @discardableResult
        func waitForLoaderSuspension() async -> Bool {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    lock.lock()
                    if parkedLoader != nil {
                        lock.unlock()
                        continuation.resume(returning: true)
                        return
                    }
                    suspensionWaiter = continuation
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                let waiter = suspensionWaiter
                suspensionWaiter = nil
                lock.unlock()
                waiter?.resume(returning: false)
            }
        }

        func release() {
            lock.lock()
            released = true
            let loader = parkedLoader
            parkedLoader = nil
            lock.unlock()
            loader?.resume()
        }
    }

    /// Races `body` against a deadline and cancels the loser, so a broken
    /// handshake fails the test instead of hanging the suite. Returns `nil`
    /// only on timeout.
    private func withTestTimeout<T: Sendable>(
        seconds: TimeInterval = 10,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Reproduces issue #131: `deleteWorkout` completing inside the
    /// assignment pass's suspension window must survive the pass's final
    /// manifest write. The pass suspends deterministically through the
    /// loader seam (no sleep race): the representative loader parks after
    /// loading the snapshot, the delete commits while it is parked, and
    /// only then is the loader released.
    func testDeleteWorkoutInsideAssignmentWindowSurvivesFinalWrite() async throws {
        // Two existing runs form one group; a pinned representative gives
        // the pass's pre-await state a pin and cached summary to resurrect.
        let family = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        try await addAll(family)
        _ = try await actor.assignRouteGroups(for: family.map(\.id))
        let groupID = try XCTUnwrap(try store.loadManifest().routeGroups.first?.id)
        let representativeID = try XCTUnwrap(
            try store.loadManifest().routeGroups.first?.representativeSummary?.workoutID
        )
        try await actor.pinRouteGroupRepresentative(groupID: groupID, workoutID: representativeID)

        // A later run of the same route: the pass loads the group's
        // representative through the seam and joins the group.
        let newcomer = loopRuns(
            sideMeters: 1_250, count: 1, latitude: 37.0, firstDayOffset: 5
        )[0]
        try await actor.addWorkout(newcomer, select: false)

        let gate = LoaderSuspensionGate()
        await actor.setRouteGroupRepresentativeLoaderSuspension { await gate.suspendLoader() }

        let library: WorkoutLibraryStoreActor = actor
        let newcomerID = newcomer.id
        let passTask = Task {
            try await library.assignRouteGroups(for: [newcomerID])
        }

        // Park the loader (the pass is suspended and the actor is free),
        // delete the pinned representative, then let the pass finish.
        let suspended = await withTestTimeout { await gate.waitForLoaderSuspension() } ?? false
        XCTAssertTrue(suspended, "assignment pass never reached the representative-loader seam")
        XCTAssertEqual(gate.parkCount, 1)

        try await actor.deleteWorkout(id: representativeID, newSelectedID: nil)
        gate.release()

        let result = try await passTask.value
        XCTAssertEqual(result.joinedCount, 1)

        // Assertions against the manifest reloaded from disk.
        let manifest = try store.loadManifest()
        XCTAssertFalse(
            manifest.workoutIDs.contains(representativeID),
            "deleted workout resurrected in workoutIDs"
        )
        XCTAssertNil(
            manifest.routeGroupAssignment(forWorkoutID: representativeID),
            "deleted workout resurrected in routeGroupAssignments"
        )
        for group in manifest.routeGroups {
            XCTAssertNotEqual(
                group.pinnedRepresentativeWorkoutID,
                representativeID as UUID?,
                "deleted workout resurrected as a pinned representative"
            )
            XCTAssertNotEqual(
                group.representativeSummary?.workoutID,
                representativeID as UUID?,
                "deleted workout resurrected as a representative summary"
            )
        }
        let presentIDs = Set(manifest.workoutIDs)
        for assignment in manifest.routeGroupAssignments {
            XCTAssertTrue(
                presentIDs.contains(assignment.workoutID),
                "assignment references a deleted workout: \(assignment.workoutID)"
            )
        }

        // The pass result reports the persisted state, not a pre-filter one.
        XCTAssertEqual(result.groups, manifest.routeGroups)
        XCTAssertEqual(result.assignments, manifest.routeGroupAssignments)
    }
}
