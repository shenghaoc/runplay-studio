#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

package struct TrainingLoadSample {
    package let heartRateBPM: Double
    package let weightSeconds: Double
    package let hasHeartRate: UInt8

    package init(heartRateBPM: Double, weightSeconds: Double, hasHeartRate: UInt8) {
        self.heartRateBPM = heartRateBPM
        self.weightSeconds = weightSeconds
        self.hasHeartRate = hasHeartRate
    }
}

package struct TrainingLoadPolicy {
    package var restingHeartRateBPM: Double
    package var maximumHeartRateBPM: Double
    package var coefficientMultiplier: Double
    package var coefficientExponent: Double
    package var zoneLowerBoundsBPM: InlineArray<5, Double>

    package init(
        restingHeartRateBPM: Double,
        maximumHeartRateBPM: Double,
        coefficientMultiplier: Double,
        coefficientExponent: Double,
        zoneLowerBoundsBPM: InlineArray<5, Double>
    ) {
        self.restingHeartRateBPM = restingHeartRateBPM
        self.maximumHeartRateBPM = maximumHeartRateBPM
        self.coefficientMultiplier = coefficientMultiplier
        self.coefficientExponent = coefficientExponent
        self.zoneLowerBoundsBPM = zoneLowerBoundsBPM
    }

    private func isFinitePositive(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    fileprivate var isValid: Bool {
        if !isFinitePositive(restingHeartRateBPM) || !isFinitePositive(maximumHeartRateBPM) {
            return false
        }
        if restingHeartRateBPM >= maximumHeartRateBPM {
            return false
        }
        if !isFinitePositive(coefficientMultiplier) {
            return false
        }
        if !isFinitePositive(coefficientExponent) {
            return false
        }
        let bounds = zoneLowerBoundsBPM
        if !bounds[0].isFinite || !bounds[1].isFinite || !bounds[2].isFinite
            || !bounds[3].isFinite || !bounds[4].isFinite
        {
            return false
        }
        return bounds[0] < bounds[1] && bounds[1] < bounds[2]
            && bounds[2] < bounds[3] && bounds[3] < bounds[4]
    }

    fileprivate func zoneIndex(_ rate: Double) -> Int {
        var index = 0
        if rate >= zoneLowerBoundsBPM[1] { index = 1 }
        if rate >= zoneLowerBoundsBPM[2] { index = 2 }
        if rate >= zoneLowerBoundsBPM[3] { index = 3 }
        if rate >= zoneLowerBoundsBPM[4] { index = 4 }
        return index
    }
}

package struct TrainingLoadSummary {
    package fileprivate(set) var totalTRIMP = 0.0
    package fileprivate(set) var meanHeartRateBPM = 0.0
    package fileprivate(set) var zoneSeconds: InlineArray<5, Double> = [0, 0, 0, 0, 0]
    package fileprivate(set) var validHeartRateSeconds = 0.0
    package fileprivate(set) var coveredSeconds = 0.0
    package fileprivate(set) var validIntervalCount: UInt64 = 0
    package fileprivate(set) var totalIntervalCount: UInt64 = 0
    package fileprivate(set) var hasMeanHeartRate: UInt8 = 0
}

package enum TrainingLoadError: Error, Equatable {
    case invalidPolicy
    case invalidInputContract
    // Mirrors the native status; neither kernel currently emits it.
    case internalFailure
}

package enum TrainingLoadKernel {
    package static let zoneCount = 5

    /// Translate the C++ accumulation in order. A thrown result carries no partial summary.
    package static func compute(
        _ samples: borrowing Span<TrainingLoadSample>,
        policy: TrainingLoadPolicy
    ) throws(TrainingLoadError) -> TrainingLoadSummary {
        var summary = TrainingLoadSummary()
        guard policy.isValid else { throw .invalidPolicy }

        let reserveSpan = policy.maximumHeartRateBPM - policy.restingHeartRateBPM
        var weightedRateSum = 0.0
        // Positive finite IEEE 754 bit patterns lie below infinity. The sign bit
        // excludes negative values; weights alone may also be negative zero.
        let greatestFiniteBits = Double.greatestFiniteMagnitude.bitPattern
        let negativeZeroBits = (-0.0).bitPattern
        for index in 0..<samples.count {
            let sample = samples[index]
            let weightBits = sample.weightSeconds.bitPattern
            guard weightBits <= greatestFiniteBits || weightBits == negativeZeroBits else {
                throw .invalidInputContract
            }
            guard sample.hasHeartRate <= 1 else { throw .invalidInputContract }

            summary.totalIntervalCount += 1
            summary.coveredSeconds += sample.weightSeconds
            if sample.hasHeartRate == 0 { continue }
            let rateBits = sample.heartRateBPM.bitPattern
            guard rateBits > 0, rateBits <= greatestFiniteBits else {
                throw .invalidInputContract
            }

            var reserve = (sample.heartRateBPM - policy.restingHeartRateBPM) / reserveSpan
            if reserve < 0 {
                reserve = 0
            } else if reserve > 1 {
                reserve = 1
            }

            summary.validHeartRateSeconds += sample.weightSeconds
            summary.validIntervalCount += 1

            let weightedRate = sample.heartRateBPM * sample.weightSeconds
            weightedRateSum += weightedRate

            let zoneSecondsIncrement = sample.weightSeconds
            summary.zoneSeconds[policy.zoneIndex(sample.heartRateBPM)] += zoneSecondsIncrement

            let minutes = sample.weightSeconds / 60.0
            let exponential = exp(policy.coefficientExponent * reserve)
            let scaledReserve = reserve * policy.coefficientMultiplier
            let contribution = minutes * scaledReserve * exponential
            summary.totalTRIMP += contribution
        }
        if summary.validHeartRateSeconds > 0 {
            summary.meanHeartRateBPM = weightedRateSum / summary.validHeartRateSeconds
            summary.hasMeanHeartRate = 1
        }
        return summary
    }
}
