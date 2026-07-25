import Foundation
import Combine

enum AppSessionRestorationPhase: Equatable, Sendable {
    case notStarted
    case restoring
    case active
}

/// Coordinates startup restoration and bounded writes for the application
/// session. The application owns this object; its AppState reference is weak
/// so a test or a future scene teardown cannot create a cycle.
@MainActor
final class AppSessionController: ObservableObject {
    @Published private(set) var phase: AppSessionRestorationPhase = .notStarted
    @Published private(set) var lastSaveError: String?

    weak var appState: AppState?

    private let store: any AppSessionStoring
    private let structuralSaveDelay: UInt64
    private let replayCheckpointInterval: UInt64
    private var structuralSaveTask: Task<Void, Never>?
    private var replayCheckpointTask: Task<Void, Never>?

    init(
        appState: AppState,
        store: any AppSessionStoring,
        structuralSaveDelay: UInt64 = 250_000_000,
        replayCheckpointInterval: UInt64 = 1_000_000_000
    ) {
        self.appState = appState
        self.store = store
        self.structuralSaveDelay = structuralSaveDelay
        self.replayCheckpointInterval = replayCheckpointInterval
        appState.replayController.onStateChange = { [weak self] in
            self?.requestSave(replay: true)
        }
        appState.replayController.onPause = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.flush()
            }
        }
    }

    deinit {
        structuralSaveTask?.cancel()
        replayCheckpointTask?.cancel()
    }

    var isRestoring: Bool {
        phase != .active
    }

    /// Runs the library-first startup sequence once for the lifetime of the
    /// application-owned AppState.
    func startIfNeeded() async {
        guard phase == .notStarted, let appState else { return }
        phase = .restoring

        await appState.start()

        let persisted = await store.load()
        let rawSnapshot = persisted ?? AppSessionSnapshot.safeDefault(
            selectedWorkoutID: appState.selectedWorkout?.id
        )
        let validation = AppSessionValidator.validate(
            rawSnapshot,
            context: appState.sessionValidationContext()
        )
        appState.applySessionSnapshot(validation.snapshot)
        // Let SwiftUI reconcile the restored selection before accepting any
        // binding callbacks emitted by the initial view tree.
        await Task.yield()
        phase = .active

        // Repair a corrupt/obsolete session after the UI has become active.
        // A missing file is also materialized so the next launch has a stable
        // baseline, but this is still debounced and never blocks startup.
        if persisted == nil || validation.usedFallback {
            requestSave()
        }
    }

    /// Debounce structural changes and throttle replay checkpoints. Replay
    /// callbacks can arrive at 30 fps, so an existing checkpoint must not be
    /// cancelled by each subsequent tick.
    func requestSave(replay: Bool = false) {
        guard phase == .active, appState != nil else { return }
        if replay {
            guard replayCheckpointTask == nil else { return }
            replayCheckpointTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: replayCheckpointInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                replayCheckpointTask = nil
                await persistCurrentSnapshot()
            }
            return
        }

        structuralSaveTask?.cancel()
        structuralSaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: structuralSaveDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            structuralSaveTask = nil
            await persistCurrentSnapshot()
        }
    }

    /// Cancel a pending debounce and persist the current logical state.
    func flush() async {
        structuralSaveTask?.cancel()
        structuralSaveTask = nil
        replayCheckpointTask?.cancel()
        replayCheckpointTask = nil
        await persistCurrentSnapshot()
    }

    private func persistCurrentSnapshot() async {
        guard phase == .active, let appState else { return }

        do {
            try await store.save(appState.makeSessionSnapshot())
            lastSaveError = nil
        } catch {
            // Session persistence is best effort. Do not surface a transient
            // alert that would itself be incorrectly restored.
            lastSaveError = error.localizedDescription
        }
    }

    /// Pause replay before an inactive/background transition and flush the
    /// paused logical position.
    func pauseReplayAndFlush() async {
        appState?.replayController.pause()
        await flush()
    }
}
