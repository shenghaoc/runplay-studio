import XCTest
@testable import RunPlayCore

/// Materialized derived route-group names (issue #134): decided once when a
/// group is first persisted, frozen afterwards, carried across a re-cluster,
/// and kept apart from user-assigned names.
final class RouteGroupMaterializedNameTests: XCTestCase {
    private let service = RouteGroupingService()

    private func uuid(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }

    private func loop(
        id: UUID,
        bearingDegrees: Double,
        distanceMeters: Double = 1_200,
        name: String? = nil,
        derivedName: String? = nil
    ) -> WorkoutRouteGroup {
        var group = RouteGroupingFixtures.namingGroup(
            id: id,
            bearingDegrees: bearingDegrees,
            totalDistanceMeters: distanceMeters,
            date: RouteGroupingFixtures.epoch,
            name: name
        )
        group.derivedName = derivedName
        return group
    }

    private func materialized(_ groups: [WorkoutRouteGroup]) -> [UUID: WorkoutRouteGroup] {
        var copy = groups
        WorkoutRouteGroup.materializeDerivedNames(in: &copy)
        return Dictionary(uniqueKeysWithValues: copy.map { ($0.id, $0) })
    }

    private func displayNames(_ groups: [WorkoutRouteGroup]) -> [UUID: String] {
        WorkoutRouteGroup.derivedDisplayNames(
            for: groups,
            loopClosureDistanceMeters: WorkoutRouteGroup.defaultLoopClosureDistanceMeters
        )
    }

    // MARK: - Migration

    /// First load of a manifest that predates the field must persist exactly
    /// the names its surfaces were already showing for unnamed groups, and
    /// give every group — user-named ones too — a distinct derived name.
    func testMigrationPersistsTheNamesAlreadyShownAndEveryDerivedNameIsDistinct() throws {
        for seed: UInt64 in [7, 21, 404] {
            let population = RouteGroupingFixtures.derivedNamePopulation(seed: seed, count: 300)
            let shownBefore = displayNames(population)
            let migrated = materialized(population)

            for group in population where (group.name ?? "").isEmpty {
                XCTAssertEqual(
                    migrated[group.id]?.derivedName,
                    shownBefore[group.id],
                    "seed \(seed): migration renamed an unnamed group"
                )
            }
            let derived = migrated.values.compactMap(\.derivedName)
            XCTAssertEqual(derived.count, population.count, "seed \(seed): every group is materialized")
            XCTAssertEqual(Set(derived).count, derived.count, "seed \(seed): derived names collide")
            // Surfaces show the same names after migration as before it.
            XCTAssertEqual(displayNames(Array(migrated.values)), shownBefore, "seed \(seed)")
        }
    }

    func testMaterializationIsIdempotentAndOrderIndependent() {
        let population = RouteGroupingFixtures.derivedNamePopulation(seed: 21, count: 300)
        let once = materialized(population)
        let twice = materialized(Array(once.values))
        XCTAssertEqual(once, twice)
        XCTAssertEqual(materialized(population.reversed()), once)
    }

    // MARK: - Frozen after creation

    /// A representative change — here the quality rule picking a member
    /// that points the other way — must not move a stored name.
    func testStoredNameIgnoresRepresentativeChange() throws {
        let group = try XCTUnwrap(materialized([
            loop(id: uuid(1), bearingDegrees: 45),
            loop(id: uuid(2), bearingDegrees: 90)
        ])[uuid(1)])
        let stored = try XCTUnwrap(group.derivedName)
        XCTAssertTrue(stored.hasSuffix("(NE)"), "got \(stored)")

        var reversed = group
        reversed.representativeSummary = loop(id: uuid(9), bearingDegrees: 225).representativeSummary
        XCTAssertEqual(displayNames([reversed, loop(id: uuid(2), bearingDegrees: 90)])[group.id], stored)
        XCTAssertEqual(materialized([reversed])[group.id]?.derivedName, stored)
    }

