import Foundation
import AppKit
import CoreGraphics
import RunPlayCore

/// Appearance for a map snapshot request (resolved Light/Dark only).
public enum WorkoutMapSnapshotAppearance: String, Hashable, Sendable {
    case light
    case dark

    public init(_ appearance: PNGSummaryExportAppearance) {
        switch appearance {
        case .light: self = .light
        case .dark: self = .dark
        }
    }

    public var pngAppearance: PNGSummaryExportAppearance {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Errors from map snapshot generation.
public enum WorkoutMapSnapshotError: Error, LocalizedError, Sendable, Equatable {
    case emptyRoute
    case invalidRegion
    case snapshotFailed(String)
    case cancelled
    case compositionFailed(String)
    case unsupportedEnvironment(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRoute:
            return "No usable route coordinates for a map snapshot."
        case .invalidRegion:
            return "Could not plan a valid map region for this route."
        case .snapshotFailed(let detail):
            return "Map imagery unavailable: \(detail)"
        case .cancelled:
            return "Map snapshot cancelled."
        case .compositionFailed(let detail):
            return "Could not draw route on map: \(detail)"
        case .unsupportedEnvironment(let detail):
            return "Map snapshot is unavailable: \(detail)"
        }
    }
}

/// Identity fields that must match for cache reuse.
public struct WorkoutMapSnapshotCacheKey: Hashable, Sendable {
    public let workoutID: UUID
    public let normalizationVersion: Int
    public let analysisVersion: Int
    public let pointCount: Int
    public let firstPointID: UUID?
    public let lastPointID: UUID?
    public let routeColorMode: WorkoutRouteColorMode
    public let routeMetricPolicyVersion: Int
    public let profileVersion: Int
    public let paletteVersion: Int
    public let appearance: WorkoutMapSnapshotAppearance
    public let width: Int
    public let height: Int
    public let regionPlannerVersion: Int

    public init(
        workoutID: UUID,
        normalizationVersion: Int,
        analysisVersion: Int,
        pointCount: Int,
        firstPointID: UUID?,
        lastPointID: UUID?,
        routeColorMode: WorkoutRouteColorMode,
        routeMetricPolicyVersion: Int,
        profileVersion: Int,
        paletteVersion: Int,
        appearance: WorkoutMapSnapshotAppearance,
        width: Int,
        height: Int,
        regionPlannerVersion: Int = MapSnapshotRegionPlanner.version
    ) {
        self.workoutID = workoutID
        self.normalizationVersion = normalizationVersion
        self.analysisVersion = analysisVersion
        self.pointCount = pointCount
        self.firstPointID = firstPointID
        self.lastPointID = lastPointID
        self.routeColorMode = routeColorMode
        self.routeMetricPolicyVersion = routeMetricPolicyVersion
        self.profileVersion = profileVersion
        self.paletteVersion = paletteVersion
        self.appearance = appearance
        self.width = width
        self.height = height
        self.regionPlannerVersion = regionPlannerVersion
    }

    public init(
        workout: RunWorkout,
        routeColorMode: WorkoutRouteColorMode,
        appearance: WorkoutMapSnapshotAppearance,
        size: CGSize,
        policyVersion: Int = RouteMetricColorPolicy.runningDefault.policyVersion,
        profileVersion: Int = 1,
        paletteVersion: Int = RouteMetricPalette.version
    ) {
        self.init(
            workoutID: workout.id,
            normalizationVersion: workout.normalizationVersion,
            analysisVersion: workout.analysisVersion,
            pointCount: workout.routePoints.count,
            firstPointID: workout.routePoints.first?.id,
            lastPointID: workout.routePoints.last?.id,
            routeColorMode: routeColorMode,
            routeMetricPolicyVersion: policyVersion,
            profileVersion: profileVersion,
            paletteVersion: paletteVersion,
            appearance: appearance,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded())
        )
    }
}

/// Request for a composited workout map snapshot.
public struct WorkoutMapSnapshotRequest: Sendable {
    public let size: CGSize
    public let appearance: WorkoutMapSnapshotAppearance
    public let routes: [RouteMapLine]
    public let markers: [RouteMapMarker]
    public let lineWidth: CGFloat
    public let cacheKey: WorkoutMapSnapshotCacheKey?

    public init(
        size: CGSize,
        appearance: WorkoutMapSnapshotAppearance,
        routes: [RouteMapLine],
        markers: [RouteMapMarker],
        lineWidth: CGFloat = 5,
        cacheKey: WorkoutMapSnapshotCacheKey? = nil
    ) {
        self.size = size
        self.appearance = appearance
        self.routes = routes
        self.markers = markers
        self.lineWidth = lineWidth
        self.cacheKey = cacheKey
    }
}

/// Platform image result suitable for Studio presentation.
///
/// Uses CGImage so results can cross actor boundaries without capturing
/// non-Sendable AppKit state beyond an unchecked image wrapper.
public struct WorkoutMapSnapshotResult: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let containsNoDataLines: Bool

    public init(cgImage: CGImage, containsNoDataLines: Bool = false) {
        self.cgImage = cgImage
        self.pixelWidth = cgImage.width
        self.pixelHeight = cgImage.height
        self.containsNoDataLines = containsNoDataLines
    }

    public var nsImage: NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
    }
}

/// Converts geographic coordinates into snapshot image pixel points.
///
/// Points use the AppKit/Core Graphics bottom-left origin convention.
public protocol MapCoordinateConverting: Sendable {
    func point(for coordinate: RouteMapCoordinate) -> CGPoint
}

/// Service that produces a basemap + composited route image.
public protocol WorkoutMapSnapshotting: Sendable {
    func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult
}
