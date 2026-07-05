import SwiftUI
import UniformTypeIdentifiers

/// Extension to register TCX and FIT file types.
extension UTType {
    static var tcx: UTType {
        UTType(importedAs: "com.garmin.tcx")
    }

    static var fit: UTType {
        UTType(importedAs: "com.garmin.fit")
    }
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
            allowedContentTypes: [.json, .xml, .tcx, .fit],
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
