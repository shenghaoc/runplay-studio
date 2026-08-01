import Foundation

/// Production Swift numeric scale/bucket finalizer for corrected elevation.
///
/// Pace and heart-rate finalization use the C++23 bulk kernel. Corrected
/// elevation intentionally remains in Swift because same-machine production
/// A/B showed a native regression above the 1.05× hard gate. This is a
/// mode-owned implementation decision, not an error-driven fallback.
///
/// Semantics match the pre-migration Swift implementation and the independent
/// test oracle: eligible filtering, distance-weighted quantiles, minimum
/// scale span, normalization, buckets, coverage, and diagnostic counts.
enum RouteMetricScaleBucketSwiftFinalizer {
    struct NumericScale: Equatable, Sendable {
        let lowerBound: Double
        let median: Double
        let upperBound: Double
    }

    struct Assignment: Equatable, Sendable {
        let normalizedValue: Double?
        let bucketIndex: Int?
    }

    struct Result: Sendable {
        let scale: NumericScale?
        let assignments: [Assignment]
        let validCoverageDistanceMeters: Double
        let validIntervalCount: Int
        let noDataIntervalCount: Int
    }

    private struct WeightedSample {
        let value: Double
        let weight: Double
    }

    static func assign(
        metricValues: [Double?],
        weightsMeters: [Double],
        lowerQuantile: Double,
        upperQuantile: Double,
        minimumScaleSpan: Double,
        minimumValidIntervalCount: Int,
        bucketCount: Int,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> Result {
        guard metricValues.count == weightsMeters.count else {
            throw RunPlayRouteMetricScaleBucketBridgeError.invalidInputContract
        }
        let stride = max(1, cancellationCheckStride)
        if isCancelled() { throw CancellationError() }

        var samples: [WeightedSample] = []
        samples.reserveCapacity(metricValues.count)
        var validCoverage = 0.0
        var validCount = 0

        for index in metricValues.indices {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            let weight = weightsMeters[index]
            // Production weights are non-negative interval distances from
            // max(0, end - start). Positive infinity is valid for coverage.
            if weight.isNaN || weight < 0 {
                throw RunPlayRouteMetricScaleBucketBridgeError.invalidInputContract
            }
            guard let value = metricValues[index], value.isFinite, weight > 0 else {
                continue
            }
            samples.append(WeightedSample(value: value, weight: weight))
            validCoverage += weight
            validCount += 1
        }

        let scale: NumericScale?
        if validCount >= minimumValidIntervalCount,
           let lower = weightedQuantile(samples, quantile: lowerQuantile),
           let median = weightedQuantile(samples, quantile: 0.5),
           let upper = weightedQuantile(samples, quantile: upperQuantile),
           abs(upper - lower) + 1e-12 >= max(0, minimumScaleSpan) {
            scale = NumericScale(lowerBound: lower, median: median, upperBound: upper)
        } else {
            scale = nil
        }

        var assignments: [Assignment] = []
        assignments.reserveCapacity(metricValues.count)
        var noDataCount = 0
        for (index, value) in metricValues.enumerated() {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            if let value, let scale {
                let normalized = normalize(value: value, scale: scale)
                assignments.append(Assignment(
                    normalizedValue: normalized,
                    bucketIndex: bucketIndex(normalized: normalized, bucketCount: bucketCount)
                ))
            } else {
                assignments.append(Assignment(normalizedValue: nil, bucketIndex: nil))
                noDataCount += 1
            }
        }

        return Result(
            scale: scale,
            assignments: assignments,
            validCoverageDistanceMeters: validCoverage,
            validIntervalCount: validCount,
            noDataIntervalCount: noDataCount
        )
    }

    private static func weightedQuantile(
        _ samples: [WeightedSample],
        quantile: Double
    ) -> Double? {
        guard quantile.isFinite else { return nil }
        let q = min(1.0, max(0.0, quantile))
        var finite: [WeightedSample] = []
        finite.reserveCapacity(samples.count)
        var maximumWeight = 0.0
        for sample in samples {
            guard sample.value.isFinite,
                  sample.weight.isFinite,
                  sample.weight > 0
            else { continue }
            finite.append(sample)
            maximumWeight = max(maximumWeight, sample.weight)
        }
        guard !finite.isEmpty, maximumWeight > 0 else { return nil }
        if finite.count == 1 { return finite[0].value }
        finite.sort { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.weight < rhs.weight
        }
        var totalWeight = 0.0
        for sample in finite {
            totalWeight += sample.weight / maximumWeight
        }
        let target = q * totalWeight
        var cumulative = 0.0
        for sample in finite {
            cumulative += sample.weight / maximumWeight
            if cumulative + 1e-12 >= target { return sample.value }
        }
        return finite.last?.value
    }

    private static func normalize(value: Double, scale: NumericScale) -> Double {
        guard value.isFinite else { return 0.5 }
        let span = scale.upperBound - scale.lowerBound
        guard span.isFinite, abs(span) > 1e-12 else { return 0.5 }
        let clamped = min(
            max(value, min(scale.lowerBound, scale.upperBound)),
            max(scale.lowerBound, scale.upperBound)
        )
        let normalized = (clamped - scale.lowerBound) / span
        return min(1, max(0, normalized))
    }

    private static func bucketIndex(normalized: Double, bucketCount: Int) -> Int {
        let count = max(2, bucketCount)
        let clamped = min(1, max(0, normalized))
        if clamped >= 1 { return count - 1 }
        return min(count - 1, Int(clamped * Double(count)))
    }
}
