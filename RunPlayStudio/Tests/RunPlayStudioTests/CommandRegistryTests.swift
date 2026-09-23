import XCTest
import RunPlayCore
@testable import RunPlayStudio
import SwiftUI

final class CommandRegistryTests: XCTestCase {

    func testNoDuplicateGlobalShortcuts() {
        let duplicates = CommandRegistry.duplicateGlobalShortcuts()
        XCTAssertTrue(
            duplicates.isEmpty,
            "Duplicate global shortcuts: \(duplicates.map { "\($0.0.rawValue)/\($0.1.rawValue)=\($0.2)" })"
        )
    }

    func testEveryCommandIDHasDefinition() {
        for id in CommandID.allCases {
            let definition = CommandRegistry.definition(for: id)
            XCTAssertEqual(definition.id, id)
            XCTAssertFalse(definition.menuTitle.isEmpty)
            XCTAssertFalse(definition.purpose.isEmpty)
            XCTAssertFalse(definition.accessibilityDescription.isEmpty)
        }
    }

    func testPreservedNavigationShortcuts() {
        XCTAssertEqual(CommandRegistry.definition(for: .workoutOverview).keyEquivalent, "1")
        XCTAssertEqual(CommandRegistry.definition(for: .workoutCharts).keyEquivalent, "2")
        XCTAssertEqual(CommandRegistry.definition(for: .workoutSplits).keyEquivalent, "3")
        XCTAssertEqual(CommandRegistry.definition(for: .workoutSegments).keyEquivalent, "4")
        XCTAssertEqual(CommandRegistry.definition(for: .showAllRuns).keyEquivalent, "L")
        XCTAssertEqual(CommandRegistry.definition(for: .showPersonalHeatmap).keyEquivalent, "H")
        XCTAssertEqual(CommandRegistry.definition(for: .importFile).keyEquivalent, "I")
        XCTAssertEqual(CommandRegistry.definition(for: .importStravaArchive).keyEquivalent, "I")
        XCTAssertEqual(CommandRegistry.definition(for: .focusLibrarySearch).keyEquivalent, "F")
    }

    func testReplayShortcutMapping() {
        XCTAssertEqual(CommandRegistry.definition(for: .replayPlayPause).keyEquivalent, "Space")
        XCTAssertEqual(CommandRegistry.definition(for: .replaySeekBackward).keyEquivalent, "←")
        XCTAssertEqual(CommandRegistry.definition(for: .replaySeekForward).keyEquivalent, "→")
        XCTAssertEqual(CommandRegistry.definition(for: .replaySlower).keyEquivalent, "[")
        XCTAssertEqual(CommandRegistry.definition(for: .replayFaster).keyEquivalent, "]")
        XCTAssertEqual(CommandRegistry.definition(for: .replayRestart).keyEquivalent, "←")
    }

    func testHelpListingMatchesRegistry() {
        let helpCommands = CommandRegistry.all
        XCTAssertEqual(helpCommands.count, CommandID.allCases.count)
        XCTAssertTrue(helpCommands.contains { $0.id == .keyboardShortcutsHelp })
    }

    func testWorkspaceRestrictions() {
        XCTAssertEqual(CommandRegistry.definition(for: .replayPlayPause).workspace, .workout)
        XCTAssertEqual(CommandRegistry.definition(for: .focusLibrarySearch).workspace, .library)
        XCTAssertEqual(CommandRegistry.definition(for: .importFile).workspace, .any)
        XCTAssertEqual(CommandRegistry.definition(for: .mapFit).workspace, .any)
    }

    func testMapPresentationUsesNativeViewMenuWithoutSystemDockShortcut() {
        let command = CommandRegistry.definition(for: .mapTogglePresentation)
        XCTAssertEqual(command.menu, "View")
        XCTAssertTrue(command.keyEquivalent.isEmpty)
        XCTAssertEqual(command.displayShortcut, "Menu")
    }

    func testLocalOnlyOpenSelectionIsNotMenuCommand() {
        XCTAssertTrue(CommandRegistry.definition(for: .openSelectedWorkout).localOnly)
        XCTAssertFalse(CommandRegistry.menuCommands.contains { $0.id == .openSelectedWorkout })
    }

    func testEveryRouteColorModeHasADistinctViewMenuCommand() {
        let commands = WorkoutRouteColorMode.allCases.map(CommandRegistry.routeColorCommand(for:))
        XCTAssertEqual(Set(commands).count, WorkoutRouteColorMode.allCases.count)
        for (index, id) in commands.enumerated() {
            let command = CommandRegistry.definition(for: id)
            XCTAssertEqual(command.menu, "View")
            XCTAssertEqual(command.workspace, .workout)
            XCTAssertEqual(command.keyEquivalent, "\(index)")
            XCTAssertEqual(command.modifiers, [.command, .option])
            XCTAssertEqual(command.displayShortcut, "⌥⌘\(index)")
        }
        XCTAssertEqual(
            CommandRegistry.definition(for: CommandRegistry.routeColorCommand(for: .solid)).menuTitle,
            WorkoutRouteColorMode.solid.displayName
        )
    }

    func testExportCommandsLiveInTheFileMenu() {
        let exports: [CommandID] = [
            .exportSummaryJSON, .exportDistanceSplitsCSV, .exportRecordedLapsCSV,
            .exportSegmentsCSV, .exportSummaryCardPNG, .exportRouteReplayMP4, .exportAllCSV
        ]
        for id in exports {
            let command = CommandRegistry.definition(for: id)
            XCTAssertEqual(command.menu, "File", id.rawValue)
            XCTAssertEqual(command.workspace, .workout, id.rawValue)
            XCTAssertTrue(command.menuTitle.hasSuffix("…"), id.rawValue)
        }
        XCTAssertEqual(CommandRegistry.definition(for: .exportSummaryCardPNG).displayShortcut, "⌘E")
        XCTAssertEqual(CommandRegistry.definition(for: .exportRouteReplayMP4).displayShortcut, "⇧⌘E")
        XCTAssertEqual(CommandRegistry.definition(for: .exportSummaryJSON).displayShortcut, "Menu")
    }

    func testMenuKeyboardShortcutOnlyForSingleLetterOrDigitKeys() {
        let png = CommandRegistry.definition(for: .exportSummaryCardPNG).menuKeyboardShortcut
        XCTAssertEqual(png?.key, KeyEquivalent("e"))
        XCTAssertEqual(png?.modifiers, .command)

        let pace = CommandRegistry.definition(for: .routeColorPace).menuKeyboardShortcut
        XCTAssertEqual(pace?.key, KeyEquivalent("1"))
        XCTAssertEqual(pace?.modifiers, [.command, .option])

        XCTAssertNil(CommandRegistry.definition(for: .exportSummaryJSON).menuKeyboardShortcut)
        XCTAssertNil(CommandRegistry.definition(for: .replayPlayPause).menuKeyboardShortcut)
        XCTAssertNil(CommandRegistry.definition(for: .replayRestart).menuKeyboardShortcut)
    }
}
