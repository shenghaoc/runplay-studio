import CoreGraphics
import CoreVideo
import Foundation
import RunPlayCore

// MARK: - Result / poster

/// File-backed comparison video export result. The MP4 is never loaded into `Data`.
public struct ComparisonVideoExportResult: Sendable {
    public let url: URL
    public let filename: String
    public let fileSizeBytes: Int64
    public let outputDurationSeconds: Double
    public let frameCount: Int
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let alignmentMode: ComparisonAlignmentMode

    public init(
        url: URL,
        filename: String,
        fileSizeBytes: Int64,
        outputDurationSeconds: Double,
        frameCount: Int,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        alignmentMode: ComparisonAlignmentMode
    ) {
        self.url = url
        self.filename = filename
        self.fileSizeBytes = fileSizeBytes
        self.outputDurationSeconds = outputDurationSeconds
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.alignmentMode = alignmentMode
    }
}

/// Poster image plus the exact midpoint comparison sample.
public struct ComparisonVideoPoster: @unchecked Sendable {
    public let image: CGImage
    public let sample: ComparisonVideoFrameSample
    public let alignmentMode: ComparisonAlignmentMode

    public init(
        image: CGImage,
        sample: ComparisonVideoFrameSample,
        alignmentMode: ComparisonAlignmentMode
    ) {
        self.image = image
        self.sample = sample
        self.alignmentMode = alignmentMode
    }
}

// MARK: - Protocol

public protocol ComparisonVideoExporting: Sendable {
    func export(
        pair: ComparisonPair,
        configuration: ComparisonVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        alignmentSeed: ComparisonVideoAlignmentSeed?,
        mapPreparation: ComparisonVideoMapPreparation?,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void
    ) async throws -> ComparisonVideoExportResult
}

// MARK: - Frame provider

private struct ComparisonVideoFrameProvider: OfflineVideoFrameProviding {
    let plan: ComparisonVideoFramePlan
    let sampler: ComparisonVideoSampler
    let map: ComparisonVideoMapPreparation
    let primaryTitle: String
    let comparisonTitle: String
    let appearance: PNGSummaryExportAppearance
    let frameRenderer: ComparisonVideoFrameRenderer

    var frameCount: Int { plan.frameCount }

    func renderFrame(at frameIndex: Int, into pixelBuffer: CVPixelBuffer) throws {
        let sample = sampler.sample(frameIndex: frameIndex, plan: plan)
        let model = ComparisonVideoFrameModel(
            sample: sample,
            primaryTitle: primaryTitle,
            comparisonTitle: comparisonTitle,
            primaryMarkerPixel: sample.primaryRoutePosition.flatMap { map.primaryPixelMap.pixel(for: $0) },
            comparisonMarkerPixel: sample.comparisonRoutePosition.flatMap {
                map.comparisonPixelMap.pixel(for: $0)
            },
            appearance: appearance,
            routesAreWidelySeparated: map.routesAreWidelySeparated
        )
        try frameRenderer.render(
            frame: model,
            staticMap: map.staticMapImage,
            into: pixelBuffer,
            mapSize: CGSize(width: map.pixelWidth, height: map.pixelHeight)
        )
    }
}

// MARK: - Implementation

/// Offline comparison MP4 exporter using the shared H.264 writer.
public struct ComparisonVideoExporter: ComparisonVideoExporting, Sendable {
    private let mapPreparer: any ComparisonVideoMapPreparing
    private let frameRenderer: ComparisonVideoFrameRenderer
    private let alignmentResolver: ComparisonVideoAlignmentResolver
    private let writer: OfflineH264VideoAssetEncoder

    public init(
        mapPreparer: any ComparisonVideoMapPreparing = MapKitComparisonVideoMapPreparer(),
        frameRenderer: ComparisonVideoFrameRenderer = ComparisonVideoFrameRenderer(),
        alignmentResolver: ComparisonVideoAlignmentResolver = ComparisonVideoAlignmentResolver(),
        writer: OfflineH264VideoAssetEncoder = OfflineH264VideoAssetEncoder()
    ) {
        self.mapPreparer = mapPreparer
        self.frameRenderer = frameRenderer
        self.alignmentResolver = alignmentResolver
        self.writer = writer
    }

