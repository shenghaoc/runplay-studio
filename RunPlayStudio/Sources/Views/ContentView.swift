import SwiftUI
import RunPlayCore
import UniformTypeIdentifiers
import RunPlayCore

/// Supported import file types built dynamically from the importer factory.
/// Uses `UTType(filenameExtension:)` so that .tcx and .fit files are selectable
/// even when no system-wide UTI declaration exists (Swift Package apps lack Info.plist).
extension UTType {
    static let supportedImportTypes: [UTType] = {
        let types = WorkoutImporterFactory.supportedExtensions.compactMap { ext in
            UTType(filenameExtension: ext)
        }
        // Fallback to .data if no types resolved (should not happen)
        return types.isEmpty ? [.data] : types
    }()
}

/// Main content view with sidebar, 3D route view, and detail panels.
struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                workouts: appState.workouts,
                selectedWorkout: Binding(
                    get: { appState.selectedWorkout },
                    set: { appState.selectWorkout($0) }
                ),
                onImport: { appState.showImporter = true }
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
        .alert("Import Error", isPresented: $appState.showingError) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "Unknown error")
        }
    }
}
