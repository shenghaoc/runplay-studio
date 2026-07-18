import SwiftUI
import RunPlayCore
import UniformTypeIdentifiers

/// Manages security-scoped resource access for the lifetime of an async import.
///
/// On macOS, files selected via `NSOpenPanel`/`.fileImporter` may require
/// `startAccessingSecurityScopedResource()` to remain accessible. This wrapper
/// keeps access alive until deallocation, which occurs after the async import
/// task completes and the URL is no longer needed.
private final class SecurityScopedURL: Sendable {
    let url: URL
    private let isAccessing: Bool

    init(_ url: URL) {
        self.url = url
        self.isAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// Supported import file types for the Swift Package app path.
/// Generic data keeps custom .tcx/.fit files selectable; importer validation
/// still rejects unsupported extensions with a clear error.
extension UTType {
    static let supportedImportTypes: [UTType] = [.data]
}

/// Main content view with sidebar, 3D route view, and detail panels.
struct ContentView: View {
    @StateObject private var appState = AppState(
        libraryRoot: ContentView.defaultLibraryRoot
    )

    /// Default library root in Application Support.
    static var defaultLibraryRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("RunPlayStudio", isDirectory: true)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                workouts: appState.workouts,
                selection: Binding(
                    get: { appState.sidebarSelection },
                    set: { appState.applySidebarSelection($0) }
                ),
                onImport: { appState.showImporter = true },
                onDelete: { workout in
                    Task { await appState.deleteWorkout(workout) }
                }
            )
        } detail: {
            switch appState.workspaceMode {
            case .personalHeatmap:
                PersonalHeatmapView(appState: appState, viewModel: appState.personalHeatmap)
            case .comparison:
                if appState.selectedWorkout != nil {
                    CompareView(appState: appState)
                } else {
                    EmptyStateView(onImport: { appState.showImporter = true })
                }
            case .workout:
                if let workout = appState.selectedWorkout {
                    WorkoutDetailView(workout: workout, appState: appState)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                HStack {
                                    if appState.isComparing {
                                        Button(action: { appState.clearComparison() }) {
                                            Label("End Comparison", systemImage: "arrow.left.arrow.right")
                                        }
                                        .help("Exit comparison mode")
                                    } else if !appState.availableForComparison.isEmpty {
                                        Button(action: { appState.setComparison(appState.availableForComparison.first) }) {
                                            Label("Compare", systemImage: "arrow.left.arrow.right")
                                        }
                                        .help("Compare with another run")
                                    } else if appState.workouts.count < 2 {
                                        Button(action: { appState.enterEmptyComparisonMode() }) {
                                            Label("Compare", systemImage: "arrow.left.arrow.right")
                                        }
                                        .help("Import another run to compare")
                                    }

                                    ExportView(
                                        workout: workout,
                                        segments: appState.detectedSegments
                                    )
                                }
                            }
                        }
                } else {
                    EmptyStateView(onImport: { appState.showImporter = true })
                }
            }
        }
        .fileImporter(
            isPresented: $appState.showImporter,
            allowedContentTypes: UTType.supportedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Keep security-scoped access alive for the full async import.
                let scoped = SecurityScopedURL(url)
                Task {
                    await appState.importWorkout(from: url)
                    _ = scoped // prevent early deallocation
                }
            case .failure(let error):
                appState.errorMessage = error.localizedDescription
                appState.showingError = true
            }
        }
        .alert("RunPlay Studio", isPresented: $appState.showingError) {
            Button("Got it") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "Something went wrong. Please try again.")
        }
        .task {
            await appState.start()
        }
        .disabled(appState.operationState != .idle)
        .overlay {
            operationStateOverlay
        }
        .focusedSceneValue(\.appWorkspaceActions, AppWorkspaceActions(
            showPersonalHeatmap: { appState.showPersonalHeatmap() }
        ))
    }

    @ViewBuilder
    private var operationStateOverlay: some View {
        switch appState.operationState {
        case .loadingLibrary:
            ProgressView("Loading workout library…")
                .padding()
        case .importing(let filename):
            ProgressView("Importing \(filename)…")
                .padding()
        case .deleting:
            ProgressView("Deleting…")
                .padding()
        case .idle:
            EmptyView()
        }
    }
}
