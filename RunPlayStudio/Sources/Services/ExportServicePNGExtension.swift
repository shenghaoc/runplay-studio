import Foundation
import RunPlayCore
import AppKit
import RunPlayCore

/// macOS-only PNG export support.
/// PNG rendering requires AppKit/SwiftUI frameworks not available in RunPlayCore.

struct PNGExportService {

    /// Export workout summary as PNG image (macOS only).
    static func exportSummaryPNG(workout: RunWorkout, segments: [SegmentHighlight]) throws -> ExportResult {
        let data = try PNGExportRenderer.renderSummaryCard(workout: workout, segments: segments)
        let filename = filenamePNG(for: workout)
        return ExportResult(format: .splitsCSV, filename: filename, data: data)
    }

    private static func filenamePNG(for workout: RunWorkout?) -> String {
        let baseName: String
        if let workout = workout {
            // Sanitize name for filename
            let allowed = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "-_ "))
            let sanitized = workout.displayName.unicodeScalars.map { char -> Character in
                allowed.contains(char) ? Character(char) : "-"
            }
            baseName = String(sanitized)
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .prefix(50)
                .lowercased()
        } else {
            baseName = "runplay-export"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())
        return "\(baseName)-\(timestamp).png"
    }
}
