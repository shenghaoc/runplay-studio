import Foundation
import RunPlayCore

/// What the run detail says about where a run's distance came from.
///
/// A route measures distance; a route-less run can only repeat what its source
/// reported. The detail says which it is, so a number nothing here measured is
/// never read as one that was.
enum DistanceProvenancePresentation {

    /// The label for a distance the source reported, or nil for a GPS-derived
    /// distance, which needs none.
    static func label(for workout: RunWorkout) -> String? {
        guard workout.summary.distanceProvenance == .sourceReported else { return nil }
        let fromHealth = workout.source == .healthKit
        guard reportsDistance(workout) else {
            return fromHealth
                ? studioLocalized("No distance from Apple Health (no GPS route)")
                : studioLocalized("No distance reported by the source (no GPS route)")
        }
        return fromHealth
            ? studioLocalized("Distance from Apple Health (no GPS route)")
            : studioLocalized("Distance reported by the source (no GPS route)")
    }

    /// Help for the Distance metric. "Total recorded route distance" is only
    /// true of a distance measured along a route.
    static func distanceHelp(for workout: RunWorkout) -> String {
        guard workout.summary.distanceProvenance == .sourceReported else {
            return studioLocalized("Total recorded route distance.")
        }
        // Whole sentences, one per source, so a translator can reorder each.
        let fromHealth = workout.source == .healthKit
        guard reportsDistance(workout) else {
            return fromHealth
                ? studioLocalized("Apple Health reported no distance for this run, and it has no GPS route to measure one.")
                : studioLocalized("The source reported no distance for this run, and it has no GPS route to measure one.")
        }
        return fromHealth
            ? studioLocalized("Distance reported by Apple Health. This run has no GPS route, so RunPlay Studio did not measure it.")
            : studioLocalized("Distance reported by the source. This run has no GPS route, so RunPlay Studio did not measure it.")
    }

    /// A run imported with only a duration keeps a zero distance and is still
    /// source-reported, because its time is. That zero is no distance, not one
    /// the source reported.
    private static func reportsDistance(_ workout: RunWorkout) -> Bool {
        let meters = workout.summary.totalDistanceMeters
        return meters.isFinite && meters > 0
    }
}

/// The notice above a run that has no GPS route.
///
/// Says what a route-less run does have, so the banner does not promise a
/// metric (cadence lives on route points) the run cannot carry.
enum RouteLessNoticePresentation {

    static func message(hasHeartRate: Bool) -> String {
        hasHeartRate
            ? studioLocalized("No GPS route — heart rate and summary metrics are available. The map, replay, splits and segments need a route.")
            : studioLocalized("No GPS route — only summary metrics are available. The map, replay, splits and segments need a route.")
    }

    /// What the Overview shows in place of a map it has no route to draw on.
    static var mapTitle: String { studioLocalized("No GPS route") }

    static func mapDetail(hasHeartRate: Bool) -> String {
        hasHeartRate
            ? studioLocalized("This run has no route to draw, so there is no map or replay. Its heart rate is on the Charts tab.")
            : studioLocalized("This run has no route to draw, so there is no map or replay.")
    }
}

/// The Splits tab's wording.
///
/// Calculated distance splits are walked along a route's cumulative distance,
/// so a run with no route can have none, and the tab says that instead of
/// showing an empty table under a sentence that promises splits.
enum SplitsPresentation {

    static var needsRouteMessage: String {
        studioLocalized("Splits need a GPS route. This run has none, so there are no distance splits to show.")
    }

    static let noRecordedLapsMessage =
        studioLocalized("No recorded laps in this file. Calculated distance splits are still available.")

    /// What the Distance Splits view shows.
    enum DistanceSplitsContent: Equatable {
        case table
        case needsRoute
    }

    static func distanceSplitsContent(hasRoute: Bool) -> DistanceSplitsContent {
        hasRoute ? .table : .needsRoute
    }

    /// The line under the header when the file has no recorded laps to switch
    /// to, or nil when there is nothing to add. Without a route it is nil
    /// because "calculated distance splits are still available" would be
    /// false: the needs-route message stands in for the table instead.
    static func noRecordedLapsNotice(hasRoute: Bool, hasRecordedLaps: Bool) -> String? {
        guard hasRoute, !hasRecordedLaps else { return nil }
        return noRecordedLapsMessage
    }
}

/// The average heart rate a header or list row shows.
///
/// One rule for both places: a summary that has no average has nothing to show,
/// and zero or a non-finite number is not an average.
enum AverageHeartRateDisplay {

    static func value(for summary: RunSummary) -> Double? {
        guard let bpm = summary.averageHeartRateBPM, bpm.isFinite, bpm > 0 else { return nil }
        return bpm
    }
}
