import Foundation

/// Deterministic mapping from output frame index to comparison-domain position.
///
/// Timing is independent of machine speed, live comparison-slider position,
/// display refresh rate, and writer readiness. Frame zero maps to domain zero;
/// the final frame maps exactly to `domainLength`.
public struct ComparisonVideoFramePlan: Hashable, Sendable {
    public let frameCount: Int
    public let framesPerSecond: Int
    public let outputDurationSeconds: Double
    public let domainLength: Double
    public let domain: ComparisonVideoDomain

    public init(
        frameCount: Int,
        framesPerSecond: Int,
        domainLength: Double,
        domain: ComparisonVideoDomain
    ) throws {
        guard frameCount >= 2 else {
            throw ComparisonVideoExportError.invalidConfiguration(
                "Video requires at least two frames"
            )
        }
        guard framesPerSecond > 0 else {
            throw ComparisonVideoExportError.invalidConfiguration("Frame rate must be positive")
        }
        guard domainLength.isFinite, domainLength > 0 else {
            throw ComparisonVideoExportError.invalidConfiguration(
                "Comparison domain length must be positive and finite"
            )
        }
        self.frameCount = frameCount
        self.framesPerSecond = framesPerSecond
        self.outputDurationSeconds = Double(frameCount) / Double(framesPerSecond)
        self.domainLength = domainLength
        self.domain = domain
    }

    /// Builds a plan for a duration preset, policy, and comparison domain.
    public static func make(
        duration: WorkoutVideoDuration,
        policy: WorkoutVideoExportPolicy,
        domainLength: Double,
        domain: ComparisonVideoDomain
    ) throws -> ComparisonVideoFramePlan {
        try policy.validate()
        let count = try WorkoutVideoFramePlan.frameCount(
            durationSeconds: duration.seconds,
            framesPerSecond: policy.framesPerSecond,
            maximumFrameCount: policy.maximumFrameCount
        )
        return try ComparisonVideoFramePlan(
            frameCount: count,
            framesPerSecond: policy.framesPerSecond,
            domainLength: domainLength,
            domain: domain
        )
    }

    /// Progress in `0...1` for frame index `i`.
    public func progress(atFrameIndex index: Int) -> Double {
        let clamped = clampFrameIndex(index)
        if frameCount == 1 { return 0 }
        return Double(clamped) / Double(frameCount - 1)
    }

    /// Domain position (metres) for frame index `i`.
    ///
    /// Frame 0 → 0; final frame → exact `domainLength`.
    public func domainPosition(atFrameIndex index: Int) -> Double {
        let clamped = clampFrameIndex(index)
        if clamped == 0 { return 0 }
        if clamped == frameCount - 1 { return domainLength }
        let progress = Double(clamped) / Double(frameCount - 1)
        let position = progress * domainLength
        guard position.isFinite else { return domainLength }
        return min(max(0, position), domainLength)
    }

    /// Presentation timescale value for `CMTime(value:timescale:)` (frame index).
    public func presentationTimeValue(atFrameIndex index: Int) -> Int64 {
        Int64(clampFrameIndex(index))
    }

    private func clampFrameIndex(_ index: Int) -> Int {
        min(max(0, index), frameCount - 1)
    }
}
