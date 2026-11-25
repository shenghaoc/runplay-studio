internal import RunPlayEngine

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

/// Core adapter over the Swift training-load kernel.
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
        guard heartRatesBPM.count == weightsSeconds.count else {
            throw RunPlayTrainingLoadBridgeError.invalidInputContract
        }
        guard zoneLowerBoundsBPM.count == TrainingLoadKernel.zoneCount else {
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

        var input = ContiguousArray<TrainingLoadSample>()
        input.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            let weight = weightsSeconds[index]
            guard weight.isFinite, weight >= 0 else {
                throw RunPlayTrainingLoadBridgeError.invalidInputContract
            }
            let rate = heartRatesBPM[index]
            if let rate {
                guard rate.isFinite, rate > 0 else {
                    throw RunPlayTrainingLoadBridgeError.invalidInputContract
                }
            }
            input.append(TrainingLoadSample(
                heartRateBPM: rate ?? 0, weightSeconds: weight, hasHeartRate: rate == nil ? 0 : 1
            ))
        }

        let policy = RunPlayEngine.TrainingLoadPolicy(
            restingHeartRateBPM: restingHeartRateBPM,
            maximumHeartRateBPM: maximumHeartRateBPM,
            coefficientMultiplier: coefficientMultiplier,
            coefficientExponent: coefficientExponent,
            zoneLowerBoundsBPM: [
                zoneLowerBoundsBPM[0], zoneLowerBoundsBPM[1], zoneLowerBoundsBPM[2],
                zoneLowerBoundsBPM[3], zoneLowerBoundsBPM[4],
            ]
        )

        try checkCancellation(isCancelled)
        let computed: Result<TrainingLoadSummary, TrainingLoadError>
        do throws(TrainingLoadError) {
            // The scoped test tally counts the kernel call.
            EngineCallObserver.record(.trainingLoad)
            let value = try TrainingLoadKernel.compute(input.span, policy: policy)
            computed = .success(value)
        } catch {
            computed = .failure(error)
        }
        // Cancellation is checked before the status is translated.
        try checkCancellation(isCancelled)
        let summary: TrainingLoadSummary
        switch computed {
        case let .success(value):
            summary = value
        case .failure(.invalidPolicy):
            throw RunPlayTrainingLoadBridgeError.invalidPolicy
        case .failure(.invalidInputContract):
            throw RunPlayTrainingLoadBridgeError.invalidInputContract
        case .failure(.internalFailure):
            throw RunPlayTrainingLoadBridgeError.engineContractViolation
        }

        guard let validCount = Int(exactly: summary.validIntervalCount),
              let totalCount = Int(exactly: summary.totalIntervalCount),
              totalCount == count,
              validCount <= totalCount,
              summary.totalTRIMP.isFinite, summary.totalTRIMP >= 0,
              summary.validHeartRateSeconds.isFinite, summary.validHeartRateSeconds >= 0,
              summary.coveredSeconds.isFinite, summary.coveredSeconds >= 0,
              summary.validHeartRateSeconds <= summary.coveredSeconds,
              summary.hasMeanHeartRate == 0 || summary.hasMeanHeartRate == 1
        else {
            throw RunPlayTrainingLoadBridgeError.engineContractViolation
        }

        let zoneSeconds = [
            summary.zoneSeconds[0],
            summary.zoneSeconds[1],
            summary.zoneSeconds[2],
            summary.zoneSeconds[3],
            summary.zoneSeconds[4],
        ]
        var zoneTotal = 0.0
        for zone in zoneSeconds {
            guard zone.isFinite, zone >= 0 else {
                throw RunPlayTrainingLoadBridgeError.engineContractViolation
            }
            zoneTotal += zone
        }
        guard abs(zoneTotal - summary.validHeartRateSeconds) <= 1e-9 * max(1.0, summary.validHeartRateSeconds)
        else {
            throw RunPlayTrainingLoadBridgeError.engineContractViolation
        }

        let meanRate: Double?
        if summary.hasMeanHeartRate == 1 {
            guard summary.meanHeartRateBPM.isFinite, summary.meanHeartRateBPM > 0 else {
                throw RunPlayTrainingLoadBridgeError.engineContractViolation
            }
            meanRate = summary.meanHeartRateBPM
        } else {
            guard summary.meanHeartRateBPM == 0 else {
                throw RunPlayTrainingLoadBridgeError.engineContractViolation
            }
            meanRate = nil
        }

        return RunPlayTrainingLoadResult(
            totalTRIMP: summary.totalTRIMP,
            meanHeartRateBPM: meanRate,
            zoneSeconds: zoneSeconds,
            validHeartRateSeconds: summary.validHeartRateSeconds,
            coveredSeconds: summary.coveredSeconds,
            validIntervalCount: validCount,
            totalIntervalCount: totalCount
        )
    }

    private static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}