    public func export(
        pair: ComparisonPair,
        configuration: ComparisonVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy = .production,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        alignmentSeed: ComparisonVideoAlignmentSeed? = nil,
        mapPreparation: ComparisonVideoMapPreparation? = nil,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void = { _ in }
    ) async throws -> ComparisonVideoExportResult {
        try policy.validate()

        let distanceAssessment = ComparisonVideoExportEligibility.distanceAssessment(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        guard distanceAssessment.canExportDistance else {
            throw ComparisonVideoExportError.ineligiblePair(
                distanceAssessment.distanceUnavailableHelp
                    ?? "Comparison video export is not available for this pair."
            )
        }

        try Task.checkCancellation()
        await progress(WorkoutVideoExportProgress(phase: .preparingRoute))

        let resolution = try alignmentResolver.resolve(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            desiredMode: configuration.alignmentMode,
            seed: alignmentSeed,
            isCancelled: { Task.isCancelled }
        )

        let effectiveMode: ComparisonAlignmentMode
        let snapshot: RouteAlignmentSnapshot?
        switch (configuration.alignmentMode, resolution) {
        case (.distance, _):
            effectiveMode = .distance
            snapshot = nil
        case (.routeAware, .routeAware(let resolved)):
            effectiveMode = .routeAware
            snapshot = resolved
        case (.routeAware, .unavailable(let reason)):
            throw ComparisonVideoExportError.routeAwareUnavailable(reason)
        case (.routeAware, .distanceOnly):
            throw ComparisonVideoExportError.routeAwareUnavailable(.algorithmFailure)
        }

        let sampler = ComparisonVideoSampler(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            alignmentMode: effectiveMode,
            snapshot: snapshot
        )
        guard sampler.isReady else {
            if effectiveMode == .routeAware {
                throw ComparisonVideoExportError.routeAwareUnavailable(.insufficientMatchedDistance)
            }
            throw ComparisonVideoExportError.noCommonDistance
        }

        let plan = try ComparisonVideoFramePlan.make(
            duration: configuration.duration,
            policy: policy,
            domainLength: sampler.domainLengthMeters,
            domain: sampler.domain
        )

        try Task.checkCancellation()
        await progress(WorkoutVideoExportProgress(phase: .loadingMap))

        let preparedMap: ComparisonVideoMapPreparation
        if let mapPreparation {
            preparedMap = mapPreparation
        } else {
            preparedMap = try await prepareMap(
                pair: pair,
                configuration: configuration,
                policy: policy
            )
        }

        try Task.checkCancellation()

        let provider = ComparisonVideoFrameProvider(
            plan: plan,
            sampler: sampler,
            map: preparedMap,
            primaryTitle: pair.primary.displayName,
            comparisonTitle: pair.comparison.displayName,
            appearance: configuration.appearance,
            frameRenderer: frameRenderer
        )

        do {
            let result = try await writer.export(
                frameCount: plan.frameCount,
                policy: policy,
                destinationURL: destinationURL,
                expectedOutputDurationSeconds: plan.outputDurationSeconds,
                progress: progress,
                provider: provider
            )
            return ComparisonVideoExportResult(
                url: result.url,
                filename: result.filename,
                fileSizeBytes: result.fileSizeBytes,
                outputDurationSeconds: result.outputDurationSeconds,
                frameCount: result.frameCount,
                width: result.width,
                height: result.height,
                framesPerSecond: result.framesPerSecond,
                alignmentMode: effectiveMode
            )
        } catch let error as WorkoutVideoExportError {
            if error.isCancellation {
                throw ComparisonVideoExportError.cancelled
            }
            throw ComparisonVideoExportError.encodingFailed(error)
        } catch is CancellationError {
            throw ComparisonVideoExportError.cancelled
        }
    }

    // MARK: - Map preparation

    public func prepareMap(
        pair: ComparisonPair,
        configuration: ComparisonVideoExportConfiguration,
        policy: WorkoutVideoExportPolicy
    ) async throws -> ComparisonVideoMapPreparation {
        try Task.checkCancellation()
        let size = CGSize(width: policy.width, height: policy.height)
        let appearance = WorkoutMapSnapshotAppearance(configuration.appearance)
        let request = ComparisonVideoMapPreparationRequest(
            size: size,
            appearance: appearance,
            primaryRoutePoints: pair.primary.routePoints,
            comparisonRoutePoints: pair.comparison.routePoints
        )
        do {
            return try await mapPreparer.prepare(request: request)
        } catch is CancellationError {
            throw ComparisonVideoExportError.cancelled
        } catch let error as ComparisonVideoExportError {
            throw error
        } catch let error as WorkoutMapSnapshotError {
            if error == .cancelled {
                throw ComparisonVideoExportError.cancelled
            }
            throw ComparisonVideoExportError.mapPreparationFailed(error.localizedDescription)
        } catch {
            throw ComparisonVideoExportError.mapPreparationFailed(error.localizedDescription)
        }
    }

    /// Poster midpoint frame for UI preview.
    public func renderPosterResult(
        pair: ComparisonPair,
        configuration: ComparisonVideoExportConfiguration,
        mapPreparation: ComparisonVideoMapPreparation,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        snapshot: RouteAlignmentSnapshot?,
        policy: WorkoutVideoExportPolicy = .poster
    ) throws -> ComparisonVideoPoster {
        try policy.validate()

        let sampler = ComparisonVideoSampler(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            alignmentMode: configuration.alignmentMode,
            snapshot: snapshot
        )
        guard sampler.isReady else {
            throw ComparisonVideoExportError.invalidConfiguration(
                "Comparison domain is not ready for poster rendering"
            )
        }
        let plan = try ComparisonVideoFramePlan.make(
            duration: configuration.duration,
            policy: policy,
            domainLength: sampler.domainLengthMeters,
            domain: sampler.domain
        )
        let midIndex = plan.frameCount / 2
        let sample = sampler.sample(frameIndex: midIndex, plan: plan)
        let model = ComparisonVideoFrameModel(
            sample: sample,
            primaryTitle: pair.primary.displayName,
            comparisonTitle: pair.comparison.displayName,
            primaryMarkerPixel: sample.primaryRoutePosition.flatMap {
                mapPreparation.primaryPixelMap.pixel(for: $0)
            },
            comparisonMarkerPixel: sample.comparisonRoutePosition.flatMap {
                mapPreparation.comparisonPixelMap.pixel(for: $0)
            },
            appearance: configuration.appearance,
            routesAreWidelySeparated: mapPreparation.routesAreWidelySeparated
        )
        let image = try frameRenderer.renderImage(
            frame: model,
            staticMap: mapPreparation.staticMapImage,
            width: policy.width,
            height: policy.height,
            mapSize: CGSize(
                width: mapPreparation.pixelWidth,
                height: mapPreparation.pixelHeight
            )
        )
        return ComparisonVideoPoster(
            image: image,
            sample: sample,
            alignmentMode: configuration.alignmentMode
        )
    }
}
