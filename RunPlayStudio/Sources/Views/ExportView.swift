import SwiftUI
import RunPlayCore
import RunPlayPlatform
import AppKit
import UniformTypeIdentifiers

/// Export menu/button for exporting workout data.
struct ExportView: View {
    let workout: RunWorkout
    let segments: [SegmentHighlight]
    let analysisContext: WorkoutAnalysisContext?

    @AppStorage("routeColorMode") private var storedRouteColorMode: String = WorkoutRouteColorMode.solid.rawValue
    @Environment(\.colorScheme) private var colorScheme

    @State private var exportError: String?
    @State private var showingError = false
    @State private var exportSuccess: String?
    @State private var showingSuccess = false
    @State private var pngViewModel: PNGSummaryExportViewModel?
    @State private var videoViewModel: WorkoutVideoExportViewModel?
    @State private var announcementPolicy = AccessibilityAnnouncementPolicy()
    @State private var videoEligibility: VideoEligibilitySnapshot?

    private let exportService = ExportService()

    private var canExportVideo: Bool {
        videoEligibility?.key == videoEligibilityKey
            && videoEligibility?.assessment.canExport == true
    }

    var body: some View {
        Menu {
            Button(action: { exportJSON() }) {
                Label("Export Summary (JSON)", systemImage: "doc.text")
            }
            .accessibilityLabel("Export workout summary as JSON")

            Button(action: { exportSplitsCSV() }) {
                Label("Export Distance Splits (CSV)", systemImage: "tablecells")
            }
            .accessibilityLabel("Export calculated kilometer splits as CSV")

            if !workout.recordedLaps.isEmpty {
                Button(action: { exportRecordedLapsCSV() }) {
                    Label("Export Recorded Laps (CSV)", systemImage: "flag.checkered")
                }
                .accessibilityLabel("Export source-recorded laps as CSV")
            }

            Button(action: { exportSegmentsCSV() }) {
                Label("Export Segments (CSV)", systemImage: "chart.xyaxis.line")
            }
            .accessibilityLabel("Export detected segments as CSV")

            Divider()

            Button(action: { openPNGSheet() }) {
                Label("Export Summary Card (PNG)", systemImage: "photo")
            }
            .accessibilityLabel("Export summary card as PNG image")

            Button(action: { openVideoSheet() }) {
                Label("Export Route Replay (MP4)", systemImage: "square.stack.3d.down.right")
            }
            .disabled(!canExportVideo)
            .help(videoExportHelp)
            .accessibilityLabel("Export route replay as MP4 video")
            .accessibilityHint(canExportVideo
                ? "Opens options for offline H.264 route replay export"
                : videoExportHelp)

            Divider()

            Button(action: { exportCombinedCSV() }) {
                Label("Export All (CSV)", systemImage: "doc.plaintext")
            }
            .accessibilityLabel("Export distance splits, recorded laps, and segments as combined CSV")
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .alert("Export Failed", isPresented: $showingError) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "An unknown error occurred while exporting.")
        }
        .alert("Export Complete", isPresented: $showingSuccess) {
            Button("OK") { exportSuccess = nil }
        } message: {
            Text(exportSuccess ?? "")
        }
        .sheet(item: $pngViewModel) { viewModel in
            PNGSummaryExportSheet(
                viewModel: viewModel,
                onDismiss: {
                    pngViewModel = nil
                },
                onSaved: { filename in
                    showSuccess("Saved to \(filename)")
                }
            )
        }
        .sheet(item: $videoViewModel) { viewModel in
            WorkoutVideoExportSheet(
                viewModel: viewModel,
                onDismiss: {
                    videoViewModel = nil
                },
                onExported: { filename in
                    showSuccess("Saved to \(filename)", announce: false)
                }
            )
        }
        .blocksBackgroundCommands(
            showingError || showingSuccess || pngViewModel != nil || videoViewModel != nil
        )
        .task(id: videoEligibilityKey) {
            videoEligibility = nil
            let key = videoEligibilityKey
            let workout = workout
            let assessment = await Task.detached(priority: .userInitiated) {
                WorkoutVideoExportEligibility.assessment(for: workout)
            }.value
            guard !Task.isCancelled, key == videoEligibilityKey else { return }
            videoEligibility = VideoEligibilitySnapshot(
                key: key,
                assessment: assessment
            )
        }
    }

    private var videoExportHelp: String {
        guard videoEligibility?.key == videoEligibilityKey else {
            return "Checking whether this workout can be exported as video."
        }
        if let unavailableHelp = videoEligibility?.assessment.unavailableHelp {
            return unavailableHelp
        }
        return "Export a deterministic offline H.264 MP4 of this route replay."
    }

    private var videoEligibilityKey: VideoEligibilityKey {
        VideoEligibilityKey(
            workoutID: workout.id,
            normalizationVersion: workout.normalizationVersion,
            routePointCount: workout.routePoints.count,
            firstPointID: workout.routePoints.first?.id,
            lastPointID: workout.routePoints.last?.id
        )
    }

    private func openPNGSheet() {
        let routeMode = WorkoutRouteColorMode(rawValue: storedRouteColorMode) ?? .solid
        let appearance: PNGSummaryExportAppearance = colorScheme == .dark ? .dark : .light
        let includeMap = PNGExportService.hasUsableRoute(workout)
        let configuration = PNGSummaryExportConfiguration(
            includeMap: includeMap,
            appearance: appearance,
            routeColorMode: routeMode
        )
        pngViewModel = PNGSummaryExportViewModel(
            workout: workout,
            segments: segments,
            initialConfiguration: configuration
        )
    }

    private func openVideoSheet() {
        guard canExportVideo else { return }
        let routeMode = WorkoutRouteColorMode(rawValue: storedRouteColorMode) ?? .solid
        let appearance: PNGSummaryExportAppearance = colorScheme == .dark ? .dark : .light
        let configuration = WorkoutVideoExportConfiguration(
            duration: .thirtySeconds,
            appearance: appearance,
            routeColorMode: routeMode
        )
        videoViewModel = WorkoutVideoExportViewModel(
            workout: workout,
            initialConfiguration: configuration,
            analysisContext: analysisContext
        )
    }

    private func exportJSON() {
        do {
            let result = try exportService.exportWorkoutSummaryJSON(workout: workout, segments: segments)
            saveFile(result)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportSplitsCSV() {
        do {
            let result = try exportService.exportSplitsCSV(workout: workout)
            saveFile(result)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportRecordedLapsCSV() {
        do {
            let result = try exportService.exportRecordedLapsCSV(workout: workout)
            saveFile(result)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportSegmentsCSV() {
        do {
            let result = try exportService.exportSegmentsCSV(segments: segments)
            saveFile(result)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportCombinedCSV() {
        do {
            let result = try exportService.exportCombinedCSV(workout: workout, segments: segments)
            saveFile(result)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveFile(_ result: ExportResult) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = result.filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(result.format.utType) {
            panel.allowedContentTypes = [type]
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try result.data.write(to: url)
                    showSuccess("Saved to \(url.lastPathComponent)")
                } catch {
                    showError("Failed to save: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showError(_ message: String) {
        exportError = "Export failed: \(message). Try choosing a different location or format."
        showingError = true
        announcementPolicy.handle(.exportFailed(message: message))
    }

    private func showSuccess(_ message: String, announce: Bool = true) {
        exportSuccess = message
        showingSuccess = true
        guard announce else { return }
        let filename = message.hasPrefix("Saved to ")
            ? String(message.dropFirst("Saved to ".count))
            : message
        announcementPolicy.handle(.exportCompleted(name: filename))
    }
}

private struct VideoEligibilityKey: Hashable {
    let workoutID: UUID
    let normalizationVersion: Int
    let routePointCount: Int
    let firstPointID: UUID?
    let lastPointID: UUID?
}

private struct VideoEligibilitySnapshot {
    let key: VideoEligibilityKey
    let assessment: WorkoutVideoExportEligibility.Assessment
}
