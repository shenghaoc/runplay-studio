import Foundation

/// Metrics at the currently selected replay position.
///
/// This is a snapshot of the route point data at the current position,
/// used to drive the current metrics panel and synchronized views.
public struct SelectedMetrics: Sendable {
    public var elapsedSeconds: Double?
    public var activeSeconds: Double?
    public var movingSeconds: Double?
    public var stoppedSeconds: Double?
    public var movementState: MovementState?
    public var isInRecordingGap: Bool
    public var distanceMeters: Double?
    public var paceSecondsPerKilometer: Double?
    public var altitudeMeters: Double?
    public var heartRateBPM: Double?
    public var speedMetersPerSecond: Double?
    public var cadence: Double?
    public var splitIndex: Int?

    public init(
        elapsedSeconds: Double? = nil,
        distanceMeters: Double? = nil,
        paceSecondsPerKilometer: Double? = nil,
        altitudeMeters: Double? = nil,
        heartRateBPM: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        cadence: Double? = nil,
        splitIndex: Int? = nil
    ) {
        self.init(
            elapsedSeconds: elapsedSeconds,
            activeSeconds: nil,
            movingSeconds: nil,
            stoppedSeconds: nil,
            movementState: nil,
            isInRecordingGap: false,
            distanceMeters: distanceMeters,
            paceSecondsPerKilometer: paceSecondsPerKilometer,
            altitudeMeters: altitudeMeters,
            heartRateBPM: heartRateBPM,
            speedMetersPerSecond: speedMetersPerSecond,
            cadence: cadence,
            splitIndex: splitIndex
        )
    }

    public init(
        elapsedSeconds: Double? = nil,
        activeSeconds: Double?,
        movingSeconds: Double? = nil,
        stoppedSeconds: Double? = nil,
        movementState: MovementState? = nil,
        isInRecordingGap: Bool = false,
        distanceMeters: Double? = nil,
        paceSecondsPerKilometer: Double? = nil,
        altitudeMeters: Double? = nil,
        heartRateBPM: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        cadence: Double? = nil,
        splitIndex: Int? = nil
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.activeSeconds = activeSeconds
        self.movingSeconds = movingSeconds
        self.stoppedSeconds = stoppedSeconds
        self.movementState = movementState
        self.isInRecordingGap = isInRecordingGap
        self.distanceMeters = distanceMeters
        self.paceSecondsPerKilometer = paceSecondsPerKilometer
        self.altitudeMeters = altitudeMeters
        self.heartRateBPM = heartRateBPM
        self.speedMetersPerSecond = speedMetersPerSecond
        self.cadence = cadence
        self.splitIndex = splitIndex
    }

    public var formattedElapsed: String {
        DisplayFormatter.formatElapsed(elapsedSeconds)
    }

    public var formattedActive: String {
        DisplayFormatter.formatElapsed(activeSeconds)
    }

    public var formattedMoving: String {
        DisplayFormatter.formatElapsed(movingSeconds)
    }

    public var formattedStopped: String {
        DisplayFormatter.formatElapsed(stoppedSeconds)
    }

    public var movementStateLabel: String {
        switch movementState {
        case .moving: return "Moving"
        case .stopped: return "Stopped"
        case .paused: return "Paused"
        case .uncertain: return "---"
        case .none: return "---"
        }
    }

    public var formattedDistance: String {
        DisplayFormatter.formatDistanceKm(distanceMeters)
    }

    public var formattedPace: String {
        DisplayFormatter.formatPace(paceSecondsPerKilometer)
    }

    public var formattedElevation: String {
        DisplayFormatter.formatElevation(altitudeMeters)
    }

    public var formattedHeartRate: String {
        DisplayFormatter.formatHeartRate(heartRateBPM)
    }

    public var formattedSpeed: String {
        DisplayFormatter.formatSpeed(speedMetersPerSecond)
    }

    public var formattedCadence: String {
        DisplayFormatter.formatCadence(cadence)
    }

    public var formattedSplit: String {
        guard let idx = splitIndex else { return "---" }
        return "Split \(idx + 1)"
    }
}
