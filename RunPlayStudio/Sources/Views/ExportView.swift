import SwiftUI
import RunPlayCore
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

/// Export menu/button for exporting workout data.
struct ExportView: View {
    let workout: RunWorkout
    let segments: [SegmentHighlight]

    @State private var exportError: String?
    @State private var showingError = false
    @State private var exportSuccess: String?
    @State private var showingSuccess = false

    private let exportService = ExportService()

    var body: some View {
        Menu {
            Button(action: { exportJSON() }) {
                Label("Export Summary (JSON)", systemImage: "doc.text")
            }
            .accessibilityLabel("Export workout summary as JSON")

            Button(action: { exportSplitsCSV() }) {
                Label("Export Splits (CSV)", systemImage: "tablecells")
            }
            .accessibilityLabel("Export kilometer splits as CSV")

            Button(action: { exportSegmentsCSV() }) {
                Label("Export Segments (CSV)", systemImage: "chart.xyaxis.line")
            }
            .accessibilityLabel("Export detected segments as CSV")

            Divider()

            Button(action: { exportPNG() }) {
                Label("Export Summary Card (PNG)", systemImage: "photo")
            }
            .accessibilityLabel("Export summary card as PNG image")

            Divider()

            Button(action: { exportCombinedCSV() }) {
                Label("Export All (CSV)", systemImage: "doc.plaintext")
            }
            .accessibilityLabel("Export all splits and segments as combined CSV")
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

    @MainActor
    private func exportPNG() {
        do {
            let result = try PNGExportService.exportSummaryPNG(workout: workout, segments: segments)
            saveFile(result)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveFile(_ result: ExportResult) {
#if os(macOS)
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
#else
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(result.filename)
        do {
            try result.data.write(to: tempURL)
            let controller = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(controller, animated: true)
            }
            showSuccess("Share sheet opened")
        } catch {
            showError("Failed to export: \(error.localizedDescription)")
        }
#endif
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
