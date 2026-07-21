import Foundation

/// Compatibility façade over `RouteMetricProfileBuilder` for legacy SceneKit callers.
///
/// Missing metric values remain missing (`NaN`); they are no longer replaced with
/// the workout median. Prefer `RouteMetricProfileBuilder` for new code.
public struct RouteColorMetrics: Sendable {
    private let builder = RouteMetricProfileBuilder()
    private let policy = RouteMetricColorPolicy.runningDefault

    public init() {}

    // MARK: - Pace

    /// Segment pace in seconds per kilometre aligned to `points.count - 1`.
    ///
    /// Cross-segment pairs and invalid intervals yield `NaN`. Values are not
    /// filled with a median.
    public func computeSegmentPace(points: [RouteScenePoint]) -> [Double] {
        guard points.count >= 2 else { return [] }
        let routePoints = routePoints(from: points)
        let context = WorkoutAnalysisContext(routePoints: routePoints, elevationProfile: ElevationProfile(routePoints: routePoints))
        guard let profile = try? builder.build(
            routePoints: routePoints,
            context: context,
            mode: .pace,
            policy: policy
        ) else {
            return Array(repeating: .nan, count: points.count - 1)
        }
        return mapProfileToAdjacentValues(points: points, profile: profile)
    }

    public func computePaceScale(points: [RouteScenePoint]) -> PaceColorScale? {
        guard points.count >= 2 else { return nil }
        let routePoints = routePoints(from: points)
        let context = WorkoutAnalysisContext(routePoints: routePoints, elevationProfile: ElevationProfile(routePoints: routePoints))
        guard let profile = try? builder.build(
            routePoints: routePoints,
            context: context,
            mode: .pace,
            policy: policy
        ),
        let scale = profile.scale
        else { return nil }

        return PaceColorScale(
            fastestPace: scale.lowerBound,
            medianPace: scale.median,
            slowestPace: scale.upperBound
        )
    }

    // MARK: - Heart Rate

    /// Segment HR values aligned to `points.count - 1`. Missing remains `NaN`.
    public func computeSegmentHeartRate(points: [RouteScenePoint]) -> [Double] {
        guard points.count >= 2 else { return [] }
        let routePoints = routePoints(from: points)
        let context = WorkoutAnalysisContext(routePoints: routePoints, elevationProfile: ElevationProfile(routePoints: routePoints))
        guard let profile = try? builder.build(
            routePoints: routePoints,
            context: context,
            mode: .heartRate,
            policy: policy
        ) else {
            return Array(repeating: .nan, count: points.count - 1)
        }
        return mapProfileToAdjacentValues(points: points, profile: profile)
    }

    public func computeHeartRateScale(points: [RouteScenePoint]) -> HeartRateColorScale? {
        guard points.count >= 2 else { return nil }
        let routePoints = routePoints(from: points)
        let context = WorkoutAnalysisContext(routePoints: routePoints, elevationProfile: ElevationProfile(routePoints: routePoints))
        guard let profile = try? builder.build(
            routePoints: routePoints,
            context: context,
            mode: .heartRate,
            policy: policy
        ),
        let scale = profile.scale
        else { return nil }

        return HeartRateColorScale(
            lowHR: scale.lowerBound,
            medianHR: scale.median,
            highHR: scale.upperBound
        )
    }

    public func hasHeartRateData(points: [RouteScenePoint]) -> Bool {
        var validCount = 0
        for point in points {
            if let hr = point.heartRateBPM, MetricValidation.isValidHeartRate(hr) {
                validCount += 1
                if validCount >= 2 { return true }
            }
        }
        return false
    }

    // MARK: - Helpers

    public func medianOf(_ values: [Double]) -> Double {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return .nan }
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return sorted[count / 2]
    }

    /// Map profile intervals onto adjacent scene-point pairs (including cross-segment NaNs).
    private func mapProfileToAdjacentValues(
        points: [RouteScenePoint],
        profile: RouteMetricProfile
    ) -> [Double] {
        var lookup: [Int: Double] = [:]
        lookup.reserveCapacity(profile.intervals.count)
        for interval in profile.intervals {
            if let value = interval.metricValue, value.isFinite {
                lookup[interval.startPointIndex] = value
            }
        }

        var result: [Double] = []
        result.reserveCapacity(points.count - 1)
        for i in 0..<(points.count - 1) {
            if points[i].routeSegmentIndex != points[i + 1].routeSegmentIndex {
                result.append(.nan)
                continue
            }
            result.append(lookup[i] ?? .nan)
        }
        return result
    }

    /// Reconstruct lightweight route points from scene points for the profile builder.
    private func routePoints(from scenePoints: [RouteScenePoint]) -> [RoutePoint] {
        let base = Date(timeIntervalSince1970: 0)
        return scenePoints.map { point in
            RoutePoint(
                id: point.id,
                timestamp: base.addingTimeInterval(point.elapsedSeconds),
                latitude: 0,
                longitude: 0,
                altitudeMeters: point.yMeters,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                heartRateBPM: point.heartRateBPM,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
    }
}

// MARK: - Scale Types

/// Pace color scale for legend display (data only, no colors).
public struct PaceColorScale: Sendable {
    public let fastestPace: Double   // seconds per km
    public let medianPace: Double
    public let slowestPace: Double

    public var fastestFormatted: String { formatPace(fastestPace) }
    public var medianFormatted: String { formatPace(medianPace) }
    public var slowestFormatted: String { formatPace(slowestPace) }

    public init(fastestPace: Double, medianPace: Double, slowestPace: Double) {
        self.fastestPace = fastestPace
        self.medianPace = medianPace
        self.slowestPace = slowestPace
    }

    private func formatPace(_ seconds: Double) -> String {
        DisplayFormatter.formatPace(seconds)
    }
}

/// Heart rate color scale for legend display (data only, no colors).
public struct HeartRateColorScale: Sendable {
    public let lowHR: Double
    public let medianHR: Double
    public let highHR: Double

    public var lowFormatted: String { formatHR(lowHR) }
    public var medianFormatted: String { formatHR(medianHR) }
    public var highFormatted: String { formatHR(highHR) }

    public init(lowHR: Double, medianHR: Double, highHR: Double) {
        self.lowHR = lowHR
        self.medianHR = medianHR
        self.highHR = highHR
    }

    private func formatHR(_ bpm: Double) -> String {
        DisplayFormatter.formatHeartRate(bpm)
    }
}
