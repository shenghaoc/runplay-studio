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
struct LibraryActions {
    var isAvailable: () -> Bool = { false }
    var focusSearch: () -> Void = {}
    var openSelection: () -> Void = {}
    var editTags: () -> Void = {}
}

/// Map commands that target the currently visible map surface.
struct MapActions {
    var isAvailable: () -> Bool = { false }
    var fit: () -> Void = {}
    var togglePresentation: () -> Void = {}
    var canTogglePresentation: () -> Bool = { true }
}

/// App-level presentation actions (help sheets, etc.).
struct AppPresentationActions {
    var showKeyboardShortcuts: () -> Void = {}
}

// MARK: - Focused value keys

private struct ReplayActionsKey: FocusedValueKey {
    typealias Value = ReplayActions
}

private struct LibraryActionsKey: FocusedValueKey {
    typealias Value = LibraryActions
}

private struct MapActionsKey: FocusedValueKey {
    typealias Value = MapActions
}

private struct AppPresentationActionsKey: FocusedValueKey {
    typealias Value = AppPresentationActions
}

private struct SheetPresentationActiveKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
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
