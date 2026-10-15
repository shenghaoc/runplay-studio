import Foundation
import RunPlayCore
import SwiftUI

/// Workspace context required for a command to be meaningful.
enum CommandWorkspace: String, CaseIterable, Sendable, Equatable {
    case any
    case workout
    case library
    case heatmap
    case comparison
    case sheet

    var displayName: String {
        switch self {
        case .any: return studioLocalized("Any")
        case .workout: return studioLocalized("Workout")
        case .library: return studioLocalized("All Runs")
        case .heatmap: return studioLocalized("Personal Heatmap")
        case .comparison: return studioLocalized("Comparison")
        case .sheet: return studioLocalized("Sheet")
        }
    }
}

/// Stable identifier for a discoverable application command.
enum CommandID: String, CaseIterable, Sendable, Equatable {
    case importFile
    case importStravaArchive
    case watchFoldersSettings
    case exportSummaryJSON
    case exportDistanceSplitsCSV
    case exportRecordedLapsCSV
    case exportSegmentsCSV
    case exportSummaryCardPNG
    case exportRouteReplayMP4
    case exportAllCSV
    case workoutOverview
    case workoutCharts
    case workoutSplits
    case workoutSegments
    case correctElevation
    case useRecordedElevation
    case showAllRuns
    case showPersonalHeatmap
    case showTrends
    case showPersonalRecords
    case showRouteGroups
    case focusLibrarySearch
    case openSelectedWorkout
    case editSelectedTags
    case replayPlayPause
    case replaySeekBackward
    case replaySeekForward
    case replaySlower
    case replayFaster
    case replayRestart
    case mapFit
    case mapTogglePresentation
    case routeColorSolid
    case routeColorPace
    case routeColorHeartRate
    case routeColorPower
    case routeColorElevation
    case keyboardShortcutsHelp
}

/// Authoritative definition of one menu/keyboard command.
struct CommandDefinition: Equatable, Sendable, Identifiable {
    let id: CommandID
    let menuTitle: String
    let menu: String
    let keyEquivalent: String
    let modifiers: EventModifiers
    let workspace: CommandWorkspace
    let purpose: String
    let accessibilityDescription: String
    /// When true, the shortcut is only applied while a specific focused control
    /// owns focus (documented in purpose); it is not a global menu shortcut.
    let localOnly: Bool

    var displayShortcut: String {
        if keyEquivalent.isEmpty {
            return studioLocalized("Menu")
        }
        // `keyEquivalent` stays the stable key name; only its display is localized.
        let key = keyEquivalent == "Space" ? studioLocalized("Space") : keyEquivalent
        let shortcut = "\(modifierSymbols)\(key)"
        if localOnly {
            return studioLocalized("\(shortcut) (when focused)")
        }
        return shortcut
    }

    /// Menu-bar shortcut for a single ASCII letter or digit key equivalent.
    ///
    /// Nil for menu-only commands and for named keys (Space, arrows), whose
    /// call sites spell out the SwiftUI key directly.
    var menuKeyboardShortcut: KeyboardShortcut? {
        guard keyEquivalent.count == 1,
              let character = keyEquivalent.lowercased().first,
              character.isASCII,
              character.isLetter || character.isNumber else {
            return nil
        }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }

