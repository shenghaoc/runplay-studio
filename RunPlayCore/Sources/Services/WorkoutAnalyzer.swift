import Foundation

/// Analyzes a workout and populates derived metrics.
///
/// This is a pure logic service with no side effects beyond modifying the workout.
/// Uses platform-neutral `GeoDistance` instead of CoreLocation.
public struct WorkoutAnalyzer: Sendable {

    public init() {}

    /// Valid heart rate range for filtering outliers.
    public static let validHeartRateRange: ClosedRange<Double> = 30...230

    /// Analyze a workout in-place, calculating summary, splits, and segments.
    ///
    /// Precondition: `workout.routePoints` must already be normalized via
    /// `RoutePointSanitizer.normalize()`. All importers (JSON, GPX, TCX, FIT)
    /// perform normalization before calling this method.
    public func analyze(_ workout: inout RunWorkout) {
        calculateDerivedMetrics(&workout)
        workout.summary = calculateSummary(workout)
        workout.splits = SplitCalculator.calculateSplits(from: workout)
        workout.segments = SegmentDetector.detectSegments(from: workout)
    }

    /// Calculate derived metrics for each route point (speed, pace).
    ///
    /// Skips computation across segment boundaries so no fake speed or pace
    /// is generated between disconnected route segments.
    private func calculateDerivedMetrics(_ workout: inout RunWorkout) {
        let points = workout.routePoints
        guard points.count >= 2 else { return }

        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]

            // Skip cross-segment-boundary computation.
            guard curr.routeSegmentIndex == prev.routeSegmentIndex else { continue }

            // Calculate speed if not already set
            if workout.routePoints[i].speedMetersPerSecond == nil {
                let distance = GeoDistance.distanceMeters(
                    fromLat: prev.latitude, lon: prev.longitude,
                    toLat: curr.latitude, lon: curr.longitude
                )
                let time = curr.elapsedSeconds - prev.elapsedSeconds
                if time > 0 {
                    workout.routePoints[i].speedMetersPerSecond = distance / time
                }
            }

            // Calculate pace if not already set
            if workout.routePoints[i].paceSecondsPerKilometer == nil,
               let speed = workout.routePoints[i].speedMetersPerSecond, speed > 0 {
                workout.routePoints[i].paceSecondsPerKilometer = 1000.0 / speed
            }
        }
    }

    /// Calculate overall workout summary.
    private func calculateSummary(_ workout: RunWorkout) -> RunSummary {
        let points = workout.routePoints
        guard !points.isEmpty else { return RunSummary() }

        let totalDistance = points.last?.distanceFromStartMeters ?? 0
        let totalTime = points.last?.elapsedSeconds ?? 0

        // Average pace
        let avgPace: Double
        if totalDistance > 0 && totalTime > 0 {
            avgPace = (totalTime / totalDistance) * 1000.0
        } else {
            avgPace = 0
        }

        // Average speed
        let avgSpeed: Double
        if totalTime > 0 && totalDistance > 0 {
            avgSpeed = totalDistance / totalTime
        } else {
            avgSpeed = 0
        }

        // Elevation (simple sum of positive/negative deltas)
        // Skip deltas across segment boundaries.
        var elevGain: Double = 0
        var elevLoss: Double = 0
        var prevAltitude: Double?
        var prevSegmentIndex: Int?

        for point in points {
            if let alt = point.altitudeMeters, let prev = prevAltitude,
               alt.isFinite, prev.isFinite,
               point.routeSegmentIndex == prevSegmentIndex {
                let diff = alt - prev
                if diff > 0 {
                    elevGain += diff
                } else {
                    elevLoss += abs(diff)
                }
            }
            prevAltitude = point.altitudeMeters
            prevSegmentIndex = point.routeSegmentIndex
        }

        // Heart rate - filter to valid range to exclude outliers
        let hrValues = points.compactMap { $0.heartRateBPM }
            .filter { Self.validHeartRateRange.contains($0) && $0.isFinite }
        let avgHR = hrValues.isEmpty ? nil : hrValues.reduce(0, +) / Double(hrValues.count)
        let maxHR = hrValues.max()

        return RunSummary(
            totalDistanceMeters: totalDistance,
            totalElapsedSeconds: totalTime,
            averagePaceSecondsPerKilometer: avgPace,
            averageSpeedMetersPerSecond: avgSpeed,
            elevationGainMeters: elevGain,
            elevationLossMeters: elevLoss,
            averageHeartRateBPM: avgHR,
            maxHeartRateBPM: maxHR
        )
    }

    /// Calculate distance between two route points using platform-neutral haversine.
    public func calculateDistance(from: RoutePoint, to: RoutePoint) -> Double {
        GeoDistance.distanceMeters(
            fromLat: from.latitude, lon: from.longitude,
            toLat: to.latitude, lon: to.longitude
        )
    }
}
