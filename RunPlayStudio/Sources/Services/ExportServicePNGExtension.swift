import RunPlayCore

/// macOS-only PNG export support.
/// PNG rendering requires AppKit/SwiftUI frameworks not available in RunPlayCore.

struct PNGExportService {

    /// Export workout summary as PNG image (macOS only).
    @MainActor
    static func exportSummaryPNG(workout: RunWorkout, segments: [SegmentHighlight]) throws -> ExportResult {
        let model = ExportSummaryCardModel(workout: workout, segments: segments)
        let view = ExportSummaryCardView(model: model)
        let data = try PNGExportRenderer.renderPNG(from: view)
        let filename = ExportFilenameBuilder.filename(for: workout, format: .png)
        return ExportResult(format: .png, filename: filename, data: data)
    }
}
