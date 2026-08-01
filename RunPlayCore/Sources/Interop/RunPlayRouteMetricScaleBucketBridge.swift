import Foundation

internal import CxxStdlib
internal import RunPlayEngineCpp

struct RunPlayRouteMetricNumericScale: Equatable, Sendable {
    let lowerBound: Double
    let median: Double
    let upperBound: Double
}

struct RunPlayRouteMetricBucketAssignment: Equatable, Sendable {
    let normalizedValue: Double?
    let bucketIndex: Int?
}

struct RunPlayRouteMetricScaleBucketResult: Sendable {
    let scale: RunPlayRouteMetricNumericScale?
    let assignments: [RunPlayRouteMetricBucketAssignment]
    let validCoverageDistanceMeters: Double
    let validIntervalCount: Int
    let noDataIntervalCount: Int
}

struct RunPlayRouteMetricScaleBucketBenchmarkReport: Sendable {
    let result: RunPlayRouteMetricScaleBucketResult
    let inputConversionMilliseconds: Double
    let outputAllocationMilliseconds: Double
    let nativeKernelMilliseconds: Double
    let outputTranslationMilliseconds: Double
}

enum RunPlayRouteMetricScaleBucketBridgeError: Error, Equatable {
    case resourceLimit
    case invalidPolicy
    case invalidInputContract
    case engineContractViolation
}

enum RunPlayRouteMetricScaleBucketBridge {
    /// Test-only invocation counter for native assign calls.
    private final class InvocationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private static let invocationCounter = InvocationCounter()

    static var assignInvocationCount: Int {
        invocationCounter.value
    }

    static func resetAssignInvocationCountForTests() {
        invocationCounter.reset()
    }

    private static func recordAssignInvocation() {
        invocationCounter.increment()
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
    ) throws -> RunPlayRouteMetricScaleBucketResult {
        recordAssignInvocation()
        return try assignNative(
            metricValues: metricValues,
            weightsMeters: weightsMeters,
            lowerQuantile: lowerQuantile,
            upperQuantile: upperQuantile,
            minimumScaleSpan: minimumScaleSpan,
            minimumValidIntervalCount: minimumValidIntervalCount,
            bucketCount: bucketCount,
            cancellationCheckStride: cancellationCheckStride,
            isCancelled: isCancelled,
            collectBenchmarkTimings: false
        ).result
    }

