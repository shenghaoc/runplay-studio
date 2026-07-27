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

        let count = routePoints.count
        var analysisAltitudes = Array<Double?>(repeating: nil, count: count)
        var rejected = Array(repeating: false, count: count)

        for index in routePoints.indices {
            try checkCancellation(index: index, policy: policy, isCancelled: isCancelled)
            guard let altitude = routePoints[index].altitudeMeters else { continue }
            if altitude.isFinite, policy.plausibleAltitudeRangeMeters.contains(altitude) {
                analysisAltitudes[index] = altitude
            } else {
                rejected[index] = true
            }
        }

        if count >= 3 {
            let sourceAltitudes = analysisAltitudes

            // A receiver can report one extreme value before its altitude fix
            // settles, or after it has already lost the fix. Endpoints lack a
            // two-sided neighbourhood, so reject only when the next/previous
            // two samples agree, remain in the same segment, and are close in
            // travelled distance. Sustained or ambiguous endpoint changes stay.
            var endpointRunCursor = 0
            while endpointRunCursor < count {
                try checkCancellation(
                    index: endpointRunCursor,
                    policy: policy,
                    isCancelled: isCancelled
                )
                guard sourceAltitudes[endpointRunCursor] != nil else {
                    endpointRunCursor += 1
                    continue
                }
                let runSegment = routePoints[endpointRunCursor].routeSegmentIndex
                let runStart = endpointRunCursor
                endpointRunCursor += 1
                while endpointRunCursor < count,
                      routePoints[endpointRunCursor].routeSegmentIndex == runSegment,
                      sourceAltitudes[endpointRunCursor] != nil {
                    endpointRunCursor += 1
                }
                let runEnd = endpointRunCursor
                guard runEnd - runStart >= 3 else { continue }

                for endpointIndex in [runStart, runEnd - 1] {
                    let isLeadingEndpoint = endpointIndex == runStart
                    let nearIndex = isLeadingEndpoint ? endpointIndex + 1 : endpointIndex - 1
                    let farIndex = isLeadingEndpoint ? endpointIndex + 2 : endpointIndex - 2
                    let endpointPoint = routePoints[endpointIndex]
                    let farPoint = routePoints[farIndex]
                    guard let endpoint = sourceAltitudes[endpointIndex],
                          let near = sourceAltitudes[nearIndex],
                          let far = sourceAltitudes[farIndex],
                          abs(near - far) <= policy.altitudeSpikeMaximumNeighborDifferenceMeters
                    else {
                        continue
                    }

                    let travelledSpan = abs(
                        farPoint.distanceFromStartMeters - endpointPoint.distanceFromStartMeters
                    )
                    let neighbourMidpoint = (near + far) / 2
                    guard travelledSpan.isFinite,
                          travelledSpan <= policy.altitudeSpikeMaximumHorizontalSpanMeters,
                          abs(endpoint - neighbourMidpoint) >= policy.altitudeSpikeMinimumDeviationMeters,
                          abs(endpoint - near) >= policy.altitudeSpikeMinimumDeviationMeters,
                          abs(endpoint - far) >= policy.altitudeSpikeMinimumDeviationMeters
                    else {
                        continue
                    }

                    analysisAltitudes[endpointIndex] = nil
                    rejected[endpointIndex] = true
                }
            }

            for index in 1..<(count - 1) {
                try checkCancellation(index: index, policy: policy, isCancelled: isCancelled)
                let previousPoint = routePoints[index - 1]
                let point = routePoints[index]
                let nextPoint = routePoints[index + 1]
                guard previousPoint.routeSegmentIndex == point.routeSegmentIndex,
                      point.routeSegmentIndex == nextPoint.routeSegmentIndex,
                      let previous = analysisAltitudes[index - 1],
                      let current = analysisAltitudes[index],
                      let next = analysisAltitudes[index + 1],
                      abs(previous - next) <= policy.altitudeSpikeMaximumNeighborDifferenceMeters
                else {
                    continue
                }

                let horizontalSpan = nextPoint.distanceFromStartMeters
                    - previousPoint.distanceFromStartMeters
                guard horizontalSpan.isFinite,
                      horizontalSpan <= policy.altitudeSpikeMaximumHorizontalSpanMeters
                else {
                    continue
                }

                let neighbourMidpoint = (previous + next) / 2
                guard abs(current - neighbourMidpoint) >= policy.altitudeSpikeMinimumDeviationMeters,
                      abs(current - previous) >= policy.altitudeSpikeMinimumDeviationMeters,
                      abs(current - next) >= policy.altitudeSpikeMinimumDeviationMeters
                else {
                    continue
                }
                analysisAltitudes[index] = nil
                rejected[index] = true
            }

            // A two-sample receiver glitch can form a short false plateau that
            // the three-point test intentionally cannot classify. Reject only
            // an extreme, tightly bounded excursion whose samples agree with
            // each other and whose surrounding trajectory returns to the same
            // level. Longer or one-sided changes remain legitimate data.
            if policy.altitudeShortExcursionMaximumSampleCount >= 2, count >= 4 {
                var start = 1
                while start < count - 1 {
                    try checkCancellation(index: start, policy: policy, isCancelled: isCancelled)
                    guard let firstExcursionAltitude = analysisAltitudes[start] else {
                        start += 1
                        continue
                    }

                    var end = start + 1
                    while end < count - 1,
                          end - start < policy.altitudeShortExcursionMaximumSampleCount,
                          routePoints[end].routeSegmentIndex == routePoints[start].routeSegmentIndex,
                          let altitude = analysisAltitudes[end],
                          abs(altitude - firstExcursionAltitude)
                            <= policy.altitudeSpikeMaximumNeighborDifferenceMeters {
                        end += 1
                    }

                    let excursionCount = end - start
                    guard excursionCount >= 2,
                          end < count,
                          routePoints[start - 1].routeSegmentIndex == routePoints[start].routeSegmentIndex,
                          routePoints[end].routeSegmentIndex == routePoints[start].routeSegmentIndex,
                          let before = analysisAltitudes[start - 1],
                          let after = analysisAltitudes[end],
                          abs(before - after) <= policy.altitudeSpikeMaximumNeighborDifferenceMeters
                    else {
                        start += 1
                        continue
                    }

                    let neighbourMidpoint = (before + after) / 2
                    let excursionIsExtreme = (start..<end).allSatisfy { index in
                        guard let altitude = analysisAltitudes[index] else { return false }
                        return abs(altitude - neighbourMidpoint)
                            >= policy.altitudeShortExcursionMinimumDeviationMeters
                    }
                    let horizontalSpan = routePoints[end].distanceFromStartMeters
                        - routePoints[start - 1].distanceFromStartMeters
                    guard excursionIsExtreme,
                          horizontalSpan.isFinite,
                          horizontalSpan <= policy.altitudeSpikeMaximumHorizontalSpanMeters
                    else {
                        start += 1
                        continue
                    }

                    for index in start..<end {
                        analysisAltitudes[index] = nil
                        rejected[index] = true
                    }
                    start = end
                }
            }
        }

        // A rejected source sample is analysis noise, not a true missing-data
        // gap. Fill only an interior sample supported by immediate neighbours.
        if count >= 3 {
            let rejectedAltitudes = analysisAltitudes
            for index in 1..<(count - 1) where rejected[index] {
                let previousPoint = routePoints[index - 1]
                let point = routePoints[index]
                let nextPoint = routePoints[index + 1]
                guard previousPoint.routeSegmentIndex == point.routeSegmentIndex,
                      point.routeSegmentIndex == nextPoint.routeSegmentIndex,
                      let previous = rejectedAltitudes[index - 1],
                      let next = rejectedAltitudes[index + 1]
                else {
                    continue
                }
                let span = nextPoint.distanceFromStartMeters - previousPoint.distanceFromStartMeters
                let fraction = span > 0
                    ? (point.distanceFromStartMeters - previousPoint.distanceFromStartMeters) / span
                    : 0.5
                analysisAltitudes[index] = Self.interpolate(previous, next, min(1, max(0, fraction)))
            }
        }

        var corrected = Array<Double?>(repeating: nil, count: count)
        var runIDs = Array<Int?>(repeating: nil, count: count)
        var reliableRunIDs = Array<Int?>(repeating: nil, count: count)
        var nextRunID = 0
        var cursor = 0

        while cursor < count {
            try checkCancellation(index: cursor, policy: policy, isCancelled: isCancelled)
            guard analysisAltitudes[cursor] != nil else {
                cursor += 1
                continue
            }
            let segment = routePoints[cursor].routeSegmentIndex
            let start = cursor
            cursor += 1
            while cursor < count,
                  routePoints[cursor].routeSegmentIndex == segment,
                  analysisAltitudes[cursor] != nil {
                try checkCancellation(index: cursor, policy: policy, isCancelled: isCancelled)
                cursor += 1
            }
            let end = cursor
            let runCount = end - start
            let runID = nextRunID
            nextRunID += 1
            for index in start..<end {
                try checkCancellation(index: index, policy: policy, isCancelled: isCancelled)
                runIDs[index] = runID
                if runCount >= policy.minimumReliableAltitudeSampleCount {
                    reliableRunIDs[index] = runID
                }
            }

            if runCount < policy.minimumReliableAltitudeSampleCount
                || policy.elevationSmoothingRadiusMeters == 0 {
                for index in start..<end {
                    corrected[index] = analysisAltitudes[index]
                }
                continue
            }

            var left = start
            var right = start
            var sum = 0.0
            var windowCount = 0
            for index in start..<end {
                try checkCancellation(index: index, policy: policy, isCancelled: isCancelled)
                let centerDistance = routePoints[index].distanceFromStartMeters
                let upperDistance = centerDistance + policy.elevationSmoothingRadiusMeters
                while right < end,
                      routePoints[right].distanceFromStartMeters <= upperDistance {
                    try checkCancellation(index: right, policy: policy, isCancelled: isCancelled)
                    if let value = analysisAltitudes[right] {
                        sum += value
                        windowCount += 1
                    }
                    right += 1
                }

                let lowerDistance = centerDistance - policy.elevationSmoothingRadiusMeters
                while left < right,
                      routePoints[left].distanceFromStartMeters < lowerDistance {
                    try checkCancellation(index: left, policy: policy, isCancelled: isCancelled)
                    if let value = analysisAltitudes[left] {
                        sum -= value
                        windowCount -= 1
                    }
                    left += 1
                }
                corrected[index] = windowCount > 0 ? sum / Double(windowCount) : analysisAltitudes[index]
            }
            // Avoid moving the endpoints of a continuous recorded span.
            corrected[start] = analysisAltitudes[start]
            corrected[end - 1] = analysisAltitudes[end - 1]
        }

        var cumulativeAscent = Array(repeating: 0.0, count: count)
        var cumulativeDescent = Array(repeating: 0.0, count: count)
        var cumulativeSigned = Array(repeating: 0.0, count: count)
        var reliableIntervals = Array(repeating: 0.0, count: count)
        var globalAscent = 0.0
        var globalDescent = 0.0
        var globalSigned = 0.0
        var globalReliableIntervals = 0.0
        cursor = 0

        while cursor < count {
            try checkCancellation(index: cursor, policy: policy, isCancelled: isCancelled)
            if let runID = runIDs[cursor] {
                let start = cursor
                cursor += 1
                while cursor < count, runIDs[cursor] == runID {
                    try checkCancellation(index: cursor, policy: policy, isCancelled: isCancelled)
                    cursor += 1
                }
                let end = cursor
                let isReliable = reliableRunIDs[start] != nil

                guard isReliable, let firstAltitude = corrected[start] else {
                    for index in start..<end {
                        try checkCancellation(index: index, policy: policy, isCancelled: isCancelled)
                        cumulativeAscent[index] = globalAscent
                        cumulativeDescent[index] = globalDescent
                        cumulativeSigned[index] = globalSigned
                        reliableIntervals[index] = globalReliableIntervals
                    }
                    continue
                }

                var trend = 0 // 0 unknown, 1 rising, -1 falling
                var pivot = firstAltitude
                var extreme = firstAltitude
                var committedAscent = globalAscent
                var committedDescent = globalDescent
                var previousAltitude = firstAltitude

                for index in start..<end {
                    try checkCancellation(index: index, policy: policy, isCancelled: isCancelled)
                    guard let altitude = corrected[index] else { continue }
                    if index > start {
                        globalSigned += altitude - previousAltitude
                        globalReliableIntervals += 1
                    }
                    previousAltitude = altitude

                    switch trend {
                    case 0:
                        if altitude - pivot >= policy.elevationGainLossDeadbandMeters {
                            trend = 1
                            extreme = altitude
                        } else if pivot - altitude >= policy.elevationGainLossDeadbandMeters {
                            trend = -1
                            extreme = altitude
                        }
                    case 1:
                        if altitude > extreme {
                            extreme = altitude
                        } else if extreme - altitude >= policy.elevationGainLossDeadbandMeters {
                            committedAscent += max(0, extreme - pivot)
                            pivot = extreme
                            trend = -1
                            extreme = altitude
                        }
                    default:
                        if altitude < extreme {
                            extreme = altitude
                        } else if altitude - extreme >= policy.elevationGainLossDeadbandMeters {
                            committedDescent += max(0, pivot - extreme)
                            pivot = extreme
                            trend = 1
                            extreme = altitude
                        }
                    }

                    let provisionalAscent = trend == 1 ? max(0, extreme - pivot) : 0
                    let provisionalDescent = trend == -1 ? max(0, pivot - extreme) : 0
                    cumulativeAscent[index] = committedAscent + provisionalAscent
                    cumulativeDescent[index] = committedDescent + provisionalDescent
                    cumulativeSigned[index] = globalSigned
                    reliableIntervals[index] = globalReliableIntervals
                }
                globalAscent = cumulativeAscent[end - 1]
                globalDescent = cumulativeDescent[end - 1]
            } else {
                cumulativeAscent[cursor] = globalAscent
                cumulativeDescent[cursor] = globalDescent
                cumulativeSigned[cursor] = globalSigned
                reliableIntervals[cursor] = globalReliableIntervals
                cursor += 1
            }
        }

        let meaningful = (reliableIntervals.last ?? 0) > 0
        // ⚡ Bolt: Inline array building avoids multiple O(N) array allocations from .map(\.property).
        var samples: [ElevationProfileSample] = []
        var distances: [Double] = []
        var segmentIndexes: [Int] = []
        samples.reserveCapacity(count)
        distances.reserveCapacity(count)
        segmentIndexes.reserveCapacity(count)

        for index in routePoints.indices {
            try checkCancellation(index: index, policy: policy, isCancelled: isCancelled)
            let point = routePoints[index]
            samples.append(ElevationProfileSample(
                routePointID: point.id,
                distanceFromStartMeters: point.distanceFromStartMeters,
                routeSegmentIndex: point.routeSegmentIndex,
                correctedAltitudeMeters: corrected[index],
                sourceAltitudeWasRejected: rejected[index],
                cumulativeAscentMeters: cumulativeAscent[index],
                cumulativeDescentMeters: cumulativeDescent[index]
            ))
            distances.append(point.distanceFromStartMeters)
            segmentIndexes.append(point.routeSegmentIndex)
        }

        let profile = ElevationProfile(
            samples: samples,
            hasMeaningfulElevation: meaningful,
            totalAscentMeters: meaningful ? cumulativeAscent.last : nil,
            totalDescentMeters: meaningful ? cumulativeDescent.last : nil,
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
        return (profile, rejected.count(where: { $0 }))
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

    private static func checkCancellation(
        index: Int,
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws {
        if index.isMultiple(of: policy.cancellationCheckStride), isCancelled() {
            throw CancellationError()
        }
    }
}
