package enum EngineElevationProfile {
    package static func build(
        samples: Span<EngineElevationProfileInput>, policy: EngineElevationProfilePolicy
    ) throws(ElevationProfileError) -> EngineElevationProfileResult {
        let count = samples.count
        if count == 0 {
            return .init(samples: [], rejectedAltitudeCount: 0, runCount: 0, reliableRunCount: 0,
                         hasMeaningfulElevation: false, totalAscentMeters: 0, totalDescentMeters: 0)
        }
        guard count <= EngineRouteLimits.maxRouteInputSamples else { throw .resourceLimit }
        try validate(policy)
        try validate(samples)

        var output = unsafe [EngineElevationProfileSample](unsafeUninitializedCapacity: count) { buffer, initialized in
            // SAFETY: each element is initialized once, in bounds, before any stage reads or mutates it.
            for index in samples.indices {
                let sample = samples[index]
                var value = EngineElevationProfileSample()
                if sample.hasAltitude != 0 {
                    let altitude = sample.altitudeMeters
                    if altitude.isFinite && altitude >= policy.plausibleAltitudeMinimumMeters
                        && altitude <= policy.plausibleAltitudeMaximumMeters {
                        value.setWorkingAltitude(altitude)
                    } else {
                        value.rejectAltitude()
                    }
                }
                unsafe buffer.initializeElement(at: index, to: value)
                initialized += 1
            }
        }
        var runCount = 0
        var reliableRunCount = 0
        do {
            // The stages mutate one fixed-size buffer, so a MutableSpan avoids per-access array uniqueness checks.
            var working = output.mutableSpan
            rejectEndpoints(samples, policy, &working)
            rejectInterior(samples, policy, &working)
            rejectExcursions(samples, policy, &working)
            fillRejected(samples, &working)
            (runCount, reliableRunCount) = smoothRuns(samples, policy, &working)
            cumulativeGainLoss(policy, &working)
        }

        var rejectedCount = 0
        for sample in output where sample.sourceAltitudeWasRejected {
            rejectedCount += 1
        }
        let last = output[count - 1]
        let meaningful = last.reliableIntervalCount > 0
        return .init(samples: output, rejectedAltitudeCount: rejectedCount,
                     runCount: runCount, reliableRunCount: reliableRunCount,
                     hasMeaningfulElevation: meaningful,
                     totalAscentMeters: meaningful ? last.cumulativeAscentMeters : 0,
                     totalDescentMeters: meaningful ? last.cumulativeDescentMeters : 0)
    }

    private static func validate(_ policy: EngineElevationProfilePolicy) throws(ElevationProfileError) {
        guard policy.plausibleAltitudeMinimumMeters.isFinite,
              policy.plausibleAltitudeMaximumMeters.isFinite,
              policy.spikeMinimumDeviationMeters.isFinite,
              policy.shortExcursionMinimumDeviationMeters.isFinite,
              policy.spikeMaximumNeighborDifferenceMeters.isFinite,
              policy.spikeMaximumHorizontalSpanMeters.isFinite,
              policy.smoothingRadiusMeters.isFinite,
              policy.gainLossDeadbandMeters.isFinite,
              policy.plausibleAltitudeMinimumMeters <= policy.plausibleAltitudeMaximumMeters,
              policy.spikeMinimumDeviationMeters >= 0,
              policy.shortExcursionMinimumDeviationMeters >= policy.spikeMinimumDeviationMeters,
              policy.shortExcursionMaximumSampleCount >= 1,
              policy.spikeMaximumNeighborDifferenceMeters >= 0,
              policy.spikeMaximumHorizontalSpanMeters >= 0,
              policy.smoothingRadiusMeters >= 0,
              policy.minimumReliableSampleCount >= 2,
              policy.gainLossDeadbandMeters >= 0 else { throw .invalidPolicy }
    }

    private static func validate(_ samples: Span<EngineElevationProfileInput>) throws(ElevationProfileError) {
        guard samples[0].continuityGroup == 0 else { throw .invalidInputContract }
        var previousGroup: Int32 = 0
        for index in samples.indices {
            let sample = samples[index]
            guard sample.hasAltitude <= 1, sample.continuityGroup >= previousGroup,
                  sample.continuityGroup - previousGroup <= 1 else { throw .invalidInputContract }
            previousGroup = sample.continuityGroup
        }
    }

    private static func interpolate(_ first: Double, _ second: Double, _ fraction: Double) -> Double {
        let difference = second - first
        let scaled = difference * fraction
        return first + scaled
    }

    private static func clampUnit(_ fraction: Double) -> Double {
        if fraction < 0 { return 0 }
        if fraction > 1 { return 1 }
        return fraction
    }

    private static func positivePart(_ value: Double) -> Double {
        // C++ std::max(0.0, value) keeps its first argument for NaN and signed zero.
        value > 0 ? value : 0
    }
}

