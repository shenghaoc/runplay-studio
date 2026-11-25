import Foundation

internal import RunPlayEngine

// MARK: - Pure-Swift result types

/// One engine elevation sample translated into Core values.
struct RunPlayElevationProfileSampleResult: Sendable {
    let correctedAltitudeMeters: Double?
    let sourceAltitudeWasRejected: Bool

    let cumulativeAscentMeters: Double
    let cumulativeDescentMeters: Double
    let cumulativeSignedChangeMeters: Double
    let reliableIntervalCount: Double

    let runIdentifier: Int?
    let reliableRunIdentifier: Int?
}

/// Complete elevation-profile build result for one route.
struct RunPlayElevationProfileBuildResult: Sendable {
    let samples: [RunPlayElevationProfileSampleResult]

    let rejectedAltitudeCount: Int
    let hasMeaningfulElevation: Bool
    let totalAscentMeters: Double?
    let totalDescentMeters: Double?
}

enum RunPlayElevationProfileBridgeError: Error, Equatable {
    case resourceLimit
    case invalidPolicy
    case invalidInputContract
    case engineContractViolation
}

// MARK: - Bridge

/// Core conversion, cancellation, and result validation for the Swift kernel.
enum RunPlayElevationProfileBridge {
    static func build(
        routePoints: [RoutePoint],
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayElevationProfileBuildResult {
        let count = routePoints.count
        guard count <= WorkoutImportResourceLimits.maxRoutePointCount else {
            throw RunPlayElevationProfileBridgeError.resourceLimit
        }

        if count == 0 {
            return RunPlayElevationProfileBuildResult(
                samples: [],
                rejectedAltitudeCount: 0,
                hasMeaningfulElevation: false,
                totalAscentMeters: nil,
                totalDescentMeters: nil
            )
        }

        let stride = max(1, policy.cancellationCheckStride)
        let samples = try engineInputs(routePoints, stride: stride, isCancelled: isCancelled)
        let kernelPolicy = engineElevationPolicy(policy)

        let summary = try runKernel(samples, policy: kernelPolicy, isCancelled: isCancelled)
        try validateSummaryTotals(summary, count: count)
        let rejectedCount = summary.rejectedAltitudeCount
        let meaningful = summary.hasMeaningfulElevation

        var results: [RunPlayElevationProfileSampleResult] = []
        results.reserveCapacity(count)
        var contract = SampleContract()

        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }
            results.append(try contract.accept(summary.samples[index]))
        }

        try validateObservedTotals(summary, contract: contract, lastResult: results.last)

