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

        return try samples.withUnsafeBufferPointer(body)
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