extension EngineElevationProfileSample {
    fileprivate mutating func setWorkingAltitude(_ altitude: Double) {
        correctedAltitudeMeters = altitude
        hasCorrectedAltitude = true
    }

    fileprivate mutating func rejectAltitude() {
        correctedAltitudeMeters = 0
        hasCorrectedAltitude = false
        sourceAltitudeWasRejected = true
    }
}

extension EngineElevationProfile {
    private static func rejectEndpoints(
        _ samples: Span<EngineElevationProfileInput>, _ policy: EngineElevationProfilePolicy,
        _ output: inout MutableSpan<EngineElevationProfileSample>
    ) {
        let count = samples.count
        // Both spans hold `count` elements: `build` creates the working buffer
        // from `samples.count`. The check runs once per stage, not per access.
        precondition(output.count == count)
        // SAFETY: every unchecked index is `cursor < count`, a run bound in
        // `start..<end` with `end <= count`, or `end - 1` with `end - start >= 3`.
        guard count >= 3 else { return }
        var cursor = 0
        while cursor < count {
            guard unsafe output[unchecked: cursor].hasCorrectedAltitude else {
                cursor += 1
                continue
            }
            let group = unsafe samples[unchecked: cursor].continuityGroup
            let start = cursor
            cursor += 1
            // The span is read outside `&&`: a span read inside that autoclosure
            // crashes Swift 6.3.3 in an optimized build (CopyPropagation).
            while cursor < count {
                guard unsafe samples[unchecked: cursor].continuityGroup == group else { break }
                guard unsafe output[unchecked: cursor].hasCorrectedAltitude else { break }
                cursor += 1
            }
            let end = cursor
            if end - start < 3 { continue }

            // Both decisions must read the same, pre-mutation working altitudes.
            let rejectLeading = isEndpointSpike(start, near: start + 1, far: start + 2,
                                                samples: samples, policy: policy, output: output)
            let rejectTrailing = isEndpointSpike(end - 1, near: end - 2, far: end - 3,
                                                 samples: samples, policy: policy, output: output)
            if rejectLeading { unsafe output[unchecked: start].rejectAltitude() }
            if rejectTrailing { unsafe output[unchecked: end - 1].rejectAltitude() }
        }
    }

    private static func isEndpointSpike(
        _ index: Int, near nearIndex: Int, far farIndex: Int,
        samples: Span<EngineElevationProfileInput>, policy: EngineElevationProfilePolicy,
        output: borrowing MutableSpan<EngineElevationProfileSample>
    ) -> Bool {
        // SAFETY: the caller passes three indices of one run inside `0..<count`
        // of `rejectEndpoints`, whose spans have the same count.
        guard unsafe output[unchecked: index].hasCorrectedAltitude, unsafe output[unchecked: nearIndex].hasCorrectedAltitude,
              unsafe output[unchecked: farIndex].hasCorrectedAltitude else { return false }
        let endpoint = unsafe output[unchecked: index].correctedAltitudeMeters
        let near = unsafe output[unchecked: nearIndex].correctedAltitudeMeters
        let far = unsafe output[unchecked: farIndex].correctedAltitudeMeters
        if abs(near - far) > policy.spikeMaximumNeighborDifferenceMeters { return false }

        let travelledSpan = unsafe abs(samples[unchecked: farIndex].distanceMeters - samples[unchecked: index].distanceMeters)
        let midpoint = (near + far) / 2
        if !travelledSpan.isFinite || travelledSpan > policy.spikeMaximumHorizontalSpanMeters
            || abs(endpoint - midpoint) < policy.spikeMinimumDeviationMeters
            || abs(endpoint - near) < policy.spikeMinimumDeviationMeters
            || abs(endpoint - far) < policy.spikeMinimumDeviationMeters {
            return false
        }
        return true
    }