        return RunPlayElevationProfileBuildResult(
            samples: results,
            rejectedAltitudeCount: rejectedCount,
            hasMeaningfulElevation: meaningful,
            totalAscentMeters: meaningful ? summary.totalAscentMeters : nil,
            totalDescentMeters: meaningful ? summary.totalDescentMeters : nil
        )

    }

    /// One engine call, with cancellation checked before and after it.
    private static func runKernel(
        _ samples: [EngineElevationProfileInput], policy kernelPolicy: EngineElevationProfilePolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> EngineElevationProfileResult {
        try checkCancellation(isCancelled: isCancelled)
        EngineCallObserver.record(.elevationProfile)
        let result: Result<EngineElevationProfileResult, ElevationProfileError>
        do throws(ElevationProfileError) {
            result = .success(try EngineElevationProfile.build(samples: samples.span, policy: kernelPolicy))
        } catch {
            result = .failure(error)
        }
        try checkCancellation(isCancelled: isCancelled)

        switch result {
        case .success(let value): return value
        case .failure(.resourceLimit): throw RunPlayElevationProfileBridgeError.resourceLimit
        case .failure(.invalidPolicy): throw RunPlayElevationProfileBridgeError.invalidPolicy
        case .failure(.invalidInputContract): throw RunPlayElevationProfileBridgeError.invalidInputContract
        }
    }

    /// The counts the samples showed match the summary's, and with meaningful
    /// elevation the last sample's cumulative values match its totals.
    private static func validateObservedTotals(
        _ summary: EngineElevationProfileResult, contract: SampleContract,
        lastResult: RunPlayElevationProfileSampleResult?
    ) throws {
        guard contract.observedRejected == summary.rejectedAltitudeCount,
              summary.runCount == contract.observedRunCount,
              summary.reliableRunCount == contract.observedReliableRunCount
        else {
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }

        if summary.hasMeaningfulElevation {
            guard let last = lastResult,
                  nearEqual(last.cumulativeAscentMeters, summary.totalAscentMeters),
                  nearEqual(last.cumulativeDescentMeters, summary.totalDescentMeters),
                  last.reliableIntervalCount > 0
            else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }
        }
    }

    /// One engine input per route point. Continuity groups are compact
    /// 0-based and increase by one at each route-segment boundary and at
    /// each switch between DEM and recorded altitude.
    private static func engineInputs(
        _ routePoints: [RoutePoint], stride: Int, isCancelled: @Sendable () -> Bool
    ) throws -> [EngineElevationProfileInput] {
        let count = routePoints.count
        var samples = [EngineElevationProfileInput]()
        samples.reserveCapacity(count)

        var compactGroup: Int32 = 0
        var previousRouteSegment: Int?
        var previousUsesDEM = false

        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }

            let point = routePoints[index]
            let segment = point.routeSegmentIndex
            let demAltitude = point.analysisDEMAltitudeMeters
            let usesDEM = demAltitude != nil
            if let previous = previousRouteSegment,
               segment != previous || usesDEM != previousUsesDEM {
                // Continuity groups are compact 0-based and increase by one.
                // A switch between DEM and recorded altitude starts a new
                // group, like a route-segment boundary, so no spike test,
                // interpolation, smoothing window or gain/loss interval spans
                // the offset between two altitude sources.
                compactGroup += 1
            }
            previousRouteSegment = segment
            previousUsesDEM = usesDEM

            let altitude = demAltitude ?? point.altitudeMeters
            samples.append(EngineElevationProfileInput(
                distanceMeters: point.distanceFromStartMeters,
                altitudeMeters: altitude ?? 0,
                continuityGroup: compactGroup,
                hasAltitude: altitude == nil ? 0 : 1
            ))
        }
        return samples
    }

    private static func engineElevationPolicy(_ policy: RouteQualityPolicy) -> EngineElevationProfilePolicy {
        EngineElevationProfilePolicy(
            plausibleAltitudeMinimumMeters: policy.plausibleAltitudeRangeMeters.lowerBound,
            plausibleAltitudeMaximumMeters: policy.plausibleAltitudeRangeMeters.upperBound,
            spikeMinimumDeviationMeters: policy.altitudeSpikeMinimumDeviationMeters,
            shortExcursionMinimumDeviationMeters: policy.altitudeShortExcursionMinimumDeviationMeters,
            shortExcursionMaximumSampleCount: UInt64(max(0, policy.altitudeShortExcursionMaximumSampleCount)),
            spikeMaximumNeighborDifferenceMeters: policy.altitudeSpikeMaximumNeighborDifferenceMeters,
            spikeMaximumHorizontalSpanMeters: policy.altitudeSpikeMaximumHorizontalSpanMeters,
            smoothingRadiusMeters: policy.elevationSmoothingRadiusMeters,
            minimumReliableSampleCount: UInt64(max(0, policy.minimumReliableAltitudeSampleCount)),
            gainLossDeadbandMeters: policy.elevationGainLossDeadbandMeters
        )
    }

    /// The engine returns one sample per input, finite non-negative totals
    /// with meaningful elevation, and zero totals without it.
    private static func validateSummaryTotals(_ summary: EngineElevationProfileResult, count: Int) throws {
        guard summary.samples.count == count else {
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }
        let meaningful = summary.hasMeaningfulElevation
        if meaningful {
            guard summary.totalAscentMeters.isFinite,
                  summary.totalDescentMeters.isFinite,
                  summary.totalAscentMeters >= 0,
                  summary.totalDescentMeters >= 0
            else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }
        } else {
            guard summary.totalAscentMeters == 0,
                  summary.totalDescentMeters == 0
            else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }
        }
    }

    /// Checks each engine sample against the profile contract, in order, and
    /// translates it into Core values: a corrected altitude is finite and a
    /// sample without one is in no run; cumulative values are finite,
    /// non-negative and never fall; run identifiers start at zero and grow by
    /// at most one; a reliable run is its sample's run.
    private struct SampleContract {
        var observedRejected = 0
        var previousAscent = 0.0
        var previousDescent = 0.0
        var previousReliableIntervals = 0.0
        var previousRunID: Int32?
        var previousReliableRunID: Int32?
        var observedRunCount = 0
        var observedReliableRunCount = 0

        mutating func accept(_ sample: EngineElevationProfileSample) throws -> RunPlayElevationProfileSampleResult {
            let wasRejected = sample.sourceAltitudeWasRejected
            let corrected: Double?
            if sample.hasCorrectedAltitude {
                guard sample.correctedAltitudeMeters.isFinite else {
                    throw RunPlayElevationProfileBridgeError.engineContractViolation
                }
                corrected = sample.correctedAltitudeMeters
            } else {
                corrected = nil
                guard sample.runIdentifier == -1 else {
                    throw RunPlayElevationProfileBridgeError.engineContractViolation
                }
            }

            if wasRejected {
                observedRejected += 1
            }

            try acceptCumulativeValues(sample)

            let runID = sample.runIdentifier
            let reliableRunID = sample.reliableRunIdentifier
            try acceptRunIdentifiers(runID: runID, reliableRunID: reliableRunID)

            let runIdentifier: Int? = runID >= 0 ? Int(runID) : nil
            let reliableRunIdentifier: Int? =
                reliableRunID >= 0 ? Int(reliableRunID) : nil

            return RunPlayElevationProfileSampleResult(
                correctedAltitudeMeters: corrected,
                sourceAltitudeWasRejected: wasRejected,
                cumulativeAscentMeters: sample.cumulativeAscentMeters,
                cumulativeDescentMeters: sample.cumulativeDescentMeters,
                cumulativeSignedChangeMeters: sample.cumulativeSignedChangeMeters,
                reliableIntervalCount: sample.reliableIntervalCount,
                runIdentifier: runIdentifier,
                reliableRunIdentifier: reliableRunIdentifier
            )
        }

        private mutating func acceptCumulativeValues(_ sample: EngineElevationProfileSample) throws {
            let ascent = sample.cumulativeAscentMeters
            let descent = sample.cumulativeDescentMeters
            let signed = sample.cumulativeSignedChangeMeters
            let reliableIntervals = sample.reliableIntervalCount
            guard ascent.isFinite, descent.isFinite, signed.isFinite,
                  reliableIntervals.isFinite,
                  ascent >= 0, descent >= 0, reliableIntervals >= 0,
                  ascent >= previousAscent - 1e-12,
                  descent >= previousDescent - 1e-12,
                  reliableIntervals >= previousReliableIntervals - 1e-12
            else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }
            previousAscent = ascent
            previousDescent = descent
            previousReliableIntervals = reliableIntervals
        }

        private mutating func acceptRunIdentifiers(runID: Int32, reliableRunID: Int32) throws {
            guard runID >= -1, reliableRunID >= -1 else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }

            if runID >= 0 {
                if let previous = previousRunID {
                    if runID < previous {
                        throw RunPlayElevationProfileBridgeError.engineContractViolation
                    }
                    if runID > previous + 1 {
                        throw RunPlayElevationProfileBridgeError.engineContractViolation
                    }
                } else if runID != 0 {
                    throw RunPlayElevationProfileBridgeError.engineContractViolation
                }
                if runID != previousRunID {
                    observedRunCount += 1
                }
                previousRunID = runID
            }

            if reliableRunID >= 0 {
                guard reliableRunID == runID else {
                    throw RunPlayElevationProfileBridgeError.engineContractViolation
                }
                if reliableRunID != previousReliableRunID {
                    observedReliableRunCount += 1
                    previousReliableRunID = reliableRunID
                }
            }
        }
    }

    private static func checkCancellation(
        isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }

    private static func nearEqual(_ a: Double, _ b: Double) -> Bool {
        if a == b { return true }
        let tolerance = max(1e-9, abs(b) * 1e-12)
        return abs(a - b) <= tolerance
    }

}
