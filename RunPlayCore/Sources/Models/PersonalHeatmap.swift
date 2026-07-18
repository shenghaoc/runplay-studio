import Foundation

// MARK: - Date filter

/// Explicit, deterministic date filter for personal heatmap aggregation.
///
/// Resolve relative ranges (last N days, calendar year) once at the Studio
/// boundary by injecting `now` and a calendar; Core never calls `Date()`.
public enum PersonalHeatmapDateFilter: Hashable, Sendable, Codable {
    /// Include every workout with usable route data, including undated ones.
    case allTime
    /// Inclusive closed range on the workout start instant (`start <= t <= end`).
    case range(start: Date, end: Date)

    public static func lastDays(_ days: Int, now: Date, calendar: Calendar) -> PersonalHeatmapDateFilter {
        let clampedDays = max(1, days)
        let end = now
        let start = calendar.date(byAdding: .day, value: -clampedDays, to: now) ?? now.addingTimeInterval(TimeInterval(-clampedDays * 86_400))
        return .range(start: start, end: end)
    }

    public static func currentCalendarYear(now: Date, calendar: Calendar) -> PersonalHeatmapDateFilter {
        let year = calendar.component(.year, from: now)
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        let endOfYear = calendar.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59)) ?? now
        let end = min(now, endOfYear)
        return .range(start: start, end: end)
    }
}

// MARK: - Resolution

/// User-facing cell-size presets in metres (Web Mercator projected).
public enum PersonalHeatmapResolution: String, CaseIterable, Hashable, Sendable, Codable {
    case fine
    case standard
    case broad

    /// Nominal cell edge length in metres.
    public var cellSizeMeters: Double {
        switch self {
        case .fine: return 25
        case .standard: return 50
        case .broad: return 100
        }
    }

    public var displayName: String {
        switch self {
        case .fine: return "Fine"
        case .standard: return "Standard"
        case .broad: return "Broad"
        }
    }

    public var helpText: String {
        "\(displayName) (\(Int(cellSizeMeters)) m cells)"
    }
}

// MARK: - Configuration

/// Immutable request configuration for heatmap aggregation.
public struct PersonalHeatmapConfiguration: Hashable, Sendable, Codable {
    /// Default rendered-cell budget. SwiftUI `MapPolygon` counts above this
    /// degrade interactivity; the builder coarsens resolution instead of
    /// dropping cells at random.
    public static let defaultMaximumRenderedCellCount = 5_000

    public var dateFilter: PersonalHeatmapDateFilter
    /// Requested cell edge length in metres. Must be finite and positive.
    public var cellSizeMeters: Double
    /// Minimum distinct-workout count for a cell to be rendered.
    public var minimumWorkoutCount: Int
    /// Hard cap on rendered cells; triggers adaptive coarsening when exceeded.
    public var maximumRenderedCellCount: Int
    /// Maximum projected length of a single interval (metres). Longer jumps
    /// are treated as malformed and skipped rather than rasterized.
    public var maximumIntervalMeters: Double

    public init(
        dateFilter: PersonalHeatmapDateFilter = .allTime,
        cellSizeMeters: Double = PersonalHeatmapResolution.standard.cellSizeMeters,
        minimumWorkoutCount: Int = 1,
        maximumRenderedCellCount: Int = PersonalHeatmapConfiguration.defaultMaximumRenderedCellCount,
        maximumIntervalMeters: Double = 50_000
    ) {
        precondition(cellSizeMeters.isFinite && cellSizeMeters > 0, "cellSizeMeters must be finite and positive")
        precondition(minimumWorkoutCount >= 1, "minimumWorkoutCount must be at least 1")
        precondition(maximumRenderedCellCount >= 1, "maximumRenderedCellCount must be at least 1")
        precondition(maximumIntervalMeters.isFinite && maximumIntervalMeters > 0, "maximumIntervalMeters must be finite and positive")

        self.dateFilter = dateFilter
        self.cellSizeMeters = cellSizeMeters
        self.minimumWorkoutCount = minimumWorkoutCount
        self.maximumRenderedCellCount = maximumRenderedCellCount
        self.maximumIntervalMeters = maximumIntervalMeters
    }

    /// Validated copy used when configuration may come from untrusted UI state.
    public static func validated(
        dateFilter: PersonalHeatmapDateFilter,
        cellSizeMeters: Double,
        minimumWorkoutCount: Int,
        maximumRenderedCellCount: Int = PersonalHeatmapConfiguration.defaultMaximumRenderedCellCount,
        maximumIntervalMeters: Double = 50_000
    ) -> PersonalHeatmapConfiguration? {
        guard cellSizeMeters.isFinite, cellSizeMeters > 0,
              minimumWorkoutCount >= 1,
              maximumRenderedCellCount >= 1,
              maximumIntervalMeters.isFinite, maximumIntervalMeters > 0 else {
            return nil
        }
        return PersonalHeatmapConfiguration(
            dateFilter: dateFilter,
            cellSizeMeters: cellSizeMeters,
            minimumWorkoutCount: minimumWorkoutCount,
            maximumRenderedCellCount: maximumRenderedCellCount,
            maximumIntervalMeters: maximumIntervalMeters
        )
    }
}

