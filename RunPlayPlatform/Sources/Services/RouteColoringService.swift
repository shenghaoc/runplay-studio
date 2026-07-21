import Foundation
import RunPlayCore
import AppKit

/// Legacy SceneKit route coloring mode.
///
/// Prefer `WorkoutRouteColorMode` for native MapKit presentation. This enum
/// remains for `RouteSceneBuilder` and existing tests.
public enum RouteColorMode: String, CaseIterable, Identifiable {
    case singleColor = "Single"
    case pace = "Pace"
    case elevation = "Elevation"
    case heartRate = "Heart Rate"

    public var id: String { rawValue }

    public var workoutMode: WorkoutRouteColorMode {
        switch self {
        case .singleColor: return .solid
        case .pace: return .pace
        case .elevation: return .correctedElevation
        case .heartRate: return .heartRate
        }
    }
}

/// Maps route metrics to `NSColor` for SceneKit tubes.
///
/// Metric values and scales come from `RouteMetricProfileBuilder` via
/// `RouteColorMetrics`. Missing data uses the neutral no-data palette token
/// rather than fabricating a median.
public struct RouteColoringService {
    private let metrics = RouteColorMetrics()
    private let profileBuilder = RouteMetricProfileBuilder()

    public init() {}

    /// Compute segment colors for the given route points and color mode.
    public func computeSegmentColors(
        points: [RouteScenePoint],
        mode: RouteColorMode,
        elevationProfile: ElevationProfile? = nil,
        defaultColor: NSColor = .systemBlue
    ) -> [NSColor] {
        guard points.count >= 2 else { return [] }

        switch mode {
        case .singleColor:
            return Array(repeating: defaultColor, count: points.count - 1)
        case .pace:
            return colorsFromProfile(
                points: points,
                mode: .pace,
                elevationProfile: elevationProfile,
                defaultColor: defaultColor
            )
        case .heartRate:
            return colorsFromProfile(
                points: points,
                mode: .heartRate,
                elevationProfile: elevationProfile,
                defaultColor: defaultColor
            )
        case .elevation:
            // Do not invent elevation color when the corrected profile is not
            // meaningful — fall back to the solid default rather than yMeters.
            if let elevationProfile, !elevationProfile.hasMeaningfulElevation {
                return Array(repeating: defaultColor, count: points.count - 1)
            }
            return colorsFromProfile(
                points: points,
                mode: .correctedElevation,
                elevationProfile: elevationProfile,
                defaultColor: defaultColor
            )
        }
    }

    // MARK: - Delegate to Core

    public func computeSegmentPace(points: [RouteScenePoint]) -> [Double] {
        metrics.computeSegmentPace(points: points)
    }

    public func computePaceScale(points: [RouteScenePoint]) -> PaceColorScale? {
        metrics.computePaceScale(points: points)
    }

    public func computeSegmentHeartRate(points: [RouteScenePoint]) -> [Double] {
        metrics.computeSegmentHeartRate(points: points)
    }

    public func computeHeartRateScale(points: [RouteScenePoint]) -> HeartRateColorScale? {
        metrics.computeHeartRateScale(points: points)
    }

    public func hasHeartRateData(points: [RouteScenePoint]) -> Bool {
        metrics.hasHeartRateData(points: points)
    }

    // MARK: - Profile → NSColor

    private func colorsFromProfile(
        points: [RouteScenePoint],
        mode: WorkoutRouteColorMode,
        elevationProfile: ElevationProfile?,
        defaultColor: NSColor
    ) -> [NSColor] {
        let routePoints = routePoints(from: points, elevationProfile: elevationProfile)
        let elevation = elevationProfile ?? ElevationProfile(routePoints: routePoints)
        let context = WorkoutAnalysisContext(
            routePoints: routePoints,
            elevationProfile: elevation
        )

        guard let profile = try? profileBuilder.build(
            routePoints: routePoints,
            context: context,
            mode: mode
        ) else {
            return Array(repeating: defaultColor, count: points.count - 1)
        }

        var lookup: [Int: RouteMetricColorBucket] = [:]
        lookup.reserveCapacity(profile.intervals.count)
        for interval in profile.intervals {
            lookup[interval.startPointIndex] = interval.bucket
        }

        var colors: [NSColor] = []
        colors.reserveCapacity(points.count - 1)
        for i in 0..<(points.count - 1) {
            if points[i].routeSegmentIndex != points[i + 1].routeSegmentIndex {
                colors.append(defaultColor)
                continue
            }
            let bucket = lookup[i] ?? .noData
            switch bucket {
            case .noData:
                // Use default for legacy SceneKit so no-data segments still show
                // the route when a solid fallback is desired; when the profile
                // has a scale, prefer the neutral no-data token.
                if profile.scale != nil {
                    colors.append(RouteMetricPalette.nsColor(mode: mode, bucket: .noData))
                } else {
                    colors.append(defaultColor)
                }
            case .level:
                colors.append(RouteMetricPalette.nsColor(mode: mode, bucket: bucket))
            }
        }
        return colors
    }

    private func routePoints(
        from scenePoints: [RouteScenePoint],
        elevationProfile: ElevationProfile?
    ) -> [RoutePoint] {
        let base = Date(timeIntervalSince1970: 0)
        return scenePoints.enumerated().map { offset, point in
            let altitude: Double?
            let id: UUID
            if let elevationProfile {
                // Prefer sourceIndex alignment when the profile was built from
                // the original route; fall back to the scene array index.
                if elevationProfile.samples.indices.contains(point.sourceIndex) {
                    let sample = elevationProfile.samples[point.sourceIndex]
                    altitude = sample.correctedAltitudeMeters ?? point.yMeters
                    id = sample.routePointID
                } else if elevationProfile.samples.indices.contains(offset) {
                    let sample = elevationProfile.samples[offset]
                    altitude = sample.correctedAltitudeMeters ?? point.yMeters
                    id = sample.routePointID
                } else {
                    altitude = point.yMeters
                    id = point.id
                }
            } else {
                altitude = point.yMeters
                id = point.id
            }

            return RoutePoint(
                id: id,
                timestamp: base.addingTimeInterval(point.elapsedSeconds),
                latitude: 0,
                longitude: 0,
                altitudeMeters: altitude,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                heartRateBPM: point.heartRateBPM,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
    }
}
