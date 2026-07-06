import Foundation

/// Service for comparing two workouts.
///
/// Provides distance-based comparison without complex route matching.
/// Handles different workout distances, missing data, and edge cases safely.
public struct WorkoutComparisonService {

    public init() {}

    /// Compare two workouts and produce a summary.
    public func compare(primary: RunWorkout, comparison: RunWorkout) -> WorkoutComparisonSummary {
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

        let maxHRDelta: Double?
        if let pHR = primarySummary.maxHeartRateBPM, let cHR = comparisonSummary.maxHeartRateBPM {
            maxHRDelta = pHR - cHR
        } else {
            maxHRDelta = nil
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
            maxHRDelta: maxHRDelta,
            primaryPointCount: primary.routePoints.count,
            comparisonPointCount: comparison.routePoints.count,
            warnings: warnings
        )
    }

    /// Compare splits between two workouts.
    public func compareSplits(primary: RunWorkout, comparison: RunWorkout) -> [SplitComparison] {
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
    public func compareMetricsOverDistance(
        primary: RunWorkout,
        comparison: RunWorkout,
        sampleIntervalMeters: Double = 100
    ) -> [ComparisonMetricPoint] {
        let primaryPoints = primary.routePoints
        let comparisonPoints = comparison.routePoints

        guard !primaryPoints.isEmpty && !comparisonPoints.isEmpty else {
            return []
        }
        guard sampleIntervalMeters.isFinite && sampleIntervalMeters > 0 else {
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
            let primaryPoint = RoutePointInterpolator.point(at: distance, in: primaryPoints)
            let comparisonPoint = RoutePointInterpolator.point(at: distance, in: comparisonPoints)

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
                primaryPace: finite(primaryPoint?.paceSecondsPerKilometer),
                comparisonPace: finite(comparisonPoint?.paceSecondsPerKilometer),
                paceDelta: paceDelta,
                primaryElevation: finite(primaryPoint?.altitudeMeters),
                comparisonElevation: finite(comparisonPoint?.altitudeMeters),
                primaryHR: finite(primaryPoint?.heartRateBPM),
                comparisonHR: finite(comparisonPoint?.heartRateBPM)
            ))

            distance += sampleIntervalMeters
        }

        return points
    }

    // MARK: - Distance Selection

    /// Maximum common distance for both routes, clamped to zero if either has no data.
    public func commonDistance(primary: RunWorkout, comparison: RunWorkout) -> Double {
        let pd = primary.routePoints.last?.distanceFromStartMeters ?? 0
        let cd = comparison.routePoints.last?.distanceFromStartMeters ?? 0
        return max(0, min(pd, cd))
    }

    /// Compute comparison metrics at a selected distance along both routes.
    ///
    /// Interpolates between the two nearest points on each route.
    /// Returns `nil` values for metrics when route data is missing or non-finite.
    public func metricsAtDistance(
        _ selectedDistance: Double,
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryScenePoints: [RouteScenePoint] = [],
        comparisonScenePoints: [RouteScenePoint] = []
    ) -> ComparisonDistanceMetrics {
        guard selectedDistance >= 0, selectedDistance.isFinite else {
            return ComparisonDistanceMetrics(
                selectedDistanceMeters: 0,
                primaryElapsedSeconds: nil, comparisonElapsedSeconds: nil,
                timeDeltaSeconds: nil,
                primaryPaceSecondsPerKm: nil, comparisonPaceSecondsPerKm: nil,
                paceDeltaSecondsPerKm: nil,
                primaryScenePoint: nil, comparisonScenePoint: nil
            )
        }

        let primaryInterp = RoutePointInterpolator.point(at: selectedDistance, in: primary.routePoints)
        let comparisonInterp = RoutePointInterpolator.point(at: selectedDistance, in: comparison.routePoints)

        let primaryElapsed = finite(primaryInterp?.elapsedSeconds)
        let comparisonElapsed = finite(comparisonInterp?.elapsedSeconds)
        let timeDelta: Double?
        if let pe = primaryElapsed, let ce = comparisonElapsed {
            timeDelta = pe - ce
        } else {
            timeDelta = nil
        }

        let primaryPace = finite(primaryInterp?.paceSecondsPerKilometer)
        let comparisonPace = finite(comparisonInterp?.paceSecondsPerKilometer)
        let paceDelta: Double?
        if let pp = primaryPace, let cp = comparisonPace {
            paceDelta = pp - cp
        } else {
            paceDelta = nil
        }

        let primaryScene = RoutePointInterpolator.scenePoint(at: selectedDistance, in: primaryScenePoints)
        let comparisonScene = RoutePointInterpolator.scenePoint(at: selectedDistance, in: comparisonScenePoints)

        return ComparisonDistanceMetrics(
            selectedDistanceMeters: selectedDistance,
            primaryElapsedSeconds: primaryElapsed,
            comparisonElapsedSeconds: comparisonElapsed,
            timeDeltaSeconds: timeDelta,
            primaryPaceSecondsPerKm: primaryPace,
            comparisonPaceSecondsPerKm: comparisonPace,
            paceDeltaSecondsPerKm: paceDelta,
            primaryScenePoint: primaryScene,
            comparisonScenePoint: comparisonScene
        )
    }

    // MARK: - Helpers

    private func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
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

        if routeEndpointsDiffer(primary: primary, comparison: comparison) {
            warnings.append(.differentRouteShape)
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

    private func routeEndpointsDiffer(primary: RunWorkout, comparison: RunWorkout) -> Bool {
        let commonDistance = min(primary.summary.totalDistanceMeters, comparison.summary.totalDistanceMeters)
        guard commonDistance > 0 else {
            return false
        }

        let threshold = max(200, min(commonDistance * 0.1, 1_000))
        let sampleDistances = [0, commonDistance * 0.5, commonDistance]

        return sampleDistances.contains { distance in
            guard
                let primaryPoint = RoutePointInterpolator.point(at: distance, in: primary.routePoints),
                let comparisonPoint = RoutePointInterpolator.point(at: distance, in: comparison.routePoints)
            else {
                return false
            }
            return coordinateDistance(primaryPoint, comparisonPoint) > threshold
        }
    }

    private func coordinateDistance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        guard GeoDistance.isValidCoordinate(lat: a.latitude, lon: a.longitude),
              GeoDistance.isValidCoordinate(lat: b.latitude, lon: b.longitude) else {
            return .infinity
        }

        return GeoDistance.distanceMeters(
            fromLat: a.latitude,
            lon: a.longitude,
            toLat: b.latitude,
            lon: b.longitude
        )
    }
}
