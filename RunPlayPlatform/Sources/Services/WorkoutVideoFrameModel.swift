import CoreGraphics
import Foundation
import RunPlayCore

/// Immutable model for one rendered video frame (formatting-ready labels).
public struct WorkoutVideoFrameModel: Sendable {
    public let frameIndex: Int
    public let frameCount: Int
    public let sourceElapsedSeconds: Double
    public let sourceTotalElapsedSeconds: Double
    public let progress: Double

    public let workoutTitle: String
    public let workoutDateText: String

    public let markerPixel: CGPoint?

    public let elapsedSeconds: Double
    public let activeSeconds: Double?
    public let movingSeconds: Double?
    public let stoppedSeconds: Double?
    public let distanceMeters: Double
    public let activePaceSecondsPerKilometer: Double?
    public let heartRateBPM: Double?
    public let correctedElevationMeters: Double?
    public let movementState: MovementState?
    public let isInRecordingGap: Bool
    public let stateLabel: String?

    public let appearance: PNGSummaryExportAppearance
    public let routeColorMode: WorkoutRouteColorMode

    public init(
        frameIndex: Int,
        frameCount: Int,
        sourceElapsedSeconds: Double,
        sourceTotalElapsedSeconds: Double,
        progress: Double,
        workoutTitle: String,
        workoutDateText: String,
        markerPixel: CGPoint?,
        elapsedSeconds: Double,
        activeSeconds: Double?,
        movingSeconds: Double?,
        stoppedSeconds: Double?,
        distanceMeters: Double,
        activePaceSecondsPerKilometer: Double?,
        heartRateBPM: Double?,
        correctedElevationMeters: Double?,
        movementState: MovementState?,
        isInRecordingGap: Bool,
        stateLabel: String?,
        appearance: PNGSummaryExportAppearance,
        routeColorMode: WorkoutRouteColorMode
    ) {
        self.frameIndex = frameIndex
        self.frameCount = frameCount
        self.sourceElapsedSeconds = sourceElapsedSeconds
        self.sourceTotalElapsedSeconds = sourceTotalElapsedSeconds
        self.progress = progress
        self.workoutTitle = workoutTitle
        self.workoutDateText = workoutDateText
        self.markerPixel = markerPixel
        self.elapsedSeconds = elapsedSeconds
        self.activeSeconds = activeSeconds
        self.movingSeconds = movingSeconds
        self.stoppedSeconds = stoppedSeconds
        self.distanceMeters = distanceMeters
        self.activePaceSecondsPerKilometer = activePaceSecondsPerKilometer
        self.heartRateBPM = heartRateBPM
        self.correctedElevationMeters = correctedElevationMeters
        self.movementState = movementState
        self.isInRecordingGap = isInRecordingGap
        self.stateLabel = stateLabel
        self.appearance = appearance
        self.routeColorMode = routeColorMode
    }

    public static func make(
        sample: WorkoutVideoFrameSample,
        markerPixel: CGPoint?,
        workoutTitle: String,
        workoutDateText: String,
        appearance: PNGSummaryExportAppearance,
        routeColorMode: WorkoutRouteColorMode
    ) -> WorkoutVideoFrameModel {
        WorkoutVideoFrameModel(
            frameIndex: sample.frameIndex,
            frameCount: sample.frameCount,
            sourceElapsedSeconds: sample.sourceElapsedSeconds,
            sourceTotalElapsedSeconds: sample.sourceTotalElapsedSeconds,
            progress: sample.progress,
            workoutTitle: workoutTitle,
            workoutDateText: workoutDateText,
            markerPixel: markerPixel,
            elapsedSeconds: sample.elapsedSeconds,
            activeSeconds: sample.activeSeconds,
            movingSeconds: sample.movingSeconds,
            stoppedSeconds: sample.stoppedSeconds,
            distanceMeters: sample.distanceMeters,
            activePaceSecondsPerKilometer: sample.activePaceSecondsPerKilometer,
            heartRateBPM: sample.heartRateBPM,
            correctedElevationMeters: sample.correctedElevationMeters,
            movementState: sample.movementState,
            isInRecordingGap: sample.isInRecordingGap,
            stateLabel: sample.stateLabel,
            appearance: appearance,
            routeColorMode: routeColorMode
        )
    }

    // MARK: - Formatted labels (DisplayFormatter semantics)

    public var formattedElapsed: String {
        DisplayFormatter.formatDuration(elapsedSeconds)
    }

    public var formattedActive: String {
        DisplayFormatter.formatDuration(activeSeconds)
    }

    public var formattedDistance: String {
        DisplayFormatter.formatDistanceKm(distanceMeters)
    }

    public var formattedPace: String {
        DisplayFormatter.formatPace(activePaceSecondsPerKilometer)
    }

    public var formattedHeartRate: String {
        DisplayFormatter.formatHeartRate(heartRateBPM)
    }

    public var formattedElevation: String {
        DisplayFormatter.formatElevation(correctedElevationMeters)
    }

    public var formattedSourceElapsed: String {
        DisplayFormatter.formatDuration(sourceElapsedSeconds)
    }

    public var formattedSourceTotal: String {
        DisplayFormatter.formatDuration(sourceTotalElapsedSeconds)
    }

    public var progressPercentLabel: String {
        "\(Int((min(1, max(0, progress)) * 100).rounded()))%"
    }
}
