import SwiftUI
import RunPlayCore
import AppKit
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
    static let stravaArchiveTypes: [UTType] = [.zip]
}

/// Main content view with sidebar, 3D route view, and detail panels.
struct ContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var sessionController: AppSessionController
    @Environment(\.scenePhase) private var scenePhase
    @State private var sidebarSelection: SidebarSelection?

    init(appState: AppState, sessionController: AppSessionController) {
        self.appState = appState
        self.sessionController = sessionController
        self._sidebarSelection = State(initialValue: appState.sidebarSelection)
    }

    /// Default library root in Application Support.
    static var defaultLibraryRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("RunPlayStudio", isDirectory: true)
    }

    private var sidebarVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch appState.sidebarVisibilityRaw {
                case "all":
                    return .all
                case "detailOnly":
                    return .detailOnly
                default:
                    return .automatic
                }
            },
            set: { visibility in
                let raw: String
                if visibility == .all || visibility == .doubleColumn {
                    raw = "all"
                } else if visibility == .detailOnly {
                    raw = "detailOnly"
                } else {
                    raw = "automatic"
                }
                appState.sidebarVisibilityRaw = raw
                appState.requestSessionSave()
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibilityBinding) {
            SidebarView(
                workouts: appState.workouts,
                favoriteIDs: appState.favoriteWorkoutIDs,
                smartCollections: appState.smartCollections,
                libraryCount: appState.workouts.count,
                totalFavoriteCount: appState.favoriteWorkoutIDs.count,
                selection: Binding(
                    get: { sidebarSelection },
                    set: {
                        sidebarSelection = $0
                        guard !sessionController.isRestoring else { return }
                        appState.applySidebarSelection($0)
                    }
                ),
                onImport: { appState.showImporter = true },
                onArchiveImport: { appState.showArchiveImporter = true },
                onDelete: { workout in
                    Task { await appState.deleteWorkout(workout) }
                },
                onShowAllFavorites: {
                    appState.showAllFavoritesInLibrary()
                },
                onManageSmartCollections: {
                    appState.showWorkoutLibrary(restoreManualQuery: false)
                    // The presentation request is shared state so it survives
                    // mounting the All Runs destination from another workspace.
                    appState.showSmartCollectionsManager = true
                }
            )
        } detail: {
            switch appState.workspaceMode {
            case .personalHeatmap:
                PersonalHeatmapView(appState: appState, viewModel: appState.personalHeatmap)
            case .workoutLibrary:
                WorkoutLibraryView(appState: appState, viewModel: appState.workoutLibrary)
            case .comparison:
                if appState.selectedWorkout != nil {
                    CompareView(appState: appState)
                } else {
                    EmptyStateView(onImport: { appState.showImporter = true }, onArchiveImport: { appState.showArchiveImporter = true })
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
                                        .accessibilityLabel("Compare runs")
                                    } else if appState.workouts.count < 2 {
                                        Button(action: { appState.enterEmptyComparisonMode() }) {
                                            Label("Compare", systemImage: "arrow.left.arrow.right")
                                        }
                                        .help("Import another run to compare")
                                        .accessibilityLabel("Compare runs")
                                    }

                                    ExportView(
                                        workout: workout,
                                        segments: appState.detectedSegments
                                    )
                                }
                            }
                        }
                } else {
                    EmptyStateView(onImport: { appState.showImporter = true }, onArchiveImport: { appState.showArchiveImporter = true })
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
        .fileImporter(
            isPresented: $appState.showArchiveImporter,
            allowedContentTypes: UTType.stravaArchiveTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                appState.beginArchiveImport(from: url)
            case .failure(let error):
                appState.errorMessage = error.localizedDescription
                appState.showingError = true
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.archiveSession != nil },
            set: { isPresented in
                guard !isPresented else { return }
                if appState.archiveSession?.phase == .importing {
                    appState.cancelArchiveImport()
                } else {
                    appState.dismissArchiveSession()
                }
            }
        )) {
            if let session = appState.archiveSession {
                StravaArchiveImportView(
                    session: session,
                    onImport: { appState.confirmArchiveImport() },
                    onCancel: { appState.cancelArchiveImport() },
                    onDone: { appState.dismissArchiveSession() },
                    onViewImported: { appState.viewMostRecentImportedRun() },
                    onOpenHeatmap: { appState.openHeatmapAfterArchiveImport() }
                )
                .interactiveDismissDisabled(session.phase == .importing)
            }
        }
        .alert("RunPlay Studio", isPresented: $appState.showingError) {
            Button("Got it") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "Something went wrong. Please try again.")
        }
        .task {
            await sessionController.startIfNeeded()
        }
        .disabled({
            if sessionController.isRestoring {
                return true
            }
            switch appState.operationState {
            case .idle, .importingArchive:
                // Archive progress UI lives in the sheet; keep the window usable.
                return false
            case .loadingLibrary, .importing, .deleting, .scanningArchive:
                return true
            }
        }())
        .overlay {
            if sessionController.isRestoring {
                ProgressView("Restoring workspace…")
                    .padding()
            } else {
                operationStateOverlay
            }
        }
        .focusedSceneValue(\.appWorkspaceActions, AppWorkspaceActions(
            showPersonalHeatmap: { appState.showPersonalHeatmap() },
            showAllRuns: { appState.showWorkoutLibrary(restoreManualQuery: true) },
            importFile: { appState.showImporter = true },
            importStravaArchive: { appState.showArchiveImporter = true }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .runPlayWorkspaceCommand)) { notification in
            guard let command = notification.object as? AppWorkspaceCommand else { return }
            appState.handleWorkspaceCommand(command)
        }
        .onChange(of: appState.sidebarSelection) { _, selection in
            sidebarSelection = selection
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task {
                await sessionController.pauseReplayAndFlush()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            Task {
                await sessionController.pauseReplayAndFlush()
            }
        }
        .onDisappear {
            Task {
                await sessionController.pauseReplayAndFlush()
            }
        }
        .frame(minWidth: 720, minHeight: 500)
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
        case .scanningArchive(let filename):
            ProgressView("Scanning \(filename)…")
                .padding()
        case .importingArchive:
            // Progress lives in the archive sheet.
            EmptyView()
        case .idle:
            EmptyView()
        }
    }
}