    private var modifierSymbols: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

/// Single authoritative inventory of RunPlay Studio commands and shortcuts.
///
/// Views and Help → Keyboard Shortcuts must derive from this registry rather
/// than hardcoding a second matrix that can drift.
enum CommandRegistry {
    /// All discoverable commands, including local-only control actions.
    static let all: [CommandDefinition] = [
        CommandDefinition(
            id: .importFile,
            menuTitle: studioLocalized("Import File…"),
            menu: "File",
            keyEquivalent: "I",
            modifiers: .command,
            workspace: .any,
            purpose: studioLocalized("Import a GPX, TCX, FIT, or JSON workout file"),
            accessibilityDescription: studioLocalized("Import a single workout file"),
            localOnly: false
        ),
        CommandDefinition(
            id: .importStravaArchive,
            menuTitle: studioLocalized("Import Strava Archive…"),
            menu: "File",
            keyEquivalent: "I",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: studioLocalized("Import running activities from a local Strava bulk-export ZIP"),
            accessibilityDescription: studioLocalized("Import a Strava archive"),
            localOnly: false
        ),
        CommandDefinition(
            id: .watchFoldersSettings,
            menuTitle: studioLocalized("Watch Folders…"),
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .any,
            purpose: studioLocalized("Manage folders that import new workout files automatically"),
            accessibilityDescription: studioLocalized("Open watch folder settings"),
            localOnly: false
        ),
        CommandDefinition(
            id: .exportSummaryJSON,
            menuTitle: studioLocalized("Summary (JSON)…"),
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Export the workout summary as JSON"),
            accessibilityDescription: studioLocalized("Export workout summary as JSON"),
            localOnly: false
        ),
        CommandDefinition(
            id: .exportDistanceSplitsCSV,
            menuTitle: studioLocalized("Distance Splits (CSV)…"),
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Export calculated kilometer splits as CSV"),
            accessibilityDescription: studioLocalized("Export distance splits as CSV"),
            localOnly: false
        ),
        CommandDefinition(
            id: .exportRecordedLapsCSV,
            menuTitle: studioLocalized("Recorded Laps (CSV)…"),
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Export source-recorded laps as CSV. Disabled when the workout has no recorded laps."),
            accessibilityDescription: studioLocalized("Export recorded laps as CSV"),
            localOnly: false
        ),
        CommandDefinition(
            id: .exportSegmentsCSV,
            menuTitle: studioLocalized("Segments (CSV)…"),
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Export detected segments as CSV"),
            accessibilityDescription: studioLocalized("Export detected segments as CSV"),
            localOnly: false
        ),
        CommandDefinition(
            id: .exportSummaryCardPNG,
            menuTitle: studioLocalized("Summary Card (PNG)…"),
            menu: "File",
            keyEquivalent: "E",
            modifiers: .command,
            workspace: .workout,
            purpose: studioLocalized("Open options for exporting the workout summary card as a PNG image"),
            accessibilityDescription: studioLocalized("Export summary card as PNG image"),
            localOnly: false
        ),
        CommandDefinition(
            id: .exportRouteReplayMP4,
            menuTitle: studioLocalized("Route Replay (MP4)…"),
            menu: "File",
            keyEquivalent: "E",
            modifiers: [.command, .shift],
            workspace: .workout,
            purpose: studioLocalized("Open options for exporting the route replay as an MP4 video. Disabled when the workout cannot be exported as video."),
            accessibilityDescription: studioLocalized("Export route replay as MP4 video"),
            localOnly: false
        ),
        CommandDefinition(
            id: .exportAllCSV,
            menuTitle: studioLocalized("All (CSV)…"),
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Export distance splits, recorded laps, and segments as one combined CSV"),
            accessibilityDescription: studioLocalized("Export combined CSV"),
            localOnly: false
        ),
        CommandDefinition(
            id: .workoutOverview,
            menuTitle: studioLocalized("Overview"),
            menu: "Workout",
            keyEquivalent: "1",
            modifiers: .command,
            workspace: .workout,
            purpose: studioLocalized("Show the workout overview and map"),
            accessibilityDescription: studioLocalized("Switch to Overview tab"),
            localOnly: false
        ),
        CommandDefinition(
            id: .workoutCharts,
            menuTitle: studioLocalized("Charts"),
            menu: "Workout",
            keyEquivalent: "2",
            modifiers: .command,
            workspace: .workout,
            purpose: studioLocalized("Show metric charts"),
            accessibilityDescription: studioLocalized("Switch to Charts tab"),
            localOnly: false
        ),
        CommandDefinition(
            id: .workoutSplits,
            menuTitle: studioLocalized("Splits"),
            menu: "Workout",
            keyEquivalent: "3",
            modifiers: .command,
            workspace: .workout,
            purpose: studioLocalized("Show distance splits and recorded laps"),
            accessibilityDescription: studioLocalized("Switch to Splits tab"),
            localOnly: false
        ),
        CommandDefinition(
            id: .workoutSegments,
            menuTitle: studioLocalized("Segments"),
            menu: "Workout",
            keyEquivalent: "4",
            modifiers: .command,
            workspace: .workout,
            purpose: studioLocalized("Show detected segment highlights"),
            accessibilityDescription: studioLocalized("Switch to Segments tab"),
            localOnly: false
        ),
        CommandDefinition(
            id: .correctElevation,
            menuTitle: studioLocalized("Correct Elevation"),
            menu: "Workout",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Correct this run's elevation from the DEM tile folder again, for example after adding tiles"),
            accessibilityDescription: studioLocalized("Correct this run's elevation from DEM tiles"),
            localOnly: false
        ),
        CommandDefinition(
            id: .useRecordedElevation,
            menuTitle: studioLocalized("Use Recorded Elevation"),
            menu: "Workout",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Keep this run's recorded altitude instead of DEM elevation"),
            accessibilityDescription: studioLocalized("Use recorded elevation for this run"),
            localOnly: false
        ),
        CommandDefinition(
            id: .showAllRuns,
            menuTitle: studioLocalized("All Runs"),
            menu: "Library",
            keyEquivalent: "L",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: studioLocalized("Browse and search the full local workout library"),
            accessibilityDescription: studioLocalized("Open All Runs"),
            localOnly: false
        ),
        CommandDefinition(
            id: .showPersonalHeatmap,
            menuTitle: studioLocalized("Personal Heatmap"),
            menu: "Library",
            keyEquivalent: "H",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: studioLocalized("Show personal route heatmap across the local library"),
            accessibilityDescription: studioLocalized("Open Personal Heatmap"),
            localOnly: false
        ),
        CommandDefinition(
            id: .showTrends,
            menuTitle: studioLocalized("Trends"),
            menu: "Library",
            keyEquivalent: "R",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: studioLocalized("Analyse the whole workout library over time by week, month, or year"),
            accessibilityDescription: studioLocalized("Open Trends"),
            localOnly: false
        ),
        CommandDefinition(
            id: .showPersonalRecords,
            menuTitle: studioLocalized("Records"),
            menu: "Library",
            keyEquivalent: "P",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: studioLocalized("Show personal records across the local workout library"),
            accessibilityDescription: studioLocalized("Open Records"),
            localOnly: false
        ),
        CommandDefinition(
            id: .showRouteGroups,
            menuTitle: studioLocalized("Routes"),
            menu: "Library",
            keyEquivalent: "G",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: studioLocalized("Group runs that follow the same route and show pace progression on each"),
            accessibilityDescription: studioLocalized("Open Routes"),
            localOnly: false
        ),
        CommandDefinition(
            id: .focusLibrarySearch,
            menuTitle: studioLocalized("Find in All Runs"),
            menu: "Library",
            keyEquivalent: "F",
            modifiers: .command,
            workspace: .library,
            purpose: studioLocalized("Focus the All Runs search field"),
            accessibilityDescription: studioLocalized("Focus library search"),
            localOnly: false
        ),
        CommandDefinition(
            id: .openSelectedWorkout,
            menuTitle: studioLocalized("Open Selected Run"),
            menu: "Library",
            keyEquivalent: "↩",
            modifiers: [],
            workspace: .library,
            purpose: studioLocalized("Open the single selected All Runs row"),
            accessibilityDescription: studioLocalized("Open selected workout"),
            localOnly: true
        ),
        CommandDefinition(
            id: .editSelectedTags,
            menuTitle: studioLocalized("Edit Tags…"),
            menu: "Library",
            keyEquivalent: "T",
            modifiers: [.command, .shift],
            workspace: .library,
            purpose: studioLocalized("Edit tags for the selected library workout(s)"),
            accessibilityDescription: studioLocalized("Edit tags for selection"),
            localOnly: false
        ),
        CommandDefinition(
            id: .replayPlayPause,
            menuTitle: studioLocalized("Play/Pause"),
            menu: "Replay",
            keyEquivalent: "Space",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Toggle route replay. Disabled while editing text."),
            accessibilityDescription: studioLocalized("Play or pause replay"),
            localOnly: false
        ),
        CommandDefinition(
            id: .replaySeekBackward,
            menuTitle: studioLocalized("Seek Backward 5 Seconds"),
            menu: "Replay",
            keyEquivalent: "←",
            modifiers: .option,
            workspace: .workout,
            purpose: studioLocalized("Seek replay backward by five elapsed seconds"),
            accessibilityDescription: studioLocalized("Seek replay backward five seconds"),
            localOnly: false
        ),
        CommandDefinition(
            id: .replaySeekForward,
            menuTitle: studioLocalized("Seek Forward 5 Seconds"),
            menu: "Replay",
            keyEquivalent: "→",
            modifiers: .option,
            workspace: .workout,
            purpose: studioLocalized("Seek replay forward by five elapsed seconds"),
            accessibilityDescription: studioLocalized("Seek replay forward five seconds"),
            localOnly: false
        ),
        CommandDefinition(
            id: .replaySlower,
            menuTitle: studioLocalized("Slower"),
            menu: "Replay",
            keyEquivalent: "[",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Choose the previous slower supported playback speed"),
            accessibilityDescription: studioLocalized("Slower replay speed"),
            localOnly: false
        ),
        CommandDefinition(
            id: .replayFaster,
            menuTitle: studioLocalized("Faster"),
            menu: "Replay",
            keyEquivalent: "]",
            modifiers: [],
            workspace: .workout,
            purpose: studioLocalized("Choose the next faster supported playback speed"),
            accessibilityDescription: studioLocalized("Faster replay speed"),
            localOnly: false
        ),
        CommandDefinition(
            id: .replayRestart,
            menuTitle: studioLocalized("Restart"),
            menu: "Replay",
            keyEquivalent: "←",
            modifiers: [.command, .shift],
            workspace: .workout,
            purpose: studioLocalized("Restart replay from the beginning and pause"),
            accessibilityDescription: studioLocalized("Restart replay from the beginning"),
            localOnly: false
        ),
        CommandDefinition(
            id: .mapFit,
            menuTitle: studioLocalized("Fit Map"),
            menu: "View",
            keyEquivalent: "0",
            modifiers: .command,
            workspace: .any,
            purpose: studioLocalized("Fit the visible route, comparison routes, or heatmap"),
            accessibilityDescription: studioLocalized("Fit the visible map content"),
            localOnly: false
        ),
        CommandDefinition(
            id: .mapTogglePresentation,
            menuTitle: studioLocalized("Toggle 2D/3D"),
            menu: "View",
            keyEquivalent: "",
            modifiers: [],
            workspace: .any,
            purpose: studioLocalized("Toggle the visible map between 2D and 3D presentation"),
            accessibilityDescription: studioLocalized("Toggle map 2D or 3D"),
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorSolid,
            menuTitle: studioLocalized("Solid"),
            menu: "View",
            keyEquivalent: "0",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: studioLocalized("Show the workout route in the primary color"),
            accessibilityDescription: studioLocalized("Route color solid"),
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorPace,
            menuTitle: studioLocalized("Pace"),
            menu: "View",
            keyEquivalent: "1",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: studioLocalized("Color the workout route by relative pace. Disabled when pace coloring is unavailable."),
            accessibilityDescription: studioLocalized("Route color by pace"),
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorHeartRate,
            menuTitle: studioLocalized("Heart Rate"),
            menu: "View",
            keyEquivalent: "2",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: studioLocalized("Color the workout route by relative heart rate. Disabled when heart-rate coloring is unavailable."),
            accessibilityDescription: studioLocalized("Route color by heart rate"),
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorPower,
            menuTitle: studioLocalized("Power"),
            menu: "View",
            keyEquivalent: "3",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: studioLocalized("Color the workout route by relative running power. Disabled when power coloring is unavailable."),
            accessibilityDescription: studioLocalized("Route color by power"),
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorElevation,
            menuTitle: studioLocalized("Elevation"),
            menu: "View",
            keyEquivalent: "4",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: studioLocalized("Color the workout route by corrected elevation. Disabled when elevation coloring is unavailable."),
            accessibilityDescription: studioLocalized("Route color by elevation"),
            localOnly: false
        ),
        CommandDefinition(
            id: .keyboardShortcutsHelp,
            menuTitle: studioLocalized("Keyboard Shortcuts"),
            menu: "Help",
            keyEquivalent: "/",
            modifiers: .command,
            workspace: .any,
            purpose: studioLocalized("Show the keyboard shortcuts reference"),
            accessibilityDescription: studioLocalized("Open keyboard shortcuts help"),
            localOnly: false
        )
    ]

