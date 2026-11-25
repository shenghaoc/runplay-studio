/// The status failures the scale/bucket kernel can report with a borrowed input span and owned output.
///
/// `invalid_input_buffer`, `invalid_output_buffer`, `invalid_workspace_buffer`,
/// `insufficient_output_capacity` and `insufficient_workspace_capacity` have no
/// Swift counterpart: a `Span` cannot pair a positive count with null storage,
/// and the kernel owns its output and its eligible-sample workspace.
package enum RouteMetricScaleBucketError: Error, Equatable {
    case invalidPolicy
    case invalidInputContract
    case resourceLimit
    case internalFailure
}

/// One interval's metric, present or absent, and its distance weight.
package struct RouteMetricScaleBucketSample: Sendable {
    package var metricValue: Double
    package var weightMeters: Double
    package var hasMetricValue: UInt8

    package init(metricValue: Double = 0, weightMeters: Double = 0, hasMetricValue: UInt8 = 0) {
        self.metricValue = metricValue
        self.weightMeters = weightMeters
        self.hasMetricValue = hasMetricValue
    }
}

package struct RouteMetricScaleBucketPolicy: Sendable {
    package var lowerQuantile: Double
    package var upperQuantile: Double
    package var minimumScaleSpan: Double
    package var minimumValidIntervalCount: UInt64
    package var bucketCount: Int64

    package init(
        lowerQuantile: Double = 0, upperQuantile: Double = 0, minimumScaleSpan: Double = 0,
        minimumValidIntervalCount: UInt64 = 0, bucketCount: Int64 = 0
    ) {
        self.lowerQuantile = lowerQuantile
        self.upperQuantile = upperQuantile
        self.minimumScaleSpan = minimumScaleSpan
        self.minimumValidIntervalCount = minimumValidIntervalCount
        self.bucketCount = bucketCount
    }
}

package struct RouteMetricScaleBucketOutputSample: Sendable {
    package var sourceIndex: UInt64 = 0
    package var metricValue: Double = 0
    package var weightMeters: Double = 0
    package var normalizedValue: Double = 0
    /// `-1` means no data; otherwise `0...(bucketCount - 1)`.
    package var bucketIndex: Int64 = -1
    package var hasMetricValue: UInt8 = 0
    package var hasNormalizedValue: UInt8 = 0

    package init() {}
}

package struct RouteMetricScaleBucketResult: Sendable {
    package var sampleCount: UInt64 = 0
    package var validIntervalCount: UInt64 = 0
    package var noDataIntervalCount: UInt64 = 0
    package var validCoverageDistanceMeters: Double = 0
    package var lowerBound: Double = 0
    package var median: Double = 0
    package var upperBound: Double = 0
    package var hasScale: Bool = false
    /// One entry per input sample, in source order. Empty only for empty input.
    package var samples: [RouteMetricScaleBucketOutputSample] = []

    package init() {}
}

