import Foundation

// Keep imported C++ declarations confined to the internal Interop layer.
internal import CxxStdlib
internal import RunPlayEngineCpp

// MARK: - Pure-Swift result types

/// One native elevation sample translated into pure Swift values.
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

/// Diagnostic-only phase timings for one complete bridge invocation.
/// Production callers never request or collect these clocks.
struct RunPlayElevationProfileBenchmarkReport: Sendable {
    let inputConversionMilliseconds: Double
    let outputAllocationMilliseconds: Double
    let nativeKernelMilliseconds: Double
    let outputTranslationMilliseconds: Double
}

enum RunPlayElevationProfileBridgeError: Error, Equatable {
    case resourceLimit
    case invalidPolicy
    case invalidInputContract
    case engineContractViolation
}

// MARK: - Bridge

/// Production adapter for the complete multi-pass ElevationProfile build.
///
/// Converts route points into one compact native input buffer, invokes
/// `build_elevation_profile` exactly once, and translates the one-to-one
/// output samples. C++ retains no pointer and performs no callback.
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

        return try buildNative(
            routePoints: routePoints,
            policy: policy,
            isCancelled: isCancelled,
            collectBenchmarkTimings: false
        ).result
    }

    /// Diagnostic-only profiled bridge used by release benchmarks. The result
    /// travels through the same conversion, native call, validation, and output
    /// translation as production.
    static func buildCollectingBenchmarkReport(
        routePoints: [RoutePoint],
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayElevationProfileBenchmarkReport {
        guard !routePoints.isEmpty else {
            return RunPlayElevationProfileBenchmarkReport(
                inputConversionMilliseconds: 0,
                outputAllocationMilliseconds: 0,
                nativeKernelMilliseconds: 0,
                outputTranslationMilliseconds: 0
            )
        }
        guard routePoints.count <= WorkoutImportResourceLimits.maxRoutePointCount else {
            throw RunPlayElevationProfileBridgeError.resourceLimit
        }

        let profiled = try buildNative(
            routePoints: routePoints,
            policy: policy,
            isCancelled: isCancelled,
            collectBenchmarkTimings: true
        )
        guard let report = profiled.report else {
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }
        return report
    }

    /// Nested so every temporary C++ value is destroyed before the pure-Swift
    /// result returns to production code.
    private static func buildNative(
        routePoints: [RoutePoint],
        policy: RouteQualityPolicy,
        isCancelled: @Sendable () -> Bool,
        collectBenchmarkTimings: Bool
    ) throws -> (
        result: RunPlayElevationProfileBuildResult,
        report: RunPlayElevationProfileBenchmarkReport?
    ) {
        let count = routePoints.count
        let stride = max(1, policy.cancellationCheckStride)
        let conversionStart = collectBenchmarkTimings
            ? DispatchTime.now().uptimeNanoseconds
            : 0

        var samples = ContiguousArray<runplay.ElevationProfileInputSample>()
        samples.reserveCapacity(count)

        var compactGroup: Int32 = 0
        var previousRouteSegment: Int?

        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }

            let point = routePoints[index]
            let segment = point.routeSegmentIndex
            if let previous = previousRouteSegment, segment != previous {
                // Continuity groups are compact 0-based and increase by one.
                compactGroup += 1
            }
            previousRouteSegment = segment

            var sample = runplay.ElevationProfileInputSample()
            sample.distance_meters = point.distanceFromStartMeters
            if let altitude = point.altitudeMeters {
                // Present NaN/infinity are data to reject, not missing values.
                sample.altitude_meters = altitude
                sample.has_altitude = 1
            } else {
                sample.altitude_meters = 0
                sample.has_altitude = 0
            }
            sample.continuity_group = compactGroup
            samples.append(sample)
        }

        var nativePolicy = runplay.ElevationProfilePolicy()
        nativePolicy.plausible_altitude_minimum_meters =
            policy.plausibleAltitudeRangeMeters.lowerBound
        nativePolicy.plausible_altitude_maximum_meters =
            policy.plausibleAltitudeRangeMeters.upperBound
        nativePolicy.spike_minimum_deviation_meters =
            policy.altitudeSpikeMinimumDeviationMeters
        nativePolicy.short_excursion_minimum_deviation_meters =
            policy.altitudeShortExcursionMinimumDeviationMeters
        nativePolicy.short_excursion_maximum_sample_count = UInt64(
            max(0, policy.altitudeShortExcursionMaximumSampleCount)
        )
        nativePolicy.spike_maximum_neighbor_difference_meters =
            policy.altitudeSpikeMaximumNeighborDifferenceMeters
        nativePolicy.spike_maximum_horizontal_span_meters =
            policy.altitudeSpikeMaximumHorizontalSpanMeters
        nativePolicy.smoothing_radius_meters =
            policy.elevationSmoothingRadiusMeters
        nativePolicy.minimum_reliable_sample_count = UInt64(
            max(0, policy.minimumReliableAltitudeSampleCount)
        )
        nativePolicy.gain_loss_deadband_meters =
            policy.elevationGainLossDeadbandMeters

        let conversionEnd = collectBenchmarkTimings
            ? DispatchTime.now().uptimeNanoseconds
            : 0
        let allocationStart = conversionEnd

        var output = ContiguousArray<runplay.ElevationProfileOutputSample>(
            repeating: runplay.ElevationProfileOutputSample(),
            count: count
        )

        let allocationEnd = collectBenchmarkTimings
            ? DispatchTime.now().uptimeNanoseconds
            : 0

        try checkCancellation(isCancelled: isCancelled)

        let nativeStart = collectBenchmarkTimings
            ? DispatchTime.now().uptimeNanoseconds
            : 0
        let summary = samples.withUnsafeBufferPointer { samplesBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                runplay.build_elevation_profile(
                    samplesBuffer.baseAddress,
                    samplesBuffer.count,
                    nativePolicy,
                    outputBuffer.baseAddress,
                    outputBuffer.count
                )
            }
        }
        let nativeEnd = collectBenchmarkTimings
            ? DispatchTime.now().uptimeNanoseconds
            : 0

        try checkCancellation(isCancelled: isCancelled)

        let translationStart = collectBenchmarkTimings
            ? DispatchTime.now().uptimeNanoseconds
            : 0

        switch summary.status {
        case .success:
            break
        case .resource_limit:
            throw RunPlayElevationProfileBridgeError.resourceLimit
        case .invalid_policy:
            throw RunPlayElevationProfileBridgeError.invalidPolicy
        case .invalid_input_contract:
            throw RunPlayElevationProfileBridgeError.invalidInputContract
        case .invalid_input_buffer,
             .invalid_output_buffer,
             .insufficient_output_capacity,
             .internal_failure:
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        default:
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }

        guard summary.sample_count == UInt64(count),
              summary.required_output_capacity == UInt64(count),
              let rejectedCount = Int(exactly: summary.rejected_altitude_count)
        else {
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }

        let meaningful = summary.has_meaningful_elevation != 0
        if summary.has_meaningful_elevation != 0 &&
            summary.has_meaningful_elevation != 1 {
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }

        if meaningful {
            guard summary.total_ascent_meters.isFinite,
                  summary.total_descent_meters.isFinite,
                  summary.total_ascent_meters >= 0,
                  summary.total_descent_meters >= 0
            else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }
        } else {
            guard summary.total_ascent_meters == 0,
                  summary.total_descent_meters == 0
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

            let sample = output[index]
            let hasCorrected = sample.has_corrected_altitude
            let wasRejected = sample.source_altitude_was_rejected
            guard hasCorrected == 0 || hasCorrected == 1,
                  wasRejected == 0 || wasRejected == 1
            else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }

            let corrected: Double?
            if hasCorrected == 1 {
                guard sample.corrected_altitude_meters.isFinite else {
                    throw RunPlayElevationProfileBridgeError.engineContractViolation
                }
                corrected = sample.corrected_altitude_meters
            } else {
                corrected = nil
                guard sample.run_identifier == -1 else {
                    throw RunPlayElevationProfileBridgeError.engineContractViolation
                }
            }

            if wasRejected == 1 {
                observedRejected += 1
            }

            let ascent = sample.cumulative_ascent_meters
            let descent = sample.cumulative_descent_meters
            let signed = sample.cumulative_signed_change_meters
            let reliableIntervals = sample.reliable_interval_count
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

            let runID = sample.run_identifier
            let reliableRunID = sample.reliable_run_identifier
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
                sourceAltitudeWasRejected: wasRejected == 1,
                cumulativeAscentMeters: ascent,
                cumulativeDescentMeters: descent,
                cumulativeSignedChangeMeters: signed,
                reliableIntervalCount: reliableIntervals,
                runIdentifier: runIdentifier,
                reliableRunIdentifier: reliableRunIdentifier
            ))
        }

        guard observedRejected == rejectedCount,
              summary.run_count == UInt64(observedRunCount),
              summary.reliable_run_count == UInt64(observedReliableRunCount)
        else {
            throw RunPlayElevationProfileBridgeError.engineContractViolation
        }

        if meaningful {
            guard let last = results.last,
                  nearEqual(last.cumulativeAscentMeters, summary.total_ascent_meters),
                  nearEqual(last.cumulativeDescentMeters, summary.total_descent_meters),
                  last.reliableIntervalCount > 0
            else {
                throw RunPlayElevationProfileBridgeError.engineContractViolation
            }
        }

        let result = RunPlayElevationProfileBuildResult(
            samples: results,
            rejectedAltitudeCount: rejectedCount,
            hasMeaningfulElevation: meaningful,
            totalAscentMeters: meaningful ? summary.total_ascent_meters : nil,
            totalDescentMeters: meaningful ? summary.total_descent_meters : nil
        )

        guard collectBenchmarkTimings else {
            return (result, nil)
        }
        let translationEnd = DispatchTime.now().uptimeNanoseconds
        let report = RunPlayElevationProfileBenchmarkReport(
            inputConversionMilliseconds: milliseconds(
                from: conversionStart,
                to: conversionEnd
            ),
            outputAllocationMilliseconds: milliseconds(
                from: allocationStart,
                to: allocationEnd
            ),
            nativeKernelMilliseconds: milliseconds(
                from: nativeStart,
                to: nativeEnd
            ),
            outputTranslationMilliseconds: milliseconds(
                from: translationStart,
                to: translationEnd
            )
        )
        return (result, report)
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

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }
}
