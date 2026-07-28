import Foundation

// Keep imported C++ declarations confined to the internal Interop layer.
internal import CxxStdlib
internal import RunPlayEngineCpp

enum RunPlayRouteInteropStatus: UInt8, Equatable, Sendable {
    case success
    case invalidBuffer
    case resourceLimit
}

/// Pure-Swift projection of the compact C++ route inspection result.
struct RunPlayRouteBatchInspection: Equatable, Sendable {
    let status: RunPlayRouteInteropStatus
    let sampleCount: UInt64

    let altitudeValueCount: UInt64
    let speedValueCount: UInt64
    let paceValueCount: UInt64
    let heartRateValueCount: UInt64
    let cadenceValueCount: UInt64
    let horizontalAccuracyValueCount: UInt64

    let segmentTransitionCount: UInt64
    let firstSourceIndex: UInt64?
    let lastSourceIndex: UInt64?
    let fieldDigest: UInt64
}

/// Internal, parity-only route value adapter.
///
/// Swift owns one contiguous buffer for the complete route. C++ borrows that
/// buffer for exactly one synchronous call and retains no pointer.
enum RunPlayRouteBridge {
    static func inspect(_ points: [RoutePoint]) -> RunPlayRouteBatchInspection {
        inspectNative(points)
    }

    /// Keeping imported values in this nested call ensures every temporary C++
    /// value is destroyed before the pure-Swift result returns to the caller.
    private static func inspectNative(
        _ points: [RoutePoint]
    ) -> RunPlayRouteBatchInspection {
        var samples = ContiguousArray<runplay.RouteInputSample>()
        samples.reserveCapacity(points.count)

        for (sourceIndex, point) in points.enumerated() {
            guard let routeSegmentIndex = Int64(exactly: point.routeSegmentIndex) else {
                preconditionFailure("RoutePoint.routeSegmentIndex must fit in Int64")
            }
            samples.append(
                runplay.RouteInputSample(
                    UInt64(sourceIndex),
                    point.timestamp.timeIntervalSinceReferenceDate,
                    point.latitude,
                    point.longitude,
                    nativeOptional(point.altitudeMeters),
                    point.distanceFromStartMeters,
                    point.elapsedSeconds,
                    nativeOptional(point.speedMetersPerSecond),
                    nativeOptional(point.paceSecondsPerKilometer),
                    nativeOptional(point.heartRateBPM),
                    nativeOptional(point.cadence),
                    nativeOptional(point.horizontalAccuracy),
                    routeSegmentIndex
                )
            )
        }

        let native = samples.withUnsafeBufferPointer { buffer in
            runplay.inspect_route_batch(buffer.baseAddress, buffer.count)
        }
        let status = switch native.status {
        case .success:
            RunPlayRouteInteropStatus.success
        case .invalid_buffer:
            RunPlayRouteInteropStatus.invalidBuffer
        case .resource_limit:
            RunPlayRouteInteropStatus.resourceLimit
        default:
            preconditionFailure("Unknown C++ route interoperability status")
        }
        let firstSourceIndex: UInt64? = Optional(
            fromCxx: native.first_source_index
        ).map { UInt64($0) }
        let lastSourceIndex: UInt64? = Optional(
            fromCxx: native.last_source_index
        ).map { UInt64($0) }

        return RunPlayRouteBatchInspection(
            status: status,
            sampleCount: native.sample_count,
            altitudeValueCount: native.altitude_value_count,
            speedValueCount: native.speed_value_count,
            paceValueCount: native.pace_value_count,
            heartRateValueCount: native.heart_rate_value_count,
            cadenceValueCount: native.cadence_value_count,
            horizontalAccuracyValueCount:
                native.horizontal_accuracy_value_count,
            segmentTransitionCount: native.segment_transition_count,
            firstSourceIndex: firstSourceIndex,
            lastSourceIndex: lastSourceIndex,
            fieldDigest: native.field_digest
        )
    }

    private static func nativeOptional(
        _ value: Double?
    ) -> runplay.RouteOptionalDouble {
        guard let value else {
            return runplay.RouteOptionalDouble()
        }
        return runplay.RouteOptionalDouble(value)
    }
}
