import Foundation

/// Analyzes a normalized workout and populates derived metrics.
public struct WorkoutAnalyzer: Sendable {

    public init() {}

    public static let validHeartRateRange: ClosedRange<Double> = 30...230

    /// Analyze a workout in place using `WorkoutTimeline` as the sole time
    /// authority for the summary, splits, and notable pace windows.
    public func analyze(_ workout: inout RunWorkout) {
        let timeline = WorkoutTimeline(workout: workout)
        calculateDerivedMetrics(&workout, timeline: timeline)
        workout.summary = calculateSummary(workout, timeline: timeline)
        workout.splits = SplitCalculator.calculateSplits(from: workout, timeline: timeline)
        workout.segments = SegmentDetector.detectSegments(from: workout, timeline: timeline)
        workout.analysisVersion = RunWorkout.currentAnalysisVersion
    }

    /// Recompute stale persisted analysis while preserving the exact stored
    /// route-point payload, including IDs and optional source metrics.
    public func reanalyzePreservingRoutePoints(_ workout: inout RunWorkout) {
        let storedRoutePoints = workout.routePoints
        analyze(&workout)
        workout.routePoints = storedRoutePoints
    }

    private func calculateDerivedMetrics(_ workout: inout RunWorkout, timeline: WorkoutTimeline) {
        let points = workout.routePoints
        guard points.count >= 2 else { return }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            guard current.routeSegmentIndex == previous.routeSegmentIndex,
                  let previousElapsed = timeline.elapsedSeconds(atPointIndex: index - 1),
                  let currentElapsed = timeline.elapsedSeconds(atPointIndex: index)
            else {
                continue
            }

            if workout.routePoints[index].speedMetersPerSecond == nil {
                let distance = GeoDistance.distanceMeters(
                    fromLat: previous.latitude,
                    lon: previous.longitude,
                    toLat: current.latitude,
                    lon: current.longitude
                )
                let elapsed = currentElapsed - previousElapsed
                if distance.isFinite, distance >= 0, elapsed.isFinite, elapsed > 0 {
                    workout.routePoints[index].speedMetersPerSecond = distance / elapsed
                }
            }

            if workout.routePoints[index].paceSecondsPerKilometer == nil,
               let speed = workout.routePoints[index].speedMetersPerSecond,
               speed.isFinite,
               speed > 0 {
                workout.routePoints[index].paceSecondsPerKilometer = 1000.0 / speed
            }
        }
    }

    private func calculateSummary(_ workout: RunWorkout, timeline: WorkoutTimeline) -> RunSummary {
        let points = workout.routePoints
        guard !points.isEmpty else { return RunSummary() }

        let totalDistance = timeline.totalDistanceMeters
        let activePace = Self.pace(seconds: timeline.totalActiveSeconds, distanceMeters: totalDistance)
        let elapsedPace = Self.pace(seconds: timeline.totalElapsedSeconds, distanceMeters: totalDistance)
        let activeSpeed = Self.speed(distanceMeters: totalDistance, seconds: timeline.totalActiveSeconds)
        let elapsedSpeed = Self.speed(distanceMeters: totalDistance, seconds: timeline.totalElapsedSeconds)

        var elevationGain: Double = 0
        var elevationLoss: Double = 0
        var previousAltitude: Double?
        var previousSegmentIndex: Int?

        for point in points {
            if let altitude = point.altitudeMeters,
               let previous = previousAltitude,
               altitude.isFinite,
               previous.isFinite,
               point.routeSegmentIndex == previousSegmentIndex {
                let difference = altitude - previous
                if difference > 0 {
                    elevationGain += difference
                } else {
                    elevationLoss += abs(difference)
                }
            }
            previousAltitude = point.altitudeMeters
            previousSegmentIndex = point.routeSegmentIndex
        }

        let heartRates = points.compactMap(\.heartRateBPM)
            .filter { Self.validHeartRateRange.contains($0) && $0.isFinite }
        let averageHeartRate = heartRates.isEmpty
            ? nil
            : heartRates.reduce(0, +) / Double(heartRates.count)

        return RunSummary(
            totalDistanceMeters: totalDistance,
            totalElapsedSeconds: timeline.totalElapsedSeconds,
            totalActiveSeconds: timeline.totalActiveSeconds,
            totalPausedSeconds: timeline.totalPausedSeconds,
            averagePaceSecondsPerKilometer: activePace,
            elapsedPaceSecondsPerKilometer: elapsedPace,
            averageSpeedMetersPerSecond: activeSpeed,
            elapsedAverageSpeedMetersPerSecond: elapsedSpeed,
            elevationGainMeters: elevationGain,
            elevationLossMeters: elevationLoss,
            averageHeartRateBPM: averageHeartRate,
            maxHeartRateBPM: heartRates.max()
        )
    }

    private static func pace(seconds: Double, distanceMeters: Double) -> Double {
        guard seconds.isFinite,
              seconds > 0,
              distanceMeters.isFinite,
              distanceMeters > 0
        else {
            return 0
        }
        return (seconds / distanceMeters) * 1000
    }

    private static func speed(distanceMeters: Double, seconds: Double) -> Double {
        guard seconds.isFinite,
              seconds > 0,
              distanceMeters.isFinite,
              distanceMeters > 0
        else {
            return 0
        }
        return distanceMeters / seconds
    }

    public func calculateDistance(from: RoutePoint, to: RoutePoint) -> Double {
        GeoDistance.distanceMeters(
            fromLat: from.latitude,
            lon: from.longitude,
            toLat: to.latitude,
            lon: to.longitude
        )
    }
}
