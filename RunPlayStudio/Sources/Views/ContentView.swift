import SwiftUI
import RunPlayCore
import UniformTypeIdentifiers

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
                selectedWorkout: Binding(
                    get: { appState.selectedWorkout },
                    set: { appState.selectWorkout($0) }
                ),
                onImport: { appState.showImporter = true },
                onDelete: { workout in appState.deleteWorkout(workout) }
            )
        } detail: {
            if let workout = appState.selectedWorkout {
                if appState.isComparing {
                    CompareView(appState: appState)
                } else {
                    WorkoutDetailView(workout: workout, appState: appState)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                HStack {
                                    if !appState.availableForComparison.isEmpty {
                                        Button(action: { appState.setComparison(appState.availableForComparison.first) }) {
                                            Label("Compare", systemImage: "arrow.left.arrow.right")
                                        }
                                    }

                                    ExportView(
                                        workout: workout,
                                        segments: appState.detectedSegments
                                    )
                                }
                            }
                        }
                }
            } else {
                EmptyStateView(onImport: { appState.showImporter = true })
            }
        }
        .fileImporter(
            isPresented: $appState.showImporter,
            allowedContentTypes: UTType.supportedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            appState.handleImport(result)
        }
        .alert("RunPlay Studio", isPresented: $appState.showingError) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "Unknown error")
        }
        .disabled(appState.isLoadingLibrary)
        .overlay {
            if appState.isLoadingLibrary {
                ProgressView("Loading workout library…")
                    .padding()
            }
        }
    }
}