    private static func rejectInterior(
        _ samples: Span<EngineElevationProfileInput>, _ policy: EngineElevationProfilePolicy,
        _ output: inout MutableSpan<EngineElevationProfileSample>
    ) {
        let count = samples.count
        // Both spans hold `count` elements: `build` creates the working buffer
        // from `samples.count`. The check runs once per stage, not per access.
        precondition(output.count == count)
        // SAFETY: `index` is in `1..<(count - 1)`, so `index - 1` and `index + 1`
        // are in `0..<count`.
        guard count >= 3 else { return }
        for index in 1..<(count - 1) {
            guard unsafe samples[unchecked: index - 1].continuityGroup == samples[unchecked: index].continuityGroup,
                  unsafe samples[unchecked: index].continuityGroup == samples[unchecked: index + 1].continuityGroup,
                  unsafe output[unchecked: index - 1].hasCorrectedAltitude, unsafe output[unchecked: index].hasCorrectedAltitude,
                  unsafe output[unchecked: index + 1].hasCorrectedAltitude else { continue }
            let previous = unsafe output[unchecked: index - 1].correctedAltitudeMeters
            let current = unsafe output[unchecked: index].correctedAltitudeMeters
            let next = unsafe output[unchecked: index + 1].correctedAltitudeMeters
            if abs(previous - next) > policy.spikeMaximumNeighborDifferenceMeters { continue }
            let horizontalSpan = unsafe samples[unchecked: index + 1].distanceMeters - samples[unchecked: index - 1].distanceMeters
            if !horizontalSpan.isFinite || horizontalSpan > policy.spikeMaximumHorizontalSpanMeters { continue }

            let midpoint = (previous + next) / 2
            if abs(current - midpoint) < policy.spikeMinimumDeviationMeters
                || abs(current - previous) < policy.spikeMinimumDeviationMeters
                || abs(current - next) < policy.spikeMinimumDeviationMeters { continue }
            unsafe output[unchecked: index].rejectAltitude()
        }
    }

