import Foundation

/// Thresholds and estimator constants for training-load computation.
///
/// The measured-versus-estimated decision is deliberately conservative on
/// both axes: a run counts as measured only when the heart-rate data covers
/// enough absolute time and enough of the recorded active time. Below either
/// threshold the load is an estimate, labelled as one, and kept out of the
/// fitness/fatigue/form model by default.
public enum TrainingLoadPolicy {
    /// Minimum absolute valid-heart-rate time for a measured load.
    public static let minimumMeasuredValidHeartRateSeconds: Double = 300

    /// Minimum fraction of covered active time that must carry valid heart
    /// rate for a measured load.
    public static let minimumMeasuredCoverageFraction: Double = 0.5

    /// Assumed heart-rate reserve bands for the pace/duration estimator, as
    /// (upper exclusive speed bound in m/s, assumed reserve). Deliberately
    /// conservative: the cap understates hard efforts rather than inflating
    /// load.
    public static let estimatorReserveBands: [(maximumSpeedMetersPerSecond: Double, reserve: Double)] = [
        (6.0 / 3.6, 0.30),
        (8.0 / 3.6, 0.40),
        (10.0 / 3.6, 0.50),
        (12.0 / 3.6, 0.60),
        (14.0 / 3.6, 0.70),
        (.infinity, 0.75),
    ]

    /// Assumed reserve when the run has duration but no usable pace either.
    public static let durationOnlyAssumedReserve: Double = 0.50
}

/// Computes one workout's `TrainingLoadSnapshot`.
///
/// Measured loads make exactly one native `compute_training_load` call over
/// same-segment heart-rate intervals — recording gaps and pauses never
/// contribute weight, because interval weights only exist between adjacent
/// samples of one segment. Estimated loads are pure Swift arithmetic
/// over pace and duration and make no native call.
///
/// Heart rate arrives as normalized `[HeartRateSample]` from
/// `RunWorkout.heartRateSamples`, so a route-less workout whose heart rate came
/// from a standalone series is measured on exactly the same path as a
/// route-bearing one. Nothing here branches on route presence.
public struct TrainingLoadCalculator: Sendable {
    public init() {}

    /// Same-segment heart-rate intervals ready for the native call.
    ///
    /// Built from adjacent sample pairs only, so a segment boundary or a
    /// non-positive time delta contributes no weight at all.
    struct IntervalAccumulation {
        var rates: [Double?]
        var weights: [Double]
        /// Whether at least one interval carries a usable reading.
        var hasAnyRate: Bool

        static let empty = IntervalAccumulation(
            rates: [], weights: [], hasAnyRate: false
        )
    }

    static func accumulateIntervals(
        from samples: [HeartRateSample],
        isCancelled: @Sendable () -> Bool
    ) throws -> IntervalAccumulation {
        guard samples.count >= 2 else { return .empty }

        var rates: [Double?] = []
        var weights: [Double] = []
        rates.reserveCapacity(samples.count - 1)
        weights.reserveCapacity(samples.count - 1)

        var previousSegment: Int? = nil
        var previousElapsed: Double = 0
        var previousRate: Double? = nil
        var hasAnyRate = false

        for sample in samples {
            if isCancelled() { throw CancellationError() }
            let rate = sample.heartRateBPM.flatMap { value in
                MetricValidation.isValidHeartRate(value) ? value : nil
            }
            if let segment = previousSegment, segment == sample.segmentIndex {
                let delta = sample.elapsedSeconds - previousElapsed
                if delta.isFinite, delta > 0 {
                    let intervalRate: Double?
                    if let leading = previousRate, let trailing = rate {
                        intervalRate = (leading + trailing) / 2
                    } else {
                        intervalRate = nil
                    }
                    if intervalRate != nil { hasAnyRate = true }
                    weights.append(delta)
                    rates.append(intervalRate)
                }
            }
            previousSegment = sample.segmentIndex
            previousElapsed = sample.elapsedSeconds
            previousRate = rate
        }

        return IntervalAccumulation(
            rates: rates,
            weights: weights,
            hasAnyRate: hasAnyRate
        )
    }

