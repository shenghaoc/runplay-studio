import SwiftUI
import RunPlayCore
import AppKit

@main
@MainActor
struct RunPlayStudioApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationCoordinator.self)
    private var terminationCoordinator
    @StateObject private var appState: AppState
    @StateObject private var sessionController: AppSessionController

    init() {
        let libraryRoot = ContentView.defaultLibraryRoot
        let appState = AppState(libraryRoot: libraryRoot)
        let sessionController = AppSessionController(
            appState: appState,
            store: FileAppSessionStore(rootURL: libraryRoot)
        )
        appState.sessionController = sessionController
        _appState = StateObject(wrappedValue: appState)
        _sessionController = StateObject(wrappedValue: sessionController)
        terminationCoordinator.sessionController = sessionController
    }

    var body: some Scene {
        Window("RunPlay Studio", id: "main") {
            ContentView(
                appState: appState,
                sessionController: sessionController
            )
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .defaultWindowPlacement { _, context in
            let visibleRect = context.defaultDisplay.visibleRect
            let width = min(1200, max(720, visibleRect.width - 80))
            let height = min(800, max(500, visibleRect.height - 120))
            return WindowPlacement(
                size: CGSize(width: width, height: height)
            )
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.automatic)
        .commands {
            WorkoutViewCommands()
        }
    }
}
