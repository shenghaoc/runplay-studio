import Foundation

/// Alignment domain used when comparing two workouts.
///
/// - `distance`: equal cumulative distance (legacy/default behaviour).
/// - `routeAware`: geographic route-shape matching via constrained DTW.
public enum ComparisonAlignmentMode: String, CaseIterable, Codable, Hashable, Sendable {
    case distance
    case routeAware

    public var displayName: String { displayName(locale: nil) }

    package func displayName(locale: Locale?) -> String {
        switch self {
        case .distance: return coreLocalized("Distance", locale: locale)
        case .routeAware: return coreLocalized("Route-Aware", locale: locale)
        }
    }

    public var helpText: String {
        switch self {
        case .distance:
            return coreLocalized("Matches equal cumulative distances in both runs.")
        case .routeAware:
            return coreLocalized("Matches corresponding route positions using GPS route shape.")
        }
    }
}
