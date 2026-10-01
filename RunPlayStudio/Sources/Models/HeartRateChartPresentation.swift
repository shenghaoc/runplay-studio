import Foundation
import RunPlayCore

/// One heart-rate reading on an elapsed-time axis.
struct HeartRateTimePoint: Identifiable, Equatable {
    let id: Int
    /// Minutes since the workout began.
    let minutes: Double
    let bpm: Double
    /// Readings in different series are not joined by a line: a recording gap
    /// starts a new series, as it does on the distance charts.
    let seriesID: Int
}

/// How a workout's heart rate is charted, decided from where that heart rate
/// lives.
///
/// Heart rate lives in one of two places: on the route points (FIT, TCX, GPX,
/// JSON), or in the standalone series an Apple Health export run carries,
/// because its route GPX holds none. The plan reads it through the workout's
/// single heart-rate accessor, so a chart cannot disagree with replay or the
/// summary about which readings a run has.
enum HeartRateChartPlan: Equatable {

    /// No usable reading anywhere: the chart says so.
    case none

    /// Heart rate rides on the route points. Charted per point over distance,
    /// smoothed, exactly as it always was.
    case routePoints

    /// A standalone series on a run that has a route. Each route point takes
    /// the reading that applies at its own time, by the accessor's hold rule, so
    /// the chart stays on the distance axis every other metric uses and its
    /// cursor and scrub readout agree with replay.
    ///
    /// The readings are held, not interpolated and not smoothed: a held step is
    /// what the source reported, and an average of two readings is a number it
    /// never produced.
    case alignedToRoute(valuesByRoutePoint: [Double?], readings: [Double])

    /// A standalone series on a run with no route. There is no distance to plot
    /// against, so the readings are charted over elapsed time.
    case timeDomain(points: [HeartRateTimePoint])

    // MARK: - Deciding the plan

    static func plan(for workout: RunWorkout) -> HeartRateChartPlan {
        switch workout.heartRateSampleSource {
        case .none:
            return .none
        case .routePoints:
            return .routePoints
        case .standaloneSeries:
            if workout.hasRoute {
                let readings = workout.heartRateSamples.compactMap { validReading($0.heartRateBPM) }
                guard !readings.isEmpty else { return .none }
                let values = workout.routePoints.indices.map { index in
                    validReading(workout.heartRateBPM(atRoutePointIndex: index))
                }
                return .alignedToRoute(valuesByRoutePoint: values, readings: readings)
            }
            // A series whose readings are all invalid, or whose times are not
            // numbers, has nothing to plot: say so rather than draw an empty
            // chart under a title that promises one.
            let points = timePoints(from: workout.heartRateSamples)
            return points.isEmpty ? .none : .timeDomain(points: points)
        }
    }

    /// The valid readings of a series on an elapsed-time axis.
    ///
    /// A reading outside the accepted range is a missing reading, not a value,
    /// so it ends the line rather than being drawn through.
    static func timePoints(from samples: [HeartRateSample]) -> [HeartRateTimePoint] {
        var points: [HeartRateTimePoint] = []
        var seriesID = 0
        var previousSegment: Int?
        for sample in samples {
            guard sample.elapsedSeconds.isFinite, let bpm = validReading(sample.heartRateBPM) else {
                previousSegment = nil
                continue
            }
            if sample.segmentIndex != previousSegment { seriesID += 1 }
            previousSegment = sample.segmentIndex
            points.append(HeartRateTimePoint(
                id: points.count,
                minutes: max(0, sample.elapsedSeconds) / 60,
                bpm: bpm,
                seriesID: seriesID
            ))
        }
        return points
    }

    private static func validReading(_ bpm: Double?) -> Double? {
        guard let bpm, bpm.isFinite, MetricValidation.isValidHeartRate(bpm) else { return nil }
        return bpm
    }

    // MARK: - What the chart view needs from the plan

