import Foundation

/// One derived elevation sample aligned with a retained route point.
public struct ElevationProfileSample: Hashable, Sendable {
    public let routePointID: UUID
    public let distanceFromStartMeters: Double
    public let routeSegmentIndex: Int
    public let correctedAltitudeMeters: Double?
    public let sourceAltitudeWasRejected: Bool
    public let cumulativeAscentMeters: Double
    public let cumulativeDescentMeters: Double

    public init(
        routePointID: UUID,
        distanceFromStartMeters: Double,
        routeSegmentIndex: Int,
        correctedAltitudeMeters: Double?,
        sourceAltitudeWasRejected: Bool,
        cumulativeAscentMeters: Double,
        cumulativeDescentMeters: Double
    ) {
        self.routePointID = routePointID
        self.distanceFromStartMeters = distanceFromStartMeters
        self.routeSegmentIndex = routeSegmentIndex
        self.correctedAltitudeMeters = correctedAltitudeMeters
        self.sourceAltitudeWasRejected = sourceAltitudeWasRejected
        self.cumulativeAscentMeters = cumulativeAscentMeters
        self.cumulativeDescentMeters = cumulativeDescentMeters
    }
}

/// Distance-domain elevation analysis aligned one-to-one with route points.
///
/// Finite source altitude remains on `RoutePoint`. This profile rejects only
/// analysis outliers, fills an isolated rejected sample from its two reliable
/// neighbours, smooths within continuous non-missing runs, and applies a
/// threshold-confirmed trend reversal algorithm for cumulative gain and loss.
public struct ElevationProfile: Sendable {
    public struct RangeChange: Hashable, Sendable {
        public let ascentMeters: Double
        public let descentMeters: Double
        public let signedChangeMeters: Double

        public init(ascentMeters: Double, descentMeters: Double, signedChangeMeters: Double) {
            self.ascentMeters = ascentMeters
            self.descentMeters = descentMeters
            self.signedChangeMeters = signedChangeMeters
        }
    }

    public let samples: [ElevationProfileSample]
    public let hasMeaningfulElevation: Bool
    public let totalAscentMeters: Double?
    public let totalDescentMeters: Double?

    private let distances: [Double]
    private let segmentIndexes: [Int]
    private let correctedAltitudes: [Double?]
    private let cumulativeAscent: [Double]
    private let cumulativeDescent: [Double]
    private let cumulativeSignedChange: [Double]
    private let reliableIntervalCounts: [Double]
    private let runIdentifiers: [Int?]
    private let reliableRunIdentifiers: [Int?]

    public init(
        routePoints: [RoutePoint],
        policy: RouteQualityPolicy = .runningDefault
    ) {
        do {
            self = try Self.build(
                routePoints: routePoints,
                policy: policy,
                isCancelled: { false }
            ).profile
        } catch {
            self = Self.empty(alignedWith: routePoints)
        }
    }

    public func correctedAltitude(atPointIndex index: Int) -> Double? {
        guard correctedAltitudes.indices.contains(index) else { return nil }
        return correctedAltitudes[index]
    }

    public func sourceAltitudeWasRejected(atPointIndex index: Int) -> Bool {
        guard samples.indices.contains(index) else { return false }
        return samples[index].sourceAltitudeWasRejected
    }

    public func correctedAltitude(
        atDistance distance: Double,
        boundary role: WorkoutDistanceBoundaryRole = .rangeEnd
    ) -> Double? {
        guard let location = distanceLocation(at: distance, boundary: role) else { return nil }
        if location.before == location.after {
            return correctedAltitudes[location.before]
        }
        guard segmentIndexes[location.before] == segmentIndexes[location.after],
              runIdentifiers[location.before] != nil,
              runIdentifiers[location.before] == runIdentifiers[location.after],
              let before = correctedAltitudes[location.before],
              let after = correctedAltitudes[location.after]
        else {
            return nil
        }
        return Self.interpolate(before, after, location.fraction)
    }

