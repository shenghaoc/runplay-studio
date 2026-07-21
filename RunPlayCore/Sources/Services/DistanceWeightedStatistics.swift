import Foundation

/// Distance-weighted statistics without expanding values into repeated arrays.
public enum DistanceWeightedStatistics: Sendable {

    /// A single sample with a non-negative weight (typically interval distance).
    public struct WeightedSample: Hashable, Sendable {
        public let value: Double
        public let weight: Double

        public init(value: Double, weight: Double) {
            self.value = value
            self.weight = weight
        }
    }

    /// Deterministic distance-weighted quantile in `0...1`.
    ///
    /// Uses the CDF of sorted unique-value groups. Zero and non-finite weights
    /// are ignored. Equal lower/upper quantiles remain safe.
    public static func weightedQuantile(
        _ samples: [WeightedSample],
        quantile: Double
    ) -> Double? {
        // NaN/inf must not propagate through min/max clamping into the CDF target.
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

        // Scale by the largest finite weight so summing several very large
        // weights cannot overflow to infinity and skew the CDF boundary.
        let totalWeight = finite.reduce(0.0) { partial, sample in
            partial + sample.weight / maximumWeight
        }
        let target = q * totalWeight
        var cumulative = 0.0
        for sample in finite {
            cumulative += sample.weight / maximumWeight
            if cumulative + 1e-12 >= target {
                return sample.value
            }
        }
        return finite.last?.value
    }

    public static func weightedMedian(_ samples: [WeightedSample]) -> Double? {
        weightedQuantile(samples, quantile: 0.5)
    }

    /// Distance-weighted median of discrete bucket indices.
    public static func weightedMedianBucket(
        values: [(bucket: Int, weight: Double)]
    ) -> Int? {
        let samples = values.compactMap { entry -> WeightedSample? in
            guard entry.weight.isFinite, entry.weight > 0 else { return nil }
            return WeightedSample(value: Double(entry.bucket), weight: entry.weight)
        }
        guard let median = weightedMedian(samples) else { return nil }
        return Int(median.rounded())
    }
}
