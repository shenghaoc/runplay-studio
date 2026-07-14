import Foundation

/// Persisted, non-fatal diagnostics produced while normalizing a route.
public struct RouteQualityDiagnostics: Codable, Hashable, Sendable {
    public var invalidCoordinatePointCount: Int
    public var discardedCoordinatePointCount: Int
    public var inferredRouteGapCount: Int
    public var discardedAltitudeSampleCount: Int
    public var invalidSourceSpeedSampleCount: Int

    public init(
        invalidCoordinatePointCount: Int = 0,
        discardedCoordinatePointCount: Int = 0,
        inferredRouteGapCount: Int = 0,
        discardedAltitudeSampleCount: Int = 0,
        invalidSourceSpeedSampleCount: Int = 0
    ) {
        self.invalidCoordinatePointCount = max(0, invalidCoordinatePointCount)
        self.discardedCoordinatePointCount = max(0, discardedCoordinatePointCount)
        self.inferredRouteGapCount = max(0, inferredRouteGapCount)
        self.discardedAltitudeSampleCount = max(0, discardedAltitudeSampleCount)
        self.invalidSourceSpeedSampleCount = max(0, invalidSourceSpeedSampleCount)
    }

    public static let empty = RouteQualityDiagnostics()

    public var hasQualityEvents: Bool {
        invalidCoordinatePointCount > 0
            || discardedCoordinatePointCount > 0
            || inferredRouteGapCount > 0
            || discardedAltitudeSampleCount > 0
            || invalidSourceSpeedSampleCount > 0
    }
}

/// Records whether normalized cumulative distance came from coordinates or
/// from a device-provided distance series.
public enum RouteDistanceSource: String, Codable, Hashable, Sendable {
    case coordinateDerived
    case deviceSupplied
    case mixed
    case legacyUnknown
}

/// Per-segment distance provenance aligned by compact route-segment index.
public struct RouteDistanceProvenance: Codable, Hashable, Sendable {
    public var segmentSources: [RouteDistanceSource]

    public init(segmentSources: [RouteDistanceSource] = []) {
        self.segmentSources = segmentSources
    }

    public static let legacyUnknown = RouteDistanceProvenance()

    public func source(forSegment index: Int) -> RouteDistanceSource {
        guard segmentSources.indices.contains(index) else { return .legacyUnknown }
        return segmentSources[index]
    }
}
