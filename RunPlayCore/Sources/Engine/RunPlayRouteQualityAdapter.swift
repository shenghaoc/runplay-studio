import Foundation

internal import RunPlayEngine

/// Errors raised by the combined route-quality geometry bulk boundary.
enum RunPlayRouteQualityBridgeError: Error, Equatable {
    case resourceLimit
    case invalidInputContract
    case invalidPolicy
    case engineContractViolation
}

/// Core projection of one complete route-quality geometry result.
struct RunPlayRouteQualityGeometryResult: Sendable {
    let routePoints: [RoutePoint]
    let discardedCoordinatePointCount: Int
    let inferredRouteGapCount: Int
    let distanceSource: RouteDistanceSource
    let distanceProvenance: RouteDistanceProvenance
}

/// Production adapter for combined Swift route-quality stages 2-4.
enum RunPlayRouteQualityBridge {
    static func process(
        _ orderedPoints: [RoutePoint],
        policy: RouteQualityPolicy,
        distancePolicy: RouteDistancePolicy,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayRouteQualityGeometryResult {
        if orderedPoints.isEmpty {
            return RunPlayRouteQualityGeometryResult(
                routePoints: [],
                discardedCoordinatePointCount: 0,
                inferredRouteGapCount: 0,
                distanceSource: .coordinateDerived,
                distanceProvenance: RouteDistanceProvenance()
            )
        }
        let stride = max(1, cancellationCheckStride)
        let geometryPolicy = swiftGeometryPolicy(from: policy)
        let (distanceStrategy, selection) = swiftSelection(orderedPoints, for: distancePolicy)
        let input = try swiftSamples(orderedPoints, stride: stride, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }

        // Capture a typed result before the after-call cancellation check, so
        // cancellation still takes precedence over translating a kernel error.
        EngineCallObserver.record(.routeQuality)
        let result: Result<EngineRouteQualityResult, RouteQualityError>
        do throws(RouteQualityError) {
            if let selection {
                result = .success(try EngineRouteQuality.process(
                    input.span, policy: geometryPolicy, distancePolicy: distanceStrategy,
                    selection: selection.span
                ))
            } else {
                result = .success(try EngineRouteQuality.process(
                    input.span, policy: geometryPolicy, distancePolicy: distanceStrategy,
                    selection: nil
                ))
            }
        } catch {
            result = .failure(error)
        }

        if isCancelled() { throw CancellationError() }
        switch result {
        case .success(let summary):
            return try projectSwiftResult(
                orderedPoints: orderedPoints, summary: summary,
                cancellationCheckStride: stride, isCancelled: isCancelled
            )
        case .failure(.resourceLimit):
            throw RunPlayRouteQualityBridgeError.resourceLimit
        case .failure(.invalidInputContract):
            throw RunPlayRouteQualityBridgeError.invalidInputContract
        case .failure(.invalidPolicy):
            throw RunPlayRouteQualityBridgeError.invalidPolicy
        case .failure(.invalidSelectionBuffer):
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        }
    }

    private static func swiftGeometryPolicy(from policy: RouteQualityPolicy) -> EngineRouteQualityPolicy {
        EngineRouteQualityPolicy(
            maximumRunningSpeed: policy.maximumPlausibleRunningSpeedMetersPerSecond,
            usefulAccuracy: policy.maximumUsefulHorizontalAccuracyMeters,
            minimumSpikeExcess: policy.coordinateSpikeMinimumExcessDistanceMeters,
            minimumSpikeDistortion: policy.coordinateSpikeMinimumDistortionRatio,
            poorAccuracyMultiplier: policy.poorAccuracyEvidenceMultiplier,
            minimumGapDistance: policy.implicitGapMinimumDistanceMeters,
            minimumGapInterval: policy.implicitGapMinimumTimeIntervalSeconds,
            minimumGapRatio: policy.implicitGapMinimumTimeDiscontinuityRatio,
            confirmationCount: UInt64(policy.relocatedClusterConfirmationPointCount),
            maximumClusterStep: policy.relocatedClusterMaximumStepMeters
        )
    }

    private static func swiftSelection(
        _ points: [RoutePoint], for policy: RouteDistancePolicy
    ) -> (EngineRouteDistancePolicy, [UInt8]?) {
        switch policy {
        case .computeFromCoordinates:
            return (.coordinates, nil)
        case .useSuppliedDistancesWhenValid:
            return (.allSupplied, nil)
        case .useSuppliedDistancesPerSegment:
            return (.suppliedPerSegment, nil)
        case .useSuppliedDistancesForSegments(let selected):
            return (.suppliedForSelection, points.map { selected.contains($0.routeSegmentIndex) ? 1 : 0 })
        }
    }

    private static func swiftSamples(
        _ points: [RoutePoint], stride: Int, isCancelled: @Sendable () -> Bool
    ) throws -> [EngineRouteInputSample] {
        var samples: [EngineRouteInputSample] = []
        samples.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            if index.isMultiple(of: stride), isCancelled() { throw CancellationError() }
            guard let segment = Int64(exactly: point.routeSegmentIndex) else {
                preconditionFailure("RoutePoint.routeSegmentIndex must fit in Int64")
            }
            samples.append(EngineRouteInputSample(
                sourceIndex: UInt64(index),
                timestampSecondsSinceReferenceDate: point.timestamp.timeIntervalSinceReferenceDate,
                latitude: point.latitude, longitude: point.longitude,
                altitudeMeters: point.altitudeMeters, demAltitudeMeters: point.demAltitudeMeters,
                distanceFromStartMeters: point.distanceFromStartMeters, elapsedSeconds: point.elapsedSeconds,
                speedMetersPerSecond: point.speedMetersPerSecond,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer, heartRateBPM: point.heartRateBPM,
                cadence: point.cadence, powerWatts: point.powerWatts,
                groundContactTimeMilliseconds: point.groundContactTimeMilliseconds,
                verticalOscillationMillimeters: point.verticalOscillationMillimeters,
                verticalRatioPercent: point.verticalRatioPercent,
                stanceTimeBalancePercent: point.stanceTimeBalancePercent, stepLengthMeters: point.stepLengthMeters,
                horizontalAccuracy: point.horizontalAccuracy, routeSegmentIndex: segment
            ))
        }
        return samples
    }

