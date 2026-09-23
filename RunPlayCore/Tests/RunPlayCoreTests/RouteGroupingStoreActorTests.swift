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
        firstDayOffset: Int = 0,
        stepMeters: Double = 20
    ) -> [RunWorkout] {
        (0..<count).map { index in
            let date = RouteGroupingFixtures.epoch.addingTimeInterval(
                Double(index + firstDayOffset) * 86_400
            )
            let points = RouteGroupingFixtures.squareLoop(
                sideMeters: sideMeters,
                stepMeters: stepMeters,
                date: date
            )
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

    // MARK: - Materialized derived names

    func testDerivedNameIsPersistedAtCreationAndSurvivesReclusterAndRename() async throws {
        let runs = loopRuns(sideMeters: 1_250, count: 3, latitude: 37.0)
        try await addAll(runs)
        _ = try await actor.assignRouteGroups(for: runs.map(\.id))
        let created = try XCTUnwrap(try store.loadManifest().routeGroups.first)
        let derived = try XCTUnwrap(created.derivedName, "a new group is named when first persisted")
        XCTAssertNil(created.name, "a derived name is never stored as a user name")

        let reclustered = try await actor.reclusterRouteGroups()
        XCTAssertNotEqual(reclustered.groups[0].id, created.id)
        XCTAssertEqual(reclustered.groups[0].derivedName, derived, "re-cluster carries the derived name")

        try await actor.renameRouteGroup(id: reclustered.groups[0].id, name: "Canal Loop")
        try await actor.renameRouteGroup(id: reclustered.groups[0].id, name: nil)
        let reset = try XCTUnwrap(try store.loadManifest().routeGroups.first)
        XCTAssertNil(reset.name)
        XCTAssertEqual(reset.derivedName, derived, "clearing a rename returns the stable original")
    }

    /// #165: a joiner that outranks the representative re-picks it, and
    /// the new representative's facts would derive a different name. The
    /// stored name must not move — only a rename changes what the user sees.
    func testDerivedNameSurvivesRepresentativeRepickOnJoin() async throws {
        let runs = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        try await addAll(runs)
        _ = try await actor.assignRouteGroups(for: runs.map(\.id))
        let before = try XCTUnwrap(try store.loadManifest().routeGroups.first)
        let stored = try XCTUnwrap(before.derivedName)

        // Denser sampling outranks the current representative; the longer
        // side moves the rendered distance from 5.0 km to 5.1 km.
        let joiner = try XCTUnwrap(
            loopRuns(sideMeters: 1_275, count: 1, latitude: 37.0, firstDayOffset: 10, stepMeters: 10).first
        )
        try await addAll([joiner])
        let pass = try await actor.assignRouteGroups(for: [joiner.id])
        XCTAssertEqual(pass.joinedCount, 1, "the joiner must group with the loop")

        let after = try XCTUnwrap(try store.loadManifest().routeGroups.first { $0.id == before.id })
        XCTAssertEqual(after.representativeSummary?.workoutID, joiner.id, "the representative was re-picked")
        var unmaterialized = after
        unmaterialized.derivedName = nil
        let fresh = WorkoutRouteGroup.derivedDisplayNames(
            for: [unmaterialized],
            loopClosureDistanceMeters: WorkoutRouteGroup.defaultLoopClosureDistanceMeters
        )[after.id]
        XCTAssertNotEqual(fresh, stored, "the new representative would derive a different name")
        XCTAssertEqual(after.derivedName, stored, "the stored name does not follow the re-pick")
    }

    func testLoadLibraryMaterializesDerivedNamesForALegacyManifest() async throws {
        let familyA = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        let familyB = loopRuns(sideMeters: 900, count: 2, latitude: 38.5)
        try await addAll(familyA + familyB)
        _ = try await actor.backfillRouteGroupAssignments()

        // Rewrite the manifest as a pre-field v4 library would have it.
        var legacy = try store.loadManifest()
        let shown = WorkoutRouteGroup.derivedDisplayNames(
            for: legacy.routeGroups.map { group in
                var stripped = group
                stripped.derivedName = nil
                return stripped
            },
            loopClosureDistanceMeters: WorkoutRouteGroup.defaultLoopClosureDistanceMeters
        )
        for index in legacy.routeGroups.indices {
            legacy.routeGroups[index].derivedName = nil
        }
        try store.saveManifest(legacy)

        _ = await actor.loadLibrary()

        let migrated = try store.loadManifest()
        XCTAssertEqual(migrated.version, 4)
        XCTAssertEqual(migrated.routeGroups.count, 2)
        for group in migrated.routeGroups {
            XCTAssertEqual(group.derivedName, shown[group.id], "migration keeps the name already shown")
        }
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

        let (result, gate) = try await runAssignmentPass(for: newcomer.id) {
            try await actor.deleteWorkout(id: representativeID, newSelectedID: nil)
        }
        XCTAssertEqual(gate.parkCount, 1)
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

    /// A rename committed inside the assignment window survives the pass's
    /// final write: group names are user intent the pass never computes.
    func testRenameRouteGroupInsideAssignmentWindowSurvivesFinalWrite() async throws {
        let family = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        try await addAll(family)
        _ = try await actor.assignRouteGroups(for: family.map(\.id))
        let groupID = try XCTUnwrap(try store.loadManifest().routeGroups.first?.id)

        let newcomer = loopRuns(
            sideMeters: 1_250, count: 1, latitude: 37.0, firstDayOffset: 5
        )[0]
        try await actor.addWorkout(newcomer, select: false)

        let (result, _) = try await runAssignmentPass(for: newcomer.id) {
            try await actor.renameRouteGroup(id: groupID, name: "Morning Loop")
        }

        XCTAssertEqual(result.joinedCount, 1)
        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups.count, 1)
        XCTAssertEqual(
            manifest.routeGroups[0].name, "Morning Loop",
            "rename committed inside the window is clobbered"
        )
        XCTAssertEqual(
            result.groups.first?.name, "Morning Loop",
            "the pass result reports the persisted name"
        )
    }

    /// A re-pin committed inside the assignment window survives the pass's
    /// final write, pin and cached summary together.
    func testPinRouteGroupRepresentativeInsideAssignmentWindowSurvivesFinalWrite() async throws {
        let family = loopRuns(sideMeters: 1_250, count: 3, latitude: 37.0)
        try await addAll(family)
        _ = try await actor.assignRouteGroups(for: family.map(\.id))
        let groupID = try XCTUnwrap(try store.loadManifest().routeGroups.first?.id)
        // family[0] is the derived representative; the in-window pin
        // targets a different member.

        let newcomer = loopRuns(
            sideMeters: 1_250, count: 1, latitude: 37.0, firstDayOffset: 5
        )[0]
        try await actor.addWorkout(newcomer, select: false)

        let (result, _) = try await runAssignmentPass(for: newcomer.id) {
            try await actor.pinRouteGroupRepresentative(groupID: groupID, workoutID: family[1].id)
        }

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups.count, 1)
        XCTAssertEqual(
            manifest.routeGroups[0].pinnedRepresentativeWorkoutID, family[1].id,
            "pin committed inside the window is clobbered"
        )
        XCTAssertEqual(manifest.routeGroups[0].representativeSummary?.workoutID, family[1].id)
        XCTAssertEqual(result.groups.first?.pinnedRepresentativeWorkoutID, family[1].id)
    }

    /// A merge committed inside the assignment window survives the pass's
    /// final write: the merged-away source group is not resurrected by the
    /// pass's pre-await group list. The pass-matched group is the merge
    /// target here; the source is the other family's group.
    func testMergeRouteGroupsInsideAssignmentWindowSurvivesFinalWrite() async throws {
        let familyA = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        let familyB = loopRuns(sideMeters: 1_250, count: 2, latitude: 38.5)
        try await addAll(familyA + familyB)
        _ = try await actor.assignRouteGroups(for: (familyA + familyB).map(\.id))

        let manifestBefore = try store.loadManifest()
        XCTAssertEqual(manifestBefore.routeGroups.count, 2)
        let targetID = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyA[0].id))
        let sourceID = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyB[0].id))

        let newcomer = loopRuns(
            sideMeters: 1_250, count: 1, latitude: 37.0, firstDayOffset: 5
        )[0]
        try await actor.addWorkout(newcomer, select: false)

        let (result, _) = try await runAssignmentPass(for: newcomer.id) {
            try await actor.mergeRouteGroups(sourceID: sourceID, into: targetID)
        }

        XCTAssertEqual(result.joinedCount, 1)
        let manifest = try store.loadManifest()
        XCTAssertEqual(
            manifest.routeGroups.count, 1,
            "merged-away source group resurrected by the pass's pre-await list"
        )
        XCTAssertEqual(manifest.routeGroups[0].id, targetID)
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: targetID).count, 5)
        XCTAssertFalse(manifest.routeGroupAssignments.contains { $0.groupID == sourceID })
    }

    /// A deliberate removal committed inside the assignment window is not
    /// auto re-added: the user's evaluated-nil marker ("removed by the
    /// user — never auto re-added", docs/architecture.md) survives the
    /// pass's computed record for the same workout. Reachable when the
    /// pass re-evaluates a stale-version record the user removed mid-pass.
    func testRemoveWorkoutFromRouteGroupInsideAssignmentWindowIsNotReAdded() async throws {
        let family = loopRuns(sideMeters: 1_250, count: 3, latitude: 37.0)
        try await addAll(family)
        _ = try await actor.assignRouteGroups(for: family.map(\.id))
        let groupID = try XCTUnwrap(try store.loadManifest().routeGroups.first?.id)

        // Age one member's record so a later pass re-evaluates it.
        let removedID = family[1].id
        var aged = try store.loadManifest()
        let recordIndex = try XCTUnwrap(
            aged.routeGroupAssignments.firstIndex { $0.workoutID == removedID }
        )
        aged.routeGroupAssignments[recordIndex] = WorkoutRouteGroupAssignment(
            workoutID: removedID,
            groupID: aged.routeGroupAssignments[recordIndex].groupID,
            algorithmVersion: aged.routeGroupAssignments[recordIndex].algorithmVersion - 1
        )
        try store.saveManifest(aged)

        let (result, _) = try await runAssignmentPass(for: removedID) {
            try await actor.removeWorkoutFromRouteGroup(workoutID: removedID)
        }

        let manifest = try store.loadManifest()
        XCTAssertNil(
            manifest.routeGroupID(forWorkoutID: removedID),
            "deliberate removal auto re-added by the pass"
        )
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: groupID).count, 2)
        XCTAssertNil(
            result.assignments.first { $0.workoutID == removedID }?.groupID,
            "the pass result reports the persisted nil marker"
        )
    }

    /// Two assignment passes can overlap: one fires un-awaited after every
    /// import commit, and both hop off the actor at the matching pass.
    /// Whichever resumes last must not replace the group list with its own
    /// pre-await output — groups the other pass created survive, and their
    /// member records (already current-version) are not re-decided.
    func testOverlappingAssignmentPassesKeepEachOthersGroups() async throws {
        let family = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        try await addAll(family)
        _ = try await actor.assignRouteGroups(for: family.map(\.id))
        let familyGroupID = try XCTUnwrap(try store.loadManifest().routeGroups.first?.id)

        // newcomer1 joins the family route (its pass parks on the
        // representative load); newcomer2 is a distinct route family whose
        // own pass creates a new group and completes while pass 1 parks.
        let newcomer1 = loopRuns(
            sideMeters: 1_250, count: 1, latitude: 37.0, firstDayOffset: 5
        )[0]
        let newcomer2 = loopRuns(
            sideMeters: 900, count: 1, latitude: 40.5, firstDayOffset: 6
        )[0]
        try await actor.addWorkout(newcomer1, select: false)
        try await actor.addWorkout(newcomer2, select: false)

        let (result1, _) = try await runAssignmentPass(for: newcomer1.id) {
            _ = try await actor.assignRouteGroups(for: [newcomer2.id])
        }

        XCTAssertEqual(result1.joinedCount, 1)
        let manifest = try store.loadManifest()
        XCTAssertEqual(
            manifest.routeGroups.count, 2,
            "group created by the overlapping pass is discarded by the last write"
        )
        XCTAssertNotNil(
            manifest.routeGroupID(forWorkoutID: newcomer2.id),
            "overlapping pass's assignment discarded"
        )
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: familyGroupID).count, 3)
        XCTAssertEqual(result1.groups, manifest.routeGroups)
    }

    /// A merge committed inside the window whose **source** is the group the
    /// pass is matching into must not be undone, and the workout the pass
    /// matched into the source lands in the merge target on the pass's own
    /// write — where the user put its siblings — instead of waiting a pass
    /// in the backlog (#164). The merged-away source is not resurrected by
    /// the pass's pre-await group list, and the target keeps its name and
    /// pin.
    func testNewcomerMatchedIntoGroupMergedAwayInsideAssignmentWindowLandsInMergeTarget() async throws {
        let familyS = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        let familyT = loopRuns(sideMeters: 900, count: 2, latitude: 38.5)
        try await addAll(familyS + familyT)
        _ = try await actor.assignRouteGroups(for: (familyS + familyT).map(\.id))

        let manifestBefore = try store.loadManifest()
        let sourceID = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyS[0].id))
        let targetID = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyT[0].id))
        // The target's user intent must ride out both the merge and the pass.
        try await actor.renameRouteGroup(id: targetID, name: "Target Route")
        try await actor.pinRouteGroupRepresentative(groupID: targetID, workoutID: familyT[1].id)

        let newcomer = loopRuns(
            sideMeters: 1_250, count: 1, latitude: 37.0, firstDayOffset: 5
        )[0]
        try await actor.addWorkout(newcomer, select: false)

        let (result, _) = try await runAssignmentPass(for: newcomer.id) {
            try await actor.mergeRouteGroups(sourceID: sourceID, into: targetID)
        }
        XCTAssertEqual(result.joinedCount, 1)

        let manifest = try store.loadManifest()
        XCTAssertNil(
            manifest.routeGroup(id: sourceID),
            "merged-away source group resurrected by the pass's pre-await list"
        )
        let record = try XCTUnwrap(
            manifest.routeGroupAssignment(forWorkoutID: newcomer.id),
            "newcomer matched into the merged-away source was left in the backlog"
        )
        XCTAssertEqual(record.groupID, targetID, "newcomer did not follow the merge")
        XCTAssertEqual(record.algorithmVersion, RouteGroupingPolicy.default.algorithmVersion)
        let target = try XCTUnwrap(manifest.routeGroup(id: targetID))
        XCTAssertEqual(target.name, "Target Route")
        XCTAssertEqual(target.pinnedRepresentativeWorkoutID, familyT[1].id)
        XCTAssertEqual(target.representativeSummary?.workoutID, familyT[1].id)
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: targetID).count, 5)
        assertEveryAssignmentReferencesAGroup(manifest)
        XCTAssertEqual(result.groups, manifest.routeGroups)
    }

    /// Chained merges inside one window — the matched group into B, then B
    /// into C — resolve through the journal to the surviving end of the
    /// chain. An unpinned target adopts the pass's source summary when the
    /// newcomer outranks the target's representative, the same rule
    /// `mergeRouteGroups` applies, so the representative is right on the
    /// first write too.
    func testNewcomerFollowsChainedMergesInsideAssignmentWindow() async throws {
        let familyA = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        let familyB = loopRuns(sideMeters: 900, count: 2, latitude: 38.5)
        let familyC = loopRuns(sideMeters: 1_100, count: 2, latitude: 40.0)
        try await addAll(familyA + familyB + familyC)
        _ = try await actor.assignRouteGroups(for: (familyA + familyB + familyC).map(\.id))

        let manifestBefore = try store.loadManifest()
        let groupA = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyA[0].id))
        let groupB = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyB[0].id))
        let groupC = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyC[0].id))

        // A denser recording of family A's loop: more route points, so it
        // outranks every existing representative.
        let newcomer = loopRuns(
            sideMeters: 1_250, count: 1, latitude: 37.0, firstDayOffset: 5, stepMeters: 10
        )[0]
        try await actor.addWorkout(newcomer, select: false)

        let (result, _) = try await runAssignmentPass(for: newcomer.id) {
            try await actor.mergeRouteGroups(sourceID: groupA, into: groupB)
            try await actor.mergeRouteGroups(sourceID: groupB, into: groupC)
        }
        XCTAssertEqual(result.joinedCount, 1)

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups.map(\.id), [groupC])
        XCTAssertEqual(manifest.routeGroupID(forWorkoutID: newcomer.id), groupC)
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: groupC).count, 7)
        XCTAssertEqual(
            manifest.routeGroup(id: groupC)?.representativeSummary?.workoutID, newcomer.id,
            "unpinned merge target was not re-ranked against the redirected newcomer"
        )
        assertEveryAssignmentReferencesAGroup(manifest)
        XCTAssertEqual(result.groups, manifest.routeGroups)
    }

    /// When the merge target is itself gone by the final write — here
    /// emptied by deliberate removals inside the same window — there is no
    /// surviving group to follow the merge into, so the newcomer falls back
    /// to record *absence*: the backlog marker, not an evaluated-nil
    /// "deliberately ungrouped" record, and the next pass re-matches it.
    func testNewcomerFallsBackToBacklogWhenMergeTargetIsGoneByFinalWrite() async throws {
        let familyS = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        let familyT = loopRuns(sideMeters: 900, count: 1, latitude: 38.5)
        try await addAll(familyS + familyT)
        _ = try await actor.assignRouteGroups(for: (familyS + familyT).map(\.id))

        let manifestBefore = try store.loadManifest()
        let sourceID = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyS[0].id))
        let targetID = try XCTUnwrap(manifestBefore.routeGroupID(forWorkoutID: familyT[0].id))

        let newcomer = loopRuns(
            sideMeters: 1_250, count: 1, latitude: 37.0, firstDayOffset: 5
        )[0]
        try await actor.addWorkout(newcomer, select: false)

        let (result, _) = try await runAssignmentPass(for: newcomer.id) {
            try await actor.mergeRouteGroups(sourceID: sourceID, into: targetID)
            for member in familyS + familyT {
                try await actor.removeWorkoutFromRouteGroup(workoutID: member.id)
            }
        }
        XCTAssertEqual(result.joinedCount, 1)

        let manifest = try store.loadManifest()
        XCTAssertNil(manifest.routeGroup(id: sourceID))
        XCTAssertNil(manifest.routeGroup(id: targetID))
        XCTAssertNil(
            manifest.routeGroupAssignment(forWorkoutID: newcomer.id),
            "newcomer with no surviving merge target must fall back to record "
                + "absence (the backlog marker), not keep any record"
        )
        assertEveryAssignmentReferencesAGroup(manifest)
        XCTAssertEqual(result.groups, manifest.routeGroups)

        // Self-healing: with no interference, the next pass picks the
        // newcomer out of the backlog and gives it a record.
        _ = try await actor.assignRouteGroups(for: [newcomer.id])
        XCTAssertNotNil(
            try store.loadManifest().routeGroupAssignment(forWorkoutID: newcomer.id),
            "backlogged newcomer is not re-assigned by the next pass"
        )
    }

    private func assertEveryAssignmentReferencesAGroup(
        _ manifest: WorkoutLibraryManifest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let groupIDs = Set(manifest.routeGroups.map(\.id))
        for assignment in manifest.routeGroupAssignments {
            if let groupID = assignment.groupID {
                XCTAssertTrue(
                    groupIDs.contains(groupID), "assignment references a missing group",
                    file: file, line: line
                )
            }
        }
    }

    /// The plain case the resurrect guard must not swallow: a pass whose
    /// newcomer founds a genuinely new group — an id in neither snapshot —
    /// still writes that group alongside the existing ones.
    func testPassCreatedGroupStillLandsAlongsideExistingGroups() async throws {
        let family = loopRuns(sideMeters: 1_250, count: 2, latitude: 37.0)
        try await addAll(family)
        _ = try await actor.assignRouteGroups(for: family.map(\.id))
        let existingGroupID = try XCTUnwrap(try store.loadManifest().routeGroups.first?.id)

        let newcomer = loopRuns(
            sideMeters: 900, count: 1, latitude: 40.5, firstDayOffset: 5
        )[0]
        try await actor.addWorkout(newcomer, select: false)

        let result = try await actor.assignRouteGroups(for: [newcomer.id])
        XCTAssertEqual(result.createdCount, 1)

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.routeGroups.count, 2)
        let createdGroup = try XCTUnwrap(manifest.routeGroups.first { $0.id != existingGroupID })
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: createdGroup.id), [newcomer.id])
        // The result reports the persisted groups; the encoder stores them
        // UUID-sorted while the in-memory list appends the created group,
        // so compare order-insensitively.
        XCTAssertEqual(
            result.groups.sorted { $0.id.uuidString < $1.id.uuidString },
            manifest.routeGroups.sorted { $0.id.uuidString < $1.id.uuidString },
            "the pass result reports the persisted groups"
        )
    }

    /// Runs one assignment pass whose representative loader is parked on a
    /// suspension gate, executes `interleave` while the pass is suspended
    /// and the actor is free, then releases the loader and awaits the pass
    /// result. Fails the test (rather than hanging) if the pass never
    /// reaches the seam.
    @discardableResult
    private func runAssignmentPass(
        for workoutID: UUID,
        interleaving interleave: () async throws -> Void
    ) async throws -> (
        result: WorkoutLibraryStoreActor.RouteGroupAssignmentPassResult,
        gate: LoaderSuspensionGate
    ) {
        let gate = LoaderSuspensionGate()
        await actor.setRouteGroupRepresentativeLoaderSuspension { await gate.suspendLoader() }

        let library: WorkoutLibraryStoreActor = actor
        let passTask = Task {
            try await library.assignRouteGroups(for: [workoutID])
        }
        defer { gate.release() }

        let suspended = await withTestTimeout { await gate.waitForLoaderSuspension() } ?? false
        XCTAssertTrue(suspended, "assignment pass never reached the representative-loader seam")
        try await interleave()
        gate.release()
        let result = try await passTask.value
        return (result, gate)
    }
}