package enum RouteMetricScaleBuckets {
    /// Run of eligible samples with the same `(metric, weight)` sort key.
    ///
    /// The metric key orders finite doubles by value and maps `+0` and `-0` to
    /// one key, exactly as `lhs.metric != rhs.metric` ties them. The weight is
    /// finite and positive, so its bit pattern orders like its value.
    ///
    /// Equal keys are bit-identical except for the sign of a zero metric. A stable
    /// sort keeps equal keys in source order, so sorting the distinct keys and
    /// repeating each `count` times, with a zero group's signs in source order,
    /// is the same sequence a stable sort of every sample produces, on every
    /// platform. C++ `std::sort` leaves equal keys in an implementation-defined
    /// order, which differs between libc++ and libstdc++ for `+0`/`-0`.
    private struct Group {
        var metricKey: UInt64
        var weightBits: UInt64
        var metric: Double
        var weight: Double
        var count: Int
    }

    private static func metricKey(_ metric: Double) -> UInt64 {
        let bits = metric == 0 ? 0 : metric.bitPattern
        // Flip all bits of negatives and the sign bit of non-negatives.
        return bits & 0x8000_0000_0000_0000 != 0 ? ~bits : bits | 0x8000_0000_0000_0000
    }

    /// The eligible samples grouped by sort key, in sorted order, plus the signs
    /// of the zero-metric samples per weight in source order.
    private struct SortedGroups {
        var groups: [Group] = []
        var zeroNegative: [UInt64: [Bool]] = [:]
    }

    private static func sortedGroups(
        samples: Span<RouteMetricScaleBucketSample>, expectedEligibleCount: Int
    ) -> SortedGroups {
        var groups: [Group] = []
        var zeroNegative: [UInt64: [Bool]] = [:]
        var table = [Int32](repeating: -1, count: 64)
        var mask = 63
        groups.reserveCapacity(min(expectedEligibleCount, 1_024))
        for index in 0..<samples.count {
            let sample = samples[index]
            if !isQuantileEligible(sample.hasMetricValue, sample.metricValue, sample.weightMeters) { continue }
            let key = metricKey(sample.metricValue)
            let weightBits = sample.weightMeters.bitPattern
            var slot = slotFor(key, weightBits) & mask
            while true {
                let found = Int(table[slot])
                if found < 0 {
                    table[slot] = Int32(truncatingIfNeeded: groups.count)
                    groups.append(Group(
                        metricKey: key, weightBits: weightBits,
                        metric: sample.metricValue, weight: sample.weightMeters, count: 1
                    ))
                    if groups.count * 2 > table.count {
                        // Grow and rehash; group indexes do not change.
                        let capacity = table.count * 4
                        table = [Int32](repeating: -1, count: capacity)
                        mask = capacity - 1
                        for groupIndex in 0..<groups.count {
                            var s = slotFor(groups[groupIndex].metricKey, groups[groupIndex].weightBits) & mask
                            while table[s] >= 0 { s = (s + 1) & mask }
                            table[s] = Int32(truncatingIfNeeded: groupIndex)
                        }
                    }
                    break
                }
                if groups[found].metricKey == key && groups[found].weightBits == weightBits {
                    groups[found].count += 1
                    break
                }
                slot = (slot + 1) & mask
            }
            if sample.metricValue == 0 {
                zeroNegative[weightBits, default: []].append(sample.metricValue.sign == .minus)
            }
        }
        // Distinct keys: a strict total order, so the sort is deterministic.
        groups.sort { lhs, rhs in
            if lhs.metricKey != rhs.metricKey { return lhs.metricKey < rhs.metricKey }
            return lhs.weightBits < rhs.weightBits
        }
        return SortedGroups(groups: groups, zeroNegative: zeroNegative)
    }

    /// 64-bit finalizer (two xor-shift-multiply rounds) so that keys whose low
    /// bits are all zero, such as whole-number doubles, still spread over the table.
    @inline(__always)
    private static func slotFor(_ key: UInt64, _ weightBits: UInt64) -> Int {
        var hash = key &+ (weightBits &* 0x9e37_79b9_7f4a_7c15)
        hash ^= hash >> 32
        hash = hash &* 0xd6e8_feb8_6659_fd93
        hash ^= hash >> 32
        hash = hash &* 0xd6e8_feb8_6659_fd93
        hash ^= hash >> 32
        return Int(truncatingIfNeeded: hash)
    }

    /// Assign a deterministic numeric scale and bucket to one metric profile.
    package static func assign(
        samples: Span<RouteMetricScaleBucketSample>, policy: RouteMetricScaleBucketPolicy
    ) throws(RouteMetricScaleBucketError) -> RouteMetricScaleBucketResult {
        let sampleCount = samples.count
        if sampleCount == 0 { return RouteMetricScaleBucketResult() }
        guard sampleCount <= EngineRouteLimits.maxRouteInputSamples else { throw .resourceLimit }

        // Read-only validation pass. Also accumulates the counts that decide
        // whether a scale can possibly exist, so guaranteed no-scale inputs skip
        // workspace compaction and sorting.
        var validCount: UInt64 = 0
        var eligibleCount = 0
        var validCoverage = 0.0
        for index in 0..<sampleCount {
            let sample = samples[index]
            if sample.hasMetricValue > 1 || sample.weightMeters.isNaN || sample.weightMeters < 0.0 {
                throw .invalidInputContract
            }
            if isValidInterval(sample.hasMetricValue, sample.metricValue, sample.weightMeters) {
                validCount += 1
                validCoverage += sample.weightMeters
                if sample.weightMeters.isFinite { eligibleCount += 1 }
            }
        }

        let scaleKnownImpossible = validCount < policy.minimumValidIntervalCount
            || eligibleCount == 0
            || !policy.lowerQuantile.isFinite
            || !policy.upperQuantile.isFinite
            || policy.minimumScaleSpan == Double.infinity

        if scaleKnownImpossible {
            return finish(
                samples: samples, validCount: validCount, noDataCount: UInt64(sampleCount),
                validCoverage: validCoverage, scale: nil, policy: policy
            )
        }

        // Group quantile-eligible samples by sort key and sort the distinct keys.
        let sorted = sortedGroups(samples: samples, expectedEligibleCount: eligibleCount)

        var maximumWeight = 0.0
        for group in sorted.groups {
            // C++ std::max(a, b) is (a < b) ? b : a.
            maximumWeight = maximumWeight < group.weight ? group.weight : maximumWeight
        }
        let lower = quantile(sorted, policy.lowerQuantile, maximumWeight)
        let median = quantile(sorted, 0.5, maximumWeight)
        let upper = quantile(sorted, policy.upperQuantile, maximumWeight)
        let span = policy.minimumScaleSpan
        let requiredSpan = 0.0 < span ? span : 0.0
        let hasScale = abs(upper - lower) + 1e-12 >= requiredSpan

        if !hasScale {
            return finish(
                samples: samples, validCount: validCount, noDataCount: UInt64(sampleCount),
                validCoverage: validCoverage, scale: nil, policy: policy
            )
        }
        return finish(
            samples: samples, validCount: validCount, noDataCount: 0,
            validCoverage: validCoverage, scale: (lower, median, upper), policy: policy
        )
    }

    /// Write the output in source order. With a scale, `noDataCount` is
    /// recomputed from the absent metrics; without one, every interval is no-data.
    private static func finish(
        samples: Span<RouteMetricScaleBucketSample>, validCount: UInt64, noDataCount: UInt64,
        validCoverage: Double, scale: (lower: Double, median: Double, upper: Double)?,
        policy: RouteMetricScaleBucketPolicy
    ) -> RouteMetricScaleBucketResult {
        let count = samples.count
        var noData = noDataCount
        let output = unsafe [RouteMetricScaleBucketOutputSample](unsafeUninitializedCapacity: count) { buffer, initialized in
            // SAFETY: each element is initialized exactly once, in order, before `initialized` grows.
            for index in 0..<count {
                let sample = samples[index]
                var out = RouteMetricScaleBucketOutputSample()
                out.sourceIndex = UInt64(index)
                out.metricValue = sample.metricValue
                out.weightMeters = sample.weightMeters
                out.hasMetricValue = sample.hasMetricValue
                if let scale {
                    if sample.hasMetricValue == 0 {
                        noData += 1
                    } else {
                        let normalized = normalizedValue(sample.metricValue, scale.lower, scale.upper)
                        out.normalizedValue = normalized
                        out.bucketIndex = bucketIndex(normalized, policy.bucketCount)
                        out.hasNormalizedValue = 1
                    }
                }
                unsafe buffer.initializeElement(at: index, to: out)
                initialized += 1
            }
        }
        var result = RouteMetricScaleBucketResult()
        result.sampleCount = UInt64(count)
        result.validIntervalCount = validCount
        result.noDataIntervalCount = noData
        result.validCoverageDistanceMeters = validCoverage
        if let scale {
            result.lowerBound = scale.lower
            result.median = scale.median
            result.upperBound = scale.upper
            result.hasScale = true
        }
        result.samples = output
        return result
    }

    /// Walks the sorted samples one at a time, repeating each group's increment
    /// `count` times so every floating-point sum has the same operands in the
    /// same order as a sum over the fully sorted array.
    private static func quantile(_ sorted: SortedGroups, _ requested: Double, _ maximumWeight: Double) -> Double {
        // std::max(0.0, requested) keeps 0.0 for NaN; std::min(1.0, x) is (x < 1.0) ? x : 1.0.
        let floored = 0.0 < requested ? requested : 0.0
        let q = floored < 1.0 ? floored : 1.0
        var total = 0.0
        for group in sorted.groups {
            let increment = group.weight / maximumWeight
            for _ in 0..<group.count { total += increment }
        }
        let target = q * total
        var cumulative = 0.0
        for group in sorted.groups {
            let increment = group.weight / maximumWeight
            for position in 0..<group.count {
                cumulative += increment
                if cumulative + 1e-12 >= target { return metric(of: group, at: position, sorted) }
            }
        }
        let last = sorted.groups[sorted.groups.count - 1]
        return metric(of: last, at: last.count - 1, sorted)
    }

    /// The metric of the sample at `position` within its tie group, in stable
    /// (source) order. Only a zero metric can differ within a group, by its sign.
    private static func metric(of group: Group, at position: Int, _ sorted: SortedGroups) -> Double {
        guard group.metric == 0, let signs = sorted.zeroNegative[group.weightBits] else { return group.metric }
        return signs[position] ? -0.0 : 0.0
    }

    private static func normalizedValue(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        if !value.isFinite { return 0.5 }
        let span = upper - lower
        if !span.isFinite || abs(span) <= 1e-12 { return 0.5 }
        let low = upper < lower ? upper : lower
        let high = lower < upper ? upper : lower
        let atLeastLow = low < value ? value : low
        let clamped = atLeastLow < high ? atLeastLow : high
        let normalized = (clamped - lower) / span
        let nonNegative = 0.0 < normalized ? normalized : 0.0
        return nonNegative < 1.0 ? nonNegative : 1.0
    }

    /// Preserve Swift `bucketIndex` semantics across the full `Int64` domain.
    /// `count` is at least 2, so `count - 1` cannot overflow. `scaled` is checked
    /// to be below `Double(count - 1)` (at most 2^63) before the `Int64` cast,
    /// so the conversion cannot trap.
    private static func bucketIndex(_ normalized: Double, _ requestedCount: Int64) -> Int64 {
        let count = 2 < requestedCount ? requestedCount : 2
        let nonNegative = 0.0 < normalized ? normalized : 0.0
        let clamped = nonNegative < 1.0 ? nonNegative : 1.0
        if clamped >= 1.0 { return count - 1 }
        let scaled = clamped * Double(count)
        if !(scaled > 0.0) { return 0 }
        let finalBucketAsDouble = Double(count - 1)
        if !scaled.isFinite || scaled >= finalBucketAsDouble { return count - 1 }
        let truncated = Int64(scaled)
        return truncated < count - 1 ? truncated : count - 1
    }

    private static func isQuantileEligible(_ has: UInt8, _ metric: Double, _ weight: Double) -> Bool {
        has == 1 && metric.isFinite && weight.isFinite && weight > 0.0
    }

    private static func isValidInterval(_ has: UInt8, _ metric: Double, _ weight: Double) -> Bool {
        has == 1 && metric.isFinite && weight > 0.0
    }
}