    private static func rejectExcursions(
        _ samples: Span<EngineElevationProfileInput>, _ policy: EngineElevationProfilePolicy,
        _ output: inout MutableSpan<EngineElevationProfileSample>
    ) {
        let count = samples.count
        // Both spans hold `count` elements: `build` creates the working buffer
        // from `samples.count`. The check runs once per stage, not per access.
        precondition(output.count == count)
        // SAFETY: `start >= 1` and `start + 1 < count`; `end` is read only after
        // `end + 1 < count` or `end < count` holds; `start - 1 >= 0`.
        let maxExcursion = policy.shortExcursionMaximumSampleCount
        guard count >= 4, maxExcursion >= 2 else { return }
        var start = 1
        while start + 1 < count {
            guard unsafe output[unchecked: start].hasCorrectedAltitude else {
                start += 1
                continue
            }

            let first = unsafe output[unchecked: start].correctedAltitudeMeters
            var end = start + 1
            // The span is read outside `&&`: a span read inside that autoclosure
            // crashes Swift 6.3.3 in an optimized build (CopyPropagation).
            while end + 1 < count {
                guard UInt64(end - start) < maxExcursion else { break }
                guard unsafe samples[unchecked: end].continuityGroup == samples[unchecked: start].continuityGroup else { break }
                guard unsafe output[unchecked: end].hasCorrectedAltitude else { break }
                let neighborDifference = unsafe abs(output[unchecked: end].correctedAltitudeMeters - first)
                guard neighborDifference <= policy.spikeMaximumNeighborDifferenceMeters else { break }
                end += 1
            }

            guard end - start >= 2, end < count,
                  unsafe samples[unchecked: start - 1].continuityGroup == samples[unchecked: start].continuityGroup,
                  unsafe samples[unchecked: end].continuityGroup == samples[unchecked: start].continuityGroup,
                  unsafe output[unchecked: start - 1].hasCorrectedAltitude, unsafe output[unchecked: end].hasCorrectedAltitude else {
                start += 1
                continue
            }
            let before = unsafe output[unchecked: start - 1].correctedAltitudeMeters
            let after = unsafe output[unchecked: end].correctedAltitudeMeters
            if abs(before - after) > policy.spikeMaximumNeighborDifferenceMeters {
                start += 1
                continue
            }

            let midpoint = (before + after) / 2
            var extreme = true
            for index in start..<end {
                if unsafe !output[unchecked: index].hasCorrectedAltitude
                    || abs(output[unchecked: index].correctedAltitudeMeters - midpoint) < policy.shortExcursionMinimumDeviationMeters {
                    extreme = false
                    break
                }
            }

            let horizontalSpan = unsafe samples[unchecked: end].distanceMeters - samples[unchecked: start - 1].distanceMeters
            if !extreme || !horizontalSpan.isFinite || horizontalSpan > policy.spikeMaximumHorizontalSpanMeters {
                start += 1
                continue
            }
            for index in start..<end {
                unsafe output[unchecked: index].rejectAltitude()
            }
            start = end
        }
    }
}

extension EngineElevationProfile {
    private static func fillRejected(
        _ samples: Span<EngineElevationProfileInput>, _ output: inout MutableSpan<EngineElevationProfileSample>
    ) {
        let count = samples.count
        // Both spans hold `count` elements: `build` creates the working buffer
        // from `samples.count`. The check runs once per stage, not per access.
        precondition(output.count == count)
        // SAFETY: the first loop is `0..<count`; the others are `1..<(count - 1)`,
        // so `index - 1` and `index + 1` are in `0..<count`.
        guard count >= 3 else { return }
        for index in 0..<count {
            unsafe output[unchecked: index].cumulativeSignedChangeMeters = 0
            unsafe output[unchecked: index].reliableIntervalCount = 0
        }

        // Stage interpolation in spare output fields so fills don't chain.
        for index in 1..<(count - 1) {
            guard unsafe output[unchecked: index].sourceAltitudeWasRejected,
                  unsafe samples[unchecked: index - 1].continuityGroup == samples[unchecked: index].continuityGroup,
                  unsafe samples[unchecked: index].continuityGroup == samples[unchecked: index + 1].continuityGroup,
                  unsafe output[unchecked: index - 1].hasCorrectedAltitude,
                  unsafe output[unchecked: index + 1].hasCorrectedAltitude else { continue }
            let previous = unsafe output[unchecked: index - 1].correctedAltitudeMeters
            let next = unsafe output[unchecked: index + 1].correctedAltitudeMeters
            let span = unsafe samples[unchecked: index + 1].distanceMeters - samples[unchecked: index - 1].distanceMeters
            let fraction = unsafe span > 0 ? (samples[unchecked: index].distanceMeters - samples[unchecked: index - 1].distanceMeters) / span : 0.5
            unsafe output[unchecked: index].cumulativeSignedChangeMeters = interpolate(previous, next, clampUnit(fraction))
            unsafe output[unchecked: index].reliableIntervalCount = 1
        }

        for index in 1..<(count - 1) where unsafe output[unchecked: index].reliableIntervalCount != 0 {
            let fill = unsafe output[unchecked: index].cumulativeSignedChangeMeters
            unsafe output[unchecked: index].setWorkingAltitude(fill)
            unsafe output[unchecked: index].cumulativeSignedChangeMeters = 0
            unsafe output[unchecked: index].reliableIntervalCount = 0
        }
    }

