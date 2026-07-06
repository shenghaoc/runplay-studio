import SwiftUI
import RunPlayCore
import AppKit
import RunPlayCore

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

            Button(action: { exportSplitsCSV() }) {
                Label("Export Splits (CSV)", systemImage: "tablecells")
            }

            Button(action: { exportSegmentsCSV() }) {
                Label("Export Segments (CSV)", systemImage: "chart.xyaxis.line")
            }

            Divider()

            Button(action: { exportPNG() }) {
                Label("Export Summary Card (PNG)", systemImage: "photo")
            }

            Divider()

            Button(action: { exportCombinedCSV() }) {
                Label("Export All (CSV)", systemImage: "doc.plaintext")
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .alert("Export Error", isPresented: $showingError) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown error")
        }
        .alert("Export Successful", isPresented: $showingSuccess) {
            Button("OK") { exportSuccess = nil }
        } message: {
            Text(exportSuccess ?? "")
        }
    }

    private func exportJSON() {
        do {
            let result = try exportService.exportWorkoutSummaryJSON(workout: workout, segments: segments)
            saveFile(data: result.data, filename: result.filename)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportSplitsCSV() {
        do {
            let result = try exportService.exportSplitsCSV(workout: workout)
            saveFile(data: result.data, filename: result.filename)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportSegmentsCSV() {
        do {
            let result = try exportService.exportSegmentsCSV(segments: segments)
            saveFile(data: result.data, filename: result.filename)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportCombinedCSV() {
        do {
            let result = try exportService.exportCombinedCSV(workout: workout, segments: segments)
            saveFile(data: result.data, filename: result.filename)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func exportPNG() {
        do {
            let result = try PNGExportService.exportSummaryPNG(workout: workout, segments: segments)
            saveFile(data: result.data, filename: result.filename)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveFile(data: Data, filename: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url)
                    showSuccess("Saved to \(url.lastPathComponent)")
                } catch {
                    showError("Failed to save: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showError(_ message: String) {
        exportError = message
        showingError = true
    }

    private func showSuccess(_ message: String) {
        exportSuccess = message
        showingSuccess = true
    }
}
