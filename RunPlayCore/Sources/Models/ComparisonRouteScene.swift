import Foundation

/// The result of projecting two routes into a shared 3D coordinate space.
///
/// Contains the projected primary and comparison routes, combined bounding box,
/// and any warnings that apply to the comparison.
public struct ComparisonRouteScene {
    /// Primary route projected into shared local meter-space.
    public let primaryRoute: [RouteScenePoint]

    /// Comparison route projected into the same shared coordinate space.
    public let comparisonRoute: [RouteScenePoint]

    /// Combined bounding box encompassing both routes.
    public let combinedBounds: (min: SIMD3<Double>, max: SIMD3<Double>)

    /// Warnings about the comparison quality.
    public let warnings: [ComparisonWarning]

    public init(
        primaryRoute: [RouteScenePoint],
        comparisonRoute: [RouteScenePoint],
        combinedBounds: (min: SIMD3<Double>, max: SIMD3<Double>),
        warnings: [ComparisonWarning]
    ) {
        self.primaryRoute = primaryRoute
        self.comparisonRoute = comparisonRoute
        self.combinedBounds = combinedBounds
        self.warnings = warnings
    }

    /// Whether both routes have at least 2 points (minimum for a polyline).
    public var hasValidRoutes: Bool {
        primaryRoute.count >= 2 && comparisonRoute.count >= 2
    }

    /// Whether the primary route has enough points to render.
    public var hasPrimaryRoute: Bool {
        primaryRoute.count >= 2
    }

    /// Whether the comparison route has enough points to render.
    public var hasComparisonRoute: Bool {
        comparisonRoute.count >= 2
    }

    /// Maximum extent of the combined bounding box for camera/grid sizing.
    public var maxExtent: Double {
        let dx = combinedBounds.max.x - combinedBounds.min.x
        let dy = combinedBounds.max.y - combinedBounds.min.y
        let dz = combinedBounds.max.z - combinedBounds.min.z
        return max(dx, dy, dz, 100) // Minimum 100m extent
    }

    /// Center of the combined bounding box.
    public var center: SIMD3<Double> {
        SIMD3<Double>(
            (combinedBounds.min.x + combinedBounds.max.x) / 2,
            (combinedBounds.min.y + combinedBounds.max.y) / 2,
            (combinedBounds.min.z + combinedBounds.max.z) / 2
        )
    }
}
