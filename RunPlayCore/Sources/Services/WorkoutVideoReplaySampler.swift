import Foundation

/// Lightweight metrics for one planned video frame, sampled from the canonical
/// elapsed timeline without mutating live UI replay state.
public struct WorkoutVideoFrameSample: Hashable, Sendable {
    public let frameIndex: Int
    public let frameCount: Int
    public let sourceElapsedSeconds: Double
    public let sourceTotalElapsedSeconds: Double
    public let progress: Double

    public let routePointIndex: Int
    public let routePointID: UUID?
    public let routeSegmentIndex: Int

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
    public let splitIndex: Int?
    public let recordedLapIndex: Int?

    public init(
        frameIndex: Int,
        frameCount: Int,
        sourceElapsedSeconds: Double,
        sourceTotalElapsedSeconds: Double,
        progress: Double,
        routePointIndex: Int,
        routePointID: UUID?,
        routeSegmentIndex: Int,
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
        splitIndex: Int?,
        recordedLapIndex: Int?
    ) {
        self.frameIndex = frameIndex
        self.frameCount = frameCount
        self.sourceElapsedSeconds = sourceElapsedSeconds
        self.sourceTotalElapsedSeconds = sourceTotalElapsedSeconds
        self.progress = progress
        self.routePointIndex = routePointIndex
        self.routePointID = routePointID
        self.routeSegmentIndex = routeSegmentIndex
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
        self.splitIndex = splitIndex
        self.recordedLapIndex = recordedLapIndex
    }

    /// Concise state label for the video HUD.
    public var stateLabel: String? {
        if isInRecordingGap {
            return "Recording Gap"
        }
        switch movementState {
        case .moving:
            return "Running"
        case .stopped:
            return "Stopped"
        case .paused:
            return "Paused"
        case .uncertain, .none:
            return nil
        }
    }
}

/// Portable sampler that seeks a private `PlaybackEngine` for each planned
/// source time. Safe for serial use from a background export task; never
/// touches the app’s live `ReplayController`.
public final class WorkoutVideoReplaySampler: @unchecked Sendable {
    private let workout: RunWorkout
    private let engine: PlaybackEngine
    private let analysisContext: WorkoutAnalysisContext
    private let lock = NSLock()

    public init(workout: RunWorkout, analysisContext: WorkoutAnalysisContext? = nil) {
        self.workout = workout
        self.analysisContext = analysisContext ?? WorkoutAnalysisContext(workout: workout)
        self.engine = PlaybackEngine()
        self.engine.load(workout, analysisContext: self.analysisContext)
    }

    /// Total source elapsed duration used for frame planning.
    public var totalElapsedSeconds: Double {
        lock.withLock { engine.state.totalDuration }
    }

    /// Whether the workout has a positive finite playable elapsed timeline.
    public var hasPlayableTimeline: Bool {
        let duration = totalElapsedSeconds
        return duration.isFinite && duration > 0 && !workout.routePoints.isEmpty
    }

    /// Sample canonical metrics at a planned frame index.
    public func sample(frameIndex: Int, plan: WorkoutVideoFramePlan) -> WorkoutVideoFrameSample {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = plan.sourceElapsedSeconds(atFrameIndex: frameIndex)
        let progress = plan.progress(atFrameIndex: frameIndex)
        engine.seekToTime(elapsed)
        let metrics = engine.selectedMetrics
        let state = engine.state
        let pointIndex = state.currentPointIndex
        let point = workout.routePoints.indices.contains(pointIndex)
            ? workout.routePoints[pointIndex]
            : nil

        let pace: Double?
        if let p = metrics.paceSecondsPerKilometer, p.isFinite, p > 0 {
            pace = p
        } else {
            pace = nil
        }
        let hr: Double?
        if let h = metrics.heartRateBPM, MetricValidation.isValidHeartRate(h) {
            hr = h
        } else {
            hr = nil
        }
        let elev: Double?
        if let e = metrics.altitudeMeters, e.isFinite {
            elev = e
        } else {
            elev = nil
        }

        return WorkoutVideoFrameSample(
            frameIndex: frameIndex,
            frameCount: plan.frameCount,
            sourceElapsedSeconds: elapsed,
            sourceTotalElapsedSeconds: plan.sourceTotalElapsedSeconds,
            progress: progress,
            routePointIndex: pointIndex,
            routePointID: point?.id,
            routeSegmentIndex: point?.routeSegmentIndex ?? 0,
            elapsedSeconds: metrics.elapsedSeconds ?? state.currentTime,
            activeSeconds: metrics.activeSeconds,
            movingSeconds: metrics.movingSeconds,
            stoppedSeconds: metrics.stoppedSeconds,
            distanceMeters: metrics.distanceMeters ?? state.currentDistance,
            activePaceSecondsPerKilometer: pace,
            heartRateBPM: hr,
            correctedElevationMeters: elev,
            movementState: metrics.movementState,
            isInRecordingGap: metrics.isInRecordingGap,
            splitIndex: metrics.splitIndex,
            recordedLapIndex: metrics.recordedLapIndex
        )
    }

    /// Snapshot of the private engine state (for tests verifying isolation).
    public var privateEngineState: ReplayState {
        lock.withLock { engine.state }
    }
}

// MARK: - Eligibility

/// Portable eligibility checks for video export (no MapKit).
public enum WorkoutVideoExportEligibility: Sendable {
    public struct Assessment: Equatable, Sendable {
        public let canExport: Bool
        public let unavailableHelp: String?

        public init(canExport: Bool, unavailableHelp: String?) {
            self.canExport = canExport
            self.unavailableHelp = unavailableHelp
        }
    }

    /// True when the workout has at least one coordinate usable for a route map.
    public static func hasUsableRoute(_ workout: RunWorkout) -> Bool {
        workout.routePoints.contains { point in
            GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude)
        }
    }

    /// True when the canonical replay elapsed duration is positive and finite.
    public static func hasPlayableTimeline(_ workout: RunWorkout) -> Bool {
        guard !workout.routePoints.isEmpty else { return false }
        let elapsed = WorkoutTimeline.playableElapsedDuration(routePoints: workout.routePoints)
        return elapsed.isFinite && elapsed > 0
    }

    /// Full gate for enabling the Export Route Replay menu action.
    public static func canExportVideo(_ workout: RunWorkout) -> Bool {
        assessment(for: workout).canExport
    }

    public static func unavailableHelp(for workout: RunWorkout) -> String? {
        assessment(for: workout).unavailableHelp
    }

    /// Evaluate the route-sized coordinate gate once. UI callers should run
    /// this off the main actor and cache the returned value for body updates.
    public static func assessment(for workout: RunWorkout) -> Assessment {
        let usableRoute = hasUsableRoute(workout)
        let playableTimeline = hasPlayableTimeline(workout)
        if !usableRoute {
            return Assessment(
                canExport: false,
                unavailableHelp: "This workout has no usable GPS route for video export."
            )
        }
        if !playableTimeline {
            return Assessment(
                canExport: false,
                unavailableHelp: "This workout has no playable elapsed timeline for video export."
            )
        }
        return Assessment(canExport: true, unavailableHelp: nil)
    }
}
