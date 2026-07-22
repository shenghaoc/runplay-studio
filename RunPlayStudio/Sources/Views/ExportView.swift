import SwiftUI
import RunPlayCore
import RunPlayPlatform
import AppKit
import UniformTypeIdentifiers

/// Export menu/button for exporting workout data.
struct ExportView: View {
    let workout: RunWorkout
    let segments: [SegmentHighlight]

    @AppStorage("routeColorMode") private var storedRouteColorMode: String = WorkoutRouteColorMode.solid.rawValue
    @Environment(\.colorScheme) private var colorScheme

    @State private var exportError: String?
    @State private var showingError = false
    @State private var exportSuccess: String?
    @State private var showingSuccess = false
    @State private var pngViewModel: PNGSummaryExportViewModel?

    private let exportService = ExportService()

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
    }

    private func showSuccess(_ message: String) {
        exportSuccess = message
        showingSuccess = true
    }
}
