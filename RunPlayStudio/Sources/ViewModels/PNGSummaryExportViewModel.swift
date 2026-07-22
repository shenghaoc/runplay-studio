import AppKit
import Foundation
import Observation
import RunPlayCore
import RunPlayPlatform
import UniformTypeIdentifiers

/// Owns PNG summary export configuration, preview generation, and save.
@MainActor
@Observable
final class PNGSummaryExportViewModel: Identifiable {
    let id = UUID()

    var configuration: PNGSummaryExportConfiguration {
        didSet {
            if configuration != oldValue {
                schedulePreview()
            }
        }
    }

    private(set) var phase: PNGSummaryExportPhase = .idle
    private(set) var previewData: Data?
    private(set) var previewImage: NSImage?
    private(set) var errorMessage: String?
    private(set) var mapFailureMessage: String?
    private(set) var availability: RouteMetricModeAvailability = .init(
        pace: false,
        heartRate: false,
        correctedElevation: false
    )
    private(set) var hasUsableRoute: Bool = false
    private(set) var isGenerating = false
    private(set) var lastSavedFilename: String?

    private let workout: RunWorkout
    private let segments: [SegmentHighlight]
    private let analysisContext: WorkoutAnalysisContext
    private let mapSnapshotter: any WorkoutMapSnapshotting
    private let profileBuilder: RouteMetricProfileBuilding
    private let lineBuilder: RouteMetricMapLineBuilding

    private var generateTask: Task<Void, Never>?
    private var requestSerial = 0
    private var readyConfiguration: PNGSummaryExportConfiguration?
    private var profileProbe: RouteMetricProfileProbe?

    /// True only when the displayed preview is ready for the current options.
    var canExportCurrentPreview: Bool {
        previewData != nil
            && readyConfiguration == configuration
            && phase == .ready
            && !isGenerating
    }

    init(
        workout: RunWorkout,
        segments: [SegmentHighlight],
        initialConfiguration: PNGSummaryExportConfiguration,
        analysisContext: WorkoutAnalysisContext? = nil,
        mapSnapshotter: any WorkoutMapSnapshotting = CachingWorkoutMapSnapshotter(),
        profileBuilder: RouteMetricProfileBuilding = DefaultRouteMetricProfileBuilder(),
        lineBuilder: RouteMetricMapLineBuilding = DefaultRouteMetricMapLineBuilder()
    ) {
        self.workout = workout
        self.segments = segments
        self.analysisContext = analysisContext ?? WorkoutAnalysisContext(workout: workout)
        self.mapSnapshotter = mapSnapshotter
        self.profileBuilder = profileBuilder
        self.lineBuilder = lineBuilder
        let usable = PNGExportService.hasUsableRoute(workout)
        self.hasUsableRoute = usable
        var config = initialConfiguration
        if !usable {
            config.includeMap = false
        }
        self.configuration = config
    }

    func onAppear() {
        schedulePreview()
    }

    func cancel() {
        generateTask?.cancel()
        generateTask = nil
        requestSerial &+= 1
        isGenerating = false
        if phase != .ready {
            phase = previewData == nil ? .idle : .ready
        }
    }

    func retry() {
        mapFailureMessage = nil
        errorMessage = nil
        schedulePreview()
    }

    func exportWithoutMap() {
        mapFailureMessage = nil
        errorMessage = nil
        configuration.includeMap = false
    }

    func reportSaveFailure(_ message: String) {
        errorMessage = message
        phase = previewData != nil && readyConfiguration == configuration ? .ready : .failed
    }

    /// Save using the last ready preview when configuration is unchanged.
    func save(to url: URL) async throws {
        let data: Data
        if let previewData, readyConfiguration == configuration {
            data = previewData
        } else {
            phase = .saving
            let result = try await generateExportResult()
            data = result.data
            previewData = result.data
            previewImage = NSImage(data: result.data)
            readyConfiguration = configuration
        }

        phase = .saving
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: url, options: .atomic)
        }.value
        lastSavedFilename = url.lastPathComponent
        phase = .ready
    }

    func defaultFilename() -> String {
        ExportFilenameBuilder.filename(for: workout, format: .png)
    }

    func previewAccessibilityLabel() -> String {
        let mapPart = configuration.includeMap && hasUsableRoute ? "map included" : "metrics only"
        return "\(workout.displayName), \(configuration.appearance.displayName) appearance, \(mapPart), \(configuration.routeColorMode.displayName) route color"
    }

    // MARK: - Generation

    private func schedulePreview() {
        generateTask?.cancel()
        requestSerial &+= 1
        let serial = requestSerial
        mapFailureMessage = nil
        errorMessage = nil
        isGenerating = true
        phase = .preparingRoute

        let config = configuration
        generateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.generateExportResult(for: config, serial: serial)
                guard serial == self.requestSerial else { return }
                self.previewData = result.data
                self.previewImage = NSImage(data: result.data)
                self.readyConfiguration = config
                self.phase = .ready
                self.isGenerating = false
                self.mapFailureMessage = nil
                self.errorMessage = nil
            } catch is CancellationError {
                guard serial == self.requestSerial else { return }
                self.isGenerating = false
                if self.previewData != nil {
                    self.phase = .ready
                } else {
                    self.phase = .idle
                }
            } catch let error as WorkoutMapSnapshotError {
                guard serial == self.requestSerial else { return }
                self.isGenerating = false
                self.phase = .failed
                if error == .cancelled {
                    self.phase = self.previewData != nil ? .ready : .idle
                    return
                }
                self.mapFailureMessage = error.localizedDescription
            } catch {
                guard serial == self.requestSerial else { return }
                self.isGenerating = false
                self.phase = .failed
                // Map failures from wrapped errors
                if let snap = error as? WorkoutMapSnapshotError, snap != .cancelled {
                    self.mapFailureMessage = snap.localizedDescription
                } else {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func generateExportResult(
        for configuration: PNGSummaryExportConfiguration? = nil,
        serial: Int? = nil
    ) async throws -> ExportResult {
        let config = configuration ?? self.configuration
        return try await PNGExportService.exportSummaryPNG(
            workout: workout,
            segments: segments,
            configuration: config,
            mapSnapshotter: mapSnapshotter,
            analysisContext: analysisContext,
            profileProbe: profileProbe,
            profileBuilder: profileBuilder,
            lineBuilder: lineBuilder,
            onPhase: { [weak self] phase in
                Task { @MainActor in
                    guard let self else { return }
                    if let serial, serial != self.requestSerial { return }
                    self.phase = phase
                }
            }
        )
    }

    func updateAvailabilityProbe() async {
        let builder = profileBuilder
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
            profileProbe = probe
            availability = probe.availability
        } catch is CancellationError {
            return
        } catch {
            profileProbe = nil
            availability = .init(pace: false, heartRate: false, correctedElevation: false)
        }
    }

    func isModeAvailable(_ mode: WorkoutRouteColorMode) -> Bool {
        availability.isAvailable(mode)
    }

    func unavailableReason(for mode: WorkoutRouteColorMode) -> String? {
        guard !isModeAvailable(mode) else { return nil }
        return mode.unavailableReason
    }
}
