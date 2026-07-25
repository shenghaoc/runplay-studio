import SwiftUI

extension Notification.Name {
    static let runPlayWorkspaceCommand = Notification.Name("runplay.workspace-command")
}

private struct WorkoutTabSelectionKey: FocusedValueKey {
    typealias Value = Binding<WorkoutDetailView.ViewTab>
}

extension FocusedValues {
    var workoutTabSelection: Binding<WorkoutDetailView.ViewTab>? {
        get { self[WorkoutTabSelectionKey.self] }
        set { self[WorkoutTabSelectionKey.self] = newValue }
    }
}

/// Actions for top-level workspace navigation from the menu bar.
struct AppWorkspaceActions {
    var showPersonalHeatmap: () -> Void
    var showAllRuns: () -> Void = {}
    var importFile: () -> Void = {}
    var importStravaArchive: () -> Void = {}
}

private struct AppWorkspaceActionsKey: FocusedValueKey {
    typealias Value = AppWorkspaceActions
}

extension FocusedValues {
    var appWorkspaceActions: AppWorkspaceActions? {
        get { self[AppWorkspaceActionsKey.self] }
        set { self[AppWorkspaceActionsKey.self] = newValue }
    }
}

/// Window-wide navigation and replay commands exposed through the native menu bar.
///
/// Shortcut definitions are owned by `CommandRegistry`. Handlers use focused
/// action bundles so availability follows the active workspace. A narrow
/// NotificationCenter fallback remains for workspace navigation when macOS
/// clears scene focus (for example after reopening the singleton window).
struct WorkoutViewCommands: Commands {
    @FocusedBinding(\.workoutTabSelection) private var selectedTab
    @FocusedValue(\.appWorkspaceActions) private var workspaceActions
    @FocusedValue(\.replayActions) private var replayActions
    @FocusedValue(\.libraryActions) private var libraryActions
    @FocusedValue(\.mapActions) private var mapActions
    @FocusedValue(\.appPresentationActions) private var presentationActions
    @FocusedValue(\.sheetPresentationActive) private var sheetActive

    private var isSheetBlocking: Bool { sheetActive == true }

    private var replayAvailable: Bool {
        !isSheetBlocking && (replayActions?.isAvailable() ?? false)
    }

    private var libraryAvailable: Bool {
        !isSheetBlocking && (libraryActions?.isAvailable() ?? false)
    }

    private var mapAvailable: Bool {
        !isSheetBlocking && (mapActions?.isAvailable() ?? false)
    }

    var body: some Commands {
        // `importExport` is absent from a non-document SwiftUI app's File menu,
        // so place these actions after the always-present New item instead.
        CommandGroup(after: .newItem) {
            Button(CommandRegistry.definition(for: .importFile).menuTitle) {
                workspaceActions?.importFile()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(isSheetBlocking)

            Button(CommandRegistry.definition(for: .importStravaArchive).menuTitle) {
                workspaceActions?.importStravaArchive()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help(CommandRegistry.definition(for: .importStravaArchive).purpose)
            .disabled(isSheetBlocking)
        }

        CommandMenu("Workout") {
            Button(CommandRegistry.definition(for: .workoutOverview).menuTitle) {
                selectedTab = .overview
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(selectedTab == nil || isSheetBlocking)

            Button(CommandRegistry.definition(for: .workoutCharts).menuTitle) {
                selectedTab = .charts
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(selectedTab == nil || isSheetBlocking)

            Button(CommandRegistry.definition(for: .workoutSplits).menuTitle) {
                selectedTab = .splits
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(selectedTab == nil || isSheetBlocking)

            Button(CommandRegistry.definition(for: .workoutSegments).menuTitle) {
                selectedTab = .segments
            }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(selectedTab == nil || isSheetBlocking)
        }

        CommandMenu("Replay") {
            Button(CommandRegistry.definition(for: .replayPlayPause).menuTitle) {
                replayActions?.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(CommandRegistry.definition(for: .replayPlayPause).purpose)
            .disabled(!replayAvailable)

            Button(CommandRegistry.definition(for: .replaySeekBackward).menuTitle) {
                replayActions?.seekBackward()
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            .disabled(!replayAvailable)

            Button(CommandRegistry.definition(for: .replaySeekForward).menuTitle) {
                replayActions?.seekForward()
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            .disabled(!replayAvailable)

            Button(CommandRegistry.definition(for: .replaySlower).menuTitle) {
                replayActions?.slower()
            }
            .keyboardShortcut("[", modifiers: [])
            .disabled(!replayAvailable)

            Button(CommandRegistry.definition(for: .replayFaster).menuTitle) {
                replayActions?.faster()
            }
            .keyboardShortcut("]", modifiers: [])
            .disabled(!replayAvailable)

            Divider()

            Button(CommandRegistry.definition(for: .replayRestart).menuTitle) {
                replayActions?.restart()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(!replayAvailable)
        }

        CommandMenu("Library") {
            Button(CommandRegistry.definition(for: .showAllRuns).menuTitle) {
                if let workspaceActions {
                    workspaceActions.showAllRuns()
                } else {
                    NotificationCenter.default.post(
                        name: .runPlayWorkspaceCommand,
                        object: AppWorkspaceCommand.showAllRuns
                    )
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help(CommandRegistry.definition(for: .showAllRuns).purpose)
            .disabled(isSheetBlocking)

            Button(CommandRegistry.definition(for: .showPersonalHeatmap).menuTitle) {
                if let workspaceActions {
                    workspaceActions.showPersonalHeatmap()
                } else {
                    NotificationCenter.default.post(
                        name: .runPlayWorkspaceCommand,
                        object: AppWorkspaceCommand.showPersonalHeatmap
                    )
                }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help(CommandRegistry.definition(for: .showPersonalHeatmap).purpose)
            .disabled(isSheetBlocking)

            Divider()

            Button(CommandRegistry.definition(for: .focusLibrarySearch).menuTitle) {
                libraryActions?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .help(CommandRegistry.definition(for: .focusLibrarySearch).purpose)
            .disabled(!libraryAvailable)

            Button(CommandRegistry.definition(for: .editSelectedTags).menuTitle) {
                libraryActions?.editTags()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .help(CommandRegistry.definition(for: .editSelectedTags).purpose)
            .disabled(
                !libraryAvailable
                    || !(libraryActions?.canEditTags() ?? false)
            )
        }

        CommandMenu("View") {
            Button(CommandRegistry.definition(for: .mapFit).menuTitle) {
                mapActions?.fit()
            }
            .keyboardShortcut("0", modifiers: .command)
            .help(CommandRegistry.definition(for: .mapFit).purpose)
            .disabled(!mapAvailable)

            Button(CommandRegistry.definition(for: .mapTogglePresentation).menuTitle) {
                mapActions?.togglePresentation()
            }
            .help(CommandRegistry.definition(for: .mapTogglePresentation).purpose)
            .disabled(!mapAvailable || !(mapActions?.canTogglePresentation() ?? false))
        }

        CommandGroup(after: .help) {
            Button(CommandRegistry.definition(for: .keyboardShortcutsHelp).menuTitle) {
                presentationActions?.showKeyboardShortcuts()
            }
            .keyboardShortcut("/", modifiers: .command)
            .help(CommandRegistry.definition(for: .keyboardShortcutsHelp).purpose)
        }
    }
}
