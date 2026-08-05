import CoreGraphics
import CoreVideo
import Foundation
import RunPlayCore

/// Single-workout video frame provider for the shared H.264 writer.
private struct WorkoutVideoFrameProvider: OfflineVideoFrameProviding {
    let plan: WorkoutVideoFramePlan
    let sampler: WorkoutVideoReplaySampler
    let map: WorkoutVideoMapPreparation
    let mapSize: CGSize
    let title: String
    let dateText: String
    let configuration: WorkoutVideoExportConfiguration
    let frameRenderer: WorkoutVideoFrameRenderer

    var frameCount: Int { plan.frameCount }

    func renderFrame(at frameIndex: Int, into pixelBuffer: CVPixelBuffer) throws {
        let sample = sampler.sample(frameIndex: frameIndex, plan: plan)
        let model = WorkoutVideoFrameModel.make(
            sample: sample,
            markerPixel: map.markerPixel(for: sample),
            workoutTitle: title,
            workoutDateText: dateText,
            appearance: configuration.appearance,
            routeColorMode: map.effectiveRouteColorMode
        )
        try frameRenderer.render(
            frame: model,
            staticMap: map.staticMapImage,
            into: pixelBuffer,
            mapSize: mapSize
        )
    }
}

/// Owns single-workout sampling/frame-model construction and delegates H.264
/// writing, temporary-file transaction, and validation to
/// `OfflineH264VideoAssetEncoder`.
struct WorkoutVideoAssetEncoder: Sendable {
    let frameRenderer: WorkoutVideoFrameRenderer
    private let writer: OfflineH264VideoAssetEncoder

    init(
        frameRenderer: WorkoutVideoFrameRenderer,
        writer: OfflineH264VideoAssetEncoder = OfflineH264VideoAssetEncoder()
    ) {
        self.frameRenderer = frameRenderer
        self.writer = writer
    }

    func export(
        plan: WorkoutVideoFramePlan,
        policy: WorkoutVideoExportPolicy,
        sampler: WorkoutVideoReplaySampler,
        map: WorkoutVideoMapPreparation,
        title: String,
        dateText: String,
        configuration: WorkoutVideoExportConfiguration,
        destinationURL: URL,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void
    ) async throws -> WorkoutVideoExportResult {
        let provider = WorkoutVideoFrameProvider(
            plan: plan,
            sampler: sampler,
            map: map,
            mapSize: CGSize(width: map.pixelWidth, height: map.pixelHeight),
            title: title,
            dateText: dateText,
            configuration: configuration,
            frameRenderer: frameRenderer
        )
        return try await writer.export(
            frameCount: plan.frameCount,
            policy: policy,
            destinationURL: destinationURL,
            expectedOutputDurationSeconds: plan.outputDurationSeconds,
            progress: progress,
            provider: provider
        )
    }
}
