import Foundation
import RunPlayCore

/// Run count and date span of one route group — the secondary line under a
/// route's name in the All Runs route filter and the Personal Heatmap route
/// picker ("5 runs · Mar – Aug 2026"). It tells routes apart before
/// selecting even when their names are similar, and is derived on the fly
/// from library entries: nothing here is persisted.
struct RouteGroupMenuDetail: Equatable {
    var runCount: Int
    var firstRunDate: Date?
    var lastRunDate: Date?

    /// Details for every group with at least one member among `entries`,
    /// keyed by group id. One pass over the library; membership is the
    /// entry's `routeGroupID`, the same field the route filter evaluates, so
    /// the count always equals what selecting the route shows.
    static func details(for entries: [WorkoutLibraryEntry]) -> [UUID: RouteGroupMenuDetail] {
        var details: [UUID: RouteGroupMenuDetail] = [:]
        for entry in entries {
            guard let groupID = entry.routeGroupID else { continue }
            var detail = details[groupID] ?? RouteGroupMenuDetail(runCount: 0)
            detail.runCount += 1
            if let date = entry.startDate {
                detail.firstRunDate = min(detail.firstRunDate ?? date, date)
                detail.lastRunDate = max(detail.lastRunDate ?? date, date)
            }
            details[groupID] = detail
        }
        return details
    }

    /// "5 runs · Mar – Aug 2026", "1 run · Mar 2026", or just "5 runs" when
    /// no member has a date. Month precision: the line identifies a route,
    /// it does not replace the Routes workspace's statistics.
    func subtitle(
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let runs = "\(runCount) run\(runCount == 1 ? "" : "s")"
        guard let first = firstRunDate, let last = lastRunDate else {
            return runs
        }
        var monthCalendar = calendar
        monthCalendar.timeZone = timeZone
        let span: String
        if monthCalendar.isDate(first, equalTo: last, toGranularity: .month) {
            var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            style = style.month(.abbreviated).year()
            span = first.formatted(style)
        } else {
            var style = Date.IntervalFormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            style = style.month(.abbreviated).year()
            span = (first..<last).formatted(style)
        }
        return "\(runs) · \(span)"
    }
}