    /// Threshold-confirmed ascent/descent and corrected signed change over a
    /// global cumulative-distance range. Multiple continuous route segments
    /// may contribute, but no interpolation or delta crosses a gap.
    public func change(from startDistance: Double, to endDistance: Double) -> RangeChange? {
        guard startDistance.isFinite,
              endDistance.isFinite,
              startDistance <= endDistance,
              let startAscent = sampled(cumulativeAscent, at: startDistance, boundary: .rangeStart),
              let endAscent = sampled(cumulativeAscent, at: endDistance, boundary: .rangeEnd),
              let startDescent = sampled(cumulativeDescent, at: startDistance, boundary: .rangeStart),
              let endDescent = sampled(cumulativeDescent, at: endDistance, boundary: .rangeEnd),
              let startSigned = sampled(cumulativeSignedChange, at: startDistance, boundary: .rangeStart),
              let endSigned = sampled(cumulativeSignedChange, at: endDistance, boundary: .rangeEnd),
              let startReliable = sampled(reliableIntervalCounts, at: startDistance, boundary: .rangeStart),
              let endReliable = sampled(reliableIntervalCounts, at: endDistance, boundary: .rangeEnd),
              endReliable > startReliable
        else {
            return nil
        }

        return RangeChange(
            ascentMeters: max(0, endAscent - startAscent),
            descentMeters: max(0, endDescent - startDescent),
            signedChangeMeters: endSigned - startSigned
        )
    }

    public func ascent(from startDistance: Double, to endDistance: Double) -> Double? {
        change(from: startDistance, to: endDistance)?.ascentMeters
    }

    public func descent(from startDistance: Double, to endDistance: Double) -> Double? {
        change(from: startDistance, to: endDistance)?.descentMeters
    }

    public func signedChange(from startDistance: Double, to endDistance: Double) -> Double? {
        change(from: startDistance, to: endDistance)?.signedChangeMeters
    }

    /// True only when both boundaries fall inside the same reliable elevation
    /// run. Notable climb/descent windows use this to avoid bridging gaps.
    public func hasContinuousReliableElevation(from startDistance: Double, to endDistance: Double) -> Bool {
        guard startDistance.isFinite,
              endDistance.isFinite,
              startDistance <= endDistance,
              let start = distanceLocation(at: startDistance, boundary: .rangeStart),
              let end = distanceLocation(at: endDistance, boundary: .rangeEnd),
              let startID = reliableRunIdentifier(for: start),
              let endID = reliableRunIdentifier(for: end)
        else {
            return false
        }
        return startID == endID
    }

    // MARK: - Construction

    static func build(
        routePoints: [RoutePoint],
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> (profile: ElevationProfile, rejectedAltitudeCount: Int) {
        guard !routePoints.isEmpty else {
            return (empty(alignedWith: []), 0)
        }

        // Complete multi-pass elevation construction runs in one C++23 bulk
        // call. Swift retains UUIDs, public samples, distance queries, and
        // segment-detection snapshots.
        let native = try RunPlayElevationProfileBridge.build(
            routePoints: routePoints,
            policy: policy,
            isCancelled: isCancelled
        )

        let count = routePoints.count
        precondition(native.samples.count == count)

        var samples: [ElevationProfileSample] = []
        var distances: [Double] = []
        var segmentIndexes: [Int] = []
        var corrected: [Double?] = []
        var cumulativeAscent: [Double] = []
        var cumulativeDescent: [Double] = []
        var cumulativeSigned: [Double] = []
        var reliableIntervals: [Double] = []
        var runIDs: [Int?] = []
        var reliableRunIDs: [Int?] = []

        samples.reserveCapacity(count)
        distances.reserveCapacity(count)
        segmentIndexes.reserveCapacity(count)
        corrected.reserveCapacity(count)
        cumulativeAscent.reserveCapacity(count)
        cumulativeDescent.reserveCapacity(count)
        cumulativeSigned.reserveCapacity(count)
        reliableIntervals.reserveCapacity(count)
        runIDs.reserveCapacity(count)
        reliableRunIDs.reserveCapacity(count)

        let stride = max(1, policy.cancellationCheckStride)
        for index in routePoints.indices {
            if index.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }
            let point = routePoints[index]
            let result = native.samples[index]
            samples.append(ElevationProfileSample(
                routePointID: point.id,
                distanceFromStartMeters: point.distanceFromStartMeters,
                routeSegmentIndex: point.routeSegmentIndex,
                correctedAltitudeMeters: result.correctedAltitudeMeters,
                sourceAltitudeWasRejected: result.sourceAltitudeWasRejected,
                cumulativeAscentMeters: result.cumulativeAscentMeters,
                cumulativeDescentMeters: result.cumulativeDescentMeters
            ))
            distances.append(point.distanceFromStartMeters)
            segmentIndexes.append(point.routeSegmentIndex)
            corrected.append(result.correctedAltitudeMeters)
            cumulativeAscent.append(result.cumulativeAscentMeters)
            cumulativeDescent.append(result.cumulativeDescentMeters)
            cumulativeSigned.append(result.cumulativeSignedChangeMeters)
            reliableIntervals.append(result.reliableIntervalCount)
            runIDs.append(result.runIdentifier)
            reliableRunIDs.append(result.reliableRunIdentifier)
        }

        let profile = ElevationProfile(
            samples: samples,
            hasMeaningfulElevation: native.hasMeaningfulElevation,
            totalAscentMeters: native.totalAscentMeters,
            totalDescentMeters: native.totalDescentMeters,
            distances: distances,
            segmentIndexes: segmentIndexes,
            correctedAltitudes: corrected,
            cumulativeAscent: cumulativeAscent,
            cumulativeDescent: cumulativeDescent,
            cumulativeSignedChange: cumulativeSigned,
            reliableIntervalCounts: reliableIntervals,
            runIdentifiers: runIDs,
            reliableRunIdentifiers: reliableRunIDs
        )
        return (profile, native.rejectedAltitudeCount)
    }

