import Foundation

/// Bounded video-length presets for route-replay export.
public enum WorkoutVideoDuration: Int, CaseIterable, Codable, Hashable, Sendable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case sixtySeconds = 60

    public var displayName: String {
        "\(rawValue) seconds"
    }

    public var seconds: Int { rawValue }
}

/// User-facing configuration for workout route-replay video export.
///
/// Not persisted on `RunWorkout`. Appearance reuses the PNG export Light/Dark
/// resolution contract so video and PNG stay consistent.
public struct WorkoutVideoExportConfiguration: Codable, Hashable, Sendable {
    public var duration: WorkoutVideoDuration
    public var appearance: PNGSummaryExportAppearance
    public var routeColorMode: WorkoutRouteColorMode

    public init(
        duration: WorkoutVideoDuration = .thirtySeconds,
        appearance: PNGSummaryExportAppearance = .light,
        routeColorMode: WorkoutRouteColorMode = .solid
    ) {
        self.duration = duration
        self.appearance = appearance
        self.routeColorMode = routeColorMode
    }
}

/// Centralized numeric policy for video export dimensions, timing, and writer bounds.
///
/// Views, renderer, and encoder MUST read limits from this type rather than
/// scattering magic numbers.
public struct WorkoutVideoExportPolicy: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let averageBitRate: Int
    public let maximumFrameCount: Int
    public let progressUpdateStride: Int
    public let policyVersion: Int

    public init(
        width: Int = 1_920,
        height: Int = 1_080,
        framesPerSecond: Int = 30,
        averageBitRate: Int = 8_000_000,
        maximumFrameCount: Int = 1_800,
        progressUpdateStride: Int = 10,
        policyVersion: Int = 1
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.averageBitRate = averageBitRate
        self.maximumFrameCount = maximumFrameCount
        self.progressUpdateStride = progressUpdateStride
        self.policyVersion = policyVersion
    }

    /// Production 1080p30 H.264 policy.
    public static let production = WorkoutVideoExportPolicy()

    /// Half-resolution poster policy (960×540 @ 30 fps geometry; poster uses one frame).
    public static let poster = WorkoutVideoExportPolicy(
        width: 960,
        height: 540,
        framesPerSecond: 30,
        averageBitRate: 2_000_000,
        maximumFrameCount: 1_800,
        progressUpdateStride: 10,
        policyVersion: 1
    )

    /// Tiny injectable policy for unit tests (CI-friendly encode).
    public static let unitTest = WorkoutVideoExportPolicy(
        width: 320,
        height: 180,
        framesPerSecond: 10,
        averageBitRate: 500_000,
        maximumFrameCount: 600,
        progressUpdateStride: 2,
        policyVersion: 1
    )

    /// Validates dimensions, frame rate, bitrate, and even-dimension H.264 rules.
    public func validate() throws {
        guard width > 0, height > 0 else {
            throw WorkoutVideoExportError.invalidConfiguration("Video dimensions must be positive")
        }
        guard width % 2 == 0, height % 2 == 0 else {
            throw WorkoutVideoExportError.invalidConfiguration(
                "H.264 dimensions must be even (\(width)×\(height))"
            )
        }
        guard framesPerSecond > 0, framesPerSecond <= 60 else {
            throw WorkoutVideoExportError.invalidConfiguration("Frame rate must be in 1...60")
        }
        guard averageBitRate > 0 else {
            throw WorkoutVideoExportError.invalidConfiguration("Average bit rate must be positive")
        }
        guard maximumFrameCount >= 2 else {
            throw WorkoutVideoExportError.invalidConfiguration("Maximum frame count must be at least 2")
        }
        guard progressUpdateStride >= 1 else {
            throw WorkoutVideoExportError.invalidConfiguration("Progress update stride must be at least 1")
        }
    }

    /// Frame count for a duration preset under this policy.
    public func frameCount(for duration: WorkoutVideoDuration) throws -> Int {
        try WorkoutVideoFramePlan.frameCount(
            durationSeconds: duration.seconds,
            framesPerSecond: framesPerSecond,
            maximumFrameCount: maximumFrameCount
        )
    }
}

/// Progress phases for video export generation and encoding.
public enum WorkoutVideoExportPhase: String, Hashable, Sendable {
    case idle
    case preparingRoute
    case loadingMap
    case renderingPoster
    case awaitingDestination
    case encoding
    case cancelling
    case finalizing
    case completed
    case cancelled
    case failed

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .preparingRoute: return "Preparing route"
        case .loadingMap: return "Loading map"
        case .renderingPoster: return "Rendering preview"
        case .awaitingDestination: return "Choose destination"
        case .encoding: return "Encoding video"
        case .cancelling: return "Cancelling"
        case .finalizing: return "Finalizing"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }
}

/// Structured progress for throttled UI updates during encoding.
public struct WorkoutVideoExportProgress: Hashable, Sendable {
    public let phase: WorkoutVideoExportPhase
    public let completedFrames: Int
    public let totalFrames: Int

    public init(
        phase: WorkoutVideoExportPhase,
        completedFrames: Int = 0,
        totalFrames: Int = 0
    ) {
        self.phase = phase
        self.completedFrames = max(0, completedFrames)
        self.totalFrames = max(0, totalFrames)
    }

    /// Fraction in `0...1` when total frames is known.
    public var fractionComplete: Double {
        guard totalFrames > 0 else { return 0 }
        return min(1, max(0, Double(completedFrames) / Double(totalFrames)))
    }

    public var percentComplete: Int {
        Int((fractionComplete * 100).rounded(.down))
    }
}

/// Structured errors for video export. UI shows concise summaries; temporary
/// paths must never appear in user-facing strings.
public enum WorkoutVideoExportError: Error, LocalizedError, Sendable, Equatable {
    case noPlayableTimeline
    case noUsableRoute
    case invalidConfiguration(String)
    case mapPreparationFailed(String)
    case writerCreationFailed(String)
    case cannotAddVideoInput
    case cannotStartWriting(String)
    case pixelBufferAllocationFailed
    case frameRenderingFailed(String)
    case frameAppendFailed(Int, String)
    case finalizationFailed(String)
    case validationFailed(String)
    case destinationWriteFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noPlayableTimeline:
            return "This workout has no playable elapsed timeline for video export."
        case .noUsableRoute:
            return "This workout has no usable GPS route for video export."
        case .invalidConfiguration(let detail):
            return "Invalid video configuration: \(detail)"
        case .mapPreparationFailed(let detail):
            return "Map preparation failed: \(detail)"
        case .writerCreationFailed:
            return "Could not create the video writer."
        case .cannotAddVideoInput:
            return "Could not add a video track to the export."
        case .cannotStartWriting:
            return "Could not start writing the video."
        case .pixelBufferAllocationFailed:
            return "Could not allocate a video frame buffer."
        case .frameRenderingFailed:
            return "Could not render a video frame."
        case .frameAppendFailed(let index, _):
            return index >= 0
                ? "Could not write frame \(index + 1)."
                : "Could not write a video frame."
        case .finalizationFailed:
            return "Could not finalize the video."
        case .validationFailed(let detail):
            return "Exported video failed validation: \(detail)"
        case .destinationWriteFailed:
            return "Could not save the video. Check that the destination is writable and has enough free space."
        case .cancelled:
            return "Video export cancelled."
        }
    }

    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
