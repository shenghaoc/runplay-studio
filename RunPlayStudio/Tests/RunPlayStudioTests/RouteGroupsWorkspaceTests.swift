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
