import AppKit
import Foundation
import Observation
import RunPlayCore
import RunPlayPlatform

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
    private(set) var errorMessage: String?
    private(set) var mapFailureMessage: String?
    private(set) var availability = RouteMetricModeAvailability(
        pace: false,
        heartRate: false,
        correctedElevation: false
    )
    private(set) var isPreparingPoster = false
    private(set) var isExporting = false
    private(set) var lastExportedFilename: String?

    private let workout: RunWorkout
    private let analysisContext: WorkoutAnalysisContext
    private let exporter: WorkoutVideoExporter
    private let announcementPolicy: AccessibilityAnnouncementPolicy
    private let policy: WorkoutVideoExportPolicy
    private let posterPolicy: WorkoutVideoExportPolicy

    private var mapPreparation: WorkoutVideoMapPreparation?
    private var mapKey: MapPreparationKey?
    private var readyPosterKey: PosterKey?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var requestSerial = 0
    private var exportSerial = 0

    var canExport: Bool {
        mapPreparation != nil
            && mapFailureMessage == nil
            && !isExporting
            && !isPreparingPoster
            && phase != .failed
    }

    var isBusy: Bool {
        isExporting || isPreparingPoster
    }

    init(
        workout: RunWorkout,
        initialConfiguration: WorkoutVideoExportConfiguration,
        analysisContext: WorkoutAnalysisContext? = nil,
        exporter: WorkoutVideoExporter? = nil,
        announcementPolicy: AccessibilityAnnouncementPolicy = AccessibilityAnnouncementPolicy(),
        policy: WorkoutVideoExportPolicy = .production,
        posterPolicy: WorkoutVideoExportPolicy = .poster
    ) {
        self.workout = workout
        self.analysisContext = analysisContext ?? WorkoutAnalysisContext(workout: workout)
        self.configuration = initialConfiguration
        self.announcementPolicy = announcementPolicy
        self.policy = policy
        self.posterPolicy = posterPolicy
        self.exporter = exporter ?? WorkoutVideoExporter(
            mapPreparer: MapKitWorkoutVideoMapPreparer()
        )
    }

    func onAppear() {
        schedulePosterPreview()
    }

    func cancel() {
        previewTask?.cancel()
        previewTask = nil
        if isExporting {
            cancelExport()
        } else {
            requestSerial &+= 1
            isPreparingPoster = false
            if phase != .completed {
                phase = posterImage == nil ? .idle : .renderingPoster
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportSerial &+= 1
        isExporting = false
        phase = .cancelled
        progress = WorkoutVideoExportProgress(phase: .cancelled)
        announcementPolicy.handle(.videoExportCancelled)
    }

    func retryMap() {
        mapFailureMessage = nil
        errorMessage = nil
        mapPreparation = nil
        mapKey = nil
        schedulePosterPreview(forceMapRefresh: true)
    }

    func dismissCleanup() {
        previewTask?.cancel()
        exportTask?.cancel()
        previewTask = nil
        exportTask = nil
        requestSerial &+= 1
        exportSerial &+= 1
    }

    func defaultFilename() -> String {
        ExportFilenameBuilder.videoReplayFilename(for: workout)
    }

    func posterAccessibilityLabel() -> String {
        let distance: String
        let elapsed: String
        if let mapPreparation,
           let sample = try? midpointSample(using: mapPreparation) {
            distance = DisplayFormatter.formatDistanceKm(sample.distanceMeters)
            elapsed = DisplayFormatter.formatDuration(sample.elapsedSeconds)
        } else {
            distance = "—"
            elapsed = "—"
        }
        return "\(workout.displayName), \(configuration.appearance.displayName) appearance, \(configuration.routeColorMode.displayName) route color, midpoint \(distance), elapsed \(elapsed)"
    }

    func isModeAvailable(_ mode: WorkoutRouteColorMode) -> Bool {
        availability.isAvailable(mode)
    }

    func unavailableReason(for mode: WorkoutRouteColorMode) -> String? {
        guard !isModeAvailable(mode) else { return nil }
        return mode.unavailableReason
    }

    func updateAvailabilityProbe() async {
        let builder = RouteMetricProfileBuilder()
        let workout = self.workout
        let context = analysisContext
        let probeTask = Task.detached(priority: .utility) {
            try builder.probe(
                routePoints: workout.routePoints,
                context: context,
                policy: .runningDefault,
                isCancelled: { Task.isCancelled }
            )
        }
        do {
            let probe = try await withTaskCancellationHandler {
                try await probeTask.value
            } onCancel: {
                probeTask.cancel()
            }
            try Task.checkCancellation()
            availability = probe.availability
            // Snap invalid selection to solid.
            if !availability.isAvailable(configuration.routeColorMode),
               configuration.routeColorMode != .solid {
                configuration.routeColorMode = .solid
            }
        } catch is CancellationError {
            return
        } catch {
            availability = .init(pace: false, heartRate: false, correctedElevation: false)
        }
    }

    /// Encode to the chosen destination URL.
    func export(to url: URL) async {
        guard !isExporting else { return }
        errorMessage = nil
        mapFailureMessage = nil
        exportTask?.cancel()
        exportSerial &+= 1
        let serial = exportSerial
        isExporting = true
        phase = .encoding
        progress = WorkoutVideoExportProgress(phase: .encoding)

        let config = configuration
        let map = mapPreparation
        let exporter = self.exporter
        let policy = self.policy
        let workout = self.workout

        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared: WorkoutVideoMapPreparation
                if let map {
                    prepared = map
                } else {
                    await MainActor.run {
                        guard serial == self.exportSerial else { return }
                        self.phase = .loadingMap
                    }
                    prepared = try await exporter.prepareMap(
                        workout: workout,
                        configuration: config,
                        policy: policy,
                        analysisContext: self.analysisContext
                    )
                    guard serial == self.exportSerial else { return }
                    await MainActor.run {
                        self.mapPreparation = prepared
                        self.mapKey = MapPreparationKey(configuration: config, policy: policy)
                    }
                }

                let result = try await exporter.export(
                    workout: workout,
                    configuration: config,
                    destinationURL: url,
                    policy: policy,
                    mapPreparation: prepared
                ) { [weak self] progressUpdate in
                    await MainActor.run {
                        guard let self, serial == self.exportSerial else { return }
                        self.progress = progressUpdate
                        self.phase = progressUpdate.phase
                    }
                }

                guard serial == self.exportSerial else { return }
                self.isExporting = false
                self.lastExportedFilename = result.filename
                self.phase = .completed
                self.progress = WorkoutVideoExportProgress(
                    phase: .completed,
                    completedFrames: result.frameCount,
                    totalFrames: result.frameCount
                )
                self.announcementPolicy.handle(.videoExportCompleted(name: result.filename))
            } catch is CancellationError {
                guard serial == self.exportSerial else { return }
                self.isExporting = false
                self.phase = .cancelled
                self.progress = WorkoutVideoExportProgress(phase: .cancelled)
                self.announcementPolicy.handle(.videoExportCancelled)
            } catch let error as WorkoutVideoExportError where error.isCancellation {
                guard serial == self.exportSerial else { return }
                self.isExporting = false
                self.phase = .cancelled
                self.progress = WorkoutVideoExportProgress(phase: .cancelled)
                self.announcementPolicy.handle(.videoExportCancelled)
            } catch let error as WorkoutVideoExportError {
                guard serial == self.exportSerial else { return }
                self.isExporting = false
                self.phase = .failed
                if case .mapPreparationFailed(let detail) = error {
                    self.mapFailureMessage = detail
                } else {
                    self.errorMessage = error.localizedDescription
                }
                self.announcementPolicy.handle(
                    .videoExportFailed(message: error.localizedDescription)
                )
            } catch {
                guard serial == self.exportSerial else { return }
                self.isExporting = false
                self.phase = .failed
                self.errorMessage = error.localizedDescription
                self.announcementPolicy.handle(
                    .videoExportFailed(message: error.localizedDescription)
                )
            }
        }

        await exportTask?.value
    }

    // MARK: - Poster

    private func handleConfigurationChange(from old: WorkoutVideoExportConfiguration) {
        let appearanceChanged = configuration.appearance != old.appearance
        let colorChanged = configuration.routeColorMode != old.routeColorMode
        let durationOnly = configuration.duration != old.duration
            && !appearanceChanged
            && !colorChanged

        if appearanceChanged || colorChanged {
            mapPreparation = nil
            mapKey = nil
            schedulePosterPreview(forceMapRefresh: true)
        } else if durationOnly {
            // Duration must not re-request MapKit; rebuild poster from cached map.
            schedulePosterPreview(forceMapRefresh: false)
        }
    }

    private func schedulePosterPreview(forceMapRefresh: Bool = false) {
        previewTask?.cancel()
        requestSerial &+= 1
        let serial = requestSerial
        errorMessage = nil
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
        let context = analysisContext
        let existingMap = forceMapRefresh ? nil : mapPreparation

        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let map: WorkoutVideoMapPreparation
                if let existingMap {
                    map = existingMap
                } else {
                    await MainActor.run {
                        guard serial == self.requestSerial else { return }
                        self.phase = .preparingRoute
                    }
                    map = try await exporter.prepareMap(
                        workout: workout,
                        configuration: config,
                        policy: policy,
                        analysisContext: context
                    )
                    guard serial == self.requestSerial else { return }
                    await MainActor.run {
                        self.mapPreparation = map
                        self.mapKey = MapPreparationKey(configuration: config, policy: policy)
                        self.phase = .renderingPoster
                    }
                }

                try Task.checkCancellation()
                let image = try await Task.detached(priority: .userInitiated) {
                    try exporter.renderPoster(
                        workout: workout,
                        configuration: config,
                        mapPreparation: map,
                        policy: posterPolicy
                    )
                }.value

                guard serial == self.requestSerial else { return }
                self.posterImage = NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                )
                self.readyPosterKey = PosterKey(configuration: config)
                self.isPreparingPoster = false
                self.phase = .awaitingDestination
                self.mapFailureMessage = nil
                self.announcementPolicy.handle(.videoPreviewReady)
            } catch is CancellationError {
                guard serial == self.requestSerial else { return }
                self.isPreparingPoster = false
                if self.posterImage != nil {
                    self.phase = .awaitingDestination
                } else {
                    self.phase = .idle
                }
            } catch let error as WorkoutVideoExportError where error.isCancellation {
                guard serial == self.requestSerial else { return }
                self.isPreparingPoster = false
                self.phase = self.posterImage != nil ? .awaitingDestination : .idle
            } catch let error as WorkoutVideoExportError {
                guard serial == self.requestSerial else { return }
                self.isPreparingPoster = false
                self.phase = .failed
                if case .mapPreparationFailed(let detail) = error {
                    self.mapFailureMessage = detail
                } else {
                    self.errorMessage = error.localizedDescription
                }
                self.announcementPolicy.handle(
                    .videoExportFailed(message: error.localizedDescription)
                )
            } catch {
                guard serial == self.requestSerial else { return }
                self.isPreparingPoster = false
                self.phase = .failed
                self.errorMessage = error.localizedDescription
                self.announcementPolicy.handle(
                    .videoExportFailed(message: error.localizedDescription)
                )
            }
        }
    }

    private func midpointSample(
        using map: WorkoutVideoMapPreparation
    ) throws -> WorkoutVideoFrameSample {
        let sampler = WorkoutVideoReplaySampler(workout: workout, analysisContext: analysisContext)
        let plan = try WorkoutVideoFramePlan.make(
            duration: configuration.duration,
            policy: posterPolicy,
            sourceTotalElapsedSeconds: sampler.totalElapsedSeconds
        )
        return sampler.sample(frameIndex: plan.frameCount / 2, plan: plan)
    }

    // MARK: - Keys

    private struct MapPreparationKey: Hashable {
        let appearance: PNGSummaryExportAppearance
        let routeColorMode: WorkoutRouteColorMode
        let width: Int
        let height: Int

        init(configuration: WorkoutVideoExportConfiguration, policy: WorkoutVideoExportPolicy) {
            self.appearance = configuration.appearance
            self.routeColorMode = configuration.routeColorMode
            self.width = policy.width
            self.height = policy.height
        }
    }

    private struct PosterKey: Hashable {
        let duration: WorkoutVideoDuration
        let appearance: PNGSummaryExportAppearance
        let routeColorMode: WorkoutRouteColorMode

        init(configuration: WorkoutVideoExportConfiguration) {
            self.duration = configuration.duration
            self.appearance = configuration.appearance
            self.routeColorMode = configuration.routeColorMode
        }
    }
}
