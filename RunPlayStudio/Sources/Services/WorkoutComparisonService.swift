import Foundation

/// Service for comparing two workouts.
///
/// Provides distance-based comparison without complex route matching.
/// Handles different workout distances, missing data, and edge cases safely.
struct WorkoutComparisonService {

    /// Compare two workouts and produce a summary.
    func compare(primary: RunWorkout, comparison: RunWorkout) -> WorkoutComparisonSummary {
        let primarySummary = primary.summary
        let comparisonSummary = comparison.summary

        // Distance delta
        let distanceDelta = primarySummary.totalDistanceMeters - comparisonSummary.totalDistanceMeters

        // Duration delta
        let durationDelta = primarySummary.totalElapsedSeconds - comparisonSummary.totalElapsedSeconds

        // Pace delta
        let paceDelta = primarySummary.averagePaceSecondsPerKilometer - comparisonSummary.averagePaceSecondsPerKilometer

        // Elevation delta
        let elevDelta = primarySummary.elevationGainMeters - comparisonSummary.elevationGainMeters

        // Heart rate deltas
        let avgHRDelta: Double?
        if let pHR = primarySummary.averageHeartRateBPM, let cHR = comparisonSummary.averageHeartRateBPM {
            avgHRDelta = pHR - cHR
        } else {
            avgHRDelta = nil
        }

        // Generate warnings
        let warnings = generateWarnings(primary: primary, comparison: comparison)

        return WorkoutComparisonSummary(
            primaryTitle: primary.displayName,
            comparisonTitle: comparison.displayName,
            primaryDistanceMeters: primarySummary.totalDistanceMeters,
            comparisonDistanceMeters: comparisonSummary.totalDistanceMeters,
            distanceDeltaMeters: distanceDelta,
            primaryDurationSeconds: primarySummary.totalElapsedSeconds,
            comparisonDurationSeconds: comparisonSummary.totalElapsedSeconds,
            durationDeltaSeconds: durationDelta,
            primaryPaceSecondsPerKm: primarySummary.averagePaceSecondsPerKilometer,
            comparisonPaceSecondsPerKm: comparisonSummary.averagePaceSecondsPerKilometer,
            paceDeltaSecondsPerKm: paceDelta,
            primaryElevationGainMeters: primarySummary.elevationGainMeters,
            comparisonElevationGainMeters: comparisonSummary.elevationGainMeters,
            elevationGainDeltaMeters: elevDelta,
            primaryAvgHR: primarySummary.averageHeartRateBPM,
            comparisonAvgHR: comparisonSummary.averageHeartRateBPM,
            avgHRDelta: avgHRDelta,
            primaryMaxHR: primarySummary.maxHeartRateBPM,
            comparisonMaxHR: comparisonSummary.maxHeartRateBPM,
            primaryPointCount: primary.routePoints.count,
            comparisonPointCount: comparison.routePoints.count,
            warnings: warnings
        )
    }

    /// Compare splits between two workouts.
    func compareSplits(primary: RunWorkout, comparison: RunWorkout) -> [SplitComparison] {
        let maxSplits = max(primary.splits.count, comparison.splits.count)
        var comparisons: [SplitComparison] = []

        for i in 0..<maxSplits {
            let primarySplit = i < primary.splits.count ? primary.splits[i] : nil
            let comparisonSplit = i < comparison.splits.count ? comparison.splits[i] : nil

            let durationDelta: Double?
            let paceDelta: Double?
            let winner: ComparisonResult

            if let p = primarySplit, let c = comparisonSplit {
                durationDelta = p.elapsedSeconds - c.elapsedSeconds
                paceDelta = p.paceSecondsPerKilometer - c.paceSecondsPerKilometer

                if let pd = paceDelta, abs(pd) < 5 {
                    winner = .tie
                } else if let pd = paceDelta {
                    winner = pd > 0 ? .comparison : .primary
                } else {
                    winner = .unavailable
                }
            } else {
                durationDelta = nil
                paceDelta = nil
                winner = .unavailable
            }

            comparisons.append(SplitComparison(
                splitIndex: i + 1,
                primarySplit: primarySplit,
                comparisonSplit: comparisonSplit,
                durationDeltaSeconds: durationDelta,
                paceDeltaSecondsPerKm: paceDelta,
                winner: winner
            ))
        }

        return comparisons
    }

