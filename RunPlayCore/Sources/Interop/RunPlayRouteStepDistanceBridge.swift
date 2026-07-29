import Foundation

// Keep imported C++ declarations confined to the internal Interop layer.
internal import CxxStdlib
internal import RunPlayEngineCpp

/// Errors raised by the production route step-distance bulk boundary.
enum RunPlayRouteStepDistanceBridgeError: Error, Equatable {
    case resourceLimit
    case engineContractViolation
}

/// Pure-Swift projection of one complete C++ step-distance result.
struct RunPlayRouteStepDistanceResult: Sendable {
    let stepDistancesMeters: ContiguousArray<Double>
    let totalDistanceMeters: Double
    let segmentTransitionCount: UInt64
    let invalidCoordinatePairCount: UInt64
}

/// Production adapter for bulk coordinate-derived route step distances.
///
/// Builds one shared native input buffer and one Swift-owned output buffer,
/// then invokes `compute_route_step_distances` exactly once. C++ retains
/// neither pointer. Scalar per-point C++ calls are forbidden here.
enum RunPlayRouteStepDistanceBridge {
    static func compute(
        _ points: [RoutePoint]
    ) throws -> RunPlayRouteStepDistanceResult {
        if points.isEmpty {
            return RunPlayRouteStepDistanceResult(
                stepDistancesMeters: [],
                totalDistanceMeters: 0,
                segmentTransitionCount: 0,
                invalidCoordinatePairCount: 0
            )
        }

        return try computeNative(points)
    }

    /// Nested so every temporary C++ value is destroyed before the pure-Swift
    /// result returns to production code.
    private static func computeNative(
        _ points: [RoutePoint]
    ) throws -> RunPlayRouteStepDistanceResult {
        var stepDistances = ContiguousArray<Double>(
            repeating: 0,
            count: points.count
        )

        let summary = RunPlayRouteInputBuffer.withNativeSamples(points) { input in
            stepDistances.withUnsafeMutableBufferPointer { output in
                runplay.compute_route_step_distances(
                    input.baseAddress,
                    input.count,
                    output.baseAddress,
                    output.count
                )
            }
        }

        switch summary.status {
        case .success:
            break
        case .resource_limit:
            throw RunPlayRouteStepDistanceBridgeError.resourceLimit
        case .invalid_input_buffer,
             .invalid_output_buffer,
             .insufficient_output_capacity:
            throw RunPlayRouteStepDistanceBridgeError.engineContractViolation
        default:
            throw RunPlayRouteStepDistanceBridgeError.engineContractViolation
        }

        guard summary.sample_count == UInt64(points.count) else {
            throw RunPlayRouteStepDistanceBridgeError.engineContractViolation
        }

        return RunPlayRouteStepDistanceResult(
            stepDistancesMeters: stepDistances,
            totalDistanceMeters: summary.total_distance_meters,
            segmentTransitionCount: summary.segment_transition_count,
            invalidCoordinatePairCount: summary.invalid_coordinate_pair_count
        )
    }
}
