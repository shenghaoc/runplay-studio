import Foundation

/// Centralised thresholds for movement/stop detection.
///
/// All magic numbers are defined here so detection logic stays parameter-free.
/// Defaults are conservative running-oriented values using hysteresis.
public struct MovementDetectionPolicy: Hashable, Sendable {
    /// Speed (m/s) at or below which a sustained interval may be stopped.
    /// A runner below ~1.8 km/h is typically stationary.
    public var stopSpeedMetersPerSecond: Double

    /// Speed (m/s) above which a sustained interval is considered moving.
    /// Must be greater than `stopSpeedMetersPerSecond` for hysteresis.
    public var resumeSpeedMetersPerSecond: Double

    /// Minimum duration (seconds) of sustained low-speed evidence before
    /// classifying as stopped.
    public var minimumStopDurationSeconds: Double

    /// Minimum duration (seconds) of sustained higher-speed evidence before
    /// moving past the resume threshold.
    public var minimumResumeDurationSeconds: Double

    /// Minimum cumulative distance (meters) of resumed movement before
    /// a stop is considered definitively ended.
    public var minimumResumeDistanceMeters: Double

    /// Maximum net displacement (meters) during the candidate window to be
    /// considered stationary.
    public var maximumStationaryRadiusMeters: Double

    /// Maximum cumulative path length (meters) during a candidate stop
    /// window. Drift beyond this distance is too much for stationary.
    public var maximumStationaryDriftMeters: Double

    /// Minimum duration (seconds) of an interval for direct speed evidence
    /// to be considered reliable.
    public var minimumReliableIntervalDurationSeconds: Double

    /// Maximum interval duration (seconds) used for direct speed evidence.
    /// Longer intervals use distance-domain evidence instead.
    public var maximumDirectSpeedIntervalDurationSeconds: Double

    /// Minimum number of reliable intervals needed for a confident estimate.
    public var minimumReliableSampleCount: Int

    /// Cancellation is checked every this many route points.
    public var cancellationCheckStride: Int

    /// Policy version for diagnostics.
    public static let currentVersion = 1

    public init(
        stopSpeedMetersPerSecond: Double = 0.6,
        resumeSpeedMetersPerSecond: Double = 1.0,
        minimumStopDurationSeconds: Double = 4.0,
        minimumResumeDurationSeconds: Double = 3.0,
        minimumResumeDistanceMeters: Double = 5.0,
        maximumStationaryRadiusMeters: Double = 10.0,
        maximumStationaryDriftMeters: Double = 20.0,
        minimumReliableIntervalDurationSeconds: Double = 0.5,
        maximumDirectSpeedIntervalDurationSeconds: Double = 30.0,
        minimumReliableSampleCount: Int = 10,
        cancellationCheckStride: Int = 2048
    ) {
        self.stopSpeedMetersPerSecond = max(0.01, stopSpeedMetersPerSecond)
        self.resumeSpeedMetersPerSecond = max(self.stopSpeedMetersPerSecond + 0.01, resumeSpeedMetersPerSecond)
        self.minimumStopDurationSeconds = max(0.5, minimumStopDurationSeconds)
        self.minimumResumeDurationSeconds = max(0.5, minimumResumeDurationSeconds)
        self.minimumResumeDistanceMeters = max(0, minimumResumeDistanceMeters)
        self.maximumStationaryRadiusMeters = max(0.5, maximumStationaryRadiusMeters)
        self.maximumStationaryDriftMeters = max(1.0, maximumStationaryDriftMeters)
        self.minimumReliableIntervalDurationSeconds = max(0.5, minimumReliableIntervalDurationSeconds)
        self.maximumDirectSpeedIntervalDurationSeconds = max(self.minimumReliableIntervalDurationSeconds * 2,
                                                             maximumDirectSpeedIntervalDurationSeconds)
        self.minimumReliableSampleCount = max(1, minimumReliableSampleCount)
        self.cancellationCheckStride = max(1, cancellationCheckStride)
    }

    public static let runningDefault = MovementDetectionPolicy()
}
