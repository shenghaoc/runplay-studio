import Foundation
import CoreLocation

/// Analyzes a workout and populates derived metrics.
///
/// This is a pure logic service with no side effects beyond modifying the workout.
class WorkoutAnalyzer {

    /// Analyze a workout in-place, calculating summary, splits, and segments.
    func analyze(_ workout: inout RunWorkout) {
        calculateDerivedMetrics(&workout)
        workout.summary = calculateSummary(workout)
        workout.splits = SplitCalculator.calculateSplits(from: workout)
        workout.segments = SegmentDetector.detectSegments(from: workout)
    }

    /// Calculate derived metrics for each route point (speed, pace).
    private func calculateDerivedMetrics(_ workout: inout RunWorkout) {
        let points = workout.routePoints
        guard points.count >= 2 else { return }

        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]

            // Calculate speed if not already set
            if workout.routePoints[i].speedMetersPerSecond == nil {
                let distance = calculateDistance(from: prev, to: curr)
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
        if totalDistance > 0 {
            avgPace = (totalTime / totalDistance) * 1000.0
        } else {
            avgPace = 0
        }

        // Average speed
        let avgSpeed: Double
        if totalTime > 0 {
            avgSpeed = totalDistance / totalTime
        } else {
            avgSpeed = 0
        }

        // Elevation
        var elevGain: Double = 0
        var elevLoss: Double = 0
        var prevAltitude: Double?

        for point in points {
            if let alt = point.altitudeMeters, let prev = prevAltitude {
                let diff = alt - prev
                if diff > 0 {
                    elevGain += diff
                } else {
                    elevLoss += abs(diff)
                }
            }
            prevAltitude = point.altitudeMeters
        }

        // Heart rate
        let hrValues = points.compactMap { $0.heartRateBPM }
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

    /// Calculate distance between two route points using CoreLocation.
    func calculateDistance(from: RoutePoint, to: RoutePoint) -> Double {
        let fromLoc = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let toLoc = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return fromLoc.distance(from: toLoc)
    }
}
