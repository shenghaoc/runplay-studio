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
                selectedWorkout: $appState.selectedWorkout,
                onImport: { appState.showImporter = true }
            )
        } detail: {
            if let workout = appState.selectedWorkout {
                WorkoutDetailView(workout: workout, appState: appState)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            ExportView(
                                workout: workout,
                                segments: appState.detectedSegments
                            )
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
