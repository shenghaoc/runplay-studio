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
        case .any: return "Any"
        case .workout: return "Workout"
        case .library: return "All Runs"
        case .heatmap: return "Personal Heatmap"
        case .comparison: return "Comparison"
        case .sheet: return "Sheet"
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
            return "Menu"
        }
        if localOnly {
            return "\(modifierSymbols)\(keyEquivalent) (when focused)"
        }
        return "\(modifierSymbols)\(keyEquivalent)"
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
            menuTitle: "Import File…",
            menu: "File",
            keyEquivalent: "I",
            modifiers: .command,
            workspace: .any,
            purpose: "Import a GPX, TCX, FIT, or JSON workout file",
            accessibilityDescription: "Import a single workout file",
            localOnly: false
        ),
        CommandDefinition(
            id: .importStravaArchive,
            menuTitle: "Import Strava Archive…",
            menu: "File",
            keyEquivalent: "I",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: "Import running activities from a local Strava bulk-export ZIP",
            accessibilityDescription: "Import a Strava archive",
            localOnly: false
        ),
        CommandDefinition(
            id: .watchFoldersSettings,
            menuTitle: "Watch Folders…",
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .any,
            purpose: "Manage folders that import new workout files automatically",
            accessibilityDescription: "Open watch folder settings",
            localOnly: false
        ),
        CommandDefinition(
            id: .exportSummaryJSON,
            menuTitle: "Summary (JSON)…",
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: "Export the workout summary as JSON",
            accessibilityDescription: "Export workout summary as JSON",
            localOnly: false
        ),
        CommandDefinition(
            id: .exportDistanceSplitsCSV,
            menuTitle: "Distance Splits (CSV)…",
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: "Export calculated kilometer splits as CSV",
            accessibilityDescription: "Export distance splits as CSV",
            localOnly: false
        ),
        CommandDefinition(
            id: .exportRecordedLapsCSV,
            menuTitle: "Recorded Laps (CSV)…",
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: "Export source-recorded laps as CSV. Disabled when the workout has no recorded laps.",
            accessibilityDescription: "Export recorded laps as CSV",
            localOnly: false
        ),
        CommandDefinition(
            id: .exportSegmentsCSV,
            menuTitle: "Segments (CSV)…",
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: "Export detected segments as CSV",
            accessibilityDescription: "Export detected segments as CSV",
            localOnly: false
        ),
        CommandDefinition(
            id: .exportSummaryCardPNG,
            menuTitle: "Summary Card (PNG)…",
            menu: "File",
            keyEquivalent: "E",
            modifiers: .command,
            workspace: .workout,
            purpose: "Open options for exporting the workout summary card as a PNG image",
            accessibilityDescription: "Export summary card as PNG image",
            localOnly: false
        ),
        CommandDefinition(
            id: .exportRouteReplayMP4,
            menuTitle: "Route Replay (MP4)…",
            menu: "File",
            keyEquivalent: "E",
            modifiers: [.command, .shift],
            workspace: .workout,
            purpose: "Open options for exporting the route replay as an MP4 video. Disabled when the workout cannot be exported as video.",
            accessibilityDescription: "Export route replay as MP4 video",
            localOnly: false
        ),
        CommandDefinition(
            id: .exportAllCSV,
            menuTitle: "All (CSV)…",
            menu: "File",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: "Export distance splits, recorded laps, and segments as one combined CSV",
            accessibilityDescription: "Export combined CSV",
            localOnly: false
        ),
        CommandDefinition(
            id: .workoutOverview,
            menuTitle: "Overview",
            menu: "Workout",
            keyEquivalent: "1",
            modifiers: .command,
            workspace: .workout,
            purpose: "Show the workout overview and map",
            accessibilityDescription: "Switch to Overview tab",
            localOnly: false
        ),
        CommandDefinition(
            id: .workoutCharts,
            menuTitle: "Charts",
            menu: "Workout",
            keyEquivalent: "2",
            modifiers: .command,
            workspace: .workout,
            purpose: "Show metric charts",
            accessibilityDescription: "Switch to Charts tab",
            localOnly: false
        ),
        CommandDefinition(
            id: .workoutSplits,
            menuTitle: "Splits",
            menu: "Workout",
            keyEquivalent: "3",
            modifiers: .command,
            workspace: .workout,
            purpose: "Show distance splits and recorded laps",
            accessibilityDescription: "Switch to Splits tab",
            localOnly: false
        ),
        CommandDefinition(
            id: .workoutSegments,
            menuTitle: "Segments",
            menu: "Workout",
            keyEquivalent: "4",
            modifiers: .command,
            workspace: .workout,
            purpose: "Show detected segment highlights",
            accessibilityDescription: "Switch to Segments tab",
            localOnly: false
        ),
        CommandDefinition(
            id: .correctElevation,
            menuTitle: "Correct Elevation",
            menu: "Workout",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: "Correct this run's elevation from the DEM tile folder again, for example after adding tiles",
            accessibilityDescription: "Correct this run's elevation from DEM tiles",
            localOnly: false
        ),
        CommandDefinition(
            id: .useRecordedElevation,
            menuTitle: "Use Recorded Elevation",
            menu: "Workout",
            keyEquivalent: "",
            modifiers: [],
            workspace: .workout,
            purpose: "Keep this run's recorded altitude instead of DEM elevation",
            accessibilityDescription: "Use recorded elevation for this run",
            localOnly: false
        ),
        CommandDefinition(
            id: .showAllRuns,
            menuTitle: "All Runs",
            menu: "Library",
            keyEquivalent: "L",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: "Browse and search the full local workout library",
            accessibilityDescription: "Open All Runs",
            localOnly: false
        ),
        CommandDefinition(
            id: .showPersonalHeatmap,
            menuTitle: "Personal Heatmap",
            menu: "Library",
            keyEquivalent: "H",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: "Show personal route heatmap across the local library",
            accessibilityDescription: "Open Personal Heatmap",
            localOnly: false
        ),
        CommandDefinition(
            id: .showTrends,
            menuTitle: "Trends",
            menu: "Library",
            keyEquivalent: "R",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: "Analyse the whole workout library over time by week, month, or year",
            accessibilityDescription: "Open Trends",
            localOnly: false
        ),
        CommandDefinition(
            id: .showPersonalRecords,
            menuTitle: "Records",
            menu: "Library",
            keyEquivalent: "P",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: "Show personal records across the local workout library",
            accessibilityDescription: "Open Records",
            localOnly: false
        ),
        CommandDefinition(
            id: .showRouteGroups,
            menuTitle: "Routes",
            menu: "Library",
            keyEquivalent: "G",
            modifiers: [.command, .shift],
            workspace: .any,
            purpose: "Group runs that follow the same route and show pace progression on each",
            accessibilityDescription: "Open Routes",
            localOnly: false
        ),
        CommandDefinition(
            id: .focusLibrarySearch,
            menuTitle: "Find in All Runs",
            menu: "Library",
            keyEquivalent: "F",
            modifiers: .command,
            workspace: .library,
            purpose: "Focus the All Runs search field",
            accessibilityDescription: "Focus library search",
            localOnly: false
        ),
        CommandDefinition(
            id: .openSelectedWorkout,
            menuTitle: "Open Selected Run",
            menu: "Library",
            keyEquivalent: "↩",
            modifiers: [],
            workspace: .library,
            purpose: "Open the single selected All Runs row",
            accessibilityDescription: "Open selected workout",
            localOnly: true
        ),
        CommandDefinition(
            id: .editSelectedTags,
            menuTitle: "Edit Tags…",
            menu: "Library",
            keyEquivalent: "T",
            modifiers: [.command, .shift],
            workspace: .library,
            purpose: "Edit tags for the selected library workout(s)",
            accessibilityDescription: "Edit tags for selection",
            localOnly: false
        ),
        CommandDefinition(
            id: .replayPlayPause,
            menuTitle: "Play/Pause",
            menu: "Replay",
            keyEquivalent: "Space",
            modifiers: [],
            workspace: .workout,
            purpose: "Toggle route replay. Disabled while editing text.",
            accessibilityDescription: "Play or pause replay",
            localOnly: false
        ),
        CommandDefinition(
            id: .replaySeekBackward,
            menuTitle: "Seek Backward 5 Seconds",
            menu: "Replay",
            keyEquivalent: "←",
            modifiers: .option,
            workspace: .workout,
            purpose: "Seek replay backward by five elapsed seconds",
            accessibilityDescription: "Seek replay backward five seconds",
            localOnly: false
        ),
        CommandDefinition(
            id: .replaySeekForward,
            menuTitle: "Seek Forward 5 Seconds",
            menu: "Replay",
            keyEquivalent: "→",
            modifiers: .option,
            workspace: .workout,
            purpose: "Seek replay forward by five elapsed seconds",
            accessibilityDescription: "Seek replay forward five seconds",
            localOnly: false
        ),
        CommandDefinition(
            id: .replaySlower,
            menuTitle: "Slower",
            menu: "Replay",
            keyEquivalent: "[",
            modifiers: [],
            workspace: .workout,
            purpose: "Choose the previous slower supported playback speed",
            accessibilityDescription: "Slower replay speed",
            localOnly: false
        ),
        CommandDefinition(
            id: .replayFaster,
            menuTitle: "Faster",
            menu: "Replay",
            keyEquivalent: "]",
            modifiers: [],
            workspace: .workout,
            purpose: "Choose the next faster supported playback speed",
            accessibilityDescription: "Faster replay speed",
            localOnly: false
        ),
        CommandDefinition(
            id: .replayRestart,
            menuTitle: "Restart",
            menu: "Replay",
            keyEquivalent: "←",
            modifiers: [.command, .shift],
            workspace: .workout,
            purpose: "Restart replay from the beginning and pause",
            accessibilityDescription: "Restart replay from the beginning",
            localOnly: false
        ),
        CommandDefinition(
            id: .mapFit,
            menuTitle: "Fit Map",
            menu: "View",
            keyEquivalent: "0",
            modifiers: .command,
            workspace: .any,
            purpose: "Fit the visible route, comparison routes, or heatmap",
            accessibilityDescription: "Fit the visible map content",
            localOnly: false
        ),
        CommandDefinition(
            id: .mapTogglePresentation,
            menuTitle: "Toggle 2D/3D",
            menu: "View",
            keyEquivalent: "",
            modifiers: [],
            workspace: .any,
            purpose: "Toggle the visible map between 2D and 3D presentation",
            accessibilityDescription: "Toggle map 2D or 3D",
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorSolid,
            menuTitle: "Solid",
            menu: "View",
            keyEquivalent: "0",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: "Show the workout route in the primary color",
            accessibilityDescription: "Route color solid",
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorPace,
            menuTitle: "Pace",
            menu: "View",
            keyEquivalent: "1",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: "Color the workout route by relative pace. Disabled when pace coloring is unavailable.",
            accessibilityDescription: "Route color by pace",
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorHeartRate,
            menuTitle: "Heart Rate",
            menu: "View",
            keyEquivalent: "2",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: "Color the workout route by relative heart rate. Disabled when heart-rate coloring is unavailable.",
            accessibilityDescription: "Route color by heart rate",
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorPower,
            menuTitle: "Power",
            menu: "View",
            keyEquivalent: "3",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: "Color the workout route by relative running power. Disabled when power coloring is unavailable.",
            accessibilityDescription: "Route color by power",
            localOnly: false
        ),
        CommandDefinition(
            id: .routeColorElevation,
            menuTitle: "Elevation",
            menu: "View",
            keyEquivalent: "4",
            modifiers: [.command, .option],
            workspace: .workout,
            purpose: "Color the workout route by corrected elevation. Disabled when elevation coloring is unavailable.",
            accessibilityDescription: "Route color by elevation",
            localOnly: false
        ),
        CommandDefinition(
            id: .keyboardShortcutsHelp,
            menuTitle: "Keyboard Shortcuts",
            menu: "Help",
            keyEquivalent: "/",
            modifiers: .command,
            workspace: .any,
            purpose: "Show the keyboard shortcuts reference",
            accessibilityDescription: "Open keyboard shortcuts help",
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
