import CoreGraphics
import Foundation
import RunPlayCore

/// One route-point sample with cumulative distance for gap-safe pixel lookup.
public struct ComparisonVideoPixelSample: Hashable, Sendable {
    public let routePointID: UUID
    public let routePointIndex: Int
    public let routeSegmentIndex: Int
    public let distanceMeters: Double
    public let point: CGPoint

    public init(
        routePointID: UUID,
        routePointIndex: Int,
        routeSegmentIndex: Int,
        distanceMeters: Double,
        point: CGPoint
    ) {
        self.routePointID = routePointID
        self.routePointIndex = max(0, routePointIndex)
        self.routeSegmentIndex = max(0, routeSegmentIndex)
        self.distanceMeters = distanceMeters.isFinite ? max(0, distanceMeters) : 0
        self.point = point
    }
}

/// Immutable gap-safe pixel map for one workout on a prepared comparison map.
///
/// Interpolates only within the same route segment. Never bridges recording gaps.
public struct ComparisonVideoRoutePixelMap: Sendable {
    /// Sparse samples with valid pixels, ordered by route-point index.
    public let samples: [ComparisonVideoPixelSample]

    public init(samples: [ComparisonVideoPixelSample]) {
        self.samples = samples
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Resolve a map pixel for the given route position / mapped distance.
    ///
    /// 1. Clamp to route distance range
    /// 2. Binary-search bracketing samples
    /// 3. Interpolate only when both samples share the same segment
    /// 4. Otherwise same-segment nearest fallback (backward then forward)
    public func pixel(
        atDistanceMeters distanceMeters: Double,
        preferredIndex: Int? = nil,
        preferredSegment: Int? = nil
    ) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        guard distanceMeters.isFinite else { return nil }

        let firstDistance = samples[0].distanceMeters
        let lastDistance = samples[samples.count - 1].distanceMeters
        let clamped = min(max(distanceMeters, firstDistance), lastDistance)

        if clamped <= firstDistance {
            return samples[0].point
        }
        if clamped >= lastDistance {
            return samples[samples.count - 1].point
        }

        // Binary search: first sample with distance >= clamped.
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].distanceMeters < clamped {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let afterIndex = low
        if samples[afterIndex].distanceMeters == clamped {
            return samples[afterIndex].point
        }
        if afterIndex == 0 {
            return samples[0].point
        }
        let before = samples[afterIndex - 1]
        let after = samples[afterIndex]

        if before.routeSegmentIndex == after.routeSegmentIndex {
            let span = after.distanceMeters - before.distanceMeters
            if span > 0, span.isFinite {
                let fraction = max(0, min(1, (clamped - before.distanceMeters) / span))
                return CGPoint(
                    x: before.point.x + (after.point.x - before.point.x) * fraction,
                    y: before.point.y + (after.point.y - before.point.y) * fraction
                )
            }
            return after.point
        }

        // Cross-segment: prefer same-segment nearest around preferred index.
        if let preferredIndex, let preferredSegment {
            if let same = nearestSameSegment(
                aroundIndex: preferredIndex,
                segment: preferredSegment
            ) {
                return same
            }
        }
        // Prefer the earlier sample at the segment boundary.
        return before.point
    }

    public func pixel(for position: ComparisonVideoRoutePosition) -> CGPoint? {
        pixel(
            atDistanceMeters: position.distanceMeters,
            preferredIndex: position.routePointIndex,
            preferredSegment: position.routeSegmentIndex
        )
    }

    private func nearestSameSegment(aroundIndex index: Int, segment: Int) -> CGPoint? {
        // Find closest sample by routePointIndex in the same segment.
        var best: ComparisonVideoPixelSample?
        var bestDelta = Int.max
        for sample in samples {
            guard sample.routeSegmentIndex == segment else { continue }
            let delta = abs(sample.routePointIndex - index)
            if delta < bestDelta {
                bestDelta = delta
                best = sample
            }
        }
        return best?.point
    }
}