    static func assignCollectingBenchmarkReport(
        metricValues: [Double?],
        weightsMeters: [Double],
        lowerQuantile: Double,
        upperQuantile: Double,
        minimumScaleSpan: Double,
        minimumValidIntervalCount: Int,
        bucketCount: Int,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayRouteMetricScaleBucketBenchmarkReport {
        recordAssignInvocation()
        let timed = try assignNative(
            metricValues: metricValues,
            weightsMeters: weightsMeters,
            lowerQuantile: lowerQuantile,
            upperQuantile: upperQuantile,
            minimumScaleSpan: minimumScaleSpan,
            minimumValidIntervalCount: minimumValidIntervalCount,
            bucketCount: bucketCount,
            cancellationCheckStride: cancellationCheckStride,
            isCancelled: isCancelled,
            collectBenchmarkTimings: true
        )
        guard let timings = timed.timings else {
            throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
        }
        return RunPlayRouteMetricScaleBucketBenchmarkReport(
            result: timed.result,
            inputConversionMilliseconds: timings.input,
            outputAllocationMilliseconds: timings.allocation,
            nativeKernelMilliseconds: timings.native,
            outputTranslationMilliseconds: timings.translation
        )
    }

    private static func assignNative(
        metricValues: [Double?],
        weightsMeters: [Double],
        lowerQuantile: Double,
        upperQuantile: Double,
        minimumScaleSpan: Double,
        minimumValidIntervalCount: Int,
        bucketCount: Int,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool,
        collectBenchmarkTimings: Bool
    ) throws -> (
        result: RunPlayRouteMetricScaleBucketResult,
        timings: (input: Double, allocation: Double, native: Double, translation: Double)?
    ) {
        guard metricValues.count == weightsMeters.count else {
            throw RunPlayRouteMetricScaleBucketBridgeError.invalidInputContract
        }
        let count = metricValues.count
        guard count <= RunPlayEngineLimits.maxRouteInputSamples else {
            throw RunPlayRouteMetricScaleBucketBridgeError.resourceLimit
        }
        // Preserve the full public Swift `Int` domain for bucket counts.
        guard minimumValidIntervalCount >= 0,
              let nativeMinimumCount = UInt64(exactly: minimumValidIntervalCount),
              let nativeBucketCount = Int64(exactly: bucketCount)
        else {
            throw RunPlayRouteMetricScaleBucketBridgeError.invalidPolicy
        }

        let stride = max(1, cancellationCheckStride)
        try checkCancellation(isCancelled)
        let conversionStart = collectBenchmarkTimings ? DispatchTime.now().uptimeNanoseconds : 0

        var input = ContiguousArray<runplay.RouteMetricScaleBucketInputSample>()
        input.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            let weight = weightsMeters[index]
            // Accept finite nonnegative weights, +infinity, and -0. Reject NaN
            // and any negative weight including -infinity.
            if weight.isNaN || weight < 0 {
                throw RunPlayRouteMetricScaleBucketBridgeError.invalidInputContract
            }
            var sample = runplay.RouteMetricScaleBucketInputSample()
            if let metric = metricValues[index] {
                sample.metric_value = metric
                sample.has_metric_value = 1
            } else {
                sample.metric_value = 0
                sample.has_metric_value = 0
            }
            sample.weight_meters = weight
            input.append(sample)
        }

        var policy = runplay.RouteMetricScaleBucketPolicy()
        policy.lower_quantile = lowerQuantile
        policy.upper_quantile = upperQuantile
        policy.minimum_scale_span = minimumScaleSpan
        policy.minimum_valid_interval_count = nativeMinimumCount
        policy.bucket_count = nativeBucketCount

        let conversionEnd = collectBenchmarkTimings ? DispatchTime.now().uptimeNanoseconds : 0
        let allocationStart = conversionEnd
        // Typed caller-owned workspace for eligible compact/sort. Distinct from
        // the output buffer — never an overlay or type-pun of live outputs.
        var workspace = ContiguousArray<runplay.RouteMetricScaleBucketWorkspaceSample>(
            repeating: runplay.RouteMetricScaleBucketWorkspaceSample(),
            count: count
        )
        var output = ContiguousArray<runplay.RouteMetricScaleBucketOutputSample>(
            repeating: runplay.RouteMetricScaleBucketOutputSample(),
            count: count
        )
        let allocationEnd = collectBenchmarkTimings ? DispatchTime.now().uptimeNanoseconds : 0

        try checkCancellation(isCancelled)
        let nativeStart = collectBenchmarkTimings ? DispatchTime.now().uptimeNanoseconds : 0
        let summary = input.withUnsafeBufferPointer { inputBuffer in
            workspace.withUnsafeMutableBufferPointer { workspaceBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    runplay.assign_route_metric_scale_buckets(
                        inputBuffer.baseAddress,
                        inputBuffer.count,
                        policy,
                        workspaceBuffer.baseAddress,
                        workspaceBuffer.count,
                        outputBuffer.baseAddress,
                        outputBuffer.count
                    )
                }
            }
        }
        let nativeEnd = collectBenchmarkTimings ? DispatchTime.now().uptimeNanoseconds : 0
        try checkCancellation(isCancelled)
        let translationStart = collectBenchmarkTimings ? DispatchTime.now().uptimeNanoseconds : 0

        switch summary.status {
        case .success:
            break
        case .resource_limit:
            throw RunPlayRouteMetricScaleBucketBridgeError.resourceLimit
        case .invalid_policy:
            throw RunPlayRouteMetricScaleBucketBridgeError.invalidPolicy
        case .invalid_input_contract:
            throw RunPlayRouteMetricScaleBucketBridgeError.invalidInputContract
        case .invalid_input_buffer,
             .invalid_output_buffer,
             .invalid_workspace_buffer,
             .insufficient_output_capacity,
             .insufficient_workspace_capacity,
             .internal_failure:
            throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
        default:
            throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
        }

