import Foundation

/// Distance-based interpolation helpers for route analysis.
///
/// All methods use binary search for efficiency and linear interpolation
/// between the two nearest route points. Values are clamped to the route's
/// distance bounds — requesting a distance beyond the route returns the
/// first or last point.
public enum RoutePointInterpolator {

    /// Interpolate a `RoutePoint` at a given cumulative distance.
    ///
    /// Uses binary search to find the segment containing the distance,
    /// then linearly interpolates all fields between the bounding points.
    /// Returns `nil` for empty arrays or non-finite distance.
    /// Returns the single point for single-point arrays.
    ///
    /// Never interpolates across route segment boundaries — if the two
    /// bounding points belong to different segments, returns the earlier
    /// point (the boundary endpoint).
    public static func point(at distance: Double, in points: [RoutePoint]) -> RoutePoint? {
        guard !points.isEmpty, distance.isFinite else { return nil }
        guard points.count >= 2 else { return points[0] }

        let lastDistance = points.last?.distanceFromStartMeters ?? 0
        let clampedDistance = max(points[0].distanceFromStartMeters, min(distance, lastDistance))

        // Binary search for the first point >= clampedDistance
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

        if points[low].distanceFromStartMeters == clampedDistance {
            return points[lastDuplicateIndex(startingAt: low, distance: clampedDistance, in: points)]
        }

        if low == 0 { return points[0] }
        let after = points[low]
        let before = points[low - 1]

        // Do not interpolate across segment boundaries.
        guard before.routeSegmentIndex == after.routeSegmentIndex else {
            return before
        }

        let segmentDistance = after.distanceFromStartMeters - before.distanceFromStartMeters

        // When segmentDistance is 0 (duplicate distances from stationary samples),
        // prefer the last point at that distance to capture final elapsed time.
        guard segmentDistance > 0, segmentDistance.isFinite else {
            return points[lastDuplicateIndex(startingAt: low, distance: after.distanceFromStartMeters, in: points)]
        }

        let fraction = max(0, min(1, (clampedDistance - before.distanceFromStartMeters) / segmentDistance))
        return interpolate(from: before, to: after, fraction: fraction, distance: clampedDistance)
    }

    /// Interpolate a `RouteScenePoint` at a given cumulative distance.
    ///
    /// Same algorithm as `point(at:in:)` but for 3D scene points.
    /// The `sourceIndex` is taken from the point before the interpolation target.
    /// Never interpolates across route segment boundaries.
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

        if points[low].distanceFromStartMeters == clampedDistance {
            return points[lastDuplicateIndex(startingAt: low, distance: clampedDistance, in: points)]
        }

        if low == 0 { return points[0] }
        let after = points[low]
        let before = points[low - 1]

        // Do not interpolate across segment boundaries.
        guard before.routeSegmentIndex == after.routeSegmentIndex else {
            return before
        }

        let segmentDistance = after.distanceFromStartMeters - before.distanceFromStartMeters
        guard segmentDistance > 0, segmentDistance.isFinite else {
            return points[lastDuplicateIndex(startingAt: low, distance: after.distanceFromStartMeters, in: points)]
        }

        let fraction = max(0, min(1, (clampedDistance - before.distanceFromStartMeters) / segmentDistance))
        return RouteScenePoint(
            xMeters: interpolate(before.xMeters, after.xMeters, fraction),
            yMeters: interpolate(before.yMeters, after.yMeters, fraction),
            zMeters: interpolate(before.zMeters, after.zMeters, fraction),
            sourceIndex: before.sourceIndex,
            distanceFromStartMeters: clampedDistance,
            elapsedSeconds: interpolate(before.elapsedSeconds, after.elapsedSeconds, fraction),
            paceSecondsPerKilometer: interpolateOptional(before.paceSecondsPerKilometer, after.paceSecondsPerKilometer, fraction),
            heartRateBPM: interpolateOptional(before.heartRateBPM, after.heartRateBPM, fraction),
            routeSegmentIndex: before.routeSegmentIndex
        )
    }

    /// Find the index of the first point at or after the given distance.
    /// Uses binary search for O(log n) performance on sorted route arrays.
    public static func firstIndex(atOrAfter distance: Double, in points: [RoutePoint]) -> Int? {
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
        return points[low].distanceFromStartMeters >= distance ? low : nil
    }

    /// Find the index of the last point at or before the given distance.
    /// Uses binary search for O(log n) performance on sorted route arrays.
    public static func lastIndex(atOrBefore distance: Double, in points: [RoutePoint]) -> Int? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high + 1) / 2 // Round up to avoid infinite loop
            if points[mid].distanceFromStartMeters <= distance {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return points[low].distanceFromStartMeters <= distance ? low : nil
    }

    /// Compute average heart rate for points within a distance range.
    ///
    /// Filters to valid heart rates within `MetricValidation.validHeartRateRange` (30-230 bpm).
    /// Returns `nil` if no valid heart rate data exists in the range.
    public static func averageHeartRate(
        in points: [RoutePoint],
        from startDistance: Double,
        to endDistance: Double
    ) -> Double? {
        guard startDistance <= endDistance,
              let startIndex = firstIndex(atOrAfter: startDistance, in: points),
              let endIndex = lastIndex(atOrBefore: endDistance, in: points),
              startIndex <= endIndex
        else { return nil }

        var sum: Double = 0
        var count: Int = 0

        for index in startIndex...endIndex {
            let point = points[index]
            if let hr = point.heartRateBPM, hr.isFinite, MetricValidation.validHeartRateRange.contains(hr) {
                sum += hr
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return sum / Double(count)
    }

    /// Compute threshold-confirmed elevation gain from the shared corrected
    /// profile. Kept as a compatibility API for existing callers.
    public static func elevationGain(
        in points: [RoutePoint],
        from startDistance: Double,
        to endDistance: Double
    ) -> Double? {
        ElevationProfile(routePoints: points).ascent(
            from: startDistance,
            to: endDistance
        )
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
            horizontalAccuracy: interpolateOptional(before.horizontalAccuracy, after.horizontalAccuracy, fraction),
            routeSegmentIndex: before.routeSegmentIndex
        )
    }

    private static func interpolate(_ a: Double, _ b: Double, _ fraction: Double) -> Double {
        a + fraction * (b - a)
    }

    private static func interpolateOptional(_ a: Double?, _ b: Double?, _ fraction: Double) -> Double? {
        if fraction <= 0 {
            return finiteOptional(a)
        }
        if fraction >= 1 {
            return finiteOptional(b)
        }
        guard let a, let b, a.isFinite, b.isFinite else { return nil }
        return interpolate(a, b, fraction)
    }

    private static func finiteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func lastDuplicateIndex(startingAt index: Int, distance: Double, in points: [RoutePoint]) -> Int {
        var lastAtDistance = index
        while lastAtDistance + 1 < points.count &&
              points[lastAtDistance + 1].distanceFromStartMeters == distance &&
              points[lastAtDistance + 1].routeSegmentIndex == points[index].routeSegmentIndex {
            lastAtDistance += 1
        }
        return lastAtDistance
    }

    private static func lastDuplicateIndex(startingAt index: Int, distance: Double, in points: [RouteScenePoint]) -> Int {
        var lastAtDistance = index
        while lastAtDistance + 1 < points.count &&
              points[lastAtDistance + 1].distanceFromStartMeters == distance &&
              points[lastAtDistance + 1].routeSegmentIndex == points[index].routeSegmentIndex {
            lastAtDistance += 1
        }
        return lastAtDistance
    }
}
