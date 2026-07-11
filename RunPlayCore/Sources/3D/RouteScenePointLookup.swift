extension Array where Element == RouteScenePoint {
    /// Finds the projected point that best represents a source route-point index.
    ///
    /// Projection can filter invalid coordinates, so a direct source-index match
    /// is preferred and a distance-based lookup is used as a fallback.
    public func scenePoint(
        forRouteIndex routeIndex: Int,
        in routePoints: [RoutePoint]
    ) -> RouteScenePoint? {
        guard !isEmpty, routePoints.indices.contains(routeIndex) else {
            return nil
        }

        if let directMatch = first(where: { $0.sourceIndex == routeIndex }) {
            return directMatch
        }

        let targetDistance = routePoints[routeIndex].distanceFromStartMeters
        var low = startIndex
        var high = index(before: endIndex)
        while low < high {
            let middle = index(low, offsetBy: distance(from: low, to: high) / 2)
            if self[middle].distanceFromStartMeters < targetDistance {
                low = index(after: middle)
            } else {
                high = middle
            }
        }

        if low > startIndex {
            let previous = index(before: low)
            let previousDifference = abs(self[previous].distanceFromStartMeters - targetDistance)
            let currentDifference = abs(self[low].distanceFromStartMeters - targetDistance)
            if previousDifference < currentDifference {
                return self[previous]
            }
        }

        return self[low]
    }
}