    private init(
        samples: [ElevationProfileSample],
        hasMeaningfulElevation: Bool,
        totalAscentMeters: Double?,
        totalDescentMeters: Double?,
        distances: [Double],
        segmentIndexes: [Int],
        correctedAltitudes: [Double?],
        cumulativeAscent: [Double],
        cumulativeDescent: [Double],
        cumulativeSignedChange: [Double],
        reliableIntervalCounts: [Double],
        runIdentifiers: [Int?],
        reliableRunIdentifiers: [Int?]
    ) {
        self.samples = samples
        self.hasMeaningfulElevation = hasMeaningfulElevation
        self.totalAscentMeters = totalAscentMeters
        self.totalDescentMeters = totalDescentMeters
        self.distances = distances
        self.segmentIndexes = segmentIndexes
        self.correctedAltitudes = correctedAltitudes
        self.cumulativeAscent = cumulativeAscent
        self.cumulativeDescent = cumulativeDescent
        self.cumulativeSignedChange = cumulativeSignedChange
        self.reliableIntervalCounts = reliableIntervalCounts
        self.runIdentifiers = runIdentifiers
        self.reliableRunIdentifiers = reliableRunIdentifiers
    }

    private static func empty(alignedWith points: [RoutePoint]) -> ElevationProfile {
        let count = points.count
        // ⚡ Bolt: Inline array building avoids multiple O(N) array allocations from .map(\.property).
        var samples: [ElevationProfileSample] = []
        var distances: [Double] = []
        var segmentIndexes: [Int] = []
        samples.reserveCapacity(count)
        distances.reserveCapacity(count)
        segmentIndexes.reserveCapacity(count)

        for point in points {
            samples.append(ElevationProfileSample(
                routePointID: point.id,
                distanceFromStartMeters: point.distanceFromStartMeters,
                routeSegmentIndex: point.routeSegmentIndex,
                correctedAltitudeMeters: nil,
                sourceAltitudeWasRejected: false,
                cumulativeAscentMeters: 0,
                cumulativeDescentMeters: 0
            ))
            distances.append(point.distanceFromStartMeters)
            segmentIndexes.append(point.routeSegmentIndex)
        }

        return ElevationProfile(
            samples: samples,
            hasMeaningfulElevation: false,
            totalAscentMeters: nil,
            totalDescentMeters: nil,
            distances: distances,
            segmentIndexes: segmentIndexes,
            correctedAltitudes: Array(repeating: nil, count: count),
            cumulativeAscent: Array(repeating: 0, count: count),
            cumulativeDescent: Array(repeating: 0, count: count),
            cumulativeSignedChange: Array(repeating: 0, count: count),
            reliableIntervalCounts: Array(repeating: 0, count: count),
            runIdentifiers: Array(repeating: nil, count: count),
            reliableRunIdentifiers: Array(repeating: nil, count: count)
        )
    }

