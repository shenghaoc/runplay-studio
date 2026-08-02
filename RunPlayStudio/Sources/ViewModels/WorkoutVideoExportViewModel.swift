import AppKit
import Foundation
import Observation
import RunPlayCore
import RunPlayPlatform

protocol WorkoutVideoExportClient: Sendable {
    func prepareMap(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        policy: WorkoutVideoExportPolicy,
        analysisContext: WorkoutAnalysisContext?,
        profileProbe: RouteMetricProfileProbe?
    ) async throws -> WorkoutVideoMapPreparation

    func renderPosterResult(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        mapPreparation: WorkoutVideoMapPreparation,
        policy: WorkoutVideoExportPolicy,
        analysisContext: WorkoutAnalysisContext?
    ) throws -> WorkoutVideoPoster

    func export(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy,
        mapPreparation: WorkoutVideoMapPreparation?,
        analysisContext: WorkoutAnalysisContext?,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void
    ) async throws -> WorkoutVideoExportResult
}

extension WorkoutVideoExporter: WorkoutVideoExportClient {}

/// Owns video-export configuration, poster preview, and offline encode workflow.
@MainActor
@Observable
final class WorkoutVideoExportViewModel: Identifiable {
    let id = UUID()

    var configuration: WorkoutVideoExportConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            handleConfigurationChange(from: oldValue)
        }
    }

    private(set) var phase: WorkoutVideoExportPhase = .idle
    private(set) var progress = WorkoutVideoExportProgress(phase: .idle)
    private(set) var posterImage: NSImage?
    private(set) var posterAccessibilityLabel: String
    private(set) var errorMessage: String?
    private(set) var mapFailureMessage: String?
    private(set) var availability = RouteMetricModeAvailability(
        pace: false,
        heartRate: false,
        correctedElevation: false
    )
    private(set) var isLoadingAvailability = true
    private(set) var isPreparingPoster = false
    private(set) var isExporting = false
    private(set) var isCancelling = false
    private(set) var isPreviewFailure = false
    private(set) var lastExportedFilename: String?

    private let workout: RunWorkout
    private let exporter: any WorkoutVideoExportClient
    private let announcementPolicy: AccessibilityAnnouncementPolicy
    private let policy: WorkoutVideoExportPolicy
    private let posterPolicy: WorkoutVideoExportPolicy

    private var analysisContext: WorkoutAnalysisContext?
    private var analysisContextTask: Task<WorkoutAnalysisContext, Never>?
    private var profileProbe: RouteMetricProfileProbe?
    private var profileProbeTask: Task<RouteMetricProfileProbe, Error>?
    private var mapPreparation: WorkoutVideoMapPreparation?
    private var mapPreparationTask: Task<WorkoutVideoMapPreparation, Error>?
    private var readyPosterConfiguration: WorkoutVideoExportConfiguration?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var requestSerial = 0
    private var exportSerial = 0
    private var hasAppeared = false

    var canExport: Bool {
        mapPreparation != nil
            && readyPosterConfiguration == configuration
            && mapFailureMessage == nil
            && !isExporting
            && !isPreparingPoster
    }

    var isBusy: Bool {
        isExporting || isPreparingPoster
    }

    var canRetryPreview: Bool {
        isPreviewFailure && errorMessage != nil && !isBusy
    }

    var outputResolutionText: String {
        "\(policy.width) × \(policy.height)"
    }

    var outputFrameRateText: String {
        "\(policy.framesPerSecond) fps"
    }

    var outputSummaryText: String {
        "Offline H.264 MP4 · \(policy.width)×\(policy.height) · \(policy.framesPerSecond) fps · no audio"
    }

    init(
        workout: RunWorkout,
        initialConfiguration: WorkoutVideoExportConfiguration,
        analysisContext: WorkoutAnalysisContext? = nil,
        exporter: (any WorkoutVideoExportClient)? = nil,
        announcementPolicy: AccessibilityAnnouncementPolicy = AccessibilityAnnouncementPolicy(),
        policy: WorkoutVideoExportPolicy = .production,
        posterPolicy: WorkoutVideoExportPolicy = .poster
    ) {
        self.workout = workout
        self.analysisContext = analysisContext
        self.configuration = initialConfiguration
        self.announcementPolicy = announcementPolicy
        self.policy = policy
        self.posterPolicy = posterPolicy
        self.exporter = exporter ?? WorkoutVideoExporter(
            mapPreparer: MapKitWorkoutVideoMapPreparer()
        )
        self.posterAccessibilityLabel = "\(workout.displayName), preview loading"
    }

    func onAppear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        schedulePosterPreview()
    }

    func cancel() {
        previewTask?.cancel()
        previewTask = nil
        if isExporting {
            cancelExport()
        } else {
            mapPreparationTask?.cancel()
            mapPreparationTask = nil
            requestSerial &+= 1
            isPreparingPoster = false
            if phase != .completed {
                phase = posterImage == nil ? .idle : .awaitingDestination
            }
        }
    }

    /// Request cancellation but keep the workflow busy until the exporter has
    /// acknowledged it and completed writer/temp-file cleanup.
    func cancelExport() {
        guard isExporting, !isCancelling else { return }
        isCancelling = true
        phase = .cancelling
        progress = WorkoutVideoExportProgress(
            phase: .cancelling,
            completedFrames: progress.completedFrames,
            totalFrames: progress.totalFrames
        )
        exportTask?.cancel()
    }

    func retryMap() {
        mapPreparationTask?.cancel()
        mapPreparationTask = nil
        mapFailureMessage = nil
        errorMessage = nil
        isPreviewFailure = false
        mapPreparation = nil
        readyPosterConfiguration = nil
        schedulePosterPreview(forceMapRefresh: true)
    }

    func retryPreview() {
        guard canRetryPreview else { return }
        errorMessage = nil
        isPreviewFailure = false
        readyPosterConfiguration = nil
        schedulePosterPreview(forceMapRefresh: mapPreparation == nil)
    }

    func dismissCleanup() {
        previewTask?.cancel()
        exportTask?.cancel()
        analysisContextTask?.cancel()
        profileProbeTask?.cancel()
        mapPreparationTask?.cancel()
        previewTask = nil
        analysisContextTask = nil
        profileProbeTask = nil
        mapPreparationTask = nil
        requestSerial &+= 1
        exportSerial &+= 1
    }

    func defaultFilename() -> String {
        ExportFilenameBuilder.videoReplayFilename(for: workout)
    }

    func isModeAvailable(_ mode: WorkoutRouteColorMode) -> Bool {
        availability.isAvailable(mode)
    }

    func unavailableReason(for mode: WorkoutRouteColorMode) -> String? {
        guard !isModeAvailable(mode) else { return nil }
        return mode.unavailableReason
    }

    func updateAvailabilityProbe() async {
        isLoadingAvailability = true
        do {
            let probe = try await resolvedProfileProbe()
            try Task.checkCancellation()
            availability = probe.availability
            isLoadingAvailability = false

            if configuration.routeColorMode != .solid,
               !availability.isAvailable(configuration.routeColorMode) {
                configuration.routeColorMode = .solid
            }
        } catch is CancellationError {
            return
        } catch {
            profileProbe = nil
            availability = .init(
                pace: false,
                heartRate: false,
                correctedElevation: false
            )
            isLoadingAvailability = false
            if configuration.routeColorMode != .solid {
                configuration.routeColorMode = .solid
            }
        }
    }

    /// Encode to the chosen destination URL.
    func export(to url: URL) async {
        guard canExport else { return }
        errorMessage = nil
        isPreviewFailure = false
        mapFailureMessage = nil
        exportSerial &+= 1
        let serial = exportSerial
        isExporting = true
        isCancelling = false
        phase = .encoding
        progress = WorkoutVideoExportProgress(phase: .encoding)

        let config = configuration
        let map = mapPreparation
        let exporter = self.exporter
        let policy = self.policy
        let workout = self.workout
        let context = analysisContext

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let resolvedContext: WorkoutAnalysisContext
                if let context {
                    resolvedContext = context
                } else {
                    resolvedContext = await self.resolvedAnalysisContext()
                }
                let result = try await exporter.export(
                    workout: workout,
                    configuration: config,
                    destinationURL: url,
                    policy: policy,
                    mapPreparation: map,
                    analysisContext: resolvedContext
                ) { [weak self] progressUpdate in
                    await MainActor.run {
                        guard let self,
                              serial == self.exportSerial,
                              progressUpdate.phase != .completed,
                              !self.isCancelling else { return }
                        self.progress = progressUpdate
                        self.phase = progressUpdate.phase
                    }
                }

                guard serial == self.exportSerial else { return }
                self.isExporting = false
                self.isCancelling = false
                self.exportTask = nil
                self.lastExportedFilename = result.filename
                self.phase = .completed
                self.progress = WorkoutVideoExportProgress(
                    phase: .completed,
                    completedFrames: result.frameCount,
                    totalFrames: result.frameCount
                )
                self.announcementPolicy.handle(.videoExportCompleted(name: result.filename))
            } catch is CancellationError {
                self.finishCancelledExport(serial: serial)
            } catch let error as WorkoutVideoExportError where error.isCancellation {
                self.finishCancelledExport(serial: serial)
            } catch let error as WorkoutVideoExportError {
                self.finishFailedExport(error, serial: serial)
            } catch {
                self.finishFailedExport(error, serial: serial)
            }
        }

        exportTask = task
        await task.value
    }

    // MARK: - Poster

    private func handleConfigurationChange(from old: WorkoutVideoExportConfiguration) {
        guard hasAppeared else { return }
        let appearanceChanged = configuration.appearance != old.appearance
        let colorChanged = configuration.routeColorMode != old.routeColorMode
        let durationOnly = configuration.duration != old.duration
            && !appearanceChanged
            && !colorChanged

        if appearanceChanged || colorChanged {
            mapPreparation = nil
            readyPosterConfiguration = nil
            schedulePosterPreview(forceMapRefresh: true)
        } else if durationOnly {
            readyPosterConfiguration = nil
            schedulePosterPreview(forceMapRefresh: false)
        }
    }

    private func schedulePosterPreview(forceMapRefresh: Bool = false) {
        guard hasAppeared else { return }
        previewTask?.cancel()
        if forceMapRefresh {
            mapPreparationTask?.cancel()
            mapPreparationTask = nil
        }
        requestSerial &+= 1
        let serial = requestSerial
        errorMessage = nil
        isPreviewFailure = false
        if forceMapRefresh {
            mapFailureMessage = nil
        }
        isPreparingPoster = true
        phase = forceMapRefresh || mapPreparation == nil ? .loadingMap : .renderingPoster

        let config = configuration
        let exporter = self.exporter
        let policy = self.policy
        let posterPolicy = self.posterPolicy
        let workout = self.workout
        let existingMap = forceMapRefresh ? nil : mapPreparation

        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = await self.resolvedAnalysisContext()
                let probe = config.routeColorMode == .solid
                    ? nil
                    : try await self.resolvedProfileProbe()

                let map: WorkoutVideoMapPreparation
                if let existingMap {
                    map = existingMap
                } else {
                    guard serial == self.requestSerial else { return }
                    self.phase = .preparingRoute
                    let mapTask: Task<WorkoutVideoMapPreparation, Error>
                    if let activeTask = self.mapPreparationTask {
                        mapTask = activeTask
                    } else {
                        let newTask = Task {
                            try await exporter.prepareMap(
                                workout: workout,
                                configuration: config,
                                policy: policy,
                                analysisContext: context,
                                profileProbe: probe
                            )
                        }
                        self.mapPreparationTask = newTask
                        mapTask = newTask
                    }
                    map = try await mapTask.value
                    try Task.checkCancellation()
                    guard serial == self.requestSerial else { return }
                    self.mapPreparationTask = nil
                    self.mapPreparation = map
                    self.phase = .renderingPoster
                }

                try Task.checkCancellation()
                let posterTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try exporter.renderPosterResult(
                        workout: workout,
                        configuration: config,
                        mapPreparation: map,
                        policy: posterPolicy,
                        analysisContext: context
                    )
                }
                let poster = try await withTaskCancellationHandler {
                    try await posterTask.value
                } onCancel: {
                    posterTask.cancel()
                }

                guard serial == self.requestSerial else { return }
                self.posterImage = NSImage(
                    cgImage: poster.image,
                    size: NSSize(width: poster.image.width, height: poster.image.height)
                )
                self.posterAccessibilityLabel = Self.posterAccessibilitySummary(
                    workout: workout,
                    configuration: config,
                    poster: poster
                )
                self.readyPosterConfiguration = config
                self.isPreparingPoster = false
                self.phase = .awaitingDestination
                self.mapFailureMessage = nil
                self.announcementPolicy.handle(.videoPreviewReady)
            } catch is CancellationError {
                self.finishCancelledPreview(serial: serial)
            } catch let error as WorkoutVideoExportError where error.isCancellation {
                self.finishCancelledPreview(serial: serial)
            } catch let error as WorkoutVideoExportError {
                self.finishFailedPreview(error, serial: serial)
            } catch {
                self.finishFailedPreview(error, serial: serial)
            }
        }
    }

    private func resolvedAnalysisContext() async -> WorkoutAnalysisContext {
        if let analysisContext { return analysisContext }
        if let analysisContextTask {
            let context = await analysisContextTask.value
            analysisContext = context
            self.analysisContextTask = nil
            return context
        }

        let workout = self.workout
        let task = Task.detached(priority: .userInitiated) {
            WorkoutAnalysisContext(workout: workout)
        }
        analysisContextTask = task
        let context = await task.value
        analysisContext = context
        analysisContextTask = nil
        return context
    }

    private func resolvedProfileProbe() async throws -> RouteMetricProfileProbe {
        if let profileProbe { return profileProbe }
        if let profileProbeTask {
            let probe = try await profileProbeTask.value
            profileProbe = probe
            self.profileProbeTask = nil
            return probe
        }

        let workout = self.workout
        let context = await resolvedAnalysisContext()
        let builder = RouteMetricProfileBuilder()
        let task = Task.detached(priority: .utility) {
            try builder.probe(
                routePoints: workout.routePoints,
                context: context,
                policy: .runningDefault,
                isCancelled: { Task.isCancelled }
            )
        }
        profileProbeTask = task
        do {
            let probe = try await task.value
            profileProbe = probe
            profileProbeTask = nil
            return probe
        } catch {
            profileProbeTask = nil
            throw error
        }
    }

    private func finishCancelledExport(serial: Int) {
        guard serial == exportSerial else { return }
        isExporting = false
        isCancelling = false
        exportTask = nil
        phase = .cancelled
        progress = WorkoutVideoExportProgress(phase: .cancelled)
        announcementPolicy.handle(.videoExportCancelled)
    }

    private func finishFailedExport(_ error: Error, serial: Int) {
        guard serial == exportSerial else { return }
        isExporting = false
        isCancelling = false
        exportTask = nil
        phase = .failed
        if case .mapPreparationFailed(let detail) = error as? WorkoutVideoExportError {
            mapFailureMessage = detail
        } else {
            errorMessage = error.localizedDescription
        }
        isPreviewFailure = false
        announcementPolicy.handle(.videoExportFailed(message: error.localizedDescription))
    }

    private func finishCancelledPreview(serial: Int) {
        guard serial == requestSerial else { return }
        isPreparingPoster = false
        phase = readyPosterConfiguration == configuration ? .awaitingDestination : .idle
    }

    private func finishFailedPreview(_ error: Error, serial: Int) {
        guard serial == requestSerial else { return }
        mapPreparationTask = nil
        isPreparingPoster = false
        phase = .failed
        readyPosterConfiguration = nil
        if case .mapPreparationFailed(let detail) = error as? WorkoutVideoExportError {
            mapFailureMessage = detail
        } else {
            errorMessage = error.localizedDescription
            isPreviewFailure = true
        }
        announcementPolicy.handle(.videoPreviewFailed(message: error.localizedDescription))
    }

    private static func posterAccessibilitySummary(
        workout: RunWorkout,
        configuration: WorkoutVideoExportConfiguration,
        poster: WorkoutVideoPoster
    ) -> String {
        let distance = DisplayFormatter.formatDistanceKm(poster.sample.distanceMeters)
        let elapsed = DisplayFormatter.formatDuration(poster.sample.elapsedSeconds)
        return "\(workout.displayName), \(configuration.appearance.displayName) appearance, \(poster.effectiveRouteColorMode.displayName) route color, midpoint \(distance), elapsed \(elapsed)"
    }
}
