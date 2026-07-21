import Foundation

/// Builds a deterministic route metric profile for native map coloring.
///
/// Single source of truth for pace, heart-rate, and corrected-elevation interval
/// semantics. Platform and UI must not recompute metrics independently.
public struct RouteMetricProfileBuilder: Sendable {
    public init() {}

    // MARK: - Public API

    public func build(
        workout: RunWorkout,
        context: WorkoutAnalysisContext,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy = .runningDefault,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteMetricProfile {
        try build(
            routePoints: workout.routePoints,
            context: context,
            mode: mode,
            policy: policy,
            isCancelled: isCancelled
        )
    }

    public func build(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy = .runningDefault,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteMetricProfile {
        if isCancelled() { throw CancellationError() }

        switch mode {
        case .solid:
            return solidProfile(routePoints: routePoints, policy: policy)
        case .pace:
            return try paceProfile(
                routePoints: routePoints,
                context: context,
                policy: policy,
                isCancelled: isCancelled
            )
        case .heartRate:
            return try heartRateProfile(
                routePoints: routePoints,
                context: context,
                policy: policy,
                isCancelled: isCancelled
            )
        case .correctedElevation:
            return try elevationProfile(
                routePoints: routePoints,
                context: context,
                policy: policy,
                isCancelled: isCancelled
            )
        }
    }

    /// Lightweight availability probe without full line coalescing.
    public func availability(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy = .runningDefault,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteMetricModeAvailability {
        try probe(
            routePoints: routePoints,
            context: context,
            policy: policy,
            isCancelled: isCancelled
        ).availability
    }

    /// Build availability and all three metric profiles in one reusable probe.
    public func probe(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy = .runningDefault,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteMetricProfileProbe {
        if isCancelled() { throw CancellationError() }

        let pace = try build(
            routePoints: routePoints,
            context: context,
            mode: .pace,
            policy: policy,
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        let hr = try build(
            routePoints: routePoints,
            context: context,
            mode: .heartRate,
            policy: policy,
            isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        let elev = try build(
            routePoints: routePoints,
            context: context,
            mode: .correctedElevation,
            policy: policy,
            isCancelled: isCancelled
        )

        let availability = RouteMetricModeAvailability(
            solid: true,
            pace: isModeEnabled(profile: pace, policy: policy, coverageFloor: policy.minimumValidCoverageFraction),
            heartRate: isModeEnabled(
                profile: hr,
                policy: policy,
                coverageFloor: policy.minimumHeartRateCoverageFraction
            ),
            correctedElevation: isModeEnabled(
                profile: elev,
                policy: policy,
                coverageFloor: policy.minimumElevationCoverageFraction
            ),
            heartRateCoverageFraction: hr.validCoverageFraction,
            elevationCoverageFraction: elev.validCoverageFraction,
            paceCoverageFraction: pace.validCoverageFraction
        )
        return RouteMetricProfileProbe(
            availability: availability,
            paceProfile: pace,
            heartRateProfile: hr,
            correctedElevationProfile: elev
        )
    }

    // MARK: - Solid

    private func solidProfile(
        routePoints: [RoutePoint],
        policy: RouteMetricColorPolicy
    ) -> RouteMetricProfile {
        let total = totalRouteDistance(routePoints)
        return RouteMetricProfile(
            mode: .solid,
            intervals: [],
            scale: nil,
            validCoverageDistanceMeters: total,
            totalRouteDistanceMeters: total,
            diagnostics: RouteMetricDiagnostics(
                intervalCount: 0,
                validIntervalCount: 0,
                noDataIntervalCount: 0,
                validCoverageFraction: total > 0 ? 1 : 0,
                bucketCount: policy.bucketCount,
                policyVersion: policy.policyVersion
            )
        )
    }

    // MARK: - Pace

    private func paceProfile(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfile {
        let raw = try rawIntervals(
            routePoints: routePoints,
            isCancelled: isCancelled
        ) { start, end, startIndex, endIndex in
            let distance = end.distanceFromStartMeters - start.distanceFromStartMeters
            guard distance > 0 else { return nil }

            let startActive = context.timeline.activeSeconds(atPointIndex: startIndex) ?? 0
            let endActive = context.timeline.activeSeconds(atPointIndex: endIndex) ?? 0
            let activeDelta = endActive - startActive
            guard activeDelta > 0, activeDelta.isFinite else { return nil }

            let pace = (activeDelta / distance) * 1000.0
            guard pace.isFinite,
                  policy.validPaceRangeSecondsPerKm.contains(pace)
            else { return nil }
            return pace
        }

        let smoothed = try smoothDistanceDomain(
            rawValues: raw.map(\.metricValue),
            intervals: raw,
            halfWindowMeters: policy.paceSmoothingHalfWindowMeters,
            isCancelled: isCancelled
        )

        return try finalizeProfile(
            mode: .pace,
            routePoints: routePoints,
            rawIntervals: raw,
            smoothedValues: smoothed,
            direction: .lowerIsBetter,
            policy: policy,
            formatLower: { DisplayFormatter.formatPace($0) },
            formatMedian: { DisplayFormatter.formatPace($0) },
            formatUpper: { DisplayFormatter.formatPace($0) },
            isCancelled: isCancelled
        )
    }

    // MARK: - Heart rate

    private func heartRateProfile(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfile {
        let timeline = context.timeline
        let raw = try rawIntervals(
            routePoints: routePoints,
            isCancelled: isCancelled
        ) { start, end, startIndex, endIndex in
            let hr1 = validatedHR(start.heartRateBPM, policy: policy)
            let hr2 = validatedHR(end.heartRateBPM, policy: policy)

            if let h1 = hr1, let h2 = hr2 {
                return (h1 + h2) / 2
            }

            // Adjacent same-segment pairs may use a single valid endpoint when
            // the interval elapsed span is within the short-gap policy. Longer
            // sampling gaps remain no-data rather than inventing HR. Intervals
            // with neither endpoint never receive a median fill.
            guard let single = hr1 ?? hr2 else { return nil }
            let startElapsed = timeline.elapsedSeconds(atPointIndex: startIndex) ?? start.elapsedSeconds
            let endElapsed = timeline.elapsedSeconds(atPointIndex: endIndex) ?? end.elapsedSeconds
            let gap = abs(endElapsed - startElapsed)
            guard gap.isFinite, gap <= policy.maximumHeartRateEndpointGapSeconds else {
                return nil
            }
            return single
        }

        let smoothed = try smoothDistanceDomain(
            rawValues: raw.map(\.metricValue),
            intervals: raw,
            halfWindowMeters: policy.heartRateSmoothingHalfWindowMeters,
            isCancelled: isCancelled
        )

        return try finalizeProfile(
            mode: .heartRate,
            routePoints: routePoints,
            rawIntervals: raw,
            smoothedValues: smoothed,
            direction: .higherIsMore,
            policy: policy,
            formatLower: { DisplayFormatter.formatHeartRate($0) },
            formatMedian: { DisplayFormatter.formatHeartRate($0) },
            formatUpper: { DisplayFormatter.formatHeartRate($0) },
            isCancelled: isCancelled
        )
    }

    // MARK: - Corrected elevation

    private func elevationProfile(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfile {
        let elevation = context.elevationProfile
        guard elevation.hasMeaningfulElevation else {
            let raw = try rawIntervals(
                routePoints: routePoints,
                isCancelled: isCancelled
            ) { _, _, _, _ in nil }
            return try finalizeProfile(
                mode: .correctedElevation,
                routePoints: routePoints,
                rawIntervals: raw,
                smoothedValues: Array(repeating: nil, count: raw.count),
                direction: .higherIsMore,
                policy: policy,
                minimumScaleSpan: policy.minimumElevationSpanMeters,
                formatLower: { DisplayFormatter.formatElevation($0) },
                formatMedian: { DisplayFormatter.formatElevation($0) },
                formatUpper: { DisplayFormatter.formatElevation($0) },
                isCancelled: isCancelled
            )
        }
        var elevationSamplesByPointID: [UUID: ElevationProfileSample] = [:]
        elevationSamplesByPointID.reserveCapacity(elevation.samples.count)
        for sample in elevation.samples {
            elevationSamplesByPointID[sample.routePointID] = sample
        }
        let raw = try rawIntervals(
            routePoints: routePoints,
            isCancelled: isCancelled
        ) { start, end, startIndex, endIndex in
            guard let e1 = correctedAltitude(
                at: startIndex,
                point: start,
                profile: elevation,
                samplesByPointID: elevationSamplesByPointID
            ),
            let e2 = correctedAltitude(
                at: endIndex,
                point: end,
                profile: elevation,
                samplesByPointID: elevationSamplesByPointID
            ) else {
                return nil
            }
            return (e1 + e2) / 2
        }

        // Elevation is already corrected/smoothed in ElevationProfile; do not
        // re-smooth. Pass raw values through as the smoothed series.
        let values = raw.map(\.metricValue)

        return try finalizeProfile(
            mode: .correctedElevation,
            routePoints: routePoints,
            rawIntervals: raw,
            smoothedValues: values,
            direction: .higherIsMore,
            policy: policy,
            minimumScaleSpan: policy.minimumElevationSpanMeters,
            formatLower: { DisplayFormatter.formatElevation($0) },
            formatMedian: { DisplayFormatter.formatElevation($0) },
            formatUpper: { DisplayFormatter.formatElevation($0) },
            isCancelled: isCancelled
        )
    }

    // MARK: - Shared construction

    private struct RawInterval {
        let startPointIndex: Int
        let endPointIndex: Int
        let routeSegmentIndex: Int
        let startDistanceMeters: Double
        let endDistanceMeters: Double
        let metricValue: Double?
    }

    private func rawIntervals(
        routePoints: [RoutePoint],
        isCancelled: @Sendable () -> Bool,
        metric: (RoutePoint, RoutePoint, Int, Int) -> Double?
    ) throws -> [RawInterval] {
        guard routePoints.count >= 2 else { return [] }

        var result: [RawInterval] = []
        result.reserveCapacity(routePoints.count - 1)

        for i in 0..<(routePoints.count - 1) {
            if i % 512 == 0, isCancelled() { throw CancellationError() }

            let start = routePoints[i]
            let end = routePoints[i + 1]

            // Never form a metric interval across route segment boundaries.
            guard start.routeSegmentIndex == end.routeSegmentIndex else { continue }

            let startDistance = start.distanceFromStartMeters
            let endDistance = end.distanceFromStartMeters
            guard startDistance.isFinite, endDistance.isFinite else { continue }

            let value = metric(start, end, i, i + 1)
            let finiteValue: Double? = {
                guard let value, value.isFinite else { return nil }
                return value
            }()

            result.append(RawInterval(
                startPointIndex: i,
                endPointIndex: i + 1,
                routeSegmentIndex: start.routeSegmentIndex,
                startDistanceMeters: startDistance,
                endDistanceMeters: max(startDistance, endDistance),
                metricValue: finiteValue
            ))
        }
        return result
    }

    /// Distance-domain moving average within continuous valid runs of one segment.
    ///
    /// Uses a two-pointer window so work is O(n) per contiguous valid run, not O(n²).
    private func smoothDistanceDomain(
        rawValues: [Double?],
        intervals: [RawInterval],
        halfWindowMeters: Double,
        isCancelled: @Sendable () -> Bool
    ) throws -> [Double?] {
        guard rawValues.count == intervals.count else { return rawValues }
        guard halfWindowMeters > 0 else { return rawValues }

        var output: [Double?] = Array(repeating: nil, count: rawValues.count)

        // Process per continuous same-segment run so we never bridge gaps.
        var runStart = 0
        while runStart < intervals.count {
            if runStart % 256 == 0, isCancelled() { throw CancellationError() }

            var runEnd = runStart + 1
            let segment = intervals[runStart].routeSegmentIndex
            while runEnd < intervals.count,
                  intervals[runEnd].routeSegmentIndex == segment,
                  intervals[runEnd].startPointIndex == intervals[runEnd - 1].endPointIndex {
                runEnd += 1
            }

            // Within the run, only smooth across contiguous valid samples;
            // break at nil so missing data remains missing.
            var validStart = runStart
            while validStart < runEnd {
                while validStart < runEnd, rawValues[validStart] == nil {
                    output[validStart] = nil
                    validStart += 1
                }
                guard validStart < runEnd else { break }

                var validEnd = validStart + 1
                while validEnd < runEnd, rawValues[validEnd] != nil {
                    validEnd += 1
                }

                // Prefix sums make each triangular-window evaluation O(1)
                // after the two pointers advance. This remains linear even
                // when thousands of samples share nearly the same distance.
                let count = validEnd - validStart
                let distanceOrigin = midpoint(of: intervals[validStart])
                var distances = Array(repeating: 0.0, count: count)
                var values = Array(repeating: 0.0, count: count)
                var prefixDistance = Array(repeating: 0.0, count: count + 1)
                var prefixValue = Array(repeating: 0.0, count: count + 1)
                var prefixValueDistance = Array(repeating: 0.0, count: count + 1)

                for offset in 0..<count {
                    let sourceIndex = validStart + offset
                    let distance = midpoint(of: intervals[sourceIndex]) - distanceOrigin
                    let value = rawValues[sourceIndex] ?? 0
                    distances[offset] = distance
                    values[offset] = value
                    prefixDistance[offset + 1] = prefixDistance[offset] + distance
                    prefixValue[offset + 1] = prefixValue[offset] + value
                    prefixValueDistance[offset + 1] = prefixValueDistance[offset] + value * distance
                }

                var left = 0
                var right = 0
                for offset in 0..<count {
                    let outputIndex = validStart + offset
                    if outputIndex % 1024 == 0, isCancelled() { throw CancellationError() }

                    let centerValue = values[offset]
                    let centerDistance = distances[offset]
                    let windowLow = centerDistance - halfWindowMeters
                    let windowHigh = centerDistance + halfWindowMeters

                    while left < offset, distances[left] < windowLow {
                        left += 1
                    }
                    if right < offset { right = offset }
                    while right + 1 < count, distances[right + 1] <= windowHigh {
                        right += 1
                    }

                    let inverseWindow = 1.0 / max(halfWindowMeters, Double.leastNonzeroMagnitude)
                    let leftEnd = offset + 1
                    let leftCount = Double(leftEnd - left)
                    let leftDistance = prefixDistance[leftEnd] - prefixDistance[left]
                    let leftValue = prefixValue[leftEnd] - prefixValue[left]
                    let leftValueDistance = prefixValueDistance[leftEnd] - prefixValueDistance[left]
                    var sum = (1 - centerDistance * inverseWindow) * leftValue
                        + inverseWindow * leftValueDistance
                    var weight = (1 - centerDistance * inverseWindow) * leftCount
                        + inverseWindow * leftDistance

                    if right > offset {
                        let rightStart = offset + 1
                        let rightEnd = right + 1
                        let rightCount = Double(rightEnd - rightStart)
                        let rightDistance = prefixDistance[rightEnd] - prefixDistance[rightStart]
                        let rightValue = prefixValue[rightEnd] - prefixValue[rightStart]
                        let rightValueDistance = prefixValueDistance[rightEnd] - prefixValueDistance[rightStart]
                        sum += (1 + centerDistance * inverseWindow) * rightValue
                            - inverseWindow * rightValueDistance
                        weight += (1 + centerDistance * inverseWindow) * rightCount
                            - inverseWindow * rightDistance
                    }

                    if weight > 1e-12, sum.isFinite {
                        output[outputIndex] = sum / weight
                    } else {
                        output[outputIndex] = centerValue
                    }
                }

                validStart = validEnd
            }

            runStart = runEnd
        }

        return output
    }

    private func midpoint(of interval: RawInterval) -> Double {
        (interval.startDistanceMeters + interval.endDistanceMeters) / 2
    }

    private func finalizeProfile(
        mode: WorkoutRouteColorMode,
        routePoints: [RoutePoint],
        rawIntervals: [RawInterval],
        smoothedValues: [Double?],
        direction: RouteMetricScaleDirection,
        policy: RouteMetricColorPolicy,
        minimumScaleSpan: Double = 0,
        formatLower: (Double) -> String,
        formatMedian: (Double) -> String,
        formatUpper: (Double) -> String,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfile {
        if isCancelled() { throw CancellationError() }

        var samples: [DistanceWeightedStatistics.WeightedSample] = []
        samples.reserveCapacity(smoothedValues.count)
        var validCoverage = 0.0
        var validCount = 0

        for (index, value) in smoothedValues.enumerated() {
            let distance = max(0, rawIntervals[index].endDistanceMeters - rawIntervals[index].startDistanceMeters)
            guard let value, value.isFinite, distance > 0 else { continue }
            samples.append(.init(value: value, weight: distance))
            validCoverage += distance
            validCount += 1
        }

        let totalDistance = totalRouteDistance(routePoints)
        let scale: RouteMetricScale?
        if validCount >= policy.minimumValidIntervalCount,
           let lower = DistanceWeightedStatistics.weightedQuantile(samples, quantile: policy.lowerQuantile),
           let median = DistanceWeightedStatistics.weightedMedian(samples),
           let upper = DistanceWeightedStatistics.weightedQuantile(samples, quantile: policy.upperQuantile),
           abs(upper - lower) + 1e-12 >= max(0, minimumScaleSpan) {
            // Equal bounds remain safe; normalization maps everything to 0.5.
            scale = RouteMetricScale(
                lowerBound: lower,
                median: median,
                upperBound: upper,
                lowerLabel: formatLower(lower),
                medianLabel: formatMedian(median),
                upperLabel: formatUpper(upper),
                direction: direction
            )
        } else {
            scale = nil
        }

        var intervals: [RouteMetricInterval] = []
        intervals.reserveCapacity(rawIntervals.count)
        var noDataCount = 0

        for (index, raw) in rawIntervals.enumerated() {
            if index % policy.cancellationStride == 0, isCancelled() {
                throw CancellationError()
            }
            let value = smoothedValues[index]
            let normalized: Double?
            let bucket: RouteMetricColorBucket
            if let value, let scale {
                let n = normalize(value: value, scale: scale)
                normalized = n
                bucket = .level(bucketIndex(normalized: n, bucketCount: policy.bucketCount))
            } else {
                normalized = nil
                bucket = .noData
                noDataCount += 1
            }

            intervals.append(RouteMetricInterval(
                startPointIndex: raw.startPointIndex,
                endPointIndex: raw.endPointIndex,
                routeSegmentIndex: raw.routeSegmentIndex,
                startDistanceMeters: raw.startDistanceMeters,
                endDistanceMeters: raw.endDistanceMeters,
                metricValue: value,
                normalizedValue: normalized,
                bucket: bucket
            ))
        }

        let coverageFraction = totalDistance > 0
            ? min(1, max(0, validCoverage / totalDistance))
            : 0

        return RouteMetricProfile(
            mode: mode,
            intervals: intervals,
            scale: scale,
            validCoverageDistanceMeters: validCoverage,
            totalRouteDistanceMeters: totalDistance,
            diagnostics: RouteMetricDiagnostics(
                intervalCount: intervals.count,
                validIntervalCount: validCount,
                noDataIntervalCount: noDataCount,
                validCoverageFraction: coverageFraction,
                bucketCount: policy.bucketCount,
                policyVersion: policy.policyVersion
            )
        )
    }

    /// Normalize raw metric into `0...1` with explicit direction handling.
    ///
    /// Pace (lowerIsBetter): lower seconds → 0 (fast end of legend).
    /// HR / elevation (higherIsMore): lower → 0, higher → 1.
    public func normalize(value: Double, scale: RouteMetricScale) -> Double {
        guard value.isFinite else { return 0.5 }
        let lower = scale.lowerBound
        let upper = scale.upperBound
        let span = upper - lower
        guard span.isFinite, abs(span) > 1e-12 else { return 0.5 }

        // Both directions store lowerBound as the palette-start (normalized 0)
        // quantile: fast pace / low HR / low elevation. Direction is retained for
        // legend wording only.
        let clamped = min(max(value, min(lower, upper)), max(lower, upper))
        let t = (clamped - lower) / span
        return min(1, max(0, t))
    }

    public func bucketIndex(normalized: Double, bucketCount: Int) -> Int {
        let count = max(2, bucketCount)
        let clamped = min(1, max(0, normalized))
        if clamped >= 1 { return count - 1 }
        return min(count - 1, Int(clamped * Double(count)))
    }

    // MARK: - Helpers

    private func validatedHR(_ value: Double?, policy: RouteMetricColorPolicy) -> Double? {
        guard let value,
              value.isFinite,
              policy.validHeartRateRange.contains(value),
              MetricValidation.isValidHeartRate(value)
        else { return nil }
        return value
    }

    private func correctedAltitude(
        at index: Int,
        point: RoutePoint,
        profile: ElevationProfile,
        samplesByPointID: [UUID: ElevationProfileSample]
    ) -> Double? {
        if profile.samples.indices.contains(index),
           let altitude = alignedCorrectedAltitude(
               sample: profile.samples[index],
               point: point
           ) {
            return altitude
        }

        // Legacy SceneKit projection can filter invalid coordinates, leaving
        // compact scene points whose source indices no longer match the
        // elevation profile array. Fall back to identity-based alignment.
        guard let sample = samplesByPointID[point.id] else { return nil }
        return alignedCorrectedAltitude(sample: sample, point: point)
    }

    private func alignedCorrectedAltitude(
        sample: ElevationProfileSample,
        point: RoutePoint
    ) -> Double? {
        guard sample.routePointID == point.id,
              sample.distanceFromStartMeters == point.distanceFromStartMeters,
              sample.routeSegmentIndex == point.routeSegmentIndex,
              let altitude = sample.correctedAltitudeMeters,
              altitude.isFinite
        else {
            return nil
        }
        return altitude
    }

    private func totalRouteDistance(_ points: [RoutePoint]) -> Double {
        guard let last = points.last, last.distanceFromStartMeters.isFinite else { return 0 }
        return max(0, last.distanceFromStartMeters)
    }

    private func isModeEnabled(
        profile: RouteMetricProfile,
        policy: RouteMetricColorPolicy,
        coverageFloor: Double
    ) -> Bool {
        guard profile.scale != nil else { return false }
        guard profile.diagnostics.validIntervalCount >= policy.minimumValidIntervalCount else {
            return false
        }
        return profile.validCoverageFraction + 1e-12 >= coverageFloor
    }
}
