import Foundation

/// Distance strategy used when normalizing imported route points.
public enum RouteDistancePolicy: Sendable {
    /// Recompute cumulative distance from coordinates.
    case computeFromCoordinates
    /// Use supplied cumulative distances only when the complete series is valid.
    case useSuppliedDistancesWhenValid
}

/// Normalizes route data before analysis and UI code consume it.
public enum RoutePointSanitizer {

    /// Return route points with valid coordinates, monotonic elapsed time, and
    /// monotonic cumulative distance.
    ///
    /// When the input contains points with different `routeSegmentIndex` values,
    /// sorting and distance computation respect segment boundaries:
    /// - Points are sorted by timestamp only within each segment.
    /// - No geographic distance is added across a segment boundary.
    /// - Cumulative distance continues from the prior segment's ending value.
    public static func normalize(
        _ points: [RoutePoint],
        distancePolicy: RouteDistancePolicy = .computeFromCoordinates,
        sortByTimestamp: Bool = true
    ) -> [RoutePoint] {
        let validPoints = points.filter {
            GeoDistance.isValidCoordinate(lat: $0.latitude, lon: $0.longitude)
        }

        guard !validPoints.isEmpty else { return [] }

        // Group by segment to preserve segment boundaries during sorting.
        let segmentGroups = Dictionary(grouping: validPoints, by: \.routeSegmentIndex)
        let sortedSegmentIndexes = segmentGroups.keys.sorted()

        var ordered: [RoutePoint] = []
        ordered.reserveCapacity(validPoints.count)
        for segIdx in sortedSegmentIndexes {
            guard let segPoints = segmentGroups[segIdx] else { continue }
            if sortByTimestamp {
                ordered.append(contentsOf: segPoints.sorted {
                    if $0.timestamp == $1.timestamp {
                        return $0.elapsedSeconds < $1.elapsedSeconds
                    }
                    return $0.timestamp < $1.timestamp
                })
            } else {
                ordered.append(contentsOf: segPoints)
            }
        }

        // After ordering, re-normalize segment indexes to be compact 0-based.
        var indexMap: [Int: Int] = [:]
        var nextIndex = 0
        for point in ordered {
            if indexMap[point.routeSegmentIndex] == nil {
                indexMap[point.routeSegmentIndex] = nextIndex
                nextIndex += 1
            }
        }

        let useSuppliedDistances = distancePolicy == .useSuppliedDistancesWhenValid
            && hasValidSuppliedDistanceSeries(ordered)

        let useTimestampElapsed = elapsedSpan(from: ordered) > 0
        let useSuppliedElapsed = !useTimestampElapsed && hasValidElapsedSeries(ordered)
        let elapsedBase = useSuppliedElapsed ? ordered[0].elapsedSeconds : 0
        let startDate = ordered[0].timestamp

        var normalized: [RoutePoint] = []
        normalized.reserveCapacity(ordered.count)

        // Track the supplied distance base for the current segment.
        var segmentDistanceBase: Double = 0
        var segmentStartCumulative: Double = 0

        for point in ordered {
            let compactSegmentIndex = indexMap[point.routeSegmentIndex] ?? 0
            let isSegmentStart: Bool
            if let last = normalized.last {
                isSegmentStart = compactSegmentIndex != last.routeSegmentIndex
            } else {
                isSegmentStart = true
            }

            let distance: Double
            if isSegmentStart {
                // At a segment boundary: continue cumulative distance from prior
                // segment end. No geographic jump is added.
                segmentStartCumulative = normalized.last?.distanceFromStartMeters ?? 0
                distance = segmentStartCumulative
                if useSuppliedDistances {
                    // Record this segment's first supplied distance as the base
                    // so subsequent points in this segment compute relative deltas.
                    segmentDistanceBase = point.distanceFromStartMeters
                }
            } else if useSuppliedDistances {
                // Within a segment: compute absolute position using supplied distance,
                // offset by the segment's base, added to segment start cumulative.
                distance = segmentStartCumulative
                    + max(0, point.distanceFromStartMeters - segmentDistanceBase)
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
                speedMetersPerSecond: nonNegativeFiniteOptional(point.speedMetersPerSecond),
                paceSecondsPerKilometer: positiveFiniteOptional(point.paceSecondsPerKilometer),
                heartRateBPM: validHeartRate(point.heartRateBPM),
                cadence: nonNegativeFiniteOptional(point.cadence),
                horizontalAccuracy: nonNegativeFiniteOptional(point.horizontalAccuracy),
                routeSegmentIndex: compactSegmentIndex
            ))
        }

