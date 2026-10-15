import Foundation
import RunPlayCore
import SwiftUI

/// The All Runs Tags filter's Match Any Selected and Match All Selected
/// submenus. Each lists every tag as a checkable row. Tags are multi-select:
/// a submenu checks the tags the filter selects under its match mode, and
/// choosing a row adds or removes that tag.
extension WorkoutLibraryTagFilter {
    /// Whether the `match` submenu checks `tagID`: the filter selects that
    /// tag under that match mode. The other submenu leaves it unchecked.
    func selects(_ tagID: UUID, match: WorkoutLibraryTagMatchMode) -> Bool {
        if case .selected(let ids, let mode) = self {
            return mode == match && ids.contains(tagID)
        }
        return false
    }

    /// The filter after choosing `tagID` in the `match` submenu.
    ///
    /// Under the same match mode the choice adds or removes the tag, and
    /// removing the last one clears the tag restriction. After Any Tags,
    /// Untagged Only, or a selection under the other match mode, the
    /// selection restarts with this tag alone.
    func togglingTag(_ tagID: UUID, match: WorkoutLibraryTagMatchMode) -> WorkoutLibraryTagFilter {
        switch self {
        case .selected(let ids, let mode) where mode == match:
            var next = ids
            if next.contains(tagID) {
                next.remove(tagID)
            } else {
                next.insert(tagID)
            }
            return next.isEmpty ? .anyTags : .selected(tagIDs: next, match: match)
        default:
            return .selected(tagIDs: [tagID], match: match)
        }
    }

    /// The check mark on `tagID`'s row in the `match` submenu, as the binding
    /// of the row's `Toggle`: on while `filter()` selects the tag under that
    /// match mode.
    ///
    /// Both writes take effect. Choosing an unchecked row writes `true`,
    /// which adds the tag; choosing a checked row writes `false`, which
    /// removes it. A write that matches the current mark changes nothing.
    /// The closures are main-actor isolated because `Binding` takes
    /// `@Sendable` accessors.
    @MainActor
    static func menuCheck(
        for tagID: UUID,
        match: WorkoutLibraryTagMatchMode,
        filter: @escaping @MainActor () -> WorkoutLibraryTagFilter,
        setFilter: @escaping @MainActor (WorkoutLibraryTagFilter) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { filter().selects(tagID, match: match) },
            set: { isOn in
                let current = filter()
                guard isOn != current.selects(tagID, match: match) else { return }
                setFilter(current.togglingTag(tagID, match: match))
            }
        )
    }
}
