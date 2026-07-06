import Foundation

/// Distance-based interpolation helpers for route analysis.
public enum RoutePointInterpolator {

    public static func point(at distance: Double, in points: [RoutePoint]) -> RoutePoint? {
        guard !points.isEmpty, distance.isFinite else { return nil }
        guard points.count >= 2 else { return points[0] }

        let lastDistance = points.last?.distanceFromStartMeters ?? 0
        let clampedDistance = max(points[0].distanceFromStartMeters, min(distance, lastDistance))

        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].distanceFromStartMeters < clampedDistance {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low == 0 { return points[0] }
        let after = points[low]
        let before = points[low - 1]
        let segmentDistance = after.distanceFromStartMeters - before.distanceFromStartMeters
        guard segmentDistance > 0, segmentDistance.isFinite else { return before }

        let fraction = max(0, min(1, (clampedDistance - before.distanceFromStartMeters) / segmentDistance))
        return interpolate(from: before, to: after, fraction: fraction, distance: clampedDistance)
    }

    public static func scenePoint(at distance: Double, in points: [RouteScenePoint]) -> RouteScenePoint? {
        guard !points.isEmpty, distance.isFinite else { return nil }
        guard points.count >= 2 else { return points[0] }

        let lastDistance = points.last?.distanceFromStartMeters ?? 0
        let clampedDistance = max(points[0].distanceFromStartMeters, min(distance, lastDistance))

        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].distanceFromStartMeters < clampedDistance {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low == 0 { return points[0] }
        let after = points[low]
        let before = points[low - 1]
        let segmentDistance = after.distanceFromStartMeters - before.distanceFromStartMeters
        guard segmentDistance > 0, segmentDistance.isFinite else { return before }

        let fraction = max(0, min(1, (clampedDistance - before.distanceFromStartMeters) / segmentDistance))
        return RouteScenePoint(
            xMeters: interpolate(before.xMeters, after.xMeters, fraction),
            yMeters: interpolate(before.yMeters, after.yMeters, fraction),
            zMeters: interpolate(before.zMeters, after.zMeters, fraction),
            sourceIndex: before.sourceIndex,
            distanceFromStartMeters: clampedDistance,
            elapsedSeconds: interpolate(before.elapsedSeconds, after.elapsedSeconds, fraction),
            paceSecondsPerKilometer: interpolateOptional(before.paceSecondsPerKilometer, after.paceSecondsPerKilometer, fraction),
            heartRateBPM: interpolateOptional(before.heartRateBPM, after.heartRateBPM, fraction)
        )
    }

    public static func firstIndex(atOrAfter distance: Double, in points: [RoutePoint]) -> Int? {
        points.firstIndex { $0.distanceFromStartMeters >= distance }
    }

    public static func lastIndex(atOrBefore distance: Double, in points: [RoutePoint]) -> Int? {
        points.lastIndex { $0.distanceFromStartMeters <= distance }
    }

    public static func averageHeartRate(
        in points: [RoutePoint],
        from startDistance: Double,
        to endDistance: Double
    ) -> Double? {
        let values = points
            .filter { $0.distanceFromStartMeters >= startDistance && $0.distanceFromStartMeters <= endDistance }
            .compactMap { point -> Double? in
                guard let hr = point.heartRateBPM,
                      hr.isFinite,
                      WorkoutAnalyzer.validHeartRateRange.contains(hr)
                else { return nil }
                return hr
            }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func elevationGain(
        in points: [RoutePoint],
        from startDistance: Double,
        to endDistance: Double
    ) -> Double? {
        guard var previous = point(at: startDistance, in: points),
              let end = point(at: endDistance, in: points)
        else { return nil }

        var samples = points.filter {
            $0.distanceFromStartMeters > startDistance && $0.distanceFromStartMeters < endDistance
        }
        samples.append(end)

        var gain: Double = 0
        var sawAltitude = previous.altitudeMeters != nil
        for sample in samples {
            if let currentAltitude = sample.altitudeMeters,
               let previousAltitude = previous.altitudeMeters,
               currentAltitude.isFinite,
               previousAltitude.isFinite {
                gain += max(0, currentAltitude - previousAltitude)
                sawAltitude = true
            }
            previous = sample
        }

        return sawAltitude ? gain : nil
    }

    private static func interpolate(from before: RoutePoint, to after: RoutePoint, fraction: Double, distance: Double) -> RoutePoint {
        RoutePoint(
            timestamp: before.timestamp.addingTimeInterval(fraction * after.timestamp.timeIntervalSince(before.timestamp)),
            latitude: interpolate(before.latitude, after.latitude, fraction),
            longitude: interpolate(before.longitude, after.longitude, fraction),
            altitudeMeters: interpolateOptional(before.altitudeMeters, after.altitudeMeters, fraction),
            distanceFromStartMeters: distance,
            elapsedSeconds: interpolate(before.elapsedSeconds, after.elapsedSeconds, fraction),
            speedMetersPerSecond: interpolateOptional(before.speedMetersPerSecond, after.speedMetersPerSecond, fraction),
            paceSecondsPerKilometer: interpolateOptional(before.paceSecondsPerKilometer, after.paceSecondsPerKilometer, fraction),
            heartRateBPM: interpolateOptional(before.heartRateBPM, after.heartRateBPM, fraction),
            cadence: interpolateOptional(before.cadence, after.cadence, fraction),
            horizontalAccuracy: interpolateOptional(before.horizontalAccuracy, after.horizontalAccuracy, fraction)
        )
    }

    private static func interpolate(_ a: Double, _ b: Double, _ fraction: Double) -> Double {
        a + fraction * (b - a)
    }

    private static func interpolateOptional(_ a: Double?, _ b: Double?, _ fraction: Double) -> Double? {
        guard let a, let b, a.isFinite, b.isFinite else { return nil }
        return interpolate(a, b, fraction)
    }
}
