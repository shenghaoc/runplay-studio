import Foundation

/// Resolved appearance for a single PNG summary export.
///
/// A UI “System” option must resolve to one of these cases before rendering.
/// Appearance must not change mid-export.
public enum PNGSummaryExportAppearance: String, CaseIterable, Codable, Hashable, Sendable {
    case light
    case dark

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Card layout policy for the PNG summary export.
public enum PNGSummaryCardLayout: String, CaseIterable, Codable, Hashable, Sendable {
    /// Full metrics-focused card (up to 5 segments / 10 splits).
    case metricsOnly
    /// Map-inclusive card with compact secondary tables.
    case mapInclusive

    public var maxSegments: Int {
        switch self {
        case .metricsOnly: return 5
        case .mapInclusive: return 3
        }
    }

    public var maxSplits: Int {
        switch self {
        case .metricsOnly: return 10
        case .mapInclusive: return 5
        }
    }
}

/// User-facing configuration for PNG summary export.
///
/// Not persisted on `RunWorkout`. App-level preference storage is allowed.
public struct PNGSummaryExportConfiguration: Hashable, Sendable, Codable {
    public var includeMap: Bool
    public var appearance: PNGSummaryExportAppearance
    public var routeColorMode: WorkoutRouteColorMode

    public init(
        includeMap: Bool,
        appearance: PNGSummaryExportAppearance,
        routeColorMode: WorkoutRouteColorMode = .solid
    ) {
        self.includeMap = includeMap
        self.appearance = appearance
        self.routeColorMode = routeColorMode
    }

    /// Layout derived from whether the exported card will show a map image.
    public func layout(hasMapImage: Bool) -> PNGSummaryCardLayout {
        (includeMap && hasMapImage) ? .mapInclusive : .metricsOnly
    }
}

/// Progress phases for map-aware PNG export generation.
public enum PNGSummaryExportPhase: String, Hashable, Sendable {
    case idle
    case preparingRoute
    case loadingMap
    case drawingRoute
    case renderingCard
    case ready
    case saving
    case failed

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .preparingRoute: return "Preparing route"
        case .loadingMap: return "Loading map"
        case .drawingRoute: return "Drawing route"
        case .renderingCard: return "Rendering card"
        case .ready: return "Ready"
        case .saving: return "Saving"
        case .failed: return "Failed"
        }
    }
}

/// Fixed PNG summary card dimensions in pixels (and layout points at scale 1).
public enum PNGSummaryExportDimensions {
    public static let width: Int = 1_200
    public static let height: Int = 1_600
    /// Explicit rasterization scale — never derived from a display.
    public static let rasterizationScale: Double = 1.0
}
