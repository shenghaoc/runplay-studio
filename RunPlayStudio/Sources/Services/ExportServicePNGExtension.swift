import RunPlayCore
import AppKit

/// macOS-only PNG export support.
/// PNG rendering requires AppKit/SwiftUI frameworks not available in RunPlayCore.

struct PNGExportService {

    /// Export workout summary as PNG image (macOS only).
    static func exportSummaryPNG(workout: RunWorkout, segments: [SegmentHighlight]) throws -> ExportResult {
        let data = try PNGExportRenderer.renderSummaryCard(workout: workout, segments: segments)
        let filename = ExportFilenameBuilder.filename(for: workout, format: .png)
        return ExportResult(format: .png, filename: filename, data: data)
    }
}
