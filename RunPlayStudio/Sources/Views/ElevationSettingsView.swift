import AppKit
import SwiftUI
import RunPlayCore

/// Elevation settings (Settings pane): the DEM tile folder the user
/// downloaded, whether new imports are corrected, and the explicit pass over
/// the existing library. Keyboard-navigable; every status is text, never
/// colour alone.
struct ElevationSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var folderMessage: String?

    var body: some View {
        Form {
            folderSection
            importSection
            librarySection
            privacyFooter
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - Folder

    private var folderSection: some View {
        Section {
            if let folder = appState.demTileSettings.folder {
                LabeledContent("Folder", value: folder.displayName)
                if case .unavailable(let message) = appState.demFolderStatus {
                    Text(message)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.orange)
                }
                Picker("Zoom", selection: zoomBinding(for: folder)) {
                    ForEach(folder.availableZooms, id: \.self) { zoom in
                        Text("\(zoom)").tag(zoom)
                    }
                }
                .disabled(appState.demFolderStatus != .ready || passIsRunning)
                .help("Higher zooms hold finer detail but need more tiles per run")
                LabeledContent("Tile size", value: "\(folder.tileSize) pixels")
            } else {
                Text("No tile folder chosen. Runs keep their recorded elevation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(appState.demTileSettings.folder == nil ? "Choose Folder…" : "Choose Another Folder…") {
                    chooseFolder()
                }
                .disabled(passIsRunning)
                if appState.demTileSettings.folder != nil {
                    Button("Stop Using Folder") {
                        folderMessage = nil
                        appState.forgetDEMTileFolder()
                    }
                    .disabled(passIsRunning)
                }
            }
            if let folderMessage {
                Text(folderMessage)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("DEM tile folder")
        } footer: {
            Text("A folder of Terrarium PNG elevation tiles in z/x/y.png layout that you downloaded yourself, such as the free AWS Terrain Tiles. RunPlay Studio only reads it and never downloads tiles. Zoom 13 or 14 suits running.")
        }
    }

    private func zoomBinding(for folder: DEMTileFolder) -> Binding<Int> {
        Binding(
            get: { appState.demTileSettings.folder?.zoom ?? folder.zoom },
            set: { folderMessage = appState.setDEMTileZoom($0) }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of Terrarium PNG elevation tiles (z/x/y.png)"
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderMessage = appState.chooseDEMTileFolder(at: url)
    }

    // MARK: - New imports

    private var importSection: some View {
        Section {
            Toggle("Correct new imports", isOn: Binding(
                get: { appState.demTileSettings.correctsNewImports },
                set: { appState.setDEMCorrectsNewImports($0) }
            ))
            .disabled(appState.demTileSettings.folder == nil)
        } header: {
            Text("Imports")
        } footer: {
            Text("Altitude from a watch that records a barometric altimeter is kept, and DEM elevation fills its gaps. Other recorded altitude is replaced wherever a tile covers the route. Choose Workout ▸ Use Recorded Elevation to undo it for one run.")
        }
    }

    // MARK: - Library

    private var passIsRunning: Bool {
        if case .running = appState.demCorrectionPassState { return true }
        return false
    }

    private var librarySection: some View {
        Section {
            switch appState.demCorrectionPassState {
            case .idle, .finished:
                let uncorrected = appState.demUncorrectedCount
                Button(uncorrected > 0
                    ? "Correct Elevation of \(uncorrected) Run\(uncorrected == 1 ? "" : "s")"
                    : "Correct Library Elevation") {
                    appState.correctLibraryElevation()
                }
                .disabled(appState.demFolderStatus != .ready || !appState.hasPersistedLibrary)
                if case .finished(let summary) = appState.demCorrectionPassState {
                    Text(summary)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
            case .running(let completed, let total, let name):
                VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
                    ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0) {
                        Text("Correcting — \(completed) of \(total) runs\(name.isEmpty ? "" : " — \(name)")")
                            .font(AppDesign.Typography.compactLabel)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") {
                        appState.cancelDEMCorrectionPass()
                    }
                }
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Corrects runs already in your library. Runs that were only partly covered are checked again, in case you have added tiles. Cancelling keeps every run corrected so far.")
        }
    }

    private var privacyFooter: some View {
        Section {
            Text("The folder is remembered as a bookmark beside your workout library on this Mac. Tiles never leave it, and nothing is uploaded.")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
        }
    }
}