        return normalized
    }

    /// Check if a numeric field across route points is finite, non-negative, and monotonically non-decreasing.
    private static func isMonotonicallyNonDecreasing(
        _ keyPath: KeyPath<RoutePoint, Double>,
        in points: [RoutePoint]
    ) -> Bool {
        guard !points.isEmpty else { return false }
        var previous = -Double.infinity
        for point in points {
            let value = point[keyPath: keyPath]
            guard value.isFinite, value >= 0, value >= previous else {
                return false
            }
            previous = value
        }
        return true
    }

    /// Check if the supplied distance series is valid: monotonically non-decreasing
    /// within each segment, and complete (no NaN/inf values).
    private static func hasValidSuppliedDistanceSeries(_ points: [RoutePoint]) -> Bool {
        guard !points.isEmpty else { return false }
        // Group by segment and check monotonicity within each segment separately.
        let segmentGroups = Dictionary(grouping: points, by: \.routeSegmentIndex)
        for (_, segPoints) in segmentGroups {
            let sorted = segPoints.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
            guard isMonotonicallyNonDecreasing(\.distanceFromStartMeters, in: sorted) else {
                return false
            }
        }
        return true
    }

    private static func hasValidElapsedSeries(_ points: [RoutePoint]) -> Bool {
        isMonotonicallyNonDecreasing(\.elapsedSeconds, in: points)
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

    private static func nonNegativeFiniteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func validHeartRate(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              MetricValidation.validHeartRateRange.contains(value)
        else {
            return nil
        }
        return value
    }
}

enum RouteTimestampResolver {

    static func resolve(_ timestamps: [Date?]) -> [Date]? {
        guard !timestamps.isEmpty, timestamps.contains(where: { $0 != nil }) else {
            return nil
        }

        return timestamps.indices.map { index in
            if let timestamp = timestamps[index] {
                return timestamp
            }

            let previous = previousTimestamp(before: index, in: timestamps)
            let next = nextTimestamp(after: index, in: timestamps)

            switch (previous, next) {
            case let (.some(previous), .some(next)):
                let totalSteps = max(1, next.index - previous.index)
                let interval = next.timestamp.timeIntervalSince(previous.timestamp) / Double(totalSteps)
                return previous.timestamp.addingTimeInterval(interval * Double(index - previous.index))
            case let (.some(previous), .none):
                return previous.timestamp.addingTimeInterval(Double(index - previous.index))
            case let (.none, .some(next)):
                return next.timestamp.addingTimeInterval(-Double(next.index - index))
            case (.none, .none):
                // Unreachable if caller verified at least one non-nil timestamp.
                // Return distant past as safe fallback instead of crashing.
                return Date.distantPast
            }
        }
    }

    private static func previousTimestamp(before index: Int, in timestamps: [Date?]) -> (index: Int, timestamp: Date)? {
        guard index > 0 else { return nil }
        for candidate in stride(from: index - 1, through: 0, by: -1) {
            if let timestamp = timestamps[candidate] {
                return (candidate, timestamp)
            }
        }
        return nil
    }

    private static func nextTimestamp(after index: Int, in timestamps: [Date?]) -> (index: Int, timestamp: Date)? {
        guard index + 1 < timestamps.count else { return nil }
        for candidate in (index + 1)..<timestamps.count {
            if let timestamp = timestamps[candidate] {
                return (candidate, timestamp)
            }
        }
        return nil
    }
}