    /// The production entry point. Reads heart rate through the workout's
    /// single accessor, never through `routePoints` directly.
    public static func compute(
        for workout: RunWorkout,
        profile: AthleteProfile,
        referenceYear: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> TrainingLoadSnapshot {
        try compute(
            heartRateSamples: workout.heartRateSamples,
            activeSeconds: workout.summary.totalActiveSeconds,
            averageSpeedMetersPerSecond: workout.summary.averageSpeedMetersPerSecond > 0
                ? workout.summary.averageSpeedMetersPerSecond
                : nil,
            profile: profile,
            referenceYear: referenceYear,
            isCancelled: isCancelled
        )
    }

    public static func compute(
        heartRateSamples samples: [HeartRateSample],
        activeSeconds: Double,
        averageSpeedMetersPerSecond: Double?,
        profile: AthleteProfile,
        referenceYear: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> TrainingLoadSnapshot {
        let effective = profile.effectiveProfile(referenceYear: referenceYear)

        let intervals = try accumulateIntervals(
            from: samples,
            isCancelled: isCancelled
        )
        let rates = intervals.rates
        let weights = intervals.weights

        if intervals.hasAnyRate {
            let result = try RunPlayTrainingLoadBridge.compute(
                heartRatesBPM: rates,
                weightsSeconds: weights,
                restingHeartRateBPM: effective.restingHeartRateBPM,
                maximumHeartRateBPM: effective.maximumHeartRateBPM,
                coefficientMultiplier: effective.coefficientMultiplier,
                coefficientExponent: effective.coefficientExponent,
                zoneLowerBoundsBPM: effective.zoneLowerBoundsBPM,
                cancellationCheckStride: 2_048,
                isCancelled: isCancelled
            )

            let coverageFraction = result.coveredSeconds > 0
                ? result.validHeartRateSeconds / result.coveredSeconds
                : 0
            let measured = result.validHeartRateSeconds >= TrainingLoadPolicy.minimumMeasuredValidHeartRateSeconds
                && coverageFraction >= TrainingLoadPolicy.minimumMeasuredCoverageFraction

            if measured {
                return TrainingLoadSnapshot(
                    kind: .measured,
                    banisterTRIMP: result.totalTRIMP,
                    zoneSeconds: result.zoneSeconds,
                    meanHeartRateBPM: result.meanHeartRateBPM,
                    validHeartRateSeconds: result.validHeartRateSeconds,
                    coveredActiveSeconds: result.coveredSeconds,
                    profile: profile
                )
            }

            // Not enough usable heart rate: keep the coverage numbers for
            // disclosure, fall through to the estimator.
            return estimate(
                activeSeconds: activeSeconds,
                averageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
                effective: effective,
                profile: profile,
                validHeartRateSeconds: result.validHeartRateSeconds
            )
        }

        return estimate(
            activeSeconds: activeSeconds,
            averageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
            effective: effective,
            profile: profile,
            validHeartRateSeconds: 0
        )
    }

    /// The pace/duration estimator. Pure Swift, no native call, conservative
    /// by design: the assumed-reserve bands cap at 0.75, so a hard strapless
    /// effort is understated rather than inflated.
    private static func estimate(
        activeSeconds: Double,
        averageSpeedMetersPerSecond: Double?,
        effective: EffectiveTrainingLoadProfile,
        profile: AthleteProfile,
        validHeartRateSeconds: Double
    ) -> TrainingLoadSnapshot {
        let basis: TrainingLoadSnapshot.EstimateBasis
        let reserve: Double
        if let speed = averageSpeedMetersPerSecond, speed.isFinite, speed > 0 {
            basis = .paceDuration
            reserve = TrainingLoadPolicy.assumedReserve(forAverageSpeedMetersPerSecond: speed)
        } else {
            basis = .durationOnly
            reserve = TrainingLoadPolicy.durationOnlyAssumedReserve
        }

        let minutes = max(0, activeSeconds) / 60
        let exponential = exp(effective.coefficientExponent * reserve)
        let scaled = reserve * effective.coefficientMultiplier
        let trimp = minutes * scaled * exponential

        return TrainingLoadSnapshot(
            kind: .estimated,
            banisterTRIMP: trimp,
            zoneSeconds: nil,
            meanHeartRateBPM: nil,
            validHeartRateSeconds: validHeartRateSeconds,
            coveredActiveSeconds: max(0, activeSeconds),
            estimateBasis: basis,
            assumedHeartRateReserve: reserve,
            profile: profile
        )
    }
}

extension TrainingLoadPolicy {
    /// Map an average speed onto the assumed heart-rate reserve band.
    public static func assumedReserve(forAverageSpeedMetersPerSecond speed: Double) -> Double {
        for band in estimatorReserveBands where speed < band.maximumSpeedMetersPerSecond {
            return band.reserve
        }
        return estimatorReserveBands.last?.reserve ?? durationOnlyAssumedReserve
    }
}
