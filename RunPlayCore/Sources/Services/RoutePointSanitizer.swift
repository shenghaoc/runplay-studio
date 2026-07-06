import Foundation

/// Distance strategy used when normalizing imported route points.
public enum RouteDistancePolicy {
    /// Recompute cumulative distance from coordinates.
    case computeFromCoordinates
    /// Use supplied cumulative distances only when the complete series is valid.
    case useSuppliedDistancesWhenValid
}

/// Normalizes route data before analysis and UI code consume it.
public enum RoutePointSanitizer {

    /// Return route points with valid coordinates, monotonic elapsed time, and
    /// monotonic cumulative distance.
    public static func normalize(
        _ points: [RoutePoint],
        distancePolicy: RouteDistancePolicy = .computeFromCoordinates,
        sortByTimestamp: Bool = true
    ) -> [RoutePoint] {
        let validPoints = points.filter {
            GeoDistance.isValidCoordinate(lat: $0.latitude, lon: $0.longitude)
        }

        guard !validPoints.isEmpty else { return [] }

        let ordered: [RoutePoint]
        if sortByTimestamp {
            ordered = validPoints.sorted {
                if $0.timestamp == $1.timestamp {
                    return $0.elapsedSeconds < $1.elapsedSeconds
                }
                return $0.timestamp < $1.timestamp
            }
        } else {
            ordered = validPoints
        }

        let useSuppliedDistances = distancePolicy == .useSuppliedDistancesWhenValid
            && hasValidSuppliedDistanceSeries(ordered)
        let distanceBase = useSuppliedDistances ? ordered[0].distanceFromStartMeters : 0

        let useTimestampElapsed = elapsedSpan(from: ordered) > 0
        let useSuppliedElapsed = !useTimestampElapsed && hasValidElapsedSeries(ordered)
        let elapsedBase = useSuppliedElapsed ? ordered[0].elapsedSeconds : 0
        let startDate = ordered[0].timestamp

        var normalized: [RoutePoint] = []
        normalized.reserveCapacity(ordered.count)

        for point in ordered {
            let distance: Double
            if useSuppliedDistances {
                distance = max(0, point.distanceFromStartMeters - distanceBase)
            } else if let previous = normalized.last {
                distance = previous.distanceFromStartMeters + GeoDistance.distanceMeters(
                    fromLat: previous.latitude,
                    lon: previous.longitude,
                    toLat: point.latitude,
                    lon: point.longitude
                )
            } else {
                distance = 0
            }

            let elapsed: Double
            if useTimestampElapsed {
                elapsed = max(0, point.timestamp.timeIntervalSince(startDate))
            } else if useSuppliedElapsed {
                elapsed = max(0, point.elapsedSeconds - elapsedBase)
            } else {
                elapsed = Double(normalized.count)
            }

            normalized.append(RoutePoint(
                id: point.id,
                timestamp: point.timestamp,
                latitude: point.latitude,
                longitude: point.longitude,
                altitudeMeters: finiteOptional(point.altitudeMeters),
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                speedMetersPerSecond: positiveFiniteOptional(point.speedMetersPerSecond),
                paceSecondsPerKilometer: positiveFiniteOptional(point.paceSecondsPerKilometer),
                heartRateBPM: validHeartRate(point.heartRateBPM),
                cadence: positiveFiniteOptional(point.cadence),
                horizontalAccuracy: positiveFiniteOptional(point.horizontalAccuracy)
            ))
        }

        return normalized
    }

    private static func hasValidSuppliedDistanceSeries(_ points: [RoutePoint]) -> Bool {
        guard !points.isEmpty else { return false }
        var previous = -Double.infinity
        for point in points {
            let distance = point.distanceFromStartMeters
            guard distance.isFinite, distance >= 0, distance >= previous else {
                return false
            }
            previous = distance
        }
        return true
    }

    private static func hasValidElapsedSeries(_ points: [RoutePoint]) -> Bool {
        guard !points.isEmpty else { return false }
        var previous = -Double.infinity
        for point in points {
            let elapsed = point.elapsedSeconds
            guard elapsed.isFinite, elapsed >= 0, elapsed >= previous else {
                return false
            }
            previous = elapsed
        }
        return true
    }

    private static func elapsedSpan(from points: [RoutePoint]) -> TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        return span.isFinite ? span : 0
    }

    private static func finiteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func positiveFiniteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func validHeartRate(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              WorkoutAnalyzer.validHeartRateRange.contains(value)
        else {
            return nil
        }
        return value
    }
}
