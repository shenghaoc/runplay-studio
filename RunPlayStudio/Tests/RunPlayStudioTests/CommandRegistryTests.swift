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

    /// Help → Keyboard Shortcuts groups commands by `menu`, so the registry's
    /// menus must be the menu bar's: the standard menus the commands join, and
    /// the menus `CommandMenu` declares. A `CommandMenu` named after a standard
    /// menu adds a second menu of that name instead of joining it.
    func testRegistryMenusMatchTheMenuBar() throws {
        let declared = try Self.declaredCommandMenus()
        XCTAssertTrue(
            declared.isDisjoint(with: Self.standardMenus),
            "CommandMenu duplicates a standard menu: \(declared.intersection(Self.standardMenus).sorted())"
        )
        let registryMenus = Set(CommandRegistry.all.map(\.menu))
        XCTAssertEqual(registryMenus.subtracting(Self.standardMenus).sorted(), declared.sorted())
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

    /// The menus AppKit and SwiftUI already put in RunPlay Studio's menu bar.
    private static let standardMenus: Set<String> = ["File", "Edit", "View", "Window", "Help"]

    /// Titles of the `CommandMenu`s declared in Studio's sources. An XCTest
    /// process runs no `App`, so SwiftUI never builds a menu bar to inspect.
    private static func declaredCommandMenus(filePath: StaticString = #filePath) throws -> Set<String> {
        let sources = URL(filePath: "\(filePath)")
            .deletingLastPathComponent() // CommandRegistryTests.swift
            .deletingLastPathComponent() // RunPlayStudioTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        // Line-anchored, so a comment that mentions a declaration is not one.
        let declaration = /^\s*CommandMenu\(\s*"([^"]+)"/.anchorsMatchLineEndings()
        var titles: Set<String> = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in source.matches(of: declaration) {
                titles.insert(String(match.1))
            }
        }
        return titles
    }
}
