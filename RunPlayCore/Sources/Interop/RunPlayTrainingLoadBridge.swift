import Foundation

internal import CxxStdlib
internal import RunPlayEngineCpp

/// Pure Swift result of one training-load pass.
struct RunPlayTrainingLoadResult: Equatable, Sendable {
    let totalTRIMP: Double
    let meanHeartRateBPM: Double?
    let zoneSeconds: [Double]
    let validHeartRateSeconds: Double
    let coveredSeconds: Double
    let validIntervalCount: Int
    let totalIntervalCount: Int
}

enum RunPlayTrainingLoadBridgeError: Error, Equatable {
    case invalidPolicy
    case invalidInputContract
    case engineContractViolation
}

/// Adapter over the native `compute_training_load` boundary.
///
/// One call covers one whole workout. The interval weights are Swift-owned
/// active-time semantics: the caller only passes same-segment adjacent-point
/// intervals, so a recording gap or pause never contributes weight.
enum RunPlayTrainingLoadBridge {
    static func compute(
        heartRatesBPM: [Double?],
        weightsSeconds: [Double],
        restingHeartRateBPM: Double,
        maximumHeartRateBPM: Double,
        coefficientMultiplier: Double,
        coefficientExponent: Double,
        zoneLowerBoundsBPM: [Double],
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayTrainingLoadResult {
        NativeCallObserver.record(.trainingLoad)

        guard heartRatesBPM.count == weightsSeconds.count else {
            throw RunPlayTrainingLoadBridgeError.invalidInputContract
        }
        guard zoneLowerBoundsBPM.count == Int(runplay.training_load_zone_count) else {
            throw RunPlayTrainingLoadBridgeError.invalidPolicy
        }
        guard restingHeartRateBPM.isFinite, restingHeartRateBPM > 0,
              maximumHeartRateBPM.isFinite, maximumHeartRateBPM > restingHeartRateBPM,
              coefficientMultiplier.isFinite, coefficientMultiplier > 0,
              coefficientExponent.isFinite, coefficientExponent > 0
        else {
            throw RunPlayTrainingLoadBridgeError.invalidPolicy
        }
        // Ascending zone bounds are a kernel contract; validate here so the
        // policy error is attributed before any buffer work.
        var previousBound = -Double.infinity
        for bound in zoneLowerBoundsBPM {
            guard bound.isFinite, bound > previousBound else {
                throw RunPlayTrainingLoadBridgeError.invalidPolicy
            }
            previousBound = bound
        }

        let count = heartRatesBPM.count
        let stride = max(1, cancellationCheckStride)
        try checkCancellation(isCancelled)

        var input = ContiguousArray<runplay.TrainingLoadSample>()
        input.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            let weight = weightsSeconds[index]
            guard weight.isFinite, weight >= 0 else {
                throw RunPlayTrainingLoadBridgeError.invalidInputContract
            }
            var sample = runplay.TrainingLoadSample()
            sample.weight_seconds = weight
            if let rate = heartRatesBPM[index] {
                guard rate.isFinite, rate > 0 else {
                    throw RunPlayTrainingLoadBridgeError.invalidInputContract
                }
                sample.heart_rate_bpm = rate
                sample.has_heart_rate = 1
            }
            input.append(sample)
        }

        var policy = runplay.TrainingLoadPolicy()
        policy.resting_heart_rate_bpm = restingHeartRateBPM
        policy.maximum_heart_rate_bpm = maximumHeartRateBPM
        policy.coefficient_multiplier = coefficientMultiplier
        policy.coefficient_exponent = coefficientExponent
        policy.zone1_lower_bound_bpm = zoneLowerBoundsBPM[0]
        policy.zone2_lower_bound_bpm = zoneLowerBoundsBPM[1]
        policy.zone3_lower_bound_bpm = zoneLowerBoundsBPM[2]
        policy.zone4_lower_bound_bpm = zoneLowerBoundsBPM[3]
        policy.zone5_lower_bound_bpm = zoneLowerBoundsBPM[4]

        try checkCancellation(isCancelled)
        let summary = input.withUnsafeBufferPointer { buffer in
            runplay.compute_training_load(
                buffer.baseAddress,
                buffer.count,
                policy
            )
        }
        try checkCancellation(isCancelled)

        switch summary.status {
        case .success:
            break
        case .invalid_policy:
            throw RunPlayTrainingLoadBridgeError.invalidPolicy
        case .invalid_input_contract:
            throw RunPlayTrainingLoadBridgeError.invalidInputContract
        case .invalid_input_buffer, .internal_failure:
            throw RunPlayTrainingLoadBridgeError.engineContractViolation
        default:
            throw RunPlayTrainingLoadBridgeError.engineContractViolation
        }

        guard let validCount = Int(exactly: summary.valid_interval_count),
              let totalCount = Int(exactly: summary.total_interval_count),
              totalCount == count,
              validCount <= totalCount,
              summary.total_trimp.isFinite, summary.total_trimp >= 0,
              summary.valid_heart_rate_seconds.isFinite, summary.valid_heart_rate_seconds >= 0,
              summary.covered_seconds.isFinite, summary.covered_seconds >= 0,
              summary.valid_heart_rate_seconds <= summary.covered_seconds,
              summary.has_mean_heart_rate == 0 || summary.has_mean_heart_rate == 1
        else {
            throw RunPlayTrainingLoadBridgeError.engineContractViolation
        }

        let zoneSeconds = [
            summary.zone1_seconds,
            summary.zone2_seconds,
            summary.zone3_seconds,
            summary.zone4_seconds,
            summary.zone5_seconds,
        ]
        var zoneTotal = 0.0
        for zone in zoneSeconds {
            guard zone.isFinite, zone >= 0 else {
                throw RunPlayTrainingLoadBridgeError.engineContractViolation
            }
            zoneTotal += zone
        }
        guard abs(zoneTotal - summary.valid_heart_rate_seconds) <= 1e-9 * max(1.0, summary.valid_heart_rate_seconds)
        else {
            throw RunPlayTrainingLoadBridgeError.engineContractViolation
        }

        let meanRate: Double?
        if summary.has_mean_heart_rate == 1 {
            guard summary.mean_heart_rate_bpm.isFinite, summary.mean_heart_rate_bpm > 0 else {
                throw RunPlayTrainingLoadBridgeError.engineContractViolation
            }
            meanRate = summary.mean_heart_rate_bpm
        } else {
            guard summary.mean_heart_rate_bpm == 0 else {
                throw RunPlayTrainingLoadBridgeError.engineContractViolation
            }
            meanRate = nil
        }

        return RunPlayTrainingLoadResult(
            totalTRIMP: summary.total_trimp,
            meanHeartRateBPM: meanRate,
            zoneSeconds: zoneSeconds,
            validHeartRateSeconds: summary.valid_heart_rate_seconds,
            coveredSeconds: summary.covered_seconds,
            validIntervalCount: validCount,
            totalIntervalCount: totalCount
        )
    }

    private static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}
