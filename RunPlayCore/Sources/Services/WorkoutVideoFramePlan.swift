import Foundation

/// Deterministic mapping from output frame index to source elapsed time.
///
/// Timing is independent of machine speed, live replay position, display
/// refresh rate, and writer readiness. Frame zero maps to source elapsed zero;
/// the final frame maps exactly to the workout total elapsed.
public struct WorkoutVideoFramePlan: Hashable, Sendable {
    public let frameCount: Int
    public let framesPerSecond: Int
    public let outputDurationSeconds: Double
    public let sourceTotalElapsedSeconds: Double

    public init(
        frameCount: Int,
        framesPerSecond: Int,
        sourceTotalElapsedSeconds: Double
    ) throws {
        guard frameCount >= 2 else {
            throw WorkoutVideoExportError.invalidConfiguration("Video requires at least two frames")
        }
        guard framesPerSecond > 0 else {
            throw WorkoutVideoExportError.invalidConfiguration("Frame rate must be positive")
        }
        guard sourceTotalElapsedSeconds.isFinite, sourceTotalElapsedSeconds > 0 else {
            throw WorkoutVideoExportError.invalidConfiguration(
                "Workout total elapsed duration must be positive and finite"
            )
        }
        self.frameCount = frameCount
        self.framesPerSecond = framesPerSecond
        self.outputDurationSeconds = Double(frameCount) / Double(framesPerSecond)
        self.sourceTotalElapsedSeconds = sourceTotalElapsedSeconds
    }

    /// Builds a plan for a duration preset and policy.
    public static func make(
        duration: WorkoutVideoDuration,
        policy: WorkoutVideoExportPolicy,
        sourceTotalElapsedSeconds: Double
    ) throws -> WorkoutVideoFramePlan {
        try policy.validate()
        let count = try frameCount(
            durationSeconds: duration.seconds,
            framesPerSecond: policy.framesPerSecond,
            maximumFrameCount: policy.maximumFrameCount
        )
        return try WorkoutVideoFramePlan(
            frameCount: count,
            framesPerSecond: policy.framesPerSecond,
            sourceTotalElapsedSeconds: sourceTotalElapsedSeconds
        )
    }

    /// Overflow-safe `durationSeconds × framesPerSecond` with policy ceiling.
    public static func frameCount(
        durationSeconds: Int,
        framesPerSecond: Int,
        maximumFrameCount: Int
    ) throws -> Int {
        guard durationSeconds > 0 else {
            throw WorkoutVideoExportError.invalidConfiguration("Duration must be positive")
        }
        guard framesPerSecond > 0 else {
            throw WorkoutVideoExportError.invalidConfiguration("Frame rate must be positive")
        }
        guard maximumFrameCount >= 2 else {
            throw WorkoutVideoExportError.invalidConfiguration("Maximum frame count must be at least 2")
        }

        let (product, overflow) = durationSeconds.multipliedReportingOverflow(by: framesPerSecond)
        if overflow || product < 0 {
            throw WorkoutVideoExportError.invalidConfiguration("Frame count overflow")
        }
        guard product >= 2 else {
            throw WorkoutVideoExportError.invalidConfiguration("Video requires at least two frames")
        }
        guard product <= maximumFrameCount else {
            throw WorkoutVideoExportError.invalidConfiguration(
                "Frame count \(product) exceeds maximum \(maximumFrameCount)"
            )
        }
        return product
    }

    /// Progress in `0...1` for frame index `i`.
    public func progress(atFrameIndex index: Int) -> Double {
        let clamped = clampFrameIndex(index)
        if frameCount == 1 { return 0 }
        return Double(clamped) / Double(frameCount - 1)
    }

    /// Source elapsed seconds for frame index `i`.
    ///
    /// Frame 0 → 0; final frame → exact `sourceTotalElapsedSeconds`.
    public func sourceElapsedSeconds(atFrameIndex index: Int) -> Double {
        let clamped = clampFrameIndex(index)
        if clamped == 0 { return 0 }
        if clamped == frameCount - 1 { return sourceTotalElapsedSeconds }
        let progress = Double(clamped) / Double(frameCount - 1)
        let elapsed = progress * sourceTotalElapsedSeconds
        guard elapsed.isFinite else { return sourceTotalElapsedSeconds }
        return min(max(0, elapsed), sourceTotalElapsedSeconds)
    }

    /// Presentation timescale value for `CMTime(value:timescale:)` (frame index).
    public func presentationTimeValue(atFrameIndex index: Int) -> Int64 {
        Int64(clampFrameIndex(index))
    }

    private func clampFrameIndex(_ index: Int) -> Int {
        min(max(0, index), frameCount - 1)
    }
}
