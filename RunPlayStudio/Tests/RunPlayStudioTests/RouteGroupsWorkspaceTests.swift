import XCTest
@testable import RunPlayCore
@testable import RunPlayStudio

/// Routes workspace navigation, session restoration (v5), and the Routes
/// view-model derivation.
@MainActor
final class RouteGroupsWorkspaceTests: XCTestCase {

    // MARK: - Navigation

    func testShowRouteGroupsSetsWorkspaceAndSidebarSelection() {
        let appState = AppState(storeActor: nil, importService: nil)
        appState.showRouteGroups()

        XCTAssertEqual(appState.workspaceMode, .routeGroups)
        XCTAssertEqual(appState.sidebarSelection, .routeGroups)
        appState.applySidebarSelection(.routeGroups)
        XCTAssertEqual(appState.workspaceMode, .routeGroups)
    }

    func testSelectingWorkoutLeavesRoutesWorkspace() {
        let appState = AppState(storeActor: nil, importService: nil)
        let workout = RunWorkout(routePoints: [])
        appState.workouts = [workout]
        appState.showRouteGroups()
        appState.selectWorkout(workout)

        XCTAssertEqual(appState.workspaceMode, .workout)
    }

    func testWorkspaceCommandOpensRoutes() {
        let appState = AppState(storeActor: nil, importService: nil)
        appState.handleWorkspaceCommand(.showRouteGroups)
        XCTAssertEqual(appState.workspaceMode, .routeGroups)
    }

    // MARK: - Session (v5)