// MARK: - Cell identity and geometry

/// Stable grid cell identity. Coordinates are Web Mercator cell indexes.
///
/// Negative indexes are valid in the western and southern hemispheres.
/// Identity is not UUID-based so the same geographic cell is stable across
/// launches and platforms for a given cell size.
public struct PersonalHeatmapCellID: Hashable, Codable, Sendable, Comparable {
    public let x: Int64
    public let y: Int64

    public init(x: Int64, y: Int64) {
        self.x = x
        self.y = y
    }

    public static func < (lhs: PersonalHeatmapCellID, rhs: PersonalHeatmapCellID) -> Bool {
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.x < rhs.x
    }
}

/// Geographic bounds of one heatmap cell (axis-aligned lat/lon rectangle).
public struct PersonalHeatmapCellBounds: Hashable, Sendable, Codable {
    public let minLatitude: Double
    public let maxLatitude: Double
    public let minLongitude: Double
    public let maxLongitude: Double

    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    /// Corner coordinates in counter-clockwise order starting at SW, closed for polygons.
    public var polygonCoordinates: [(latitude: Double, longitude: Double)] {
        [
            (minLatitude, minLongitude),
            (minLatitude, maxLongitude),
            (maxLatitude, maxLongitude),
            (maxLatitude, minLongitude),
            (minLatitude, minLongitude)
        ]
    }
}

/// One aggregated heatmap cell. Intensity is derived from distinct-workout count.
public struct PersonalHeatmapCell: Identifiable, Hashable, Sendable, Codable {
    public let id: PersonalHeatmapCellID
    /// Number of distinct included workouts whose route traverses this cell.
    public let workoutCount: Int
    /// Visual intensity in `0...1` from log1p normalization against max count.
    public let normalizedIntensity: Double
    public let bounds: PersonalHeatmapCellBounds

    public init(
        id: PersonalHeatmapCellID,
        workoutCount: Int,
        normalizedIntensity: Double,
        bounds: PersonalHeatmapCellBounds
    ) {
        self.id = id
        self.workoutCount = workoutCount
        self.normalizedIntensity = normalizedIntensity
        self.bounds = bounds
    }
}

/// Overall geographic bounds of the rendered heatmap.
public struct PersonalHeatmapBounds: Hashable, Sendable, Codable {
    public let minLatitude: Double
    public let maxLatitude: Double
    public let minLongitude: Double
    public let maxLongitude: Double

    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }
}

// MARK: - Statistics and diagnostics

/// User-facing statistics for a completed heatmap build.
public struct PersonalHeatmapStatistics: Hashable, Sendable, Codable {
    /// Workouts that passed date filter and contributed at least one cell.
    public let includedWorkoutCount: Int
    /// Sum of included workouts' summary distances (not cell-derived).
    public let totalDistanceMeters: Double
    /// Highest distinct-workout count among *aggregated* cells (before min-repeat filter).
    public let maximumOverlap: Int
    /// Cell size requested by the user.
    public let requestedCellSizeMeters: Double
    /// Cell size actually used after adaptive coarsening (if any).
    public let effectiveCellSizeMeters: Double
    /// True when adaptive coarsening increased the cell size.
    public let resolutionWasAdjusted: Bool
    /// Number of workouts excluded solely because they lacked a trustworthy date.
    public let excludedUndatedWorkoutCount: Int
    /// Number of workouts excluded because they had no usable route geometry.
    public let excludedNoRouteWorkoutCount: Int

    public init(
        includedWorkoutCount: Int,
        totalDistanceMeters: Double,
        maximumOverlap: Int,
        requestedCellSizeMeters: Double,
        effectiveCellSizeMeters: Double,
        resolutionWasAdjusted: Bool,
        excludedUndatedWorkoutCount: Int,
        excludedNoRouteWorkoutCount: Int
    ) {
        self.includedWorkoutCount = includedWorkoutCount
        self.totalDistanceMeters = totalDistanceMeters
        self.maximumOverlap = maximumOverlap
        self.requestedCellSizeMeters = requestedCellSizeMeters
        self.effectiveCellSizeMeters = effectiveCellSizeMeters
        self.resolutionWasAdjusted = resolutionWasAdjusted
        self.excludedUndatedWorkoutCount = excludedUndatedWorkoutCount
        self.excludedNoRouteWorkoutCount = excludedNoRouteWorkoutCount
    }

