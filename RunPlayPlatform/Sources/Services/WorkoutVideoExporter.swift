import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
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

// MARK: - Protocol

/// Exports a deterministic offline workout route-replay MP4.
public protocol WorkoutVideoExporting: Sendable {
    func export(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy,
        mapPreparation: WorkoutVideoMapPreparation?,
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
    }

    private var fileManager: FileManager { .default }

    public func export(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy = .production,
        mapPreparation: WorkoutVideoMapPreparation? = nil,
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

        let analysisContext = WorkoutAnalysisContext(workout: workout)
        let sampler = WorkoutVideoReplaySampler(workout: workout, analysisContext: analysisContext)
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
                analysisContext: analysisContext
            )
        }

        try Task.checkCancellation()

        let title = workout.displayName
        let dateText = Self.formatWorkoutDate(workout)
        let mapSize = CGSize(
            width: preparedMap.pixelWidth,
            height: preparedMap.pixelHeight
        )

        let temporaryURL = try makeTemporaryURL(near: destinationURL)
        var temporaryRetained = true
        defer {
            if temporaryRetained {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try await encode(
                plan: plan,
                policy: policy,
                sampler: sampler,
                map: preparedMap,
                mapSize: mapSize,
                title: title,
                dateText: dateText,
                configuration: configuration,
                temporaryURL: temporaryURL,
                progress: progress
            )
        } catch is CancellationError {
            throw WorkoutVideoExportError.cancelled
        } catch let error as WorkoutVideoExportError {
            throw error
        } catch {
            throw WorkoutVideoExportError.finalizationFailed(error.localizedDescription)
        }

        try Task.checkCancellation()
        await progress(WorkoutVideoExportProgress(
            phase: .finalizing,
            completedFrames: plan.frameCount,
            totalFrames: plan.frameCount
        ))

        try await validateOutput(
            url: temporaryURL,
            policy: policy,
            plan: plan
        )

        try publish(temporaryURL: temporaryURL, to: destinationURL)
        temporaryRetained = false

        let attrs = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

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
    }

    // MARK: - Map preparation

    public func prepareMap(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        policy: WorkoutVideoExportPolicy,
        analysisContext: WorkoutAnalysisContext? = nil
    ) async throws -> WorkoutVideoMapPreparation {
        try Task.checkCancellation()
        let context = analysisContext ?? WorkoutAnalysisContext(workout: workout)
        let policyColor = RouteMetricColorPolicy.runningDefault

        let routePrep = try await Task.detached(priority: .userInitiated) {
            try Self.prepareRoutePresentation(
                workout: workout,
                context: context,
                preferredMode: configuration.routeColorMode,
                policy: policyColor,
                profileBuilder: self.profileBuilder,
                lineBuilder: self.lineBuilder,
                isCancelled: { Task.isCancelled }
            )
        }.value

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

    /// Poster midpoint frame as CGImage (for UI preview).
    public func renderPoster(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        mapPreparation: WorkoutVideoMapPreparation,
        policy: WorkoutVideoExportPolicy = .poster
    ) throws -> CGImage {
        try policy.validate()
        let sampler = WorkoutVideoReplaySampler(workout: workout)
        let plan = try WorkoutVideoFramePlan.make(
            duration: configuration.duration,
            policy: policy,
            sourceTotalElapsedSeconds: sampler.totalElapsedSeconds
        )
        // Midpoint frame for representative poster.
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
        return try frameRenderer.renderImage(
            frame: model,
            staticMap: mapPreparation.staticMapImage,
            width: policy.width,
            height: policy.height,
            mapSize: mapSize
        )
    }

    // MARK: - Encoding

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

        // Avoid embedding GPS / location metadata.
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

            try await waitUntilReady(input: input, writer: writer)

            try Task.checkCancellation()

            var pixelBuffer: CVPixelBuffer?
            let poolStatus: CVReturn
            if let pool {
                poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
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
                writer.cancelWriting()
                throw WorkoutVideoExportError.pixelBufferAllocationFailed
            }

            let sample = sampler.sample(frameIndex: frameIndex, plan: plan)
            let marker = map.markerPixel(for: sample)
            let model = WorkoutVideoFrameModel.make(
                sample: sample,
                markerPixel: marker,
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
                writer.cancelWriting()
                throw WorkoutVideoExportError.frameRenderingFailed(error.localizedDescription)
            }

            let time = CMTime(value: CMTimeValue(frameIndex), timescale: timescale)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                let detail = writer.error?.localizedDescription ?? "append failed"
                writer.cancelWriting()
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

        // AVAssetWriter is not Sendable; finishWriting always runs its handler
        // on a writer-owned queue after the session ends.
        nonisolated(unsafe) let finishingWriter = writer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishingWriter.finishWriting {
                switch finishingWriter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: WorkoutVideoExportError.cancelled)
                case .failed:
                    let detail = finishingWriter.error?.localizedDescription ?? "finishWriting failed"
                    continuation.resume(throwing: WorkoutVideoExportError.finalizationFailed(detail))
                default:
                    continuation.resume(
                        throwing: WorkoutVideoExportError.finalizationFailed(
                            "Unexpected writer status \(finishingWriter.status.rawValue)"
                        )
                    )
                }
            }
        }
    }

    /// Cooperative backpressure wait — short sleeps, no full-CPU spin, not on main actor.
    private func waitUntilReady(input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed {
                let detail = writer.error?.localizedDescription ?? "writer failed while waiting"
                throw WorkoutVideoExportError.frameAppendFailed(-1, detail)
            }
            if writer.status == .cancelled {
                throw WorkoutVideoExportError.cancelled
            }
            try await Task.sleep(nanoseconds: 2_000_000) // 2 ms
        }
        if Task.isCancelled {
            writer.cancelWriting()
            throw WorkoutVideoExportError.cancelled
        }
    }

    // MARK: - Validation

    private func validateOutput(
        url: URL,
        policy: WorkoutVideoExportPolicy,
        plan: WorkoutVideoFramePlan
    ) async throws {
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
        guard duration.isNumeric, !duration.isIndefinite else {
            throw WorkoutVideoExportError.validationFailed("Output duration is not finite")
        }
        let durationSeconds = CMTimeGetSeconds(duration)
        let expected = plan.outputDurationSeconds
        let tolerance = 1.0 / Double(policy.framesPerSecond) + 0.05
        // Last frame presentation time is (frameCount-1)/fps; container duration
        // is typically frameCount/fps or one frame shorter depending on encoder.
        let minDuration = expected - tolerance - (1.0 / Double(policy.framesPerSecond))
        let maxDuration = expected + tolerance
        guard durationSeconds >= minDuration, durationSeconds <= maxDuration + 0.25 else {
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
        let transformed = naturalSize.applying(preferredTransform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        guard width == policy.width, height == policy.height else {
            throw WorkoutVideoExportError.validationFailed(
                "Dimensions \(width)×\(height) do not match \(policy.width)×\(policy.height)"
            )
        }

        let formatDescriptions = try await track.load(.formatDescriptions)
        guard !formatDescriptions.isEmpty else {
            throw WorkoutVideoExportError.validationFailed("Video track has no format description")
        }

        // Decode first, middle, and last samples when practical.
        try await decodeSampleFrames(asset: asset, plan: plan)
    }

    private func decodeSampleFrames(asset: AVURLAsset, plan: WorkoutVideoFramePlan) async throws {
        guard let reader = try? AVAssetReader(asset: asset) else {
            // Reader failure is soft when format is otherwise valid.
            return
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }

        var samplesRead = 0
        while let sample = output.copyNextSampleBuffer() {
            samplesRead += 1
            _ = sample
            // Bound decode work in CI: stop after a handful of samples.
            if samplesRead >= 3 { break }
        }
        reader.cancelReading()
        guard samplesRead >= 1 else {
            throw WorkoutVideoExportError.validationFailed("Could not decode any video samples")
        }
    }

    // MARK: - File transaction

    private func makeTemporaryURL(near destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        let base = directory.path.isEmpty
            ? fileManager.temporaryDirectory
            : directory
        let name = "runplay-video-\(UUID().uuidString).mp4"
        return base.appendingPathComponent(name, isDirectory: false)
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
            let probe = try profileBuilder.probe(
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