    /// Generate pace comparison metric series over distance.
    ///
    /// Aligns by distance, sampling at regular intervals.
    /// Clamps to common distance range.
    func compareMetricsOverDistance(
        primary: RunWorkout,
        comparison: RunWorkout,
        sampleIntervalMeters: Double = 100
    ) -> [ComparisonMetricPoint] {
        let primaryPoints = primary.routePoints
        let comparisonPoints = comparison.routePoints

        guard !primaryPoints.isEmpty && !comparisonPoints.isEmpty else {
            return []
        }

        // Use common distance range
        let maxDistance = min(
            primaryPoints.last?.distanceFromStartMeters ?? 0,
            comparisonPoints.last?.distanceFromStartMeters ?? 0
        )

        guard maxDistance > 0 else { return [] }

        var points: [ComparisonMetricPoint] = []
        var distance: Double = 0

        while distance <= maxDistance {
            let primaryPoint = findNearestPoint(at: distance, in: primaryPoints)
            let comparisonPoint = findNearestPoint(at: distance, in: comparisonPoints)

            let paceDelta: Double?
            if let pp = primaryPoint?.paceSecondsPerKilometer,
               let cp = comparisonPoint?.paceSecondsPerKilometer,
               pp.isFinite && cp.isFinite {
                paceDelta = pp - cp
            } else {
                paceDelta = nil
            }

            points.append(ComparisonMetricPoint(
                distanceMeters: distance,
                primaryPace: primaryPoint?.paceSecondsPerKilometer,
                comparisonPace: comparisonPoint?.paceSecondsPerKilometer,
                paceDelta: paceDelta,
                primaryElevation: primaryPoint?.altitudeMeters,
                comparisonElevation: comparisonPoint?.altitudeMeters,
                primaryHR: primaryPoint?.heartRateBPM,
                comparisonHR: comparisonPoint?.heartRateBPM
            ))

            distance += sampleIntervalMeters
        }

        return points
    }

    // MARK: - Helpers

    private func findNearestPoint(at distance: Double, in points: [RoutePoint]) -> RoutePoint? {
        guard !points.isEmpty else { return nil }

        var low = 0
        var high = points.count - 1

        while low < high {
            let mid = (low + high) / 2
            if points[mid].distanceFromStartMeters < distance {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low > 0 {
            let prevDiff = abs(points[low - 1].distanceFromStartMeters - distance)
            let currDiff = abs(points[low].distanceFromStartMeters - distance)
            return prevDiff < currDiff ? points[low - 1] : points[low]
        }

        return points[low]
    }

    private func generateWarnings(primary: RunWorkout, comparison: RunWorkout) -> [ComparisonWarning] {
        var warnings: [ComparisonWarning] = []

        let primaryDist = primary.summary.totalDistanceMeters
        let comparisonDist = comparison.summary.totalDistanceMeters

        // Different distances
        let distRatio = primaryDist > 0 ? comparisonDist / primaryDist : 0
        if distRatio < 0.7 || distRatio > 1.4 {
            warnings.append(.differentDistances)
        }

        // Insufficient overlap
        let commonDist = min(primaryDist, comparisonDist)
        if commonDist < 500 {
            warnings.append(.insufficientOverlap)
        }

        // Too few points
        if primary.routePoints.count < 10 || comparison.routePoints.count < 10 {
            warnings.append(.tooFewPoints)
        }

        // Missing heart rate
        if !primary.hasHeartRateData || !comparison.hasHeartRateData {
            warnings.append(.missingHeartRate)
        }

        // Missing elevation
        if !primary.hasAltitudeData || !comparison.hasAltitudeData {
            warnings.append(.missingElevation)
        }

        return warnings
    }
}