        // Positive infinity is a legal valid-coverage result (extreme finite
        // interval weights may overflow during accumulation). Reject only NaN
        // and negative coverage.
        guard summary.sample_count == UInt64(count),
              summary.required_output_capacity == UInt64(count),
              summary.valid_interval_count <= UInt64(count),
              summary.no_data_interval_count <= UInt64(count),
              summary.has_scale == 0 || summary.has_scale == 1,
              !summary.valid_coverage_distance_meters.isNaN,
              summary.valid_coverage_distance_meters >= 0,
              let validCount = Int(exactly: summary.valid_interval_count),
              let noDataCount = Int(exactly: summary.no_data_interval_count)
        else {
            throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
        }

        let numericScale: RunPlayRouteMetricNumericScale?
        if summary.has_scale == 1 {
            guard summary.lower_bound.isFinite,
                  summary.median.isFinite,
                  summary.upper_bound.isFinite
            else {
                throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
            }
            numericScale = RunPlayRouteMetricNumericScale(
                lowerBound: summary.lower_bound,
                median: summary.median,
                upperBound: summary.upper_bound
            )
        } else {
            guard summary.lower_bound == 0,
                  summary.median == 0,
                  summary.upper_bound == 0
            else {
                throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
            }
            numericScale = nil
        }

        let effectiveBucketCount = max(2, bucketCount)
        var assignments: [RunPlayRouteMetricBucketAssignment] = []
        assignments.reserveCapacity(count)
        var observedNoDataCount = 0
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            let native = output[index]
            guard native.source_index == UInt64(index),
                  native.weight_meters.bitPattern == weightsMeters[index].bitPattern,
                  native.has_metric_value == 0 || native.has_metric_value == 1,
                  native.has_normalized_value == 0 || native.has_normalized_value == 1
            else {
                throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
            }

            let expectedMetric = metricValues[index]
            guard native.has_metric_value == (expectedMetric == nil ? 0 : 1),
                  metricMatches(native.metric_value, expectedMetric)
            else {
                throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
            }

            if native.has_normalized_value == 0 {
                guard native.bucket_index == -1 else {
                    throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
                }
                observedNoDataCount += 1
                assignments.append(RunPlayRouteMetricBucketAssignment(
                    normalizedValue: nil,
                    bucketIndex: nil
                ))
            } else {
                guard native.normalized_value.isFinite,
                      (0...1).contains(native.normalized_value),
                      native.bucket_index >= 0,
                      let bucket = Int(exactly: native.bucket_index),
                      bucket < effectiveBucketCount,
                      numericScale != nil,
                      expectedMetric != nil
                else {
                    throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
                }
                assignments.append(RunPlayRouteMetricBucketAssignment(
                    normalizedValue: native.normalized_value,
                    bucketIndex: bucket
                ))
            }
        }

        guard observedNoDataCount == noDataCount else {
            throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
        }

        let result = RunPlayRouteMetricScaleBucketResult(
            scale: numericScale,
            assignments: assignments,
            validCoverageDistanceMeters: summary.valid_coverage_distance_meters,
            validIntervalCount: validCount,
            noDataIntervalCount: noDataCount
        )
        guard collectBenchmarkTimings else { return (result, nil) }
        let translationEnd = DispatchTime.now().uptimeNanoseconds
        return (
            result,
            (
                milliseconds(conversionStart, conversionEnd),
                milliseconds(allocationStart, allocationEnd),
                milliseconds(nativeStart, nativeEnd),
                milliseconds(translationStart, translationEnd)
            )
        )
    }

    private static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    private static func metricMatches(_ native: Double, _ expected: Double?) -> Bool {
        guard let expected else { return native == 0 }
        return native.bitPattern == expected.bitPattern
    }

    private static func milliseconds(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }
}
