import SwiftUI

private struct WorkoutTabSelectionKey: FocusedValueKey {
    typealias Value = Binding<WorkoutDetailView.ViewTab>
}

extension FocusedValues {
    var workoutTabSelection: Binding<WorkoutDetailView.ViewTab>? {
        get { self[WorkoutTabSelectionKey.self] }
        set { self[WorkoutTabSelectionKey.self] = newValue }
    }
}

/// Window-wide workout navigation exposed through the native menu bar.
struct WorkoutViewCommands: Commands {
    @FocusedBinding(\.workoutTabSelection) private var selectedTab

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
        }
    }
}
