import Foundation
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
    case workoutOverview
    case workoutCharts
    case workoutSplits
    case workoutSegments
    case showAllRuns
    case showPersonalHeatmap
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
