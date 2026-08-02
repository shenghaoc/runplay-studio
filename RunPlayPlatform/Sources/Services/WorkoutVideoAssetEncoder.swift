import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RunPlayCore

/// Owns the H.264 writer, temporary-file transaction, and post-encode asset
/// validation. High-level route/map orchestration remains in
/// `WorkoutVideoExporter`.
struct WorkoutVideoAssetEncoder: Sendable {
    let frameRenderer: WorkoutVideoFrameRenderer

    init(frameRenderer: WorkoutVideoFrameRenderer) {
        self.frameRenderer = frameRenderer
    }

    private var fileManager: FileManager { .default }

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
        let temporaryURL = makeTemporaryURL(near: destinationURL)

        do {
            try await encode(
                plan: plan,
                policy: policy,
                sampler: sampler,
                map: map,
                mapSize: CGSize(width: map.pixelWidth, height: map.pixelHeight),
                title: title,
                dateText: dateText,
                configuration: configuration,
                temporaryURL: temporaryURL,
                progress: progress
            )

            try Task.checkCancellation()
            await progress(WorkoutVideoExportProgress(
                phase: .finalizing,
                completedFrames: plan.frameCount,
                totalFrames: plan.frameCount
            ))
            try await validateOutput(url: temporaryURL, policy: policy, plan: plan)

            try Task.checkCancellation()
            let attrs = try fileManager.attributesOfItem(atPath: temporaryURL.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            try Task.checkCancellation()
            try publish(temporaryURL: temporaryURL, to: destinationURL)

            let result = WorkoutVideoExportResult(
                url: destinationURL,
                filename: destinationURL.lastPathComponent,
                fileSizeBytes: size,
                outputDurationSeconds: plan.outputDurationSeconds,
                frameCount: plan.frameCount,
                width: policy.width,
                height: policy.height,
                framesPerSecond: policy.framesPerSecond
            )
            await progress(WorkoutVideoExportProgress(
                phase: .completed,
                completedFrames: plan.frameCount,
                totalFrames: plan.frameCount
            ))
            return result
        } catch {
            do {
                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try fileManager.removeItem(at: temporaryURL)
                }
            } catch {
                throw WorkoutVideoExportError.finalizationFailed(
                    "Temporary output cleanup failed"
                )
            }

            if Task.isCancelled || error is CancellationError {
                throw WorkoutVideoExportError.cancelled
            }
            if let videoError = error as? WorkoutVideoExportError {
                throw videoError
            }
            throw WorkoutVideoExportError.finalizationFailed(error.localizedDescription)
        }
    }

    private func encode(
        plan: WorkoutVideoFramePlan,
        policy: WorkoutVideoExportPolicy,
        sampler: WorkoutVideoReplaySampler,
        map: WorkoutVideoMapPreparation,
        mapSize: CGSize,
        title: String,
        dateText: String,
        configuration: WorkoutVideoExportConfiguration,
        temporaryURL: URL,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void
    ) async throws {
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
        } catch {
            throw WorkoutVideoExportError.writerCreationFailed(error.localizedDescription)
        }

        writer.metadata = []
        writer.shouldOptimizeForNetworkUse = false

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: policy.averageBitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: policy.width,
            AVVideoHeightKey: policy.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw WorkoutVideoExportError.cannotAddVideoInput
        }
        writer.add(input)

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: policy.width,
            kCVPixelBufferHeightKey as String: policy.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.startWriting() else {
            let detail = writer.error?.localizedDescription ?? "unknown writer error"
            throw WorkoutVideoExportError.cannotStartWriting(detail)
        }
        defer {
            if writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
        }
        writer.startSession(atSourceTime: .zero)

        await progress(WorkoutVideoExportProgress(
            phase: .encoding,
            completedFrames: 0,
            totalFrames: plan.frameCount
        ))

        let timescale = CMTimeScale(policy.framesPerSecond)
        let pool = adaptor.pixelBufferPool
        for frameIndex in 0..<plan.frameCount {
            try Task.checkCancellation()
            try await waitUntilReady(
                input: input,
                writer: writer,
                frameIndex: frameIndex
            )
            try Task.checkCancellation()

            var pixelBuffer: CVPixelBuffer?
            let poolStatus: CVReturn
            if let pool {
                poolStatus = CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer
                )
            } else {
                poolStatus = CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    policy.width,
                    policy.height,
                    kCVPixelFormatType_32BGRA,
                    sourceAttributes as CFDictionary,
                    &pixelBuffer
                )
            }
            guard poolStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw WorkoutVideoExportError.pixelBufferAllocationFailed
            }

            let sample = sampler.sample(frameIndex: frameIndex, plan: plan)
            let model = WorkoutVideoFrameModel.make(
                sample: sample,
                markerPixel: map.markerPixel(for: sample),
                workoutTitle: title,
                workoutDateText: dateText,
                appearance: configuration.appearance,
                routeColorMode: map.effectiveRouteColorMode
            )
            do {
                try frameRenderer.render(
                    frame: model,
                    staticMap: map.staticMapImage,
                    into: buffer,
                    mapSize: mapSize
                )
            } catch {
                throw WorkoutVideoExportError.frameRenderingFailed(error.localizedDescription)
            }

            let time = CMTime(value: CMTimeValue(frameIndex), timescale: timescale)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                let detail = writer.error?.localizedDescription ?? "append failed"
                throw WorkoutVideoExportError.frameAppendFailed(frameIndex, detail)
            }

            let completed = frameIndex + 1
            if completed == plan.frameCount
                || completed % policy.progressUpdateStride == 0 {
                await progress(WorkoutVideoExportProgress(
                    phase: .encoding,
                    completedFrames: completed,
                    totalFrames: plan.frameCount
                ))
            }
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(
            value: CMTimeValue(plan.frameCount),
            timescale: timescale
        ))

        nonisolated(unsafe) let finishingWriter = writer
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                finishingWriter.finishWriting {
                    switch finishingWriter.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: WorkoutVideoExportError.cancelled)
                    case .failed:
                        let detail = finishingWriter.error?.localizedDescription
                            ?? "finishWriting failed"
                        continuation.resume(
                            throwing: WorkoutVideoExportError.finalizationFailed(detail)
                        )
                    default:
                        continuation.resume(
                            throwing: WorkoutVideoExportError.finalizationFailed(
                                "Unexpected writer status \(finishingWriter.status.rawValue)"
                            )
                        )
                    }
                }
            }
        } onCancel: {
            finishingWriter.cancelWriting()
        }
    }

    private func waitUntilReady(
        input: AVAssetWriterInput,
        writer: AVAssetWriter,
        frameIndex: Int
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed {
                let detail = writer.error?.localizedDescription ?? "writer failed while waiting"
                throw WorkoutVideoExportError.frameAppendFailed(frameIndex, detail)
            }
            if writer.status == .cancelled {
                throw WorkoutVideoExportError.cancelled
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try Task.checkCancellation()
    }

    private func validateOutput(
        url: URL,
        policy: WorkoutVideoExportPolicy,
        plan: WorkoutVideoFramePlan
    ) async throws {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkoutVideoExportError.validationFailed("Temporary output file is missing")
        }
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw WorkoutVideoExportError.validationFailed("Temporary output file is empty")
        }

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        try Task.checkCancellation()
        guard videoTracks.count == 1 else {
            throw WorkoutVideoExportError.validationFailed(
                "Expected exactly one video track, found \(videoTracks.count)"
            )
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.isEmpty else {
            throw WorkoutVideoExportError.validationFailed("Output must not contain an audio track")
        }

        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        guard duration.isNumeric, !duration.isIndefinite else {
            throw WorkoutVideoExportError.validationFailed("Output duration is not finite")
        }
        let durationSeconds = CMTimeGetSeconds(duration)
        let expected = plan.outputDurationSeconds
        let tolerance = 1.0 / Double(policy.framesPerSecond) + 0.01
        guard abs(durationSeconds - expected) <= tolerance else {
            throw WorkoutVideoExportError.validationFailed(
                String(
                    format: "Duration %.3fs outside expected range around %.3fs",
                    durationSeconds,
                    expected
                )
            )
        }

        let track = videoTracks[0]
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        try Task.checkCancellation()
        let transformed = naturalSize.applying(preferredTransform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        guard width == policy.width, height == policy.height else {
            throw WorkoutVideoExportError.validationFailed(
                "Dimensions \(width)×\(height) do not match \(policy.width)×\(policy.height)"
            )
        }

        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let format = formatDescriptions.first else {
            throw WorkoutVideoExportError.validationFailed("Video track has no format description")
        }
        guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
            throw WorkoutVideoExportError.validationFailed("Video track is not H.264")
        }
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        guard abs(Double(nominalFrameRate) - Double(policy.framesPerSecond)) <= 0.01 else {
            throw WorkoutVideoExportError.validationFailed(
                "Frame rate \(nominalFrameRate) does not match \(policy.framesPerSecond) fps"
            )
        }
        guard CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        ) != nil,
        CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) != nil,
        CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix
        ) != nil else {
            throw WorkoutVideoExportError.validationFailed(
                "Video track is missing required color metadata"
            )
        }

        try await validateFrameSamples(
            asset: asset,
            track: track,
            plan: plan,
            policy: policy
        )
    }

    private func validateFrameSamples(
        asset: AVURLAsset,
        track: AVAssetTrack,
        plan: WorkoutVideoFramePlan,
        policy: WorkoutVideoExportPolicy
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WorkoutVideoExportError.validationFailed(
                "Could not inspect encoded video samples"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw WorkoutVideoExportError.validationFailed(
                "Could not read encoded video samples"
            )
        }

        var samplesRead = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferIsValid(sample) else {
                reader.cancelReading()
                throw WorkoutVideoExportError.validationFailed(
                    "Video contains an invalid encoded sample"
                )
            }
            samplesRead += CMSampleBufferGetNumSamples(sample)
            if samplesRead % max(1, policy.framesPerSecond) == 0 {
                try Task.checkCancellation()
            }
        }
        guard reader.status == .completed else {
            throw WorkoutVideoExportError.validationFailed(
                "Could not finish reading encoded video samples"
            )
        }
        guard samplesRead == plan.frameCount else {
            throw WorkoutVideoExportError.validationFailed(
                "Frame count \(samplesRead) does not match \(plan.frameCount)"
            )
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        nonisolated(unsafe) let cancellationGenerator = generator
        let finalFrameTime = Double(plan.frameCount - 1) / Double(policy.framesPerSecond)
        let sampleTimes = [
            CMTime.zero,
            CMTime(
                seconds: finalFrameTime / 2,
                preferredTimescale: CMTimeScale(policy.framesPerSecond * 1_000)
            ),
            CMTime(
                seconds: finalFrameTime,
                preferredTimescale: CMTimeScale(policy.framesPerSecond * 1_000)
            ),
        ]
        for time in sampleTimes {
            try Task.checkCancellation()
            _ = try await withTaskCancellationHandler {
                try await generator.image(at: time)
            } onCancel: {
                cancellationGenerator.cancelAllCGImageGeneration()
            }
        }
    }

    private func makeTemporaryURL(near destination: URL) -> URL {
        let directory = destination.deletingLastPathComponent()
        let base = directory.path.isEmpty ? fileManager.temporaryDirectory : directory
        return base.appendingPathComponent(
            "runplay-video-\(UUID().uuidString).mp4",
            isDirectory: false
        )
    }

    private func publish(temporaryURL: URL, to destinationURL: URL) throws {
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            throw WorkoutVideoExportError.destinationWriteFailed(error.localizedDescription)
        }
    }
}
