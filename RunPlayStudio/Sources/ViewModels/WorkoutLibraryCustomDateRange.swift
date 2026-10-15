import Foundation
import RunPlayCore

/// A custom All Runs date range as the From and To row under the All Runs
/// controls edits it.
///
/// Each bound is on or off. An off bound leaves that side of the range open
/// and reaches the query as `nil`, as a smart collection's one-sided range
/// does, so editing one side never closes the other.
///
/// `rememberedStart` and `rememberedEnd` are the dates a picker shows while
/// its bound is off, and the date that turning the bound on applies. While a
/// bound is on, its remembered date is its own date, so turning it off keeps
/// showing that date. They are the view model's `customDateStart` and
/// `customDateEnd`, which Custom Date Range… applies.
///
/// The query service starts a range at the start of its From day and ends it
/// after the whole of its To day. The row therefore compares calendar days: a
/// range may start and end on the same day, and an edit never ends it on a
/// day before the day it starts.
struct WorkoutLibraryCustomDateRange: Equatable {
    enum Bound: CaseIterable {
        case start
        case end
    }

    private(set) var start: Date?
    private(set) var end: Date?
    private(set) var rememberedStart: Date
    private(set) var rememberedEnd: Date

    /// The range that `filter` holds, or nil for a preset, which shows no
    /// row.
    init?(filter: WorkoutLibraryDateFilter, rememberedStart: Date, rememberedEnd: Date) {
        guard case .custom(let start, let end) = filter else { return nil }
        self.start = start
        self.end = end
        self.rememberedStart = start ?? rememberedStart
        self.rememberedEnd = end ?? rememberedEnd
    }

    /// The date filter this range applies.
    var filter: WorkoutLibraryDateFilter {
        .custom(start: start, end: end)
    }

    /// Whether `bound` limits the range: its checkbox.
    func includes(_ bound: Bound) -> Bool {
        date(of: bound) != nil
    }

    /// Whether `bound` can be turned off. Only while the other bound is on:
    /// a custom range keeps at least one date, because one with neither
    /// would count as an active filter that matches every run.
    func canExclude(_ bound: Bound) -> Bool {
        includes(bound.other)
    }

    /// The date `bound`'s picker shows: the bound's own date while it is on,
    /// otherwise its remembered date.
    func pickerDate(for bound: Bound) -> Date {
        date(of: bound) ?? rememberedDate(of: bound)
    }

    /// The dates `bound`'s picker offers. While the other bound is on, the
    /// From picker stops at the end of the To day and the To picker starts at
    /// the start of the From day. The range always contains the picker's own
    /// date, so a stored range that already ends before it starts is shown
    /// as stored rather than moved by the picker.
    func selectableDates(for bound: Bound, calendar: Calendar) -> ClosedRange<Date> {
        let own = pickerDate(for: bound)
        let allowed = allowedDates(for: bound, calendar: calendar)
        return min(allowed.lowerBound, own)...max(allowed.upperBound, own)
    }

    /// Pick `date` for `bound`, which turns the bound on. The other bound is
    /// unchanged, so an open side stays open. A date beyond the other bound's
    /// day is clamped to that day.
    mutating func pick(_ date: Date, for bound: Bound, calendar: Calendar) {
        let allowed = allowedDates(for: bound, calendar: calendar)
        let clamped = min(max(date, allowed.lowerBound), allowed.upperBound)
        setDate(clamped, of: bound)
    }

    /// Turn `bound` on, at its remembered date clamped as `pick` clamps, or
    /// off. Turning off the only bound that is on changes nothing.
    mutating func setIncluded(_ isIncluded: Bool, for bound: Bound, calendar: Calendar) {
        guard isIncluded != includes(bound) else { return }
        if isIncluded {
            pick(rememberedDate(of: bound), for: bound, calendar: calendar)
        } else if canExclude(bound) {
            switch bound {
            case .start: start = nil
            case .end: end = nil
            }
        }
    }

    // MARK: - Private

    private func date(of bound: Bound) -> Date? {
        switch bound {
        case .start: return start
        case .end: return end
        }
    }

    private func rememberedDate(of bound: Bound) -> Date {
        switch bound {
        case .start: return rememberedStart
        case .end: return rememberedEnd
        }
    }

    private mutating func setDate(_ date: Date, of bound: Bound) {
        switch bound {
        case .start:
            start = date
            rememberedStart = date
        case .end:
            end = date
            rememberedEnd = date
        }
    }

    /// The dates `bound` may take without ending the range on a day before
    /// the day it starts: bounded by the other bound's day while it is on.
    private func allowedDates(for bound: Bound, calendar: Calendar) -> ClosedRange<Date> {
        switch bound {
        case .start:
            guard let end else { return Date.distantPast...Date.distantFuture }
            return Date.distantPast...Self.lastInstant(ofDayOf: end, calendar: calendar)
        case .end:
            guard let start else { return Date.distantPast...Date.distantFuture }
            return calendar.startOfDay(for: start)...Date.distantFuture
        }
    }

    /// The last second of `date`'s calendar day: one second before the next
    /// day starts, as the calendar counts days across a daylight-saving
    /// change.
    private static func lastInstant(ofDayOf date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return max(startOfDay, nextDay.addingTimeInterval(-1))
    }
}

extension WorkoutLibraryCustomDateRange.Bound {
    fileprivate var other: Self {
        switch self {
        case .start: return .end
        case .end: return .start
        }
    }
}
