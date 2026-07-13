import SwiftUI
import RunPlayCore

@main
struct RunPlayStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
#if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
#endif
    }
}