    /// A newcomer refines around the names already shown; the name the user
    /// has learned stays bare.
    func testNewcomerRefinesAroundAStoredName() throws {
        let existing = try XCTUnwrap(materialized([loop(id: uuid(1), bearingDegrees: 0)])[uuid(1)])
        let base = WorkoutRouteGroup.defaultDisplayName(distanceMeters: 1_200, closesLoop: true)
        XCTAssertEqual(existing.derivedName, base)

        let after = materialized([existing, loop(id: uuid(2), bearingDegrees: 90)])
        XCTAssertEqual(after[uuid(1)]?.derivedName, base, "the stored name never moves")
        XCTAssertEqual(after[uuid(2)]?.derivedName, base + " (E)")

        // Same answer on the read path before the newcomer is persisted.
        XCTAssertEqual(displayNames([existing, loop(id: uuid(2), bearingDegrees: 90)])[uuid(2)], base + " (E)")
    }

    /// A newcomer whose whole compass ladder is taken falls through to its
    /// id digest rather than duplicating a stored name.
    func testNewcomerFallsThroughToDigestWhenEveryCompassRungIsTaken() throws {
        let base = WorkoutRouteGroup.defaultDisplayName(distanceMeters: 1_200, closesLoop: true)
        let occupants = [base, base + " (N)", base + " (NNE)"].enumerated().map { index, name in
            loop(id: uuid(UInt8(10 + index)), bearingDegrees: 200, distanceMeters: 1_200, derivedName: name)
        }
        let newcomer = loop(id: uuid(1), bearingDegrees: 20)
        let name = try XCTUnwrap(materialized(occupants + [newcomer])[uuid(1)]?.derivedName)
        let digest = WorkoutRouteGroup.stableDigestHex(for: uuid(1))
        XCTAssertEqual(name, base + " (NNE·\(digest.prefix(3)))")
    }

    // MARK: - User-assigned names stay apart

    func testRenameAndResetRoundTripsTheStoredName() throws {
        var group = try XCTUnwrap(materialized([loop(id: uuid(1), bearingDegrees: 0)])[uuid(1)])
        let stored = try XCTUnwrap(group.derivedName)

        group.name = "Canal Loop"
        XCTAssertEqual(displayNames([group])[group.id], "Canal Loop")
        XCTAssertEqual(materialized([group])[group.id]?.derivedName, stored, "renaming is non-destructive")

        group.name = nil
        XCTAssertEqual(displayNames([group])[group.id], stored, "clearing the rename returns the original")
    }

    func testUserNamesAreNeverSuffixedButStillGetDistinctDerivedNames() throws {
        let result = materialized([
            loop(id: uuid(1), bearingDegrees: 0, name: "Home"),
            loop(id: uuid(2), bearingDegrees: 90, name: "Home"),
            loop(id: uuid(3), bearingDegrees: 180)
        ])
        let names = displayNames(Array(result.values))
        XCTAssertEqual(names[uuid(1)], "Home")
        XCTAssertEqual(names[uuid(2)], "Home")

        let base = WorkoutRouteGroup.defaultDisplayName(distanceMeters: 1_200, closesLoop: true)
        XCTAssertEqual(result[uuid(3)]?.derivedName, base, "user-named groups do not unsettle an unnamed one")
        let derived = [uuid(1), uuid(2), uuid(3)].compactMap { result[$0]?.derivedName }
        XCTAssertEqual(Set(derived).count, 3, "got \(derived)")
    }

    // MARK: - Repair

    func testDuplicatedStoredNameIsRepairedForTheLaterIDOnly() throws {
        let base = WorkoutRouteGroup.defaultDisplayName(distanceMeters: 1_200, closesLoop: true)
        let result = materialized([
            loop(id: uuid(2), bearingDegrees: 90, derivedName: base),
            loop(id: uuid(1), bearingDegrees: 0, derivedName: base)
        ])
        XCTAssertEqual(result[uuid(1)]?.derivedName, base)
        XCTAssertEqual(result[uuid(2)]?.derivedName, base + " (E)")
    }

    func testGroupWithoutSummaryStaysUnmaterialized() {
        let bare = WorkoutRouteGroup(id: uuid(1))
        XCTAssertNil(materialized([bare])[uuid(1)]?.derivedName)
    }

    // MARK: - Persistence

    func testLegacyGroupWithoutDerivedNameDecodesAndRoundTrips() throws {
        let legacy = """
        {"id":"\(uuid(1).uuidString)","name":"Canal"}
        """
        let decoded = try JSONDecoder().decode(WorkoutRouteGroup.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.name, "Canal")
        XCTAssertNil(decoded.derivedName)

        var named = decoded
        named.derivedName = "1.2 km Loop (NE)"
        let roundTripped = try JSONDecoder().decode(
            WorkoutRouteGroup.self,
            from: JSONEncoder().encode(named)
        )
        XCTAssertEqual(roundTripped, named)
    }

