import Foundation

/// Maps chart interaction positions to workout distances and route points.
///
/// Provides pure, testable logic for converting chart x-positions
/// to workout distances, with safe clamping and validation.
public struct ChartSelectionMapper {

    /// Map a chart x-position (in km) to a workout distance (in meters).
    ///
    /// Safely clamps to valid range and handles edge cases.
    public static func distanceForChartPosition(
        positionKm: Double,
        totalDistanceMeters: Double
    ) -> Double? {
        // Handle NaN/infinity
        guard positionKm.isFinite,
              totalDistanceMeters.isFinite,
              totalDistanceMeters >= 0 else {
            return nil
        }

        let distanceMeters = positionKm * 1000

        // Clamp to valid range
        return max(0, min(distanceMeters, totalDistanceMeters))
    }

    /// Find the nearest route point index for a given distance.
    ///
    /// Uses binary search for efficiency. Returns nil for empty arrays.
    public static func nearestRoutePointIndex(
        forDistance distance: Double,
        in points: [RoutePoint]
    ) -> Int? {
        guard !points.isEmpty else { return nil }

        // Handle NaN/infinity
        guard distance.isFinite, !distance.isNaN else {
            return nil
        }

        let clampedDistance = max(0, min(distance, points.last?.distanceFromStartMeters ?? 0))

        // Binary search for closest point
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

        // Check if previous point is closer
        if low > 0 {
            let prevDiff = abs(points[low - 1].distanceFromStartMeters - clampedDistance)
            let currDiff = abs(points[low].distanceFromStartMeters - clampedDistance)
            return prevDiff < currDiff ? low - 1 : low
        }

        return low
    }

    /// Find the nearest route point index for a given elapsed time.
    ///
    /// Uses binary search for efficiency. Returns nil for empty arrays.
    public static func nearestRoutePointIndex(
        forElapsedTime elapsed: Double,
        in points: [RoutePoint]
    ) -> Int? {
        guard !points.isEmpty else { return nil }

        // Handle NaN/infinity
        guard elapsed.isFinite, !elapsed.isNaN else {
            return nil
        }

        let clampedTime = max(0, min(elapsed, points.last?.elapsedSeconds ?? 0))

        // Binary search for closest point
        var low = 0
        var high = points.count - 1

        while low < high {
            let mid = (low + high) / 2
            if points[mid].elapsedSeconds < clampedTime {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // Check if previous point is closer
        if low > 0 {
            let prevDiff = abs(points[low - 1].elapsedSeconds - clampedTime)
            let currDiff = abs(points[low].elapsedSeconds - clampedTime)
            return prevDiff < currDiff ? low - 1 : low
        }

        return low
    }

    /// Map chart x-position directly to route point index.
    public static func routePointIndex(
        forChartPositionKm positionKm: Double,
        in points: [RoutePoint]
    ) -> Int? {
        let totalDistance = points.last?.distanceFromStartMeters ?? 0
        guard let distance = distanceForChartPosition(positionKm: positionKm, totalDistanceMeters: totalDistance) else {
            return nil
        }
        return nearestRoutePointIndex(forDistance: distance, in: points)
    }
}
