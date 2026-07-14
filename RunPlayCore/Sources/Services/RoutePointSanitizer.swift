import Foundation

/// Distance strategy used when normalizing imported route points.
public enum RouteDistancePolicy: Sendable {
    /// Recompute cumulative distance from coordinates.
    case computeFromCoordinates
    /// Use supplied cumulative distances only when the complete series is valid.
    case useSuppliedDistancesWhenValid
    /// Use a supplied series for each segment that is complete and monotonic;
    /// recompute only invalid segments from their coordinates.
    case useSuppliedDistancesPerSegment
    /// Preserve only the explicitly proven device-distance segments.
    case useSuppliedDistancesForSegments(Set<Int>)
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
        RouteQualityProcessor().processUncancellable(
            points,
            distancePolicy: distancePolicy,
            sortByTimestamp: sortByTimestamp
        ).routePoints
    }
}

enum RouteTimestampResolver {

    static func resolve(_ timestamps: [Date?]) -> [Date]? {
        guard !timestamps.isEmpty else {
            return nil
        }

        var knownIndices: [Int] = []
        knownIndices.reserveCapacity(timestamps.count)
        for index in timestamps.indices where timestamps[index] != nil {
            knownIndices.append(index)
        }
        guard let firstKnownIndex = knownIndices.first,
              let firstKnownTimestamp = timestamps[firstKnownIndex]
        else {
            return nil
        }

        var resolved = Array(repeating: firstKnownTimestamp, count: timestamps.count)

        if firstKnownIndex > 0 {
            for index in 0..<firstKnownIndex {
                resolved[index] = firstKnownTimestamp.addingTimeInterval(
                    -Double(firstKnownIndex - index)
                )
            }
        }

        for pairIndex in 0..<(knownIndices.count - 1) {
            let previousIndex = knownIndices[pairIndex]
            let nextIndex = knownIndices[pairIndex + 1]
            guard let previousTimestamp = timestamps[previousIndex],
                  let nextTimestamp = timestamps[nextIndex]
            else {
                continue
            }
            resolved[previousIndex] = previousTimestamp
            let totalSteps = max(1, nextIndex - previousIndex)
            let interval = nextTimestamp.timeIntervalSince(previousTimestamp) / Double(totalSteps)
            if nextIndex > previousIndex + 1 {
                for index in (previousIndex + 1)..<nextIndex {
                    resolved[index] = previousTimestamp.addingTimeInterval(
                        interval * Double(index - previousIndex)
                    )
                }
            }
            resolved[nextIndex] = nextTimestamp
        }

        guard let lastKnownIndex = knownIndices.last,
              let lastKnownTimestamp = timestamps[lastKnownIndex]
        else {
            return nil
        }
        resolved[lastKnownIndex] = lastKnownTimestamp
        if lastKnownIndex + 1 < timestamps.count {
            for index in (lastKnownIndex + 1)..<timestamps.count {
                resolved[index] = lastKnownTimestamp.addingTimeInterval(
                    Double(index - lastKnownIndex)
                )
            }
        }

        return resolved
    }
}