    private static func smoothRuns(
        _ samples: Span<EngineElevationProfileInput>, _ policy: EngineElevationProfilePolicy,
        _ output: inout MutableSpan<EngineElevationProfileSample>
    ) -> (Int, Int) {
        let count = samples.count
        // Both spans hold `count` elements: `build` creates the working buffer
        // from `samples.count`. The check runs once per stage, not per access.
        precondition(output.count == count)
        // SAFETY: every unchecked index is `cursor < count` or in a run
        // `start..<end` with `end <= count`.
        var cursor = 0
        var nextRunID: Int32 = 0
        var runCount = 0
        var reliableRunCount = 0
        while cursor < count {
            guard unsafe output[unchecked: cursor].hasCorrectedAltitude else {
                unsafe output[unchecked: cursor].runIdentifier = -1
                unsafe output[unchecked: cursor].reliableRunIdentifier = -1
                cursor += 1
                continue
            }

            let segment = unsafe samples[unchecked: cursor].continuityGroup
            let start = cursor
            cursor += 1
            // The span is read outside `&&`: a span read inside that autoclosure
            // crashes Swift 6.3.3 in an optimized build (CopyPropagation).
            while cursor < count {
                guard unsafe samples[unchecked: cursor].continuityGroup == segment else { break }
                guard unsafe output[unchecked: cursor].hasCorrectedAltitude else { break }
                cursor += 1
            }
            let end = cursor
            let runID = nextRunID
            nextRunID += 1
            runCount += 1
            let reliable = UInt64(end - start) >= policy.minimumReliableSampleCount
            if reliable { reliableRunCount += 1 }
            for index in start..<end {
                unsafe output[unchecked: index].runIdentifier = runID
                unsafe output[unchecked: index].reliableRunIdentifier = reliable ? runID : -1
            }
            if !reliable || policy.smoothingRadiusMeters == 0 { continue }
            smoothRun(start: start, end: end, samples: samples, radius: policy.smoothingRadiusMeters, output: &output)
        }
        return (runCount, reliableRunCount)
    }

    private static func smoothRun(
        start: Int, end: Int, samples: Span<EngineElevationProfileInput>, radius: Double,
        output: inout MutableSpan<EngineElevationProfileSample>
    ) {
        // SAFETY: `smoothRuns` passes a run with `0 <= start < end <= count`;
        // `left` and `right` stay in `start...end` and are read only while `< end`.
        // The output descent field is temporary storage of the unsmoothed values.
        for index in start..<end {
            let unsmoothed = unsafe output[unchecked: index].correctedAltitudeMeters
            unsafe output[unchecked: index].cumulativeDescentMeters = unsmoothed
        }

        var left = start
        var right = start
        var sum = 0.0
        var windowCount = 0
        for index in start..<end {
            let center = unsafe samples[unchecked: index].distanceMeters
            let upper = center + radius
            // The span is read outside `&&`: a span read inside that autoclosure
            // crashes Swift 6.3.3 in an optimized build (CopyPropagation).
            while right < end {
                guard unsafe samples[unchecked: right].distanceMeters <= upper else { break }
                sum += unsafe output[unchecked: right].cumulativeDescentMeters
                windowCount += 1
                right += 1
            }
            let lower = center - radius
            while left < right {
                guard unsafe samples[unchecked: left].distanceMeters < lower else { break }
                sum -= unsafe output[unchecked: left].cumulativeDescentMeters
                windowCount -= 1
                left += 1
            }
            let smoothed = unsafe windowCount > 0 ? sum / Double(windowCount) : output[unchecked: index].cumulativeDescentMeters
            unsafe output[unchecked: index].setWorkingAltitude(smoothed)
        }

        // Do not move endpoints of a recorded span.
        let first = unsafe output[unchecked: start].cumulativeDescentMeters
        let last = unsafe output[unchecked: end - 1].cumulativeDescentMeters
        unsafe output[unchecked: start].setWorkingAltitude(first)
        unsafe output[unchecked: end - 1].setWorkingAltitude(last)
        for index in start..<end {
            unsafe output[unchecked: index].cumulativeDescentMeters = 0
        }
    }

