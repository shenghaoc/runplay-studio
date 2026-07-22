import AppKit
import Foundation
import RunPlayCore
import RunPlayPlatform

/// macOS-only PNG export support.
///
/// PNG rendering requires AppKit/SwiftUI frameworks not available in RunPlayCore.
struct PNGExportService {
    /// Default map image size inside the 1200×1600 card (horizontal padding 40).
    static let mapImageSize = CGSize(width: 1_120, height: 560)

    /// Metrics-only export (legacy synchronous entry). Always 1200×1600 @ scale 1.
    @MainActor
    static func exportSummaryPNG(workout: RunWorkout, segments: [SegmentHighlight]) throws -> ExportResult {
        let configuration = PNGSummaryExportConfiguration(
            includeMap: false,
            appearance: .light,
            routeColorMode: .solid
        )
        return try renderMetricsOnly(workout: workout, segments: segments, configuration: configuration)
    }

    /// Configurable async export with optional map snapshot.
    @MainActor
    static func exportSummaryPNG(
        workout: RunWorkout,
        segments: [SegmentHighlight],
        configuration: PNGSummaryExportConfiguration,
        mapSnapshotter: (any WorkoutMapSnapshotting)? = nil,
        analysisContext: WorkoutAnalysisContext? = nil,
        profileProbe: RouteMetricProfileProbe? = nil,
        profileBuilder: RouteMetricProfileBuilding = DefaultRouteMetricProfileBuilder(),
        lineBuilder: RouteMetricMapLineBuilding = DefaultRouteMetricMapLineBuilder(),
        onPhase: (@Sendable (PNGSummaryExportPhase) -> Void)? = nil
    ) async throws -> ExportResult {
        let report: @Sendable (PNGSummaryExportPhase) -> Void = { phase in
            onPhase?(phase)
        }

        report(.preparingRoute)

        if !configuration.includeMap {
            report(.renderingCard)
            let result = try renderMetricsOnly(
                workout: workout,
                segments: segments,
                configuration: configuration
            )
            report(.ready)
            return result
        }

        let usableRoute = Self.hasUsableRoute(workout)
        guard usableRoute else {
            report(.renderingCard)
            let result = try renderMetricsOnly(
                workout: workout,
                segments: segments,
                configuration: configuration
            )
            report(.ready)
            return result
        }

        let snapshotter = mapSnapshotter ?? CachingWorkoutMapSnapshotter()
        let context = analysisContext ?? WorkoutAnalysisContext(workout: workout)
        let policy = RouteMetricColorPolicy.runningDefault

        let routePreparationTask = Task.detached(priority: .userInitiated) {
            try prepareRoutePresentation(
                workout: workout,
                context: context,
                preferredMode: configuration.routeColorMode,
                policy: policy,
                profileProbe: profileProbe,
                profileBuilder: profileBuilder,
                lineBuilder: lineBuilder,
                isCancelled: { Task.isCancelled }
            )
        }
        let routePrep = try await withTaskCancellationHandler {
            try await routePreparationTask.value
        } onCancel: {
            routePreparationTask.cancel()
        }

        try Task.checkCancellation()
        report(.loadingMap)

        let appearance = WorkoutMapSnapshotAppearance(configuration.appearance)
        let cacheKey = WorkoutMapSnapshotCacheKey(
            workout: workout,
            routeColorMode: routePrep.effectiveMode,
            appearance: appearance,
            size: mapImageSize,
            policyVersion: policy.policyVersion
        )
        let request = WorkoutMapSnapshotRequest(
            size: mapImageSize,
            appearance: appearance,
            routes: routePrep.lines,
            markers: routePrep.markers,
            lineWidth: 5,
            cacheKey: cacheKey
        )

        report(.drawingRoute)
        let snapshot: WorkoutMapSnapshotResult
        do {
            snapshot = try await snapshotter.makeSnapshot(request: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkoutMapSnapshotError where error == .cancelled {
            throw CancellationError()
        } catch {
            // Propagate map failure so the UI can offer Retry / Export Without Map.
            throw error
        }

        try Task.checkCancellation()
        report(.renderingCard)

        let layout: PNGSummaryCardLayout = .mapInclusive
        let model = ExportSummaryCardModel(
            workout: workout,
            segments: segments,
            layout: layout,
            includesMapImagery: true
        )
        let legend: RouteMetricLegendModel?
        if let profile = routePrep.profile, let scale = profile.scale, routePrep.effectiveMode != .solid {
            legend = RouteMetricLegendModel(
                mode: routePrep.effectiveMode,
                scale: scale,
                showsNoData: snapshot.containsNoDataLines || profile.diagnostics.noDataIntervalCount > 0,
                coverageFraction: profile.validCoverageFraction
            )
        } else {
            legend = nil
        }

        let presentation = ExportSummaryCardPresentation(
            model: model,
            mapImage: snapshot.nsImage,
            routeLegend: legend,
            appearance: configuration.appearance,
            layout: layout
        )
        let view = ExportSummaryCardView(presentation: presentation)
        let data = try PNGExportRenderer.renderPNG(
            from: view,
            appearance: configuration.appearance
        )
        let filename = ExportFilenameBuilder.filename(for: workout, format: .png)
        report(.ready)
        return ExportResult(format: .png, filename: filename, data: data)
    }

    // MARK: - Helpers

    static func hasUsableRoute(_ workout: RunWorkout) -> Bool {
        workout.routePoints.contains { point in
            RouteMapCoordinate(point) != nil
        }
    }

    @MainActor
    private static func renderMetricsOnly(
        workout: RunWorkout,
        segments: [SegmentHighlight],
        configuration: PNGSummaryExportConfiguration
    ) throws -> ExportResult {
        let model = ExportSummaryCardModel(
            workout: workout,
            segments: segments,
            layout: .metricsOnly,
            includesMapImagery: false
        )
        let presentation = ExportSummaryCardPresentation(
            model: model,
            mapImage: nil,
            routeLegend: nil,
            appearance: configuration.appearance,
            layout: .metricsOnly
        )
        let view = ExportSummaryCardView(presentation: presentation)
        let data = try PNGExportRenderer.renderPNG(
            from: view,
            appearance: configuration.appearance
        )
        let filename = ExportFilenameBuilder.filename(for: workout, format: .png)
        return ExportResult(format: .png, filename: filename, data: data)
    }

    nonisolated private static func prepareRoutePresentation(
        workout: RunWorkout,
        context: WorkoutAnalysisContext,
        preferredMode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy,
        profileProbe: RouteMetricProfileProbe?,
        profileBuilder: RouteMetricProfileBuilding,
        lineBuilder: RouteMetricMapLineBuilding,
        isCancelled: @Sendable () -> Bool
    ) throws -> PreparedRouteExport {
        if isCancelled() { throw CancellationError() }

        let effective: WorkoutRouteColorMode
        let profile: RouteMetricProfile
        if preferredMode == .solid {
            // Solid rendering does not need metric availability or metric
            // profiles, so avoid calculating pace, heart rate, and elevation.
            effective = .solid
            profile = try profileBuilder.build(
                routePoints: workout.routePoints,
                context: context,
                mode: .solid,
                policy: policy,
                isCancelled: isCancelled
            )
        } else {
            let probe: RouteMetricProfileProbe
            if let profileProbe {
                probe = profileProbe
            } else {
                probe = try profileBuilder.probe(
                    routePoints: workout.routePoints,
                    context: context,
                    policy: policy,
                    isCancelled: isCancelled
                )
            }
            effective = probe.availability.isAvailable(preferredMode) ? preferredMode : .solid

            if let probed = probe.profile(for: effective) {
                profile = probed
            } else {
                profile = try profileBuilder.build(
                    routePoints: workout.routePoints,
                    context: context,
                    mode: effective,
                    policy: policy,
                    isCancelled: isCancelled
                )
            }
        }

        let lineResult = try lineBuilder.build(
            routePoints: workout.routePoints,
            profile: profile,
            idPrefix: "export-route",
            policy: policy,
            isCancelled: isCancelled
        )

        let markers = RouteMapContent.endpointMarkers(
            points: workout.routePoints,
            idPrefix: "export"
        )

        return PreparedRouteExport(
            lines: lineResult.lines,
            markers: markers,
            profile: effective == .solid ? nil : profile,
            effectiveMode: effective
        )
    }
}

private struct PreparedRouteExport: Sendable {
    let lines: [RouteMapLine]
    let markers: [RouteMapMarker]
    let profile: RouteMetricProfile?
    let effectiveMode: WorkoutRouteColorMode
}
