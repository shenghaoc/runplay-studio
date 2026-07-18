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

/// Window-wide workout navigation exposed through the native menu bar.
struct WorkoutViewCommands: Commands {
    @FocusedBinding(\.workoutTabSelection) private var selectedTab
    @FocusedValue(\.appWorkspaceActions) private var workspaceActions

    var body: some Commands {
        CommandMenu("Workout") {
            Button("Overview") {
                selectedTab = .overview
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(selectedTab == nil)

            Button("Charts") {
                selectedTab = .charts
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(selectedTab == nil)

            Button("Splits") {
                selectedTab = .splits
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(selectedTab == nil)

            Button("Segments") {
                selectedTab = .segments
            }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(selectedTab == nil)

            Divider()

            Button("Personal Heatmap") {
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
            .help("Show personal route heatmap across the local library")
        }
    }
}
