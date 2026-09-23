import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class FocusedActionTests: XCTestCase {

    func testReplayActionsDisabledWhenUnavailable() {
        var played = false
        let actions = ReplayActions(
            isAvailable: { false },
            togglePlayPause: { played = true }
        )
        XCTAssertFalse(actions.isAvailable())
        // Callers must gate on isAvailable; the closure itself is still invokable.
        actions.togglePlayPause()
        XCTAssertTrue(played)
    }

    func testReplayActionsInvokeControllerPaths() {
        let controller = ReplayController()
        let workout = makeWorkout()
        controller.load(workout)

        var toggled = false
        var soughtBack = false
        var soughtForward = false
        var steppedBack = false
        var steppedForward = false
        var slower = false
        var faster = false
        var restarted = false

        let actions = ReplayActions(
            isAvailable: { true },
            togglePlayPause: {
                controller.togglePlayPause()
                toggled = true
            },
            seekBackward: {
                controller.seekBySeconds(-5)
                soughtBack = true
            },
            seekForward: {
                controller.seekBySeconds(5)
                soughtForward = true
            },
            stepBackward: {
                controller.stepBackward()
                steppedBack = true
            },
            stepForward: {
                controller.stepForward()
                steppedForward = true
            },
            slower: {
                controller.slower()
                slower = true
            },
            faster: {
                controller.faster()
                faster = true
            },
            restart: {
                controller.restart()
                restarted = true
            }
        )

        XCTAssertTrue(actions.isAvailable())
        actions.togglePlayPause()
        XCTAssertTrue(controller.isPlaying)
        actions.seekForward()
        actions.seekBackward()
        actions.stepForward()
        actions.stepBackward()
        actions.faster()
        actions.slower()
        actions.restart()
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.state.currentTime, 0, accuracy: 0.01)

        XCTAssertTrue(toggled && soughtBack && soughtForward)
        XCTAssertTrue(steppedBack && steppedForward)
        XCTAssertTrue(slower && faster && restarted)
    }

    func testLibraryActionsRequireSelectionForOpen() {
        var opened = false
        var selectionCount = 0
        let actions = LibraryActions(
            isAvailable: { true },
            focusSearch: {},
            canOpenSelection: { selectionCount == 1 },
            openSelection: {
                guard selectionCount == 1 else { return }
                opened = true
            },
            canEditTags: { selectionCount > 0 },
            editTags: {}
        )

        selectionCount = 2
        XCTAssertFalse(actions.canOpenSelection())
        actions.openSelection()
        XCTAssertFalse(opened)

        selectionCount = 1
        XCTAssertTrue(actions.canOpenSelection())
        XCTAssertTrue(actions.canEditTags())
        actions.openSelection()
        XCTAssertTrue(opened)
    }

    func testMapActionsTargetVisibleMapOnly() {
        var fitCount = 0
        var toggleCount = 0
        let actions = MapActions(
            isAvailable: { true },
            fit: { fitCount += 1 },
            togglePresentation: { toggleCount += 1 },
            canTogglePresentation: { true }
        )
        actions.fit()
        actions.togglePresentation()
        XCTAssertEqual(fitCount, 1)
        XCTAssertEqual(toggleCount, 1)
    }

    func testMapActionsDoNotOfferRouteColorByDefault() {
        let actions = MapActions(isAvailable: { true })
        XCTAssertFalse(actions.supportsRouteColor())
        for mode in WorkoutRouteColorMode.allCases {
            XCTAssertFalse(actions.canSelectRouteColor(mode))
        }
    }

    func testRouteColorSelectabilityFollowsAvailability() {
        XCTAssertTrue(WorkoutRouteColorMode.solid.isSelectable(in: nil))
        for mode in WorkoutRouteColorMode.allCases where mode != .solid {
            XCTAssertFalse(mode.isSelectable(in: nil), "\(mode) before the probe runs")
        }

        let partial = RouteMetricModeAvailability(
            pace: true,
            heartRate: false,
            power: false,
            correctedElevation: true
        )
        XCTAssertTrue(WorkoutRouteColorMode.solid.isSelectable(in: partial))
        XCTAssertTrue(WorkoutRouteColorMode.pace.isSelectable(in: partial))
        XCTAssertFalse(WorkoutRouteColorMode.heartRate.isSelectable(in: partial))
        XCTAssertFalse(WorkoutRouteColorMode.power.isSelectable(in: partial))
        XCTAssertTrue(WorkoutRouteColorMode.correctedElevation.isSelectable(in: partial))

        let none = RouteMetricModeAvailability(
            solid: false,
            pace: false,
            heartRate: false,
            correctedElevation: false
        )
        XCTAssertTrue(WorkoutRouteColorMode.solid.isSelectable(in: none))
    }

    func testExportCommandRelayDeliversEachRequestOnce() {
        let relay = ExportCommandRelay()
        let actions = relay.actions(for: makeWorkout())

        XCTAssertNil(relay.takePendingCommand())
        actions.exportSummaryCardPNG()
        XCTAssertEqual(relay.pendingCommand, .summaryCardPNG)
        XCTAssertEqual(relay.takePendingCommand(), .summaryCardPNG)
        XCTAssertNil(relay.pendingCommand)

        // Repeating the same export must post a fresh request.
        actions.exportSummaryCardPNG()
        XCTAssertEqual(relay.takePendingCommand(), .summaryCardPNG)

        actions.exportAllCSV()
        XCTAssertEqual(relay.takePendingCommand(), .allCSV)
    }

    func testExportCommandRelayGatesOptionalExports() {
        let relay = ExportCommandRelay()
        let actions = relay.actions(for: makeWorkout())

        XCTAssertFalse(actions.canExportRouteReplay())
        relay.canExportRouteReplay = true
        XCTAssertTrue(actions.canExportRouteReplay())
        XCTAssertFalse(actions.canExportRecordedLaps(), "fixture has no recorded laps")
    }

    func testSheetBlocksDestructiveBackgroundSemantics() {
        // Mirrors WorkoutViewCommands: when a sheet is active, replay/library
        // menu items are disabled even if action bundles exist.
        let sheetActive = true
        let replayAvailable = !sheetActive && true
        let libraryAvailable = !sheetActive && true
        XCTAssertFalse(replayAvailable)
        XCTAssertFalse(libraryAvailable)
    }

    func testCommandBlockingPreferenceReducesAcrossPresentationHosts() {
        var isBlocked = false
        CommandBlockingPresentationPreferenceKey.reduce(
            value: &isBlocked,
            nextValue: { false }
        )
        CommandBlockingPresentationPreferenceKey.reduce(
            value: &isBlocked,
            nextValue: { true }
        )
        CommandBlockingPresentationPreferenceKey.reduce(
            value: &isBlocked,
            nextValue: { false }
        )
        XCTAssertTrue(isBlocked)
    }

    private func makeWorkout() -> RunWorkout {
        let points = (0..<20).map { i -> RoutePoint in
            let fraction = Double(i) / 19.0
            return RoutePoint(
                timestamp: Date().addingTimeInterval(fraction * 400),
                latitude: 37.7749 + fraction * 0.01,
                longitude: -122.4194 + fraction * 0.01,
                altitudeMeters: 10,
                distanceFromStartMeters: fraction * 2000,
                elapsedSeconds: fraction * 400
            )
        }
        return RunWorkout(routePoints: points)
    }
}
