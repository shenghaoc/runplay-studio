import Foundation

/// Classification of a time interval inside a continuous route segment.
///
/// `paused` covers explicit recording gaps and inter-segment boundaries;
/// those intervals are owned by `WorkoutTimeline` and are not active time.
public enum MovementState: String, Codable, Hashable, Sendable {
    /// Confidently moving.
    case moving
    /// Confidently stationary while recording remained active.
    case stopped
    /// Explicit recording pause or route-segment gap.
    case paused
    /// Insufficient evidence to make a confident classification.
    /// Counts as moving for summary calculations (conservative).
    case uncertain
}
