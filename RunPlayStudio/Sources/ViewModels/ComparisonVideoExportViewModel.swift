import AppKit
import Foundation
import Observation
import RunPlayCore
import RunPlayPlatform

protocol ComparisonVideoExportClient: Sendable {
    func prepareMap(
        pair: ComparisonPair,
        configuration: ComparisonVideoExportConfiguration,
        policy: WorkoutVideoExportPolicy
    ) async throws -> ComparisonVideoMapPreparation

    func renderPosterResult(
        pair: ComparisonPair,
        configuration: ComparisonVideoExportConfiguration,
        mapPreparation: ComparisonVideoMapPreparation,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        snapshot: RouteAlignmentSnapshot?,
        policy: WorkoutVideoExportPolicy
    ) throws -> ComparisonVideoPoster

    func export(
        pair: ComparisonPair,
        configuration: ComparisonVideoExportConfiguration,
        destinationURL: URL,
        policy: WorkoutVideoExportPolicy,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        alignmentSeed: ComparisonVideoAlignmentSeed?,
        mapPreparation: ComparisonVideoMapPreparation?,
        progress: @Sendable (WorkoutVideoExportProgress) async -> Void
    ) async throws -> ComparisonVideoExportResult
}

extension ComparisonVideoExporter: ComparisonVideoExportClient {}

/// Owns comparison-video configuration, alignment prep, poster, and offline encode.
@MainActor
@Observable
final class ComparisonVideoExportViewModel: Identifiable {
    let id = UUID()

    /// Immutable pair captured when the sheet opened.
    let pair: ComparisonPair
    private let primaryContext: WorkoutAnalysisContext
    private let comparisonContext: WorkoutAnalysisContext
    private let initialSeed: ComparisonVideoAlignmentSeed?

