import Foundation

/// Protocol for pure Core route-shape alignment implementations.
public protocol RouteComparisonAligning: Sendable {
    func align(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteAlignmentSnapshot
}

/// Cancellation token for cooperative DTW work.
public struct RouteAlignmentCancellation: Error, Equatable, Sendable {}
