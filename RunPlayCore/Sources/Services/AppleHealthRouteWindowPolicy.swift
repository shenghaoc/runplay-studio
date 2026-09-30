import Foundation

/// Time-window decisions for a chronologically normalized GPX route.
/// Selection uses two binary searches; numeric route analysis stays in the
/// existing bulk normalization pipeline.
public enum AppleHealthRouteWindowPolicy {
    public enum Decision: Equatable, Sendable {
        case keep
        case trim(Range<Int>)
        case mismatch
    }

    public static let toleranceSeconds: Double = 60
    public static let maximumOverrunSeconds: Double = 300

    public static func decision(
        for points: [RoutePoint], window: AppleHealthWorkoutWindow
    ) -> Decision {
        guard points.count >= 2, let first = points.first, let last = points.last else { return .mismatch }
        let start = Double(window.startSeconds), end = Double(window.endSeconds)
        let routeStart = first.timestamp.timeIntervalSince1970
        let routeEnd = last.timestamp.timeIntervalSince1970
        guard routeStart.isFinite, routeEnd.isFinite, start <= end, routeStart <= routeEnd,
              routeStart <= end, routeEnd >= start else { return .mismatch }
        let low = start - toleranceSeconds, high = end + toleranceSeconds
        if routeStart >= low, routeEnd <= high { return .keep }
        guard start - routeStart <= maximumOverrunSeconds,
              routeEnd - end <= maximumOverrunSeconds else { return .mismatch }

        let lower = boundary(in: points, seconds: low, afterEqual: false)
        let upper = boundary(in: points, seconds: high, afterEqual: true)
        guard upper - lower >= 2 else { return .mismatch }
        return .trim(lower..<upper)
    }

    private static func boundary(in points: [RoutePoint], seconds: Double, afterEqual: Bool) -> Int {
        var low = 0, high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            let time = points[middle].timestamp.timeIntervalSince1970
            if time < seconds || (afterEqual && time == seconds) { low = middle + 1 }
            else { high = middle }
        }
        return low
    }
}
