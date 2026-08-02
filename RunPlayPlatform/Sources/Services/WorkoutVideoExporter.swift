import CoreGraphics
import Foundation
import RunPlayCore

// MARK: - Result

/// File-backed video export result. The MP4 is never loaded into `Data`.
public struct WorkoutVideoExportResult: Sendable {
    public let url: URL
    public let filename: String
    public let fileSizeBytes: Int64
    public let outputDurationSeconds: Double
    public let frameCount: Int
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int

    public init(
        url: URL,
        filename: String,
        fileSizeBytes: Int64,
        outputDurationSeconds: Double,
        frameCount: Int,
        width: Int,
        height: Int,
        framesPerSecond: Int
    ) {
        self.url = url
        self.filename = filename
        self.fileSizeBytes = fileSizeBytes
        self.outputDurationSeconds = outputDurationSeconds
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }
}

/// Poster image plus the exact midpoint state represented by that image.
/// `CGImage` is immutable; the unchecked conformance only bridges the SDK's
/// missing Sendable annotation for that immutable Core Graphics value.
public struct WorkoutVideoPoster: @unchecked Sendable {
    public let image: CGImage
    public let sample: WorkoutVideoFrameSample
    public let effectiveRouteColorMode: WorkoutRouteColorMode

    public init(
        image: CGImage,
        sample: WorkoutVideoFrameSample,
        effectiveRouteColorMode: WorkoutRouteColorMode
    ) {
        self.image = image
        self.sample = sample
        self.effectiveRouteColorMode = effectiveRouteColorMode
    }
}

// MARK: - Protocol

/// Exports a deterministic offline workout route-replay MP4.
public protocol WorkoutVideoExporting: Sendable {
    func export(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy,
        mapPreparation: WorkoutVideoMapPreparation?,
        analysisContext: WorkoutAnalysisContext?,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void
    ) async throws -> WorkoutVideoExportResult
}

// MARK: - Implementation

/// AVFoundation H.264 exporter with temporary-file transaction and validation.
public struct WorkoutVideoExporter: WorkoutVideoExporting, Sendable {
    private let mapPreparer: any WorkoutVideoMapPreparing
    private let profileBuilder: RouteMetricProfileBuilder
    private let lineBuilder: RouteMetricMapLineBuilder
    private let frameRenderer: WorkoutVideoFrameRenderer
    private let assetEncoder: WorkoutVideoAssetEncoder

    public init(
        mapPreparer: any WorkoutVideoMapPreparing = MapKitWorkoutVideoMapPreparer(),
        profileBuilder: RouteMetricProfileBuilder = RouteMetricProfileBuilder(),
        lineBuilder: RouteMetricMapLineBuilder = RouteMetricMapLineBuilder(),
        frameRenderer: WorkoutVideoFrameRenderer = WorkoutVideoFrameRenderer()
    ) {
        self.mapPreparer = mapPreparer
        self.profileBuilder = profileBuilder
        self.lineBuilder = lineBuilder
        self.frameRenderer = frameRenderer
        self.assetEncoder = WorkoutVideoAssetEncoder(frameRenderer: frameRenderer)
    }

    public func export(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy = .production,
        mapPreparation: WorkoutVideoMapPreparation? = nil,
        analysisContext: WorkoutAnalysisContext? = nil,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void = { _ in }
    ) async throws -> WorkoutVideoExportResult {
        try policy.validate()

        guard WorkoutVideoExportEligibility.canExportVideo(workout) else {
            if !WorkoutVideoExportEligibility.hasUsableRoute(workout) {
                throw WorkoutVideoExportError.noUsableRoute
            }
            throw WorkoutVideoExportError.noPlayableTimeline
        }

        try Task.checkCancellation()
        await progress(WorkoutVideoExportProgress(phase: .preparingRoute))

        let context = analysisContext ?? WorkoutAnalysisContext(workout: workout)
        let sampler = WorkoutVideoReplaySampler(workout: workout, analysisContext: context)
        guard sampler.hasPlayableTimeline else {
            throw WorkoutVideoExportError.noPlayableTimeline
        }

        let plan = try WorkoutVideoFramePlan.make(
            duration: configuration.duration,
            policy: policy,
            sourceTotalElapsedSeconds: sampler.totalElapsedSeconds
        )

        try Task.checkCancellation()
        await progress(WorkoutVideoExportProgress(phase: .loadingMap))

        let preparedMap: WorkoutVideoMapPreparation
        if let mapPreparation {
            preparedMap = mapPreparation
        } else {
            preparedMap = try await prepareMap(
                workout: workout,
                configuration: configuration,
                policy: policy,
                analysisContext: context
            )
        }

        try Task.checkCancellation()

        return try await assetEncoder.export(
            plan: plan,
            policy: policy,
            sampler: sampler,
            map: preparedMap,
            title: workout.displayName,
            dateText: Self.formatWorkoutDate(workout),
            configuration: configuration,
            destinationURL: destinationURL,
            progress: progress
        )
    }

    // MARK: - Map preparation