    /// Menu-bar commands only (excludes local-only table/control actions).
    static var menuCommands: [CommandDefinition] {
        all.filter { !$0.localOnly }
    }

    static func definition(for id: CommandID) -> CommandDefinition {
        guard let match = all.first(where: { $0.id == id }) else {
            preconditionFailure("Missing command definition for \(id.rawValue)")
        }
        return match
    }

    /// Detects duplicate global key equivalents within the same modifier set.
    static func duplicateGlobalShortcuts() -> [(CommandID, CommandID, String)] {
        var seen: [String: CommandID] = [:]
        var duplicates: [(CommandID, CommandID, String)] = []
        for command in menuCommands where !command.keyEquivalent.isEmpty {
            let key = shortcutKey(command)
            if let existing = seen[key] {
                duplicates.append((existing, command.id, key))
            } else {
                seen[key] = command.id
            }
        }
        return duplicates
    }

    /// The View → Route Color command for one route color mode.
    static func routeColorCommand(for mode: WorkoutRouteColorMode) -> CommandID {
        switch mode {
        case .solid: return .routeColorSolid
        case .pace: return .routeColorPace
        case .heartRate: return .routeColorHeartRate
        case .power: return .routeColorPower
        case .correctedElevation: return .routeColorElevation
        }
    }

    /// Known intentional non-conflicts with standard macOS commands.
    ///
    /// - Command-N/O/S/W/Q remain system/document defaults (unused here).
    /// - Command-Comma remains system Settings (unused).
    /// - Command-Plus/Minus are not bound (MapKit zoom owns zoom steppers).
    /// - Bare Left/Right arrows are not global; they remain local to tables,
    ///   lists, sliders, and focused replay step controls.
    /// - Space play/pause is a menu command; the system suppresses it while
    ///   text fields and text editors own first responder.
    /// - Escape is not a global command; sheets use cancelAction and All Runs
    ///   clears search only when the search field owns focus and is nonempty.
    /// - Delete is not a global command; All Runs delete requires a single
    ///   eligible selected persisted workout in the table context.
    static let reservedSystemShortcuts: [String] = [
        "⌘N", "⌘O", "⌘S", "⌘W", "⌘Q", "⌘,", "⌘+", "⌘-", "Esc", "Delete"
    ]

    private static func shortcutKey(_ command: CommandDefinition) -> String {
        "\(command.modifiers.rawValue)|\(command.keyEquivalent.uppercased())"
    }
}
