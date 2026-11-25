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

        let kernelPolicy = EngineElevationProfilePolicy(
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

        try checkCancellation(isCancelled: isCancelled)
        EngineCallObserver.record(.elevationProfile)
        let result: Result<EngineElevationProfileResult, ElevationProfileError>
        do throws(ElevationProfileError) {
            result = .success(try EngineElevationProfile.build(samples: samples.span, policy: kernelPolicy))
        } catch {
            result = .failure(error)
        }
        try checkCancellation(isCancelled: isCancelled)

        let summary: EngineElevationProfileResult
        switch result {
        case .success(let value): summary = value
        case .failure(.resourceLimit): throw RunPlayElevationProfileBridgeError.resourceLimit
        case .failure(.invalidPolicy): throw RunPlayElevationProfileBridgeError.invalidPolicy
        case .failure(.invalidInputContract): throw RunPlayElevationProfileBridgeError.invalidInputContract
        }
        guard summary.samples.count == count else {
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }
        let rejectedCount = summary.rejectedAltitudeCount
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

        var results: [RunPlayElevationProfileSampleResult] = []
        results.reserveCapacity(count)
        var observedRejected = 0
        var previousAscent = 0.0
        var previousDescent = 0.0
        var previousReliableIntervals = 0.0
        var previousRunID: Int32?
        var previousReliableRunID: Int32?
        var observedRunCount = 0
        var observedReliableRunCount = 0

        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }

            let sample = summary.samples[index]
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

            let runID = sample.runIdentifier
            let reliableRunID = sample.reliableRunIdentifier
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

            let runIdentifier: Int? = runID >= 0 ? Int(runID) : nil
            let reliableRunIdentifier: Int? =
                reliableRunID >= 0 ? Int(reliableRunID) : nil

            results.append(RunPlayElevationProfileSampleResult(
                correctedAltitudeMeters: corrected,
                sourceAltitudeWasRejected: wasRejected,
                cumulativeAscentMeters: ascent,
                cumulativeDescentMeters: descent,
                cumulativeSignedChangeMeters: signed,
                reliableIntervalCount: reliableIntervals,
                runIdentifier: runIdentifier,
                reliableRunIdentifier: reliableRunIdentifier
            ))
        }

        guard observedRejected == rejectedCount,
              summary.runCount == observedRunCount,
              summary.reliableRunCount == observedReliableRunCount
        else {
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }

        if meaningful {
            guard let last = results.last,
                  nearEqual(last.cumulativeAscentMeters, summary.totalAscentMeters),
                  nearEqual(last.cumulativeDescentMeters, summary.totalDescentMeters),
                  last.reliableIntervalCount > 0
            else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }
        }

        return RunPlayElevationProfileBuildResult(
            samples: results,
            rejectedAltitudeCount: rejectedCount,
            hasMeaningfulElevation: meaningful,
            totalAscentMeters: meaningful ? summary.totalAscentMeters : nil,
            totalDescentMeters: meaningful ? summary.totalDescentMeters : nil
        )

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