    // MARK: - Distance lookup

    private struct DistanceLocation {
        let before: Int
        let after: Int
        let fraction: Double
    }

    private func distanceLocation(
        at requestedDistance: Double,
        boundary role: WorkoutDistanceBoundaryRole
    ) -> DistanceLocation? {
        guard requestedDistance.isFinite, !distances.isEmpty else { return nil }
        let distance = min(max(requestedDistance, distances[0]), distances[distances.count - 1])
        let firstAtOrAfter = lowerBound(distance)

        if firstAtOrAfter < distances.count, distances[firstAtOrAfter] == distance {
            let last = upperBound(distance) - 1
            let selected = role == .rangeStart ? last : firstAtOrAfter
            return DistanceLocation(before: selected, after: selected, fraction: 0)
        }

        guard firstAtOrAfter > 0, firstAtOrAfter < distances.count else {
            let selected = firstAtOrAfter == 0 ? 0 : distances.count - 1
            return DistanceLocation(before: selected, after: selected, fraction: 0)
        }
        let before = firstAtOrAfter - 1
        let after = firstAtOrAfter
        let span = distances[after] - distances[before]
        guard span > 0 else {
            let selected = role == .rangeStart ? after : before
            return DistanceLocation(before: selected, after: selected, fraction: 0)
        }
        return DistanceLocation(
            before: before,
            after: after,
            fraction: min(1, max(0, (distance - distances[before]) / span))
        )
    }

    private func sampled(
        _ values: [Double],
        at distance: Double,
        boundary role: WorkoutDistanceBoundaryRole
    ) -> Double? {
        guard let location = distanceLocation(at: distance, boundary: role),
              values.indices.contains(location.before),
              values.indices.contains(location.after)
        else {
            return nil
        }
        if location.before == location.after {
            return values[location.before]
        }
        if segmentIndexes[location.before] != segmentIndexes[location.after] {
            return role == .rangeStart ? values[location.after] : values[location.before]
        }
        return Self.interpolate(values[location.before], values[location.after], location.fraction)
    }

    private func reliableRunIdentifier(for location: DistanceLocation) -> Int? {
        if location.before == location.after {
            return reliableRunIdentifiers[location.before]
        }
        guard reliableRunIdentifiers[location.before] != nil,
              reliableRunIdentifiers[location.before] == reliableRunIdentifiers[location.after]
        else {
            return nil
        }
        return reliableRunIdentifiers[location.before]
    }

    private func lowerBound(_ value: Double) -> Int {
        var low = 0
        var high = distances.count
        while low < high {
            let mid = low + (high - low) / 2
            if distances[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func upperBound(_ value: Double) -> Int {
        var low = 0
        var high = distances.count
        while low < high {
            let mid = low + (high - low) / 2
            if distances[mid] <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func interpolate(_ first: Double, _ second: Double, _ fraction: Double) -> Double {
        first + ((second - first) * fraction)
    }

    // MARK: - Segment-detection snapshot

    /// Lightweight copy-on-write snapshot of elevation arrays consumed by
    /// the C++23 SegmentDetector window-search kernel.
    struct ElevationSegmentDetectionSnapshot: Sendable {
        let cumulativeAscentMeters: [Double]
        let cumulativeDescentMeters: [Double]
        let reliableIntervalCounts: [Double]
        let reliableRunIdentifiers: [Int?]
    }

    /// Returns the exact internal elevation arrays through copy-on-write so
    /// the segment-detection bridge can build compact native input without
    /// recomputing any elevation values.
    func segmentDetectionSnapshot()
        -> ElevationSegmentDetectionSnapshot
    {
        ElevationSegmentDetectionSnapshot(
            cumulativeAscentMeters: cumulativeAscent,
            cumulativeDescentMeters: cumulativeDescent,
            reliableIntervalCounts: reliableIntervalCounts,
            reliableRunIdentifiers: reliableRunIdentifiers
        )
    }
}
