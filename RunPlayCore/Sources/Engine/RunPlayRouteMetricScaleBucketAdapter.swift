import Foundation

internal import RunPlayEngine

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

enum RunPlayRouteMetricScaleBucketBridgeError: Error, Equatable {
    case resourceLimit
    case invalidPolicy
    case invalidInputContract
    case engineContractViolation
}

/// Production adapter for the route-metric numeric scale and bucket kernel.
///
/// Converts the Core model into one compact engine sample array, makes one
/// synchronous engine call, and projects the owned result back into Core
/// values. Pace, heart-rate and power profiles use it. Corrected-elevation
/// finalization stays in Swift (`RouteMetricScaleBucketSwiftFinalizer`).
enum RunPlayRouteMetricScaleBucketBridge {
    /// One engine sample per interval. Accept finite nonnegative weights,
    /// +infinity, and -0. Reject NaN and any negative weight including
    /// -infinity.
    private static func engineSamples(
        metricValues: [Double?], weightsMeters: [Double], stride: Int, isCancelled: @Sendable () -> Bool
    ) throws -> [RouteMetricScaleBucketSample] {
        let count = metricValues.count
        var input = [RouteMetricScaleBucketSample]()
        input.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            let weight = weightsMeters[index]
            // Accept finite nonnegative weights, +infinity, and -0. Reject NaN
            // and any negative weight including -infinity.
            if weight.isNaN || weight < 0 {
                throw RunPlayRouteMetricScaleBucketBridgeError.invalidInputContract
            }
            if let metric = metricValues[index] {
                input.append(.init(metricValue: metric, weightMeters: weight, hasMetricValue: 1))
            } else {
                input.append(.init(metricValue: 0, weightMeters: weight, hasMetricValue: 0))
            }
        }
        return input
    }

    private static func runKernel(
        _ input: [RouteMetricScaleBucketSample], policy: RouteMetricScaleBucketPolicy
    ) throws -> RouteMetricScaleBucketResult {
        do {
            return try RouteMetricScaleBuckets.assign(samples: input.span, policy: policy)
        } catch {
            switch error {
            case .resourceLimit: throw RunPlayRouteMetricScaleBucketBridgeError.resourceLimit
            case .invalidPolicy: throw RunPlayRouteMetricScaleBucketBridgeError.invalidPolicy
            case .invalidInputContract: throw RunPlayRouteMetricScaleBucketBridgeError.invalidInputContract
            case .internalFailure: throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
            }
        }
    }

    /// Each interval's normalized value and bucket, or no data.
    private static func bucketAssignments(
        _ output: RouteMetricScaleBucketResult, stride: Int, isCancelled: @Sendable () -> Bool
    ) throws -> [RunPlayRouteMetricBucketAssignment] {
        let count = output.samples.count
        var assignments: [RunPlayRouteMetricBucketAssignment] = []
        assignments.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            let item = output.samples[index]
            if item.hasNormalizedValue == 0 {
                assignments.append(.init(normalizedValue: nil, bucketIndex: nil))
            } else {
                // The engine keeps the bucket in 0..<max(2, bucketCount), so the
                // conversion to Int is exact on every supported target.
                guard let bucket = Int(exactly: item.bucketIndex) else {
                    throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
                }
                assignments.append(.init(normalizedValue: item.normalizedValue, bucketIndex: bucket))
            }
        }
        return assignments
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
        EngineCallObserver.record(.routeMetricScaleBucket)
        guard metricValues.count == weightsMeters.count else {
            throw RunPlayRouteMetricScaleBucketBridgeError.invalidInputContract
        }
        let count = metricValues.count
        guard count <= RunPlayEngineLimits.maxRouteInputSamples else {
            throw RunPlayRouteMetricScaleBucketBridgeError.resourceLimit
        }
        // Preserve the full public Swift `Int` domain for bucket counts.
        guard minimumValidIntervalCount >= 0,
              let engineMinimumCount = UInt64(exactly: minimumValidIntervalCount),
              let engineBucketCount = Int64(exactly: bucketCount)
        else {
            throw RunPlayRouteMetricScaleBucketBridgeError.invalidPolicy
        }

        let stride = max(1, cancellationCheckStride)
        if isCancelled() { throw CancellationError() }

        let input = try engineSamples(
            metricValues: metricValues, weightsMeters: weightsMeters, stride: stride, isCancelled: isCancelled
        )

        let policy = RouteMetricScaleBucketPolicy(
            lowerQuantile: lowerQuantile, upperQuantile: upperQuantile,
            minimumScaleSpan: minimumScaleSpan, minimumValidIntervalCount: engineMinimumCount,
            bucketCount: engineBucketCount
        )

        if isCancelled() { throw CancellationError() }
        let output = try runKernel(input, policy: policy)
        if isCancelled() { throw CancellationError() }

        guard let validCount = Int(exactly: output.validIntervalCount),
              let noDataCount = Int(exactly: output.noDataIntervalCount),
              output.samples.count == count
        else {
            throw RunPlayRouteMetricScaleBucketBridgeError.engineContractViolation
        }

        let numericScale = output.hasScale
            ? RunPlayRouteMetricNumericScale(
                lowerBound: output.lowerBound, median: output.median, upperBound: output.upperBound
            )
            : nil

        let assignments = try bucketAssignments(output, stride: stride, isCancelled: isCancelled)

        return RunPlayRouteMetricScaleBucketResult(
            scale: numericScale,
            assignments: assignments,
            validCoverageDistanceMeters: output.validCoverageDistanceMeters,
            validIntervalCount: validCount,
            noDataIntervalCount: noDataCount
        )
    }
}
