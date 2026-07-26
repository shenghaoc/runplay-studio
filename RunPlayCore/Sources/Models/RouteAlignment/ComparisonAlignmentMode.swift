import Foundation

/// Alignment domain used when comparing two workouts.
///
/// - `distance`: equal cumulative distance (legacy/default behaviour).
/// - `routeAware`: geographic route-shape matching via constrained DTW.
public enum ComparisonAlignmentMode: String, CaseIterable, Codable, Hashable, Sendable {
    case distance
    case routeAware

    public var displayName: String {
        switch self {
        case .distance: return "Distance"
        case .routeAware: return "Route-Aware"
        }
    }

    public var helpText: String {
        switch self {
        case .distance:
            return "Matches equal cumulative distances in both runs."
        case .routeAware:
            return "Matches corresponding route positions using GPS route shape."
        }
    }
}
