import AppKit

@MainActor
protocol AppSessionTerminating: AnyObject {
    func pauseReplayAndFlush() async
}

extension AppSessionController: AppSessionTerminating {}

/// Defers normal application termination until the bounded session snapshot
/// has finished writing. AppKit retains native ownership of the quit flow.
@MainActor
final class AppTerminationCoordinator: NSObject, NSApplicationDelegate {
    weak var sessionController: (any AppSessionTerminating)?
    var terminationReply: ((NSApplication, Bool) -> Void)?

    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sessionController else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { [weak self] in
            await sessionController.pauseReplayAndFlush()
            guard let self else { return }
            terminationTask = nil
            if let terminationReply {
                terminationReply(sender, true)
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    deinit {
        terminationTask?.cancel()
    }
}