    func testSessionDestinationRouteGroupsRoundTrips() throws {
        let snapshot = AppSessionSnapshot(destination: .routeGroups)
        XCTAssertEqual(snapshot.version, AppSessionSnapshot.currentVersion)
        XCTAssertEqual(AppSessionSnapshot.currentVersion, 5)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.destination, .routeGroups)
    }

    func testApplySessionSnapshotRestoresRoutesWorkspace() {
        let appState = AppState(storeActor: nil, importService: nil)
        appState.applySessionSnapshot(AppSessionSnapshot(destination: .routeGroups))
        XCTAssertEqual(appState.workspaceMode, .routeGroups)
    }

    func testMakeSessionSnapshotCapturesRoutesDestination() {
        let appState = AppState(storeActor: nil, importService: nil)
        appState.showRouteGroups()
        let snapshot = appState.makeSessionSnapshot()
        XCTAssertEqual(snapshot.destination, .routeGroups)
    }

    // MARK: - View-model derivation

    private func groupedOrganization(for runs: [RunWorkout]) -> WorkoutLibraryOrganizationSnapshot {
        let group = WorkoutRouteGroup(
            id: UUID(),
            name: "Park Loop",
            representativeSummary: WorkoutRouteGroupSummary(
                workoutID: runs[0].id,
                startDate: runs[0].metadata.startDate,
                facts: RouteGroupingRouteFacts(workout: runs[0])
            )
        )
        let assignments = runs.map {
            WorkoutRouteGroupAssignment(workoutID: $0.id, groupID: group.id, algorithmVersion: 1)
        }
        return WorkoutLibraryOrganizationSnapshot(
            routeGroups: [group],
            routeGroupAssignments: assignments
        )
    }

    func testViewModelDerivesRowsStatsAndProgression() {
        let runs = (0..<3).map { RouteGroupsWorkspaceFixtures.loopRepeat(sideMeters: 1_250, index: $0) }
        let viewModel = RouteGroupsViewModel()
        viewModel.refresh(workouts: runs, organization: groupedOrganization(for: runs))

        XCTAssertEqual(viewModel.rows.count, 1)
        let row = viewModel.rows[0]
        XCTAssertEqual(row.displayName, "Park Loop")
        XCTAssertEqual(row.runCount, 3)
        XCTAssertEqual(row.bestPaceSecondsPerKilometer, 300)
        XCTAssertEqual(row.medianPaceSecondsPerKilometer, 300)
        XCTAssertEqual(row.latestPaceSecondsPerKilometer, 300)
        XCTAssertEqual(viewModel.pendingAssignmentCount, 0)

        viewModel.selectedGroupID = viewModel.rows[0].id
        XCTAssertEqual(viewModel.memberRows.count, 3)
        XCTAssertEqual(viewModel.progressionPoints.count, 3)
        XCTAssertEqual(viewModel.representativeWorkoutID, runs[0].id)
        // Members sort newest first; chart points ascend by date.
        XCTAssertGreaterThanOrEqual(
            viewModel.memberRows[0].date!,
            viewModel.memberRows[2].date!
        )
        XCTAssertLessThanOrEqual(
            viewModel.progressionPoints[0].date,
            viewModel.progressionPoints[2].date
        )
        XCTAssertFalse(viewModel.memberRows[0].isReversed)
    }

    func testViewModelCountsPendingAssignments() {
        let runs = (0..<3).map { RouteGroupsWorkspaceFixtures.loopRepeat(sideMeters: 1_250, index: $0) }
        let viewModel = RouteGroupsViewModel()
        // No organization at all: every workout is pending (nil marker).
        viewModel.refresh(workouts: runs, organization: .empty)
        XCTAssertEqual(viewModel.pendingAssignmentCount, 3)
        XCTAssertEqual(viewModel.rows.count, 0)
    }

    func testMemberReversalMarkerUsesCoarseDirectionProbe() {
        let forward = RouteGroupsWorkspaceFixtures.loopRepeat(sideMeters: 1_250, index: 0)
        let reversedPoints = RouteGroupsWorkspaceFixtures.reversed(
            forward.routePoints,
            date: RouteGroupsWorkspaceFixtures.epoch.addingTimeInterval(86_400)
        )
        let reversed = RouteGroupsWorkspaceFixtures.workout(points: reversedPoints, date: reversedPoints[0].timestamp)

        // A closed loop's start and finish coincide, so endpoint proximity
        // cannot detect direction — the coarse ordered-sequence probe must.
        XCTAssertTrue(RouteGroupingMatcher.memberRunsOppositeDirection(member: reversed, representative: forward))
        XCTAssertFalse(RouteGroupingMatcher.memberRunsOppositeDirection(member: forward, representative: forward))
    }

    func testRepresentativeLoopClosureDrivesDefaultName() {
        let loop = RouteGroupsWorkspaceFixtures.loopRepeat(sideMeters: 1_250, index: 0)
        XCTAssertTrue(RouteGroupsViewModel.representativeClosesLoop(loop))
        let date = RouteGroupsWorkspaceFixtures.epoch
        let line = RouteGroupsWorkspaceFixtures.workout(
            points: RouteGroupsWorkspaceFixtures.straightLine(distanceMeters: 2_000, date: date),
            date: date
        )
        XCTAssertFalse(RouteGroupsViewModel.representativeClosesLoop(line))
    }

    // MARK: - Derived-name adoption (#134 part 1)

    /// Two unrelated groups whose geometry rounds to the same base name must
    /// not render identically in the routes list: the rows now read the
    /// set-level derived names, so colliding siblings disambiguate.
    func testCollidingGroupsGetDistinctDerivedRowNames() {
        let north = RouteGroupsWorkspaceFixtures.namingGroup(
            bearingDegrees: 3, totalDistanceMeters: 5_000
        )
        let east = RouteGroupsWorkspaceFixtures.namingGroup(
            bearingDegrees: 93, totalDistanceMeters: 5_000
        )
        let viewModel = RouteGroupsViewModel()
        viewModel.refresh(
            workouts: [],
            organization: RouteGroupsWorkspaceFixtures.organization(groups: [north, east])
        )

        XCTAssertEqual(viewModel.rows.count, 2)
        let names = Set(viewModel.rows.map(\.displayName))
        XCTAssertEqual(names.count, 2, "colliding groups must be tellable apart: \(names)")
        for name in names {
            XCTAssertTrue(name.hasPrefix("5.0 km Loop ("), "got \(name)")
        }
    }

    /// A group nobody else collides with keeps the plain derived name — the
    /// adoption must not add tokens to uncollided rows.
    func testUncollidedGroupKeepsBareDerivedRowName() {
        let alone = RouteGroupsWorkspaceFixtures.namingGroup(
            bearingDegrees: 3, totalDistanceMeters: 5_000
        )
        let other = RouteGroupsWorkspaceFixtures.namingGroup(
            bearingDegrees: 3, totalDistanceMeters: 10_000
        )
        let viewModel = RouteGroupsViewModel()
        viewModel.refresh(
            workouts: [],
            organization: RouteGroupsWorkspaceFixtures.organization(groups: [alone, other])
        )

        let row = viewModel.rows.first { $0.id == alone.id }
        XCTAssertEqual(
            row?.displayName,
            WorkoutRouteGroup.defaultDisplayName(distanceMeters: 5_000, closesLoop: true)
        )
    }

    /// A user-assigned name is verbatim and is never suffixed.
    func testUserNamedGroupIsVerbatimInRows() {
        let named = RouteGroupsWorkspaceFixtures.namingGroup(
            bearingDegrees: 3, totalDistanceMeters: 5_000, name: "My Loop"
        )
        let twin = RouteGroupsWorkspaceFixtures.namingGroup(
            bearingDegrees: 93, totalDistanceMeters: 5_000, name: "My Loop"
        )
        let viewModel = RouteGroupsViewModel()
        viewModel.refresh(
            workouts: [],
            organization: RouteGroupsWorkspaceFixtures.organization(groups: [named, twin])
        )

        XCTAssertEqual(Set(viewModel.rows.map(\.displayName)), ["My Loop"])
    }

    /// A group with no persisted representative summary falls back to the
    /// plain unnamed string rather than inventing geometry.
    func testSummarylessGroupFallsBackToUnnamed() {
        let empty = WorkoutRouteGroup(id: UUID(), name: nil, representativeSummary: nil)
        let viewModel = RouteGroupsViewModel()
        viewModel.refresh(
            workouts: [],
            organization: RouteGroupsWorkspaceFixtures.organization(groups: [empty])
        )

        XCTAssertEqual(viewModel.rows.first?.displayName, "Route")
    }

    /// All three surfaces read the same set-level derivation, so one group
    /// must carry one name everywhere. Deriving per row, or over the menus'
    /// `prefix(15)` window instead of the full set, breaks this.
    ///
    /// This test does **not** assert that the 21 names are pairwise distinct:
    /// a straddling fine sector can defeat Core's digest escalation, so that
    /// invariant currently fails and is tracked as issue #158 rather than
    /// being papered over here. What #149 owns is that every surface agrees.
    func testMenuNamesMatchRowNamesForTheSameGroupSet() {
        // Twenty-one colliding groups: more than the menus' 15-row cap, so a
        // window-scoped derivation would name the visible ones differently.
        let groups = (0..<21).map { index in
            RouteGroupsWorkspaceFixtures.namingGroup(
                bearingDegrees: Double(index) * 17,
                totalDistanceMeters: 5_000,
                date: RouteGroupsWorkspaceFixtures.epoch.addingTimeInterval(Double(index) * 86_400)
            )
        }
        let viewModel = RouteGroupsViewModel()
        viewModel.refresh(
            workouts: [],
            organization: RouteGroupsWorkspaceFixtures.organization(groups: groups)
        )

        let rowNames = Dictionary(
            uniqueKeysWithValues: viewModel.rows.map { ($0.id, $0.displayName) }
        )
        XCTAssertEqual(rowNames.count, groups.count, "every group must produce a row")

        let names = WorkoutRouteGroup.derivedDisplayNames(
            for: groups,
            loopClosureDistanceMeters: WorkoutRouteGroup.defaultLoopClosureDistanceMeters
        )
        for group in groups {
            let expected = rowNames[group.id]
            XCTAssertNotNil(expected)
            XCTAssertEqual(
                WorkoutLibraryView.routeFilterMenuName(for: group, derivedNames: names),
                expected,
                "library filter menu disagrees with the routes list"
            )
            XCTAssertEqual(
                PersonalHeatmapView.heatmapRouteMenuName(for: group, derivedNames: names),
                expected,
                "heatmap picker disagrees with the routes list"
            )
        }

        // Collision-awareness is genuinely engaged: the bare base name alone
        // would be shared by all 21, so most rows must carry a discriminator.
        let base = WorkoutRouteGroup.defaultDisplayName(distanceMeters: 5_000, closesLoop: true)
        let disambiguated = rowNames.values.filter { $0 != base }.count
        XCTAssertGreaterThan(
            disambiguated,
            15,
            "expected most of the 21 colliding groups to be disambiguated, got \(disambiguated)"
        )
    }

    /// A summaryless group also falls back to the plain string in the menus.
    func testMenuNamesFallBackToUnnamedForSummarylessGroup() {
        let empty = WorkoutRouteGroup(id: UUID(), name: nil, representativeSummary: nil)
        let names = WorkoutRouteGroup.derivedDisplayNames(
            for: [empty],
            loopClosureDistanceMeters: WorkoutRouteGroup.defaultLoopClosureDistanceMeters
        )

        XCTAssertEqual(
            WorkoutLibraryView.routeFilterMenuName(for: empty, derivedNames: names),
            "Route"
        )
        XCTAssertEqual(
            PersonalHeatmapView.heatmapRouteMenuName(for: empty, derivedNames: names),
            "Route"
        )
    }

    /// The loop-closure threshold has exactly one product copy: the Studio
    /// constant was removed in favour of Core's, so the helper that still
    /// reads it must agree with it.
    func testRepresentativeLoopClosureUsesTheCoreThreshold() {
        XCTAssertEqual(
            WorkoutRouteGroup.defaultLoopClosureDistanceMeters,
            100,
            "the product loop-closure threshold changed; update this expectation deliberately"
        )
    }

    // MARK: - Layout budget

    /// The Routes split panes plus the navigation sidebar have to fit inside
    /// the declared minimum window width. They previously summed to exactly
    /// the window minimum (300 + 420 = 720), leaving nothing for the sidebar,
    /// so at 720x500 the detail pane was squeezed below its own minimum and
    /// the Latest Pace column and the Rename button clipped off-window.
    func testRoutesSplitMinimumsFitTheMinimumWindowAlongsideTheSidebar() {
        let panes = AppDesign.WindowLayout.routeListMinWidth
            + AppDesign.WindowLayout.routeDetailMinWidth

        XCTAssertLessThanOrEqual(
            panes,
            AppDesign.WindowLayout.workspaceWidthBudget,
            """
            Routes split minimums (\(panes)pt) exceed the workspace budget \
            (\(AppDesign.WindowLayout.workspaceWidthBudget)pt = \
            \(AppDesign.WindowLayout.minimumContentWidth)pt window minus \
            \(AppDesign.WindowLayout.sidebarAllowance)pt sidebar).
            """
        )
    }

    /// The budget must not be met by shrinking a pane below usability.
    func testRoutesSplitMinimumsStayUsable() {
        XCTAssertGreaterThanOrEqual(AppDesign.WindowLayout.routeListMinWidth, 160)
        XCTAssertGreaterThanOrEqual(AppDesign.WindowLayout.routeDetailMinWidth, 280)
    }
}
