import Foundation

/// Process entry point.
///
/// A normal launch goes straight to the SwiftUI app. Debug builds also accept
/// the headless `--demo-assets` mode that `scripts/generate-demo-assets.sh`
/// drives: it renders the README demo media through the export services and
/// exits without creating `AppState`, opening a window, or reading the workout
/// library. Release builds contain no such mode.
@main
@MainActor
enum RunPlayStudioEntryPoint {
    static func main() {
        #if DEBUG
        if DemoAssetCommandLine.isRequested(by: CommandLine.arguments) {
            DemoAssetCommand.runAndExit(arguments: CommandLine.arguments)
        }
        #endif
        RunPlayStudioApp.main()
    }
}