    /// Whether the metric picker should open on Heart Rate.
    ///
    /// True only for a run with no route: elevation, pace, power and speed are
    /// all read off route points, so heart rate is the one chart that has
    /// anything to show. A run with a route opens where every routed run does.
    var opensOnHeartRate: Bool {
        if case .timeDomain = self { return true }
        return false
    }

    /// Whether replacing one plan with another should move the picker to Heart
    /// Rate. The chart view is reused as the selection changes, so a route-less
    /// run selected after a routed one must not inherit that run's empty
    /// metric; a choice the user made on the same kind of run is left alone.
    static func movesPickerToHeartRate(from previous: HeartRateChartPlan, to current: HeartRateChartPlan) -> Bool {
        current.opensOnHeartRate && !previous.opensOnHeartRate
    }

    /// The held reading at every route point, for a standalone series charted
    /// against distance. Nil for every other plan.
    var heldValuesByRoutePoint: [Double?]? {
        if case .alignedToRoute(let values, _) = self { return values }
        return nil
    }

    /// The readings a standalone series on a routed run actually holds, for the
    /// chart's spoken range and average. These are the readings the summary's
    /// average is taken over, not the route-point repetitions of them, so the
    /// header and the spoken summary cannot disagree.
    var reportedReadings: [Double]? {
        if case .alignedToRoute(_, let readings) = self { return readings }
        return nil
    }

    /// The readings the time-domain chart draws. Nil for every other plan.
    var timeDomainPoints: [HeartRateTimePoint]? {
        if case .timeDomain(let points) = self { return points }
        return nil
    }
}

/// Everything the time-domain heart-rate chart shows and says, derived once
/// from its points.
///
/// The distance charts speak through `ChartAccessibilityModel`, whose summary
/// always ends with a distance. A run charted over time has none, so this says
/// the same things in time.
struct TimeDomainHeartRateChartModel: Equatable {
    let points: [HeartRateTimePoint]
    let minimum: Double
    let maximum: Double
    let average: Double
    let durationMinutes: Double
    let sectionCount: Int

    var title: String { "Heart Rate over time chart" }

    /// Gaps between sections, which break the line.
    var gapCount: Int { max(0, sectionCount - 1) }

    /// Past this many readings a mark per reading only blurs into the line and
    /// costs the chart time, so the line stands alone.
    static let maximumMarkedReadings = 400

    /// Whether each reading is drawn as a mark as well as part of the line.
    /// With few enough readings to tell apart, marking them keeps a sparse
    /// series reading as readings, not as a curve nobody measured.
    var marksEachReading: Bool { points.count <= Self.maximumMarkedReadings }

    var spokenSummary: String {
        var parts = [
            title + ".",
            "Time in minutes.",
            "Heart rate in bpm.",
            "Range \(Self.bpm(minimum)) to \(Self.bpm(maximum)).",
            "Average \(Self.bpm(average)).",
            "\(points.count) \(points.count == 1 ? "reading" : "readings") over \(Self.minutes(durationMinutes))."
        ]
        if gapCount > 0 {
            parts.append("\(gapCount) recording \(gapCount == 1 ? "gap breaks" : "gaps break") the series.")
        }
        return parts.joined(separator: " ")
    }

    /// Nil when there is nothing to chart.
    static func make(points: [HeartRateTimePoint]) -> TimeDomainHeartRateChartModel? {
        guard let first = points.first else { return nil }
        let values = points.map(\.bpm)
        return TimeDomainHeartRateChartModel(
            points: points,
            minimum: values.min() ?? first.bpm,
            maximum: values.max() ?? first.bpm,
            average: values.reduce(0, +) / Double(values.count),
            durationMinutes: points.map(\.minutes).max() ?? 0,
            sectionCount: Set(points.map(\.seriesID)).count
        )
    }

    private static func bpm(_ value: Double) -> String {
        "\(Int(value.rounded())) bpm"
    }

    private static func minutes(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded) \(rounded == 1 ? "minute" : "minutes")"
    }
}