    public static let empty = PersonalHeatmapStatistics(
        includedWorkoutCount: 0,
        totalDistanceMeters: 0,
        maximumOverlap: 0,
        requestedCellSizeMeters: PersonalHeatmapResolution.standard.cellSizeMeters,
        effectiveCellSizeMeters: PersonalHeatmapResolution.standard.cellSizeMeters,
        resolutionWasAdjusted: false,
        excludedUndatedWorkoutCount: 0,
        excludedNoRouteWorkoutCount: 0
    )
}

/// Detailed diagnostics for tests and optional debug UI. Not shown in the normal UI.
public struct PersonalHeatmapDiagnostics: Hashable, Sendable, Codable {
    public let totalCandidateWorkouts: Int
    public let includedWorkouts: Int
    public let excludedUndatedWorkouts: Int
    public let excludedNoRouteWorkouts: Int
    public let invalidRouteIntervalsSkipped: Int
    public let adaptiveResolutionRetries: Int
    public let requestedCellSizeMeters: Double
    public let effectiveCellSizeMeters: Double
    public let aggregatedCellCount: Int
    public let renderedCellCount: Int

    public init(
        totalCandidateWorkouts: Int,
        includedWorkouts: Int,
        excludedUndatedWorkouts: Int,
        excludedNoRouteWorkouts: Int,
        invalidRouteIntervalsSkipped: Int,
        adaptiveResolutionRetries: Int,
        requestedCellSizeMeters: Double,
        effectiveCellSizeMeters: Double,
        aggregatedCellCount: Int,
        renderedCellCount: Int
    ) {
        self.totalCandidateWorkouts = totalCandidateWorkouts
        self.includedWorkouts = includedWorkouts
        self.excludedUndatedWorkouts = excludedUndatedWorkouts
        self.excludedNoRouteWorkouts = excludedNoRouteWorkouts
        self.invalidRouteIntervalsSkipped = invalidRouteIntervalsSkipped
        self.adaptiveResolutionRetries = adaptiveResolutionRetries
        self.requestedCellSizeMeters = requestedCellSizeMeters
        self.effectiveCellSizeMeters = effectiveCellSizeMeters
        self.aggregatedCellCount = aggregatedCellCount
        self.renderedCellCount = renderedCellCount
    }

    public static let empty = PersonalHeatmapDiagnostics(
        totalCandidateWorkouts: 0,
        includedWorkouts: 0,
        excludedUndatedWorkouts: 0,
        excludedNoRouteWorkouts: 0,
        invalidRouteIntervalsSkipped: 0,
        adaptiveResolutionRetries: 0,
        requestedCellSizeMeters: PersonalHeatmapResolution.standard.cellSizeMeters,
        effectiveCellSizeMeters: PersonalHeatmapResolution.standard.cellSizeMeters,
        aggregatedCellCount: 0,
        renderedCellCount: 0
    )
}

// MARK: - Snapshot

/// Immutable result of a heatmap aggregation. Derived and not persisted.
public struct PersonalHeatmapSnapshot: Hashable, Sendable, Codable {
    /// Rendered cells after minimum-repeat filtering, sorted by cell ID.
    public let cells: [PersonalHeatmapCell]
    public let statistics: PersonalHeatmapStatistics
    public let diagnostics: PersonalHeatmapDiagnostics
    /// Configuration that produced this snapshot (effective cell size may differ).
    public let configuration: PersonalHeatmapConfiguration
    public let bounds: PersonalHeatmapBounds?

    public init(
        cells: [PersonalHeatmapCell],
        statistics: PersonalHeatmapStatistics,
        diagnostics: PersonalHeatmapDiagnostics,
        configuration: PersonalHeatmapConfiguration,
        bounds: PersonalHeatmapBounds?
    ) {
        self.cells = cells
        self.statistics = statistics
        self.diagnostics = diagnostics
        self.configuration = configuration
        self.bounds = bounds
    }

    public static func empty(configuration: PersonalHeatmapConfiguration) -> PersonalHeatmapSnapshot {
        PersonalHeatmapSnapshot(
            cells: [],
            statistics: PersonalHeatmapStatistics(
                includedWorkoutCount: 0,
                totalDistanceMeters: 0,
                maximumOverlap: 0,
                requestedCellSizeMeters: configuration.cellSizeMeters,
                effectiveCellSizeMeters: configuration.cellSizeMeters,
                resolutionWasAdjusted: false,
                excludedUndatedWorkoutCount: 0,
                excludedNoRouteWorkoutCount: 0
            ),
            diagnostics: PersonalHeatmapDiagnostics(
                totalCandidateWorkouts: 0,
                includedWorkouts: 0,
                excludedUndatedWorkouts: 0,
                excludedNoRouteWorkouts: 0,
                invalidRouteIntervalsSkipped: 0,
                adaptiveResolutionRetries: 0,
                requestedCellSizeMeters: configuration.cellSizeMeters,
                effectiveCellSizeMeters: configuration.cellSizeMeters,
                aggregatedCellCount: 0,
                renderedCellCount: 0
            ),
            configuration: configuration,
            bounds: nil
        )
    }
}
