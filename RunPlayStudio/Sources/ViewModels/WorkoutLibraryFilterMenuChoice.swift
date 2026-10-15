import Foundation
import RunPlayCore
import SwiftUI

// The All Runs Filters menu's one-of-many rows that set a filter outright:
// Date's presets and Custom Date Range…, Tags' Any Tags and Untagged Only,
// and Route's Any Route and Not on a Route. The Personal Heatmap's route menu
// uses Route's Any Route row too. Each row is a `Toggle`, because a
// macOS menu draws a Toggle row's check mark and reports it as the item's AX
// mark character, while a `Button` row has no mark.
//
// Every write to a row's `menuCheck` applies the row's choice, as its Button
// did. Choosing an unchecked row writes `true`; choosing the checked row
// writes `false`, and applying the choice again keeps it checked. The binding
// does not ignore `false`, because choosing a row again is not always a
// no-op: it marks an unmodified smart collection Modified, and Custom Date
// Range… takes the From and To pickers' dates again.

/// A row of the All Runs Filters → Date submenu.
enum WorkoutLibraryDateMenuChoice: CaseIterable {
    case allTime
    case last30Days
    case last90Days
    case currentCalendarYear
    case customRange

    /// The row that `filter` checks: its preset, or Custom Date Range… for
    /// any custom range. That includes a smart collection's one-sided range
    /// and a range with neither bound, which still counts as a filter.
    init(checkedBy filter: WorkoutLibraryDateFilter) {
        switch filter {
        case .allTime: self = .allTime
        case .last30Days: self = .last30Days
        case .last90Days: self = .last90Days
        case .currentCalendarYear: self = .currentCalendarYear
        case .custom: self = .customRange
        }
    }

    /// The filter that choosing this row applies. Custom Date Range… takes
    /// the From and To pickers' dates.
    func appliedFilter(customStart: Date, customEnd: Date) -> WorkoutLibraryDateFilter {
        switch self {
        case .allTime: return .allTime
        case .last30Days: return .last30Days
        case .last90Days: return .last90Days
        case .currentCalendarYear: return .currentCalendarYear
        case .customRange: return .custom(start: customStart, end: customEnd)
        }
    }

    /// The check mark on this row, as the binding of the row's `Toggle`: on
    /// while `filter()` checks this row. Every write applies the row's
    /// filter, reading the pickers' dates from `customRange()`. The closures
    /// are main-actor isolated because `Binding` takes `@Sendable` accessors.
    @MainActor
    func menuCheck(
        filter: @escaping @MainActor () -> WorkoutLibraryDateFilter,
        customRange: @escaping @MainActor () -> (start: Date, end: Date),
        setFilter: @escaping @MainActor (WorkoutLibraryDateFilter) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { Self(checkedBy: filter()) == self },
            set: { _ in
                let range = customRange()
                setFilter(appliedFilter(customStart: range.start, customEnd: range.end))
            }
        )
    }
}

/// A row of the All Runs Filters → Tags submenu that sets the tag filter
/// outright.
enum WorkoutLibraryTagMenuChoice: CaseIterable {
    case anyTags
    case untaggedOnly

    /// The row that `filter` checks, if either. Any Tags is checked while no
    /// tag restriction applies. While tags are selected neither row is: the
    /// selection lives in the Match Any Selected and Match All Selected
    /// submenus, which check its tags.
    init?(checkedBy filter: WorkoutLibraryTagFilter) {
        switch filter {
        case .untaggedOnly:
            self = .untaggedOnly
        case .anyTags, .selected:
            // An empty selection restricts nothing, as Any Tags does.
            guard !filter.isActive else { return nil }
            self = .anyTags
        }
    }

    /// The filter that choosing this row applies.
    var appliedFilter: WorkoutLibraryTagFilter {
        switch self {
        case .anyTags: return .anyTags
        case .untaggedOnly: return .untaggedOnly
        }
    }

    /// The check mark on this row, as the binding of the row's `Toggle`: on
    /// while `filter()` checks this row. Every write applies the row's
    /// filter. The closures are main-actor isolated because `Binding` takes
    /// `@Sendable` accessors.
    @MainActor
    func menuCheck(
        filter: @escaping @MainActor () -> WorkoutLibraryTagFilter,
        setFilter: @escaping @MainActor (WorkoutLibraryTagFilter) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { Self(checkedBy: filter()) == self },
            set: { _ in setFilter(appliedFilter) }
        )
    }
}

/// A row of the All Runs Filters → Route submenu that sets the route filter
/// outright: Any Route or Not on a Route. The Personal Heatmap's route menu
/// filters by the same `WorkoutLibraryRouteFilter` and lists Any Route only.
enum WorkoutLibraryRouteMenuChoice: CaseIterable {
    case anyRoute
    case ungroupedOnly

    /// The row that `filter` checks, if either. While one route is the
    /// filter neither row is: that route's own row is checked instead, when
    /// the menu lists it.
    init?(checkedBy filter: WorkoutLibraryRouteFilter) {
        switch filter {
        case .anyRoute: self = .anyRoute
        case .ungroupedOnly: self = .ungroupedOnly
        case .group: return nil
        }
    }

    /// The filter that choosing this row applies.
    var appliedFilter: WorkoutLibraryRouteFilter {
        switch self {
        case .anyRoute: return .anyRoute
        case .ungroupedOnly: return .ungroupedOnly
        }
    }

    /// The check mark on this row, as the binding of the row's `Toggle`: on
    /// while `filter()` checks this row. Every write applies the row's
    /// filter. The closures are main-actor isolated because `Binding` takes
    /// `@Sendable` accessors.
    @MainActor
    func menuCheck(
        filter: @escaping @MainActor () -> WorkoutLibraryRouteFilter,
        setFilter: @escaping @MainActor (WorkoutLibraryRouteFilter) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { Self(checkedBy: filter()) == self },
            set: { _ in setFilter(appliedFilter) }
        )
    }
}
