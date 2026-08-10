import SwiftUI

/// Help → Keyboard Shortcuts reference, driven by `CommandRegistry`.
struct KeyboardShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private var commands: [CommandDefinition] {
        CommandRegistry.all.sorted { lhs, rhs in
            if lhs.menu == rhs.menu {
                return lhs.menuTitle.localizedCaseInsensitiveCompare(rhs.menuTitle) == .orderedAscending
            }
            return lhs.menu.localizedCaseInsensitiveCompare(rhs.menu) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(AppDesign.Typography.heading2)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // Chained `.keyboardShortcut` modifiers do not stack: the
                // innermost one wins and any outer one is ignored. Escape still
                // closes this sheet through SwiftUI's built-in sheet dismissal,
                // so Return is the only shortcut this button needs to declare.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Table(commands) {
                TableColumn("Command") { command in
                    Text(command.menuTitle)
                }
                .width(min: 160, ideal: 200)

                TableColumn("Shortcut") { command in
                    Text(command.displayShortcut)
                        .font(AppDesign.Typography.monoCaption.monospacedDigit())
                }
                .width(min: 120, ideal: 160)

                TableColumn("Workspace") { command in
                    Text(command.workspace.displayName)
                }
                .width(min: 100, ideal: 120)

                TableColumn("Purpose") { command in
                    Text(command.purpose)
                        .foregroundStyle(.secondary)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .accessibilityLabel("Keyboard shortcuts")
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
