import Foundation

// Keep imported C++ declarations confined to the internal Interop layer.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Shared builder that materializes one complete Swift-owned native sample buffer.
///
/// Callers borrow the contiguous storage only inside `withNativeSamples`. The
/// unsafe pointer never escapes this helper.
enum RunPlayRouteInputBuffer {
    static func withNativeSamples<Result>(
        _ points: [RoutePoint],
        _ body: (
            UnsafeBufferPointer<runplay.RouteInputSample>
        ) throws -> Result
    ) rethrows -> Result {
        var samples = ContiguousArray<runplay.RouteInputSample>()
        samples.reserveCapacity(points.count)
        for (sourceIndex, point) in points.enumerated() {
            samples.append(makeSample(sourceIndex: sourceIndex, point: point))
        }
        return try samples.withUnsafeBufferPointer(body)
    }

    /// Builds one complete native sample buffer while cooperatively checking
    /// cancellation at the configured stride during conversion.
    static func withNativeSamples<Result>(
        _ points: [RoutePoint],
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool,
        _ body: (
            UnsafeBufferPointer<runplay.RouteInputSample>
        ) throws -> Result
    ) throws -> Result {
        let stride = max(1, cancellationCheckStride)
        var samples = ContiguousArray<runplay.RouteInputSample>()
        samples.reserveCapacity(points.count)

        for (sourceIndex, point) in points.enumerated() {
            if sourceIndex.isMultiple(of: stride), isCancelled() {
                throw CancellationError()
            }
            samples.append(makeSample(sourceIndex: sourceIndex, point: point))
        }

        return try samples.withUnsafeBufferPointer(body)
    }

    private static func makeSample(
        sourceIndex: Int,
        point: RoutePoint
    ) -> runplay.RouteInputSample {
        guard let routeSegmentIndex = Int64(exactly: point.routeSegmentIndex) else {
            preconditionFailure("RoutePoint.routeSegmentIndex must fit in Int64")
        }
        return runplay.RouteInputSample(
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
    }

    static func nativeOptional(
        _ value: Double?
    ) -> runplay.RouteOptionalDouble {
        guard let value else {
            return runplay.RouteOptionalDouble()
        }
        return runplay.RouteOptionalDouble(value)
    }
}
