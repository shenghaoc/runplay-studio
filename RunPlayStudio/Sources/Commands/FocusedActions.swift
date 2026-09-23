import RunPlayCore
import SwiftUI

// MARK: - Action bundles

/// Replay commands valid only while a workout workspace owns focus.
struct ReplayActions {
    var isAvailable: () -> Bool = { false }
    var togglePlayPause: () -> Void = {}
    var seekBackward: () -> Void = {}
    var seekForward: () -> Void = {}
    var stepBackward: () -> Void = {}
    var stepForward: () -> Void = {}
    var slower: () -> Void = {}
    var faster: () -> Void = {}
    var restart: () -> Void = {}
}

/// Library commands valid while All Runs owns focus.
/// Per-run DEM elevation commands for the Workout menu.
struct ElevationActions {
    var canCorrect: () -> Bool = { false }
    var correct: () -> Void = {}
    var canChooseRecorded: () -> Bool = { false }
    var usesRecordedElevation: () -> Bool = { false }
    var setUsesRecordedElevation: (Bool) -> Void = { _ in }
}

struct LibraryActions {
    var isAvailable: () -> Bool = { false }
    var focusSearch: () -> Void = {}
    var canOpenSelection: () -> Bool = { false }
    var openSelection: () -> Void = {}
    var canEditTags: () -> Bool = { false }
    var editTags: () -> Void = {}
}

/// Map commands that target the currently visible map surface.
struct MapActions {
    var isAvailable: () -> Bool = { false }
    var fit: () -> Void = {}
    var togglePresentation: () -> Void = {}
    var canTogglePresentation: () -> Bool = { true }
    /// True only for the single-workout map, which owns metric route coloring.
    var supportsRouteColor: () -> Bool = { false }
    var routeColorMode: () -> WorkoutRouteColorMode = { .solid }
    var canSelectRouteColor: (WorkoutRouteColorMode) -> Bool = { _ in false }
    var selectRouteColor: (WorkoutRouteColorMode) -> Void = { _ in }
}

/// Export commands for the workout whose toolbar Export menu is on screen.
///
/// Each action runs the same path as the matching toolbar menu item, so the
/// menu bar and the toolbar share save panels, sheets, and alerts.
struct ExportActions {
    var exportSummaryJSON: () -> Void = {}
    var exportDistanceSplitsCSV: () -> Void = {}
    var canExportRecordedLaps: () -> Bool = { false }
    var exportRecordedLapsCSV: () -> Void = {}
    var exportSegmentsCSV: () -> Void = {}
    var exportSummaryCardPNG: () -> Void = {}
    var canExportRouteReplay: () -> Bool = { false }
    var exportRouteReplayMP4: () -> Void = {}
    var exportAllCSV: () -> Void = {}
}

/// One export the menu bar can ask the toolbar Export menu to run.
enum ExportCommand: Equatable, Sendable {
    case summaryJSON
    case distanceSplitsCSV
    case recordedLapsCSV
    case segmentsCSV
    case summaryCardPNG
    case routeReplayMP4
    case allCSV
}

/// Carries File → Export requests to `ExportView`.
///
/// `ExportView` lives in the window toolbar, and a focused scene value
/// published from a toolbar item never reaches the menu bar's `Commands`
/// (observed on macOS 26). The workspace content therefore publishes
/// `ExportActions` that post requests here; `ExportView` performs each request
/// through its own export paths and reports back the eligibility only it knows.
@MainActor
@Observable
final class ExportCommandRelay {
    private(set) var pendingCommand: ExportCommand?
    /// Mirrors `ExportView`'s asynchronous video-eligibility check.
    var canExportRouteReplay = false

    func request(_ command: ExportCommand) {
        pendingCommand = command
    }

    /// Returns the pending request once and clears it.
    func takePendingCommand() -> ExportCommand? {
        defer { pendingCommand = nil }
        return pendingCommand
    }

    /// Menu-bar actions that post to this relay for `workout`.
    func actions(for workout: RunWorkout) -> ExportActions {
        ExportActions(
            exportSummaryJSON: { self.request(.summaryJSON) },
            exportDistanceSplitsCSV: { self.request(.distanceSplitsCSV) },
            canExportRecordedLaps: { !workout.recordedLaps.isEmpty },
            exportRecordedLapsCSV: { self.request(.recordedLapsCSV) },
            exportSegmentsCSV: { self.request(.segmentsCSV) },
            exportSummaryCardPNG: { self.request(.summaryCardPNG) },
            canExportRouteReplay: { self.canExportRouteReplay },
            exportRouteReplayMP4: { self.request(.routeReplayMP4) },
            exportAllCSV: { self.request(.allCSV) }
        )
    }
}

extension WorkoutRouteColorMode {
    /// Whether the Route Color menus may select this mode for the current
    /// workout. Solid is always selectable; a metric mode needs the workout's
    /// availability probe to have passed, and is unselectable before it runs.
    func isSelectable(in availability: RouteMetricModeAvailability?) -> Bool {
        self == .solid || (availability?.isAvailable(self) ?? false)
    }
}

/// App-level presentation actions (help sheets, etc.).
struct AppPresentationActions {
    var showKeyboardShortcuts: () -> Void = {}
}

// MARK: - Focused value keys

private struct ReplayActionsKey: FocusedValueKey {
    typealias Value = ReplayActions
}

private struct ElevationActionsKey: FocusedValueKey {
    typealias Value = ElevationActions
}

private struct LibraryActionsKey: FocusedValueKey {
    typealias Value = LibraryActions
}

private struct MapActionsKey: FocusedValueKey {
    typealias Value = MapActions
}

private struct ExportActionsKey: FocusedValueKey {
    typealias Value = ExportActions
}

private struct AppPresentationActionsKey: FocusedValueKey {
    typealias Value = AppPresentationActions
}

private struct SheetPresentationActiveKey: FocusedValueKey {
    typealias Value = Bool
}

/// Descendant presentation hosts publish whether they currently own a sheet or
/// alert. `ContentView` folds the preference into the scene command gate so
/// background shortcuts cannot mutate an obscured workspace.
struct CommandBlockingPresentationPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    func blocksBackgroundCommands(_ isPresented: Bool) -> some View {
        preference(
            key: CommandBlockingPresentationPreferenceKey.self,
            value: isPresented
        )
    }
}

extension FocusedValues {
    var elevationActions: ElevationActions? {
        get { self[ElevationActionsKey.self] }
        set { self[ElevationActionsKey.self] = newValue }
    }

    var replayActions: ReplayActions? {
        get { self[ReplayActionsKey.self] }
        set { self[ReplayActionsKey.self] = newValue }
    }

    var libraryActions: LibraryActions? {
        get { self[LibraryActionsKey.self] }
        set { self[LibraryActionsKey.self] = newValue }
    }

    var mapActions: MapActions? {
        get { self[MapActionsKey.self] }
        set { self[MapActionsKey.self] = newValue }
    }

    var exportActions: ExportActions? {
        get { self[ExportActionsKey.self] }
        set { self[ExportActionsKey.self] = newValue }
    }

    var appPresentationActions: AppPresentationActions? {
        get { self[AppPresentationActionsKey.self] }
        set { self[AppPresentationActionsKey.self] = newValue }
    }

    /// When true, destructive or workspace-changing background shortcuts should
    /// prefer the sheet context (sheets still use their own cancel/default keys).
    var sheetPresentationActive: Bool? {
        get { self[SheetPresentationActiveKey.self] }
        set { self[SheetPresentationActiveKey.self] = newValue }
    }
}