    private static func cumulativeGainLoss(
        _ policy: EngineElevationProfilePolicy, _ output: inout MutableSpan<EngineElevationProfileSample>
    ) {
        let count = output.count
        // SAFETY: every unchecked index is `cursor < count`, in a run
        // `start..<end` with `end <= count`, or `end - 1` with `end > start`.
        var ascent = 0.0
        var descent = 0.0
        var signed = 0.0
        var intervals = 0.0
        var cursor = 0
        while cursor < count {
            let runID = unsafe output[unchecked: cursor].runIdentifier
            let start = cursor
            cursor += 1
            if runID < 0 {
                unsafe output[unchecked: start].setCumulative(ascent: ascent, descent: descent, signed: signed, intervals: intervals)
                continue
            }
            // The span is read outside `&&`: a span read inside that autoclosure
            // crashes Swift 6.3.3 in an optimized build (CopyPropagation).
            while cursor < count {
                guard unsafe output[unchecked: cursor].runIdentifier == runID else { break }
                cursor += 1
            }
            let end = cursor
            if unsafe output[unchecked: start].reliableRunIdentifier < 0 || !output[unchecked: start].hasCorrectedAltitude {
                for index in start..<end {
                    unsafe output[unchecked: index].setCumulative(ascent: ascent, descent: descent, signed: signed, intervals: intervals)
                }
                continue
            }

            let first = unsafe output[unchecked: start].correctedAltitudeMeters
            var trend = 0 // Unknown (0), rising (1), falling (-1).
            var pivot = first
            var extreme = first
            var committedAscent = ascent
            var committedDescent = descent
            var previous = first

            for index in start..<end {
                guard unsafe output[unchecked: index].hasCorrectedAltitude else { continue }
                let altitude = unsafe output[unchecked: index].correctedAltitudeMeters
                if index > start {
                    signed += altitude - previous
                    intervals += 1
                }
                previous = altitude

                switch trend {
                case 0:
                    if altitude - pivot >= policy.gainLossDeadbandMeters {
                        trend = 1
                        extreme = altitude
                    } else if pivot - altitude >= policy.gainLossDeadbandMeters {
                        trend = -1
                        extreme = altitude
                    }
                case 1:
                    if altitude > extreme {
                        extreme = altitude
                    } else if extreme - altitude >= policy.gainLossDeadbandMeters {
                        committedAscent += positivePart(extreme - pivot)
                        pivot = extreme
                        trend = -1
                        extreme = altitude
                    }
                default:
                    if altitude < extreme {
                        extreme = altitude
                    } else if altitude - extreme >= policy.gainLossDeadbandMeters {
                        committedDescent += positivePart(pivot - extreme)
                        pivot = extreme
                        trend = 1
                        extreme = altitude
                    }
                }
                let provisionalAscent = trend == 1 ? positivePart(extreme - pivot) : 0
                let provisionalDescent = trend == -1 ? positivePart(pivot - extreme) : 0
                unsafe output[unchecked: index].setCumulative(ascent: committedAscent + provisionalAscent,
                                            descent: committedDescent + provisionalDescent,
                                            signed: signed, intervals: intervals)
            }

            ascent = unsafe output[unchecked: end - 1].cumulativeAscentMeters
            descent = unsafe output[unchecked: end - 1].cumulativeDescentMeters
        }
    }
}

extension EngineElevationProfileSample {
    fileprivate mutating func setCumulative(ascent: Double, descent: Double, signed: Double, intervals: Double) {
        cumulativeAscentMeters = ascent
        cumulativeDescentMeters = descent
        cumulativeSignedChangeMeters = signed
        reliableIntervalCount = intervals
    }
}
