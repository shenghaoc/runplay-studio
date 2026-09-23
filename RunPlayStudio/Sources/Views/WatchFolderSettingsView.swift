import SwiftUI
import RunPlayCore
import AppKit

/// Watch-folder management (Settings pane): add/remove folders, pause,
/// import-existing-now, per-folder default tag, and the recent-imports list.
///
/// Everything is keyboard-navigable and VoiceOver-labelled; the folder table
/// rows expose their pause state and resolved meaning in the label so screen
/// readers get status without focus tricks.
struct WatchFolderSettingsView: View {
    @ObservedObject var coordinator: WatchFolderCoordinator

    @State private var selectedFolderID: UUID?
    @State private var newTagNameDraft: String = ""

    var body: some View {
        Form {
            foldersSection
            existingFilesSection
            recentImportsSection
            privacyFooter
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
    }

    // MARK: - Folders

    private var foldersSection: some View {
        Section {
            if coordinator.folders.isEmpty {
                Text("No watched folders yet. Add one to import new GPX, TCX, FIT, and JSON files automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.folders) { folder in
                    folderRow(folder)
                }
                .onDelete(perform: deleteSelectedFolders)
            }
        } header: {
            Text("Watched Folders")
        } footer: {
            Text("Folders persist as security-scoped bookmarks and keep working across launches.")
        }
    }

    private func folderRow(_ folder: WatchFolderConfiguration) -> some View {
        HStack {
            Image(systemName: statusIcon(for: folder))
                .foregroundStyle(statusColor(for: folder))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                    .fontWeight(.medium)
                Text(statusText(for: folder))
                    .font(.caption)
                    .foregroundStyle(isUnavailable(folder) ? Color.orange : Color.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenFolderStatus(for: folder))
            Spacer()
            TextField(
                "Default tag",
                text: Binding(
                    get: { folder.defaultTagName },
                    set: { coordinator.setDefaultTag($0, folderID: folder.id) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 130)
            .help("Tag applied to workouts imported from this folder. Leave empty for none.")
            .accessibilityLabel("Default tag for \(folder.displayName)")
            Button {
                coordinator.setPaused(!folder.isPaused, folderID: folder.id)
            } label: {
                Text(folder.isPaused ? "Resume" : "Pause")
            }
            .accessibilityLabel(folder.isPaused
                ? "Resume watching \(folder.displayName)"
                : "Pause watching \(folder.displayName)")
        }
        .padding(.vertical, 2)
    }

    private func deleteSelectedFolders(at offsets: IndexSet) {
        for index in offsets {
            let folder = coordinator.folders[index]
            coordinator.removeFolder(id: folder.id)
        }
        if let selected = selectedFolderID,
           !coordinator.folders.contains(where: { $0.id == selected }) {
            selectedFolderID = nil
        }
    }

    // MARK: - Folder status

    /// A folder that was watchable but whose directory is currently gone
    /// (volume ejected, folder deleted or moved). A paused folder never reads
    /// as unavailable: pausing stops access on purpose, so an unreadable
    /// directory there is expected rather than a fault.
    private func isUnavailable(_ folder: WatchFolderConfiguration) -> Bool {
        !folder.isPaused && coordinator.unavailableFolderIDs.contains(folder.id)
    }

    private func statusText(for folder: WatchFolderConfiguration) -> String {
        if folder.isPaused { return "Paused" }
        if isUnavailable(folder) { return "Unavailable — watching resumes if it returns" }
        return "Watching"
    }

    private func statusIcon(for folder: WatchFolderConfiguration) -> String {
        if folder.isPaused { return "pause.circle" }
        if isUnavailable(folder) { return "exclamationmark.triangle" }
        return "arrow.down.circle"
    }

    private func statusColor(for folder: WatchFolderConfiguration) -> Color {
        if folder.isPaused { return Color.secondary }
        if isUnavailable(folder) { return Color.orange }
        return Color.green
    }

    /// Status spoken as text, because the icon is hidden from accessibility and
    /// colour alone must never be the only signal.
    private func spokenFolderStatus(for folder: WatchFolderConfiguration) -> String {
        "\(folder.displayName), \(statusText(for: folder))"
    }

    // MARK: - Existing files

    private var existingFilesSection: some View {
        Section {
            HStack {
                Button("Add Folder…") {
                    chooseFolder()
                }
                Button("Import Existing Files Now") {
                    coordinator.importExistingNow()
                }
                .disabled(coordinator.folders.allSatisfy(\.isPaused) && !coordinator.folders.isEmpty)
                Spacer()
                Toggle("Pause Watching", isOn: Binding(
                    get: { coordinator.isPaused },
                    set: { coordinator.setAllPaused($0) }
                ))
                .accessibilityLabel("Pause watching all folders")
            }
        } header: {
            Text("Controls")
        } footer: {
            Text("Files still being written are detected by a size-stability check and imported once they settle. Each folder keeps a local content-hash ledger so nothing is imported twice.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to watch for new workout files"
        panel.prompt = "Watch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = coordinator.addFolder(url: url)
    }

    // MARK: - Recent imports

    private var recentImportsSection: some View {
        Section {
            if coordinator.recentImports.isEmpty {
                Text("Imports from watched folders will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.recentImports) { record in
                    RecentImportRow(record: record)
                }
            }
        } header: {
            Text("Recent Imports")
        }
    }

    // MARK: - Privacy

    private var privacyFooter: some View {
        Section {
            Text("Watched folders stay on this Mac. RunPlay Studio stores the folder bookmarks, a SHA-256 content hash and filename per processed file, and the outcome — nothing else, and nothing leaves the machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One recent-import row: status icon, filename, folder, time, failure
/// detail, and reveal-in-Finder.
struct RecentImportRow: View {
    let record: WatchFolderImportRecord
    @State private var revealFailed = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.fileName)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(record.folderName)
                    Text("·")
                    Text(record.processedAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !record.failureDetail.isEmpty {
                    Text(record.failureDetail)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            // The status icon is hidden from accessibility, so the spoken row
            // must carry the status as text — never colour or icon alone.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenSummary)
            Spacer()
            Button {
                reveal()
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show this file in Finder")
            .accessibilityLabel("Reveal \(record.fileName) in Finder")
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch record.status {
        case .imported: return "checkmark.circle.fill"
        case .skippedDuplicate: return "arrow.uturn.right.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .awaitingReview: return "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch record.status {
        case .imported: return .green
        case .skippedDuplicate: return .secondary
        case .failed: return .red
        case .awaitingReview: return .orange
        }
    }

    /// Spoken form of the row: status as text, then file, folder, time, and
    /// any failure detail. Deliberately excludes the icon and colour.
    private var spokenSummary: String {
        var parts = [statusText, record.fileName, record.folderName]
        if !record.failureDetail.isEmpty {
            parts.append(record.failureDetail)
        }
        return parts.joined(separator: ", ")
    }

    private var statusText: String {
        switch record.status {
        case .imported: return "Imported"
        case .skippedDuplicate: return "Skipped, already imported"
        case .failed: return "Failed"
        case .awaitingReview: return "Waiting for review"
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
    }
}