    public func prepareMap(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        policy: WorkoutVideoExportPolicy,
        analysisContext: WorkoutAnalysisContext? = nil,
        profileProbe: RouteMetricProfileProbe? = nil
    ) async throws -> WorkoutVideoMapPreparation {
        try Task.checkCancellation()
        let context = analysisContext ?? WorkoutAnalysisContext(workout: workout)
        let policyColor = RouteMetricColorPolicy.runningDefault

        let routeTask = Task.detached(priority: .userInitiated) {
            try Self.prepareRoutePresentation(
                workout: workout,
                context: context,
                preferredMode: configuration.routeColorMode,
                policy: policyColor,
                profileProbe: profileProbe,
                profileBuilder: self.profileBuilder,
                lineBuilder: self.lineBuilder,
                isCancelled: { Task.isCancelled }
            )
        }
        let routePrep = try await withTaskCancellationHandler {
            try await routeTask.value
        } onCancel: {
            routeTask.cancel()
        }

        try Task.checkCancellation()

        let size = CGSize(width: policy.width, height: policy.height)
        let appearance = WorkoutMapSnapshotAppearance(configuration.appearance)
        let cacheKey = WorkoutMapSnapshotCacheKey(
            workout: workout,
            routeColorMode: routePrep.effectiveMode,
            appearance: appearance,
            size: size,
            policyVersion: policyColor.policyVersion
        )
        let request = WorkoutVideoMapPreparationRequest(
            size: size,
            appearance: appearance,
            routes: routePrep.lines,
            markers: routePrep.markers,
            routePoints: workout.routePoints,
            lineWidth: 5,
            cacheKey: cacheKey
        )

        do {
            let prepared = try await mapPreparer.prepare(request: request)
            return prepared.withEffectiveRouteColorMode(routePrep.effectiveMode)
        } catch is CancellationError {
            throw WorkoutVideoExportError.cancelled
        } catch let error as WorkoutMapSnapshotError {
            if error == .cancelled {
                throw WorkoutVideoExportError.cancelled
            }
            throw WorkoutVideoExportError.mapPreparationFailed(error.localizedDescription)
        } catch {
            throw WorkoutVideoExportError.mapPreparationFailed(error.localizedDescription)
        }
    }

    /// Poster midpoint frame and exact accessibility state for UI preview.
    public func renderPosterResult(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        mapPreparation: WorkoutVideoMapPreparation,
        policy: WorkoutVideoExportPolicy = .poster,
        analysisContext: WorkoutAnalysisContext? = nil
    ) throws -> WorkoutVideoPoster {
        try policy.validate()
        let sampler = WorkoutVideoReplaySampler(
            workout: workout,
            analysisContext: analysisContext
        )
        let plan = try WorkoutVideoFramePlan.make(
            duration: configuration.duration,
            policy: policy,
            sourceTotalElapsedSeconds: sampler.totalElapsedSeconds
        )
        let midIndex = plan.frameCount / 2
        let sample = sampler.sample(frameIndex: midIndex, plan: plan)
        let marker = mapPreparation.markerPixel(for: sample)
        let model = WorkoutVideoFrameModel.make(
            sample: sample,
            markerPixel: marker,
            workoutTitle: workout.displayName,
            workoutDateText: Self.formatWorkoutDate(workout),
            appearance: configuration.appearance,
            routeColorMode: mapPreparation.effectiveRouteColorMode
        )
        let mapSize = CGSize(
            width: mapPreparation.pixelWidth,
            height: mapPreparation.pixelHeight
        )
        let image = try frameRenderer.renderImage(
            frame: model,
            staticMap: mapPreparation.staticMapImage,
            width: policy.width,
            height: policy.height,
            mapSize: mapSize
        )
        return WorkoutVideoPoster(
            image: image,
            sample: sample,
            effectiveRouteColorMode: mapPreparation.effectiveRouteColorMode
        )
    }

    /// Compatibility convenience for callers that need only the image.
    public func renderPoster(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        mapPreparation: WorkoutVideoMapPreparation,
        policy: WorkoutVideoExportPolicy = .poster
    ) throws -> CGImage {
        try renderPosterResult(
            workout: workout,
            configuration: configuration,
            mapPreparation: mapPreparation,
            policy: policy
        ).image
    }

    // MARK: - Route prep (mirrors PNG export ownership)

    private struct PreparedRouteExport: Sendable {
        let lines: [RouteMapLine]
        let markers: [RouteMapMarker]
        let effectiveMode: WorkoutRouteColorMode
    }

    private static func prepareRoutePresentation(
        workout: RunWorkout,
        context: WorkoutAnalysisContext,
        preferredMode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy,
        profileProbe: RouteMetricProfileProbe?,
        profileBuilder: RouteMetricProfileBuilder,
        lineBuilder: RouteMetricMapLineBuilder,
        isCancelled: @Sendable () -> Bool
    ) throws -> PreparedRouteExport {
        if isCancelled() { throw CancellationError() }

        let effective: WorkoutRouteColorMode
        let profile: RouteMetricProfile
        if preferredMode == .solid {
            effective = .solid
            profile = try profileBuilder.build(
                routePoints: workout.routePoints,
                context: context,
                mode: .solid,
                policy: policy,
                isCancelled: isCancelled
            )
        } else {
            let probe = try profileProbe ?? profileBuilder.probe(
                routePoints: workout.routePoints,
                context: context,
                policy: policy,
                isCancelled: isCancelled
            )
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
            idPrefix: "video-route",
            policy: policy,
            isCancelled: isCancelled
        )
        let markers = RouteMapContent.endpointMarkers(
            points: workout.routePoints,
            idPrefix: "video"
        )
        return PreparedRouteExport(
            lines: lineResult.lines,
            markers: markers,
            effectiveMode: effective
        )
    }

    private static let workoutDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static func formatWorkoutDate(_ workout: RunWorkout) -> String {
        if let date = workout.metadata.startDate {
            return workoutDateFormatter.string(from: date)
        }
        return ""
    }
}
