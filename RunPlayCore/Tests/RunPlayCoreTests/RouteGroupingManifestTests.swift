import XCTest
@testable import RunPlayCore

/// Manifest schema v4 route-group persistence: migration, repair, and the
/// nil-marker semantics.
final class RouteGroupingManifestTests: XCTestCase {
    private func makeGroup(
        name: String? = nil,
        pin: UUID? = nil,
        summary: WorkoutRouteGroupSummary? = nil
    ) -> WorkoutRouteGroup {
        WorkoutRouteGroup(
            id: UUID(),
            name: name,
            pinnedRepresentativeWorkoutID: pin,
            representativeSummary: summary
        )
    }

    private func emptySummary(workoutID: UUID) -> WorkoutRouteGroupSummary {
        WorkoutRouteGroupSummary(
            workoutID: workoutID,
            startDate: nil,
            facts: RouteGroupingRouteFacts(
                minLatitude: 0, maxLatitude: 0,
                minLongitude: 0, maxLongitude: 0,
                startLatitude: 0, startLongitude: 0,
                finishLatitude: 0, finishLongitude: 0,
                totalDistanceMeters: 5_000,
                routePointCount: 250,
                discardedCoordinatePointCount: 0
            )
        )
    }

    // MARK: - Migration

    func testVersionThreeManifestDecodesWithEmptyRouteGroups() throws {
        let legacy = """
        {
          "version": 3,
          "workoutIDs": [],
          "tags": [],
          "tagAssignments": [],
          "smartCollections": []
        }
        """
        let decoded = try JSONDecoder().decode(WorkoutLibraryManifest.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.version, 3)
        XCTAssertTrue(decoded.routeGroups.isEmpty)
        XCTAssertTrue(decoded.routeGroupAssignments.isEmpty)

        var upgraded = decoded
        upgraded.upgradeSchemaVersionIfNeeded()
        XCTAssertEqual(upgraded.version, WorkoutLibraryManifest.currentVersion)
        XCTAssertEqual(WorkoutLibraryManifest.currentVersion, 4)
    }

    func testRouteGroupsRoundTripThroughJSON() throws {
        let workoutA = UUID()
        let workoutB = UUID()
        let group = makeGroup(
            name: "River Loop",
            pin: workoutB,
            summary: emptySummary(workoutID: workoutB)
        )
        let manifest = WorkoutLibraryManifest(
            workoutIDs: [workoutA, workoutB],
            routeGroups: [group],
            routeGroupAssignments: [
                WorkoutRouteGroupAssignment(workoutID: workoutA, groupID: group.id, algorithmVersion: 1),
                WorkoutRouteGroupAssignment(workoutID: workoutB, groupID: nil, algorithmVersion: 1)
            ]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(WorkoutLibraryManifest.self, from: data)

        XCTAssertEqual(decoded.routeGroups, [group])
        XCTAssertEqual(decoded.routeGroupAssignments.count, 2)
        XCTAssertEqual(decoded.routeGroupID(forWorkoutID: workoutA), group.id)
        XCTAssertNil(decoded.routeGroupID(forWorkoutID: workoutB))
        XCTAssertEqual(decoded.routeGroupMemberIDs(groupID: group.id), [workoutA])
    }

    // MARK: - Repair

    func testRepairDropsAssignmentsForMissingWorkoutsAndEmptyGroups() {
        let present = UUID()
        let deleted = UUID()
        let group = makeGroup(summary: emptySummary(workoutID: present))
        let emptiedGroup = makeGroup()
        var manifest = WorkoutLibraryManifest(
            workoutIDs: [present],
            routeGroups: [group, emptiedGroup],
            routeGroupAssignments: [
                WorkoutRouteGroupAssignment(workoutID: present, groupID: group.id, algorithmVersion: 1),
                WorkoutRouteGroupAssignment(workoutID: deleted, groupID: emptiedGroup.id, algorithmVersion: 1)
            ]
        )

        manifest.migrateToCurrentVersionIfNeeded()

        XCTAssertTrue(manifest.routeGroups.contains(group))
        XCTAssertFalse(manifest.routeGroups.contains(emptiedGroup), "a group with no surviving members is removed")
        XCTAssertEqual(manifest.routeGroupAssignments.count, 1)
        XCTAssertEqual(manifest.routeGroupAssignment(forWorkoutID: deleted), nil, "the nil marker: absence means pending")
    }

    func testRepairClearsPinAndSummaryThatLeftTheGroup() {
        let member = UUID()
        let leaver = UUID()
        let group = makeGroup(
            name: "Kept",
            pin: leaver,
            summary: emptySummary(workoutID: leaver)
        )
        var manifest = WorkoutLibraryManifest(
            workoutIDs: [member, leaver],
            routeGroups: [group],
            routeGroupAssignments: [
                WorkoutRouteGroupAssignment(workoutID: member, groupID: group.id, algorithmVersion: 1),
                WorkoutRouteGroupAssignment(workoutID: leaver, groupID: nil, algorithmVersion: 1)
            ]
        )

        manifest.migrateToCurrentVersionIfNeeded()

        let repaired = manifest.routeGroups.first { $0.id == group.id }
        XCTAssertNotNil(repaired)
        XCTAssertNil(repaired?.pinnedRepresentativeWorkoutID)
        XCTAssertNil(repaired?.representativeSummary)
        // The group still has a member, so it survives with a pending
        // representative refresh.
        XCTAssertEqual(manifest.routeGroupMemberIDs(groupID: group.id), [member])
    }

    // MARK: - Assignment record semantics

    func testSetRouteGroupAssignmentReplacesExistingRecord() {
        let workout = UUID()
        let groupA = UUID()
        let groupB = UUID()
        var manifest = WorkoutLibraryManifest(
            workoutIDs: [workout],
            routeGroupAssignments: [
                WorkoutRouteGroupAssignment(workoutID: workout, groupID: groupA, algorithmVersion: 1)
            ]
        )

        manifest.setRouteGroupAssignment(WorkoutRouteGroupAssignment(
            workoutID: workout,
            groupID: groupB,
            algorithmVersion: 2
        ))

        XCTAssertEqual(manifest.routeGroupAssignments.count, 1)
        XCTAssertEqual(manifest.routeGroupID(forWorkoutID: workout), groupB)
        // A nil-group record is meaningful and persists.
        manifest.setRouteGroupAssignment(WorkoutRouteGroupAssignment(
            workoutID: workout,
            groupID: nil,
            algorithmVersion: 2
        ))
        XCTAssertEqual(manifest.routeGroupAssignments.count, 1)
        XCTAssertNil(manifest.routeGroupID(forWorkoutID: workout))
    }
}