    func testManifestRepairMaterializesAndKeepsSchemaVersion() {
        let workoutID = uuid(9)
        var group = loop(id: uuid(1), bearingDegrees: 0)
        group.representativeSummary?.workoutID = workoutID
        var manifest = WorkoutLibraryManifest(
            workoutIDs: [workoutID],
            routeGroups: [group],
            routeGroupAssignments: [
                WorkoutRouteGroupAssignment(workoutID: workoutID, groupID: group.id, algorithmVersion: 1)
            ]
        )
        manifest.migrateToCurrentVersionIfNeeded()
        XCTAssertEqual(
            manifest.routeGroups.first?.derivedName,
            WorkoutRouteGroup.defaultDisplayName(distanceMeters: 1_200, closesLoop: true)
        )
        XCTAssertEqual(manifest.version, 4, "an additive optional needs no schema bump")
    }

    // MARK: - Re-cluster carry-over

    func testReclusterCarriesTheDerivedName() throws {
        let runs = (0..<2).map { RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: $0) }
        var previous = try XCTUnwrap(try service.recluster(workouts: runs, policy: .default).groups.first)
        previous.derivedName = "5.0 km Loop (NE)"

        let result = try service.recluster(workouts: runs, previousGroups: [previous], policy: .default)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertNotEqual(result.groups[0].id, previous.id, "re-cluster mints new ids")
        XCTAssertEqual(result.groups[0].derivedName, "5.0 km Loop (NE)")
        XCTAssertNil(result.groups[0].name)
    }

    /// Two previous groups collapse into one new group: the one contributing
    /// more members wins, even though the other has the smaller id — the
    /// order that used to decide.
    func testMergeCollisionKeepsTheLargestContributorsNames() throws {
        let runs = (0..<3).map { RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: $0) }
        let small = WorkoutRouteGroup(
            id: uuid(1),
            name: "Small",
            representativeSummary: WorkoutRouteGroupSummary(
                workoutID: runs[0].id,
                startDate: nil,
                facts: RouteGroupingRouteFacts(workout: runs[0])
            ),
            derivedName: "Small derived"
        )
        let large = WorkoutRouteGroup(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            name: "Large",
            representativeSummary: WorkoutRouteGroupSummary(
                workoutID: runs[1].id,
                startDate: nil,
                facts: RouteGroupingRouteFacts(workout: runs[1])
            ),
            derivedName: "Large derived"
        )
        let previousAssignments = [
            WorkoutRouteGroupAssignment(workoutID: runs[0].id, groupID: small.id, algorithmVersion: 1),
            WorkoutRouteGroupAssignment(workoutID: runs[1].id, groupID: large.id, algorithmVersion: 1),
            WorkoutRouteGroupAssignment(workoutID: runs[2].id, groupID: large.id, algorithmVersion: 1)
        ]

        let result = try service.recluster(
            workouts: runs,
            previousGroups: [small, large],
            previousAssignments: previousAssignments,
            policy: .default
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].name, "Large")
        XCTAssertEqual(result.groups[0].derivedName, "Large derived")
    }

    /// Equal contributions: the previous group whose members start earliest
    /// wins, again regardless of id order.
    func testMergeCollisionTieGoesToTheEarliestStart() throws {
        let runs = (0..<2).map { RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: $0) }
        func previous(_ id: UUID, _ name: String, reference: RunWorkout) -> WorkoutRouteGroup {
            WorkoutRouteGroup(
                id: id,
                name: name,
                representativeSummary: WorkoutRouteGroupSummary(
                    workoutID: reference.id,
                    startDate: nil,
                    facts: RouteGroupingRouteFacts(workout: reference)
                )
            )
        }
        let later = previous(uuid(1), "Later", reference: runs[1])
        let earlier = previous(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, "Earlier", reference: runs[0])

        let result = try service.recluster(
            workouts: runs,
            previousGroups: [later, earlier],
            previousAssignments: [
                WorkoutRouteGroupAssignment(workoutID: runs[0].id, groupID: earlier.id, algorithmVersion: 1),
                WorkoutRouteGroupAssignment(workoutID: runs[1].id, groupID: later.id, algorithmVersion: 1)
            ],
            policy: .default
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].name, "Earlier")
    }
}