    var configuration: ComparisonVideoExportConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            handleConfigurationChange(from: oldValue)
        }
    }

    private(set) var phase: ComparisonVideoExportPhase = .idle
    private(set) var progress = WorkoutVideoExportProgress(phase: .idle)
    private(set) var posterImage: NSImage?
    private(set) var posterAccessibilityLabel: String
    private(set) var errorMessage: String?
    private(set) var mapFailureMessage: String?
    private(set) var routeAwareUnavailableReason: RouteAlignmentUnavailableReason?
    private(set) var routeAwareStatusText: String?
    private(set) var isRouteAwareAvailable = false
    private(set) var resolvedSnapshot: RouteAlignmentSnapshot?
    private(set) var isPreparingAlignment = false
    private(set) var isPreparingPoster = false
    private(set) var isExporting = false
    private(set) var isCancelling = false
    private(set) var isPreviewFailure = false
    private(set) var lastExportedFilename: String?

    private let exporter: any ComparisonVideoExportClient
    private let alignmentResolver: ComparisonVideoAlignmentResolver
    private let announcementPolicy: AccessibilityAnnouncementPolicy
    private let policy: WorkoutVideoExportPolicy
    private let posterPolicy: WorkoutVideoExportPolicy

    private var mapPreparation: ComparisonVideoMapPreparation?
    private var mapPreparationTask: Task<ComparisonVideoMapPreparation, Error>?
    private var alignmentTask: Task<Void, Never>?
    private var readyPosterConfiguration: ComparisonVideoExportConfiguration?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var requestSerial = 0
    private var exportSerial = 0
    private var hasAppeared = false

    var canExport: Bool {
        let modeOK = ComparisonVideoExportEligibility.canExport(
            mode: configuration.alignmentMode,
            assessment: currentAssessment
        )
        return modeOK
            && mapPreparation != nil
            && readyPosterConfiguration == configuration
            && mapFailureMessage == nil
            && !isExporting
            && !isPreparingPoster
            && !isPreparingAlignment
    }

    var isBusy: Bool {
        isExporting || isPreparingPoster || isPreparingAlignment
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

    var currentAssessment: ComparisonVideoExportEligibility.Assessment {
        ComparisonVideoExportEligibility.assessment(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            snapshot: resolvedSnapshot
        )
    }

    var alignmentHelpText: String {
        switch configuration.alignmentMode {
        case .distance:
            return "Matches equal cumulative distances."
        case .routeAware:
            if isPreparingAlignment {
                return "Aligning routes…"
            }
            if let reason = routeAwareUnavailableReason {
                return reason.userFacingExplanation
            }
            if let status = routeAwareStatusText {
                return status
            }
            return ComparisonAlignmentMode.routeAware.helpText
        }
    }

    init(
        pair: ComparisonPair,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        initialConfiguration: ComparisonVideoExportConfiguration,
        alignmentSeed: ComparisonVideoAlignmentSeed? = nil,
        exporter: (any ComparisonVideoExportClient)? = nil,
        alignmentResolver: ComparisonVideoAlignmentResolver = ComparisonVideoAlignmentResolver(),
        announcementPolicy: AccessibilityAnnouncementPolicy = AccessibilityAnnouncementPolicy(),
        policy: WorkoutVideoExportPolicy = .production,
        posterPolicy: WorkoutVideoExportPolicy = .poster
    ) {
        self.pair = pair
        self.primaryContext = primaryContext
        self.comparisonContext = comparisonContext
        self.initialSeed = alignmentSeed
        self.configuration = initialConfiguration
        self.alignmentResolver = alignmentResolver
        self.announcementPolicy = announcementPolicy
        self.policy = policy
        self.posterPolicy = posterPolicy
        self.exporter = exporter ?? ComparisonVideoExporter(
            mapPreparer: MapKitComparisonVideoMapPreparer()
        )
        self.posterAccessibilityLabel =
            "\(pair.primary.displayName) vs \(pair.comparison.displayName), preview loading"
        if let seed = alignmentSeed,
           seed.matches(
               pair: pair,
               primaryContext: primaryContext,
               comparisonContext: comparisonContext
           ) {
            applyResolvedSnapshot(seed.snapshot)
        }
    }

    func onAppear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        prepareAlignmentIfNeeded()
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
            alignmentTask?.cancel()
            alignmentTask = nil
            requestSerial &+= 1
            isPreparingPoster = false
            isPreparingAlignment = false
            if phase != .completed {
                phase = posterImage == nil ? .idle : .awaitingDestination
            }
        }
    }

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

    func useDistanceAlignment() {
        guard configuration.alignmentMode != .distance else { return }
        configuration.alignmentMode = .distance
    }

    func dismissCleanup() {
        previewTask?.cancel()
        exportTask?.cancel()
        alignmentTask?.cancel()
        mapPreparationTask?.cancel()
        previewTask = nil
        exportTask = nil
        alignmentTask = nil
        mapPreparationTask = nil
        requestSerial &+= 1
        exportSerial &+= 1
    }

    func defaultFilename() -> String {
        ExportFilenameBuilder.comparisonVideoReplayFilename(
            primary: pair.primary,
            comparison: pair.comparison
        )
    }

    func isAlignmentModeEnabled(_ mode: ComparisonAlignmentMode) -> Bool {
        switch mode {
        case .distance:
            return currentAssessment.canExportDistance
        case .routeAware:
            return isRouteAwareAvailable && !isPreparingAlignment
        }
    }

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
        let snapshot = resolvedSnapshot
        let seed: ComparisonVideoAlignmentSeed?
        if let snapshot {
            seed = ComparisonVideoAlignmentSeed(
                pair: pair,
                primaryContext: primaryContext,
                comparisonContext: comparisonContext,
                snapshot: snapshot
            )
        } else {
            seed = nil
        }
        let exporter = self.exporter
        let policy = self.policy
        let pair = self.pair
        let primaryContext = self.primaryContext
        let comparisonContext = self.comparisonContext

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await exporter.export(
                    pair: pair,
                    configuration: config,
                    destinationURL: url,
                    policy: policy,
                    primaryContext: primaryContext,
                    comparisonContext: comparisonContext,
                    alignmentSeed: seed,
                    mapPreparation: map
                ) { [weak self] progressUpdate in
                    await MainActor.run {
                        guard let self,
                              serial == self.exportSerial,
                              progressUpdate.phase != .completed,
                              !self.isCancelling else { return }
                        self.progress = progressUpdate
                        self.phase = .encoding
                        if progressUpdate.phase == .finalizing {
                            self.phase = .finalizing
                        }
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
                self.announcementPolicy.handle(
                    .comparisonVideoExportCompleted(name: result.filename)
                )
            } catch is CancellationError {
                self.finishCancelledExport(serial: serial)
            } catch let error as ComparisonVideoExportError where error.isCancellation {
                self.finishCancelledExport(serial: serial)
            } catch let error as ComparisonVideoExportError {
                self.finishFailedExport(error, serial: serial)
            } catch {
                self.finishFailedExport(error, serial: serial)
            }
        }

        exportTask = task
        await task.value
    }

    // MARK: - Alignment

    private func prepareAlignmentIfNeeded() {
        if configuration.alignmentMode == .distance {
            // Still warm Route-Aware in the background so the control can enable.
            if resolvedSnapshot == nil, !isPreparingAlignment {
                scheduleAlignmentResolution()
            }
            return
        }
        scheduleAlignmentResolution()
    }

    private func scheduleAlignmentResolution() {
        alignmentTask?.cancel()
        isPreparingAlignment = true
        if configuration.alignmentMode == .routeAware {
            phase = .preparingAlignment
        }
        let pair = self.pair
        let primaryContext = self.primaryContext
        let comparisonContext = self.comparisonContext
        let seed = initialSeed
        let resolver = alignmentResolver
        let serial = requestSerial

        alignmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolution = try await Task.detached(priority: .userInitiated) {
                    try resolver.resolve(
                        pair: pair,
                        primaryContext: primaryContext,
                        comparisonContext: comparisonContext,
                        desiredMode: .routeAware,
                        seed: seed,
                        isCancelled: { Task.isCancelled }
                    )
                }.value
                guard serial == self.requestSerial || self.hasAppeared else { return }
                self.isPreparingAlignment = false
                switch resolution {
                case .routeAware(let snapshot):
                    self.applyResolvedSnapshot(snapshot)
                    if self.configuration.alignmentMode == .routeAware {
                        self.schedulePosterPreview(forceMapRefresh: false)
                    }
                case .unavailable(let reason):
                    self.isRouteAwareAvailable = false
                    self.routeAwareUnavailableReason = reason
                    self.routeAwareStatusText = reason.userFacingExplanation
                    self.resolvedSnapshot = nil
                    if self.configuration.alignmentMode == .routeAware {
                        self.phase = .alignmentUnavailable
                        self.announcementPolicy.handle(.comparisonVideoRouteAwareUnavailable)
                    }
                case .distanceOnly:
                    self.isRouteAwareAvailable = false
                }
            } catch is CancellationError {
                self.isPreparingAlignment = false
            } catch let error as ComparisonVideoExportError where error.isCancellation {
                self.isPreparingAlignment = false
            } catch {
                self.isPreparingAlignment = false
                self.isRouteAwareAvailable = false
                self.routeAwareUnavailableReason = .algorithmFailure
                self.routeAwareStatusText =
                    RouteAlignmentUnavailableReason.algorithmFailure.userFacingExplanation
                if self.configuration.alignmentMode == .routeAware {
                    self.phase = .alignmentUnavailable
                    self.announcementPolicy.handle(.comparisonVideoRouteAwareUnavailable)
                }
            }
        }
    }

    private func applyResolvedSnapshot(_ snapshot: RouteAlignmentSnapshot) {
        resolvedSnapshot = snapshot
        let assessment = ComparisonVideoExportEligibility.assessment(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            snapshot: snapshot
        )
        isRouteAwareAvailable = assessment.canExportRouteAware
        if assessment.canExportRouteAware {
            routeAwareUnavailableReason = nil
            if case .available(let quality) = snapshot.availability {
                routeAwareStatusText =
                    "\(quality.displayName) · \(snapshot.diagnostics.compactStatusLabel)"
            } else {
                routeAwareStatusText = snapshot.diagnostics.compactStatusLabel
            }
        } else {
            routeAwareUnavailableReason = assessment.routeAwareUnavailableReason
            routeAwareStatusText = assessment.routeAwareUnavailableHelp
        }
    }

    // MARK: - Poster

    private func handleConfigurationChange(from old: ComparisonVideoExportConfiguration) {
        guard hasAppeared else { return }
        let appearanceChanged = configuration.appearance != old.appearance
        let alignmentChanged = configuration.alignmentMode != old.alignmentMode
        let durationOnly = configuration.duration != old.duration
            && !appearanceChanged
            && !alignmentChanged

        if alignmentChanged {
            if configuration.alignmentMode == .routeAware {
                if !isRouteAwareAvailable {
                    if resolvedSnapshot == nil {
                        prepareAlignmentIfNeeded()
                    } else {
                        phase = .alignmentUnavailable
                    }
                }
            }
            readyPosterConfiguration = nil
            schedulePosterPreview(forceMapRefresh: false)
        } else if appearanceChanged {
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
        if configuration.alignmentMode == .routeAware, !isRouteAwareAvailable {
            if isPreparingAlignment {
                phase = .preparingAlignment
            } else {
                phase = .alignmentUnavailable
            }
            return
        }

        previewTask?.cancel()
        if forceMapRefresh {
            mapPreparationTask?.cancel()
            mapPreparationTask = nil
        }
        requestSerial &+= 1
        let serial = requestSerial
        errorMessage = nil
        isPreviewFailure = false
        isPreparingPoster = true
        phase = mapPreparation == nil || forceMapRefresh ? .loadingMap : .renderingPoster

        let config = configuration
        let pair = self.pair
        let primaryContext = self.primaryContext
        let comparisonContext = self.comparisonContext
        let posterPolicy = self.posterPolicy
        let policy = self.policy
        let exporter = self.exporter
        let existingMap = forceMapRefresh ? nil : mapPreparation
        let snapshot = resolvedSnapshot

        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let map: ComparisonVideoMapPreparation
                if let existingMap {
                    map = existingMap
                } else {
                    let prepared = try await exporter.prepareMap(
                        pair: pair,
                        configuration: config,
                        policy: policy
                    )
                    try Task.checkCancellation()
                    guard serial == self.requestSerial else { return }
                    self.mapPreparation = prepared
                    map = prepared
                }

                guard serial == self.requestSerial else { return }
                self.phase = .renderingPoster
                let poster = try exporter.renderPosterResult(
                    pair: pair,
                    configuration: config,
                    mapPreparation: map,
                    primaryContext: primaryContext,
                    comparisonContext: comparisonContext,
                    snapshot: snapshot,
                    policy: posterPolicy
                )
                try Task.checkCancellation()
                guard serial == self.requestSerial else { return }

                self.posterImage = NSImage(
                    cgImage: poster.image,
                    size: NSSize(width: poster.image.width, height: poster.image.height)
                )
                self.posterAccessibilityLabel = self.makePosterAccessibilityLabel(poster)
                self.readyPosterConfiguration = config
                self.mapFailureMessage = nil
                self.isPreparingPoster = false
                self.phase = .awaitingDestination
                self.announcementPolicy.handle(.comparisonVideoPreviewReady)
            } catch is CancellationError {
                if serial == self.requestSerial {
                    self.isPreparingPoster = false
                }
            } catch let error as ComparisonVideoExportError where error.isCancellation {
                if serial == self.requestSerial {
                    self.isPreparingPoster = false
                }
            } catch let error as ComparisonVideoExportError {
                guard serial == self.requestSerial else { return }
                self.isPreparingPoster = false
                self.isPreviewFailure = true
                self.errorMessage = error.localizedDescription
                if case .mapPreparationFailed = error {
                    self.mapFailureMessage = error.localizedDescription
                    self.phase = .failed
                } else {
                    self.phase = .failed
                }
                self.announcementPolicy.handle(
                    .comparisonVideoExportFailed(message: error.localizedDescription)
                )
            } catch {
                guard serial == self.requestSerial else { return }
                self.isPreparingPoster = false
                self.isPreviewFailure = true
                self.errorMessage = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    private func makePosterAccessibilityLabel(_ poster: ComparisonVideoPoster) -> String {
        let sample = poster.sample
        var parts: [String] = [
            "\(pair.primary.displayName) versus \(pair.comparison.displayName)",
            "\(sample.alignmentMode.displayName) alignment",
            "Midpoint \(DisplayFormatter.formatDistanceKm(sample.domainPositionMeters)) of \(DisplayFormatter.formatDistanceKm(sample.domainLengthMeters))",
            "Primary distance \(DisplayFormatter.formatDistanceKm(sample.primaryDistanceMeters))",
            "Comparison distance \(DisplayFormatter.formatDistanceKm(sample.comparisonDistanceMeters))",
        ]
        if let elapsed = sample.elapsedDeltaSeconds {
            parts.append("Elapsed delta \(DisplayFormatter.formatSignedDurationDelta(elapsed, positiveLabel: "longer", negativeLabel: "shorter"))")
        }
        if let active = sample.activeDeltaSeconds {
            parts.append("Active delta \(DisplayFormatter.formatSignedDurationDelta(active, positiveLabel: "longer", negativeLabel: "shorter"))")
        }
        if let pace = sample.activePaceDeltaSecondsPerKm {
            parts.append("Pace delta \(DisplayFormatter.formatSignedDurationDelta(pace, suffix: "/km"))")
        }
        if let separation = sample.spatialSeparationMeters {
            parts.append("Separation \(Int(separation.rounded())) meters")
        }
        return parts.joined(separator: ". ")
    }

    private func finishCancelledExport(serial: Int) {
        guard serial == exportSerial else { return }
        isExporting = false
        isCancelling = false
        exportTask = nil
        phase = .cancelled
        progress = WorkoutVideoExportProgress(
            phase: .cancelled,
            completedFrames: progress.completedFrames,
            totalFrames: progress.totalFrames
        )
        announcementPolicy.handle(.comparisonVideoExportCancelled)
    }

    private func finishFailedExport(_ error: Error, serial: Int) {
        guard serial == exportSerial else { return }
        isExporting = false
        isCancelling = false
        exportTask = nil
        phase = .failed
        errorMessage = error.localizedDescription
        announcementPolicy.handle(
            .comparisonVideoExportFailed(message: error.localizedDescription)
        )
    }
}
