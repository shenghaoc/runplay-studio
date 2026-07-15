import Foundation

/// Persisted diagnostics explaining the movement-detection result.
public struct MovementDiagnostics: Codable, Hashable, Sendable {
    /// Version of the detection policy used. Stale versions trigger reanalysis.
    public var policyVersion: Int

    /// Number of active intervals with reliable timing evidence.
    public var reliableIntervalCount: Int

    /// Number of intervals classified as confident stops.
    public var stoppedIntervalCount: Int

    /// Number of intervals classified as uncertain.
    public var uncertainIntervalCount: Int

    /// Whether the conservative fallback (moving = active) was used because
    /// movement could not be estimated reliably.
    public var usedConservativeFallback: Bool

    /// Total number of route points analysed (including intra-segment pairs).
    public var analysedPointPairCount: Int

    public init(
        policyVersion: Int = MovementDetectionPolicy.currentVersion,
        reliableIntervalCount: Int = 0,
        stoppedIntervalCount: Int = 0,
        uncertainIntervalCount: Int = 0,
        usedConservativeFallback: Bool = true,
        analysedPointPairCount: Int = 0
    ) {
        self.policyVersion = policyVersion
        self.reliableIntervalCount = max(0, reliableIntervalCount)
        self.stoppedIntervalCount = max(0, stoppedIntervalCount)
        self.uncertainIntervalCount = max(0, uncertainIntervalCount)
        self.usedConservativeFallback = usedConservativeFallback
        self.analysedPointPairCount = max(0, analysedPointPairCount)
    }

    /// A profile can produce reliable estimates (not a fallback).
    public var isReliable: Bool {
        !usedConservativeFallback && reliableIntervalCount > 0
    }
}