    /// Retained samples start in segment zero and stay in a segment or move
    /// to the next one, and every sample of a segment has the segment's
    /// distance source. Records each new segment's source.
    @inline(__always)
    private static func acceptSegment(
        _ normalizedSegment: Int64,
        distanceSource: EngineRouteDistanceSource,
        previousNormalizedSegment: inout Int64?,
        segmentSources: inout [RouteDistanceSource]
    ) throws {
        if previousNormalizedSegment == nil {
            guard normalizedSegment == 0 else {
                throw RunPlayRouteQualityBridgeError.engineContractViolation
            }
        } else if let previous = previousNormalizedSegment {
            guard normalizedSegment == previous
                || normalizedSegment == previous + 1
            else {
                throw RunPlayRouteQualityBridgeError.engineContractViolation
            }
        }
        if previousNormalizedSegment != normalizedSegment {
            segmentSources.append(modelDistanceSource(distanceSource))
            previousNormalizedSegment = normalizedSegment
        } else if let last = segmentSources.last {
            let current = modelDistanceSource(distanceSource)
            guard last == current else {
                throw RunPlayRouteQualityBridgeError.engineContractViolation
            }
        }
    }

    private static func projectSwiftResult(
        orderedPoints: [RoutePoint],
        summary: EngineRouteQualityResult,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayRouteQualityGeometryResult {
        guard summary.samples.count == orderedPoints.count else {
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        }

        var retained: [RoutePoint] = []
        retained.reserveCapacity(summary.retainedCount)
        var retainedCount = 0
        var previousNormalizedSegment: Int64?
        var segmentSources: [RouteDistanceSource] = []

        for index in orderedPoints.indices {
            if index.isMultiple(of: cancellationCheckStride), isCancelled() {
                throw CancellationError()
            }

            let sample = summary.samples[index]
            guard sample.sourceIndex == UInt64(index) else {
                throw RunPlayRouteQualityBridgeError.engineContractViolation
            }

            if !sample.retained {
                continue
            }
            retainedCount += 1

            let normalizedSegment = sample.normalizedSegmentIndex
            try acceptSegment(
                normalizedSegment, distanceSource: sample.distanceSource,
                previousNormalizedSegment: &previousNormalizedSegment, segmentSources: &segmentSources
            )

            var point = orderedPoints[index]
            guard let segmentIndex = Int(exactly: normalizedSegment) else {
                throw RunPlayRouteQualityBridgeError.engineContractViolation
            }
            point.routeSegmentIndex = segmentIndex
            point.distanceFromStartMeters =
                sample.normalizedDistance
            retained.append(point)
        }

        guard retainedCount == summary.retainedCount,
              retained.count == retainedCount,
              segmentSources.count == summary.segmentCount
        else {
            throw RunPlayRouteQualityBridgeError.engineContractViolation
        }

        let overall = modelDistanceSource(summary.distanceSource)
        return RunPlayRouteQualityGeometryResult(
            routePoints: retained,
            discardedCoordinatePointCount: summary.discardedCount,
            inferredRouteGapCount: summary.inferredGapCount,
            distanceSource: overall,
            distanceProvenance: RouteDistanceProvenance(segmentSources: segmentSources)
        )
    }

    private static func modelDistanceSource(_ source: EngineRouteDistanceSource) -> RouteDistanceSource {
        switch source {
        case .coordinates: .coordinateDerived
        case .supplied: .deviceSupplied
        case .mixed: .mixed
        }
    }
}
