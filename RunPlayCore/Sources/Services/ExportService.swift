import Foundation

/// Export formats supported by RunPlay Studio (core, platform-neutral).
public enum ExportFormat: String, CaseIterable {
    case json = "JSON Summary"
    case splitsCSV = "Splits CSV"
    case segmentsCSV = "Segments CSV"
    case combinedCSV = "Combined CSV"
    case png = "PNG Summary Card"

    public var fileExtension: String {
        switch self {
        case .json: return "json"
        case .splitsCSV, .segmentsCSV, .combinedCSV: return "csv"
        case .png: return "png"
        }
    }

    public var utType: String {
        switch self {
        case .json: return "public.json"
        case .splitsCSV, .segmentsCSV, .combinedCSV: return "public.comma-separated-values-text"
        case .png: return "public.png"
        }
    }
}

/// Errors that can occur during export.
public enum ExportError: Error, LocalizedError {
    case noData
    case encodingFailed(String)
    case fileWriteFailed(String)
    case renderingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noData: return "No workout data to export"
        case .encodingFailed(let detail): return "Encoding failed: \(detail)"
        case .fileWriteFailed(let detail): return "File write failed: \(detail)"
        case .renderingFailed(let detail): return "Rendering failed: \(detail)"
        }
    }
}

/// Result of an export operation.
public struct ExportResult {
    public let format: ExportFormat
    public let filename: String
    public let data: Data

    public init(format: ExportFormat, filename: String, data: Data) {
        self.format = format
        self.filename = filename
        self.data = data
    }
}

/// Service for exporting workout data to various formats.
public struct ExportService {

    public init() {}

    // MARK: - JSON Export

    /// Export workout summary as JSON.
    public func exportWorkoutSummaryJSON(workout: RunWorkout, segments: [SegmentHighlight]) throws -> ExportResult {
        let summary = WorkoutExportSummary(workout: workout, segments: segments)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(summary)
            let filename = ExportFilenameBuilder.filename(for: workout, format: .json)
            return ExportResult(format: .json, filename: filename, data: data)
        } catch {
            throw ExportError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: - CSV Export

    /// Export splits as CSV.
    public func exportSplitsCSV(workout: RunWorkout) throws -> ExportResult {
        let csv = generateSplitsCSV(workout: workout)
        guard let data = csv.data(using: .utf8) else {
            throw ExportError.encodingFailed("Could not encode CSV as UTF-8")
        }
        let filename = ExportFilenameBuilder.filename(for: workout, format: .splitsCSV)
        return ExportResult(format: .splitsCSV, filename: filename, data: data)
    }

    /// Export segment highlights as CSV.
    public func exportSegmentsCSV(segments: [SegmentHighlight]) throws -> ExportResult {
        let csv = generateSegmentsCSV(segments: segments)
        guard let data = csv.data(using: .utf8) else {
            throw ExportError.encodingFailed("Could not encode CSV as UTF-8")
        }
        let filename = ExportFilenameBuilder.filename(for: nil, format: .segmentsCSV)
        return ExportResult(format: .segmentsCSV, filename: filename, data: data)
    }

    /// Export combined splits and segments as CSV.
    public func exportCombinedCSV(workout: RunWorkout, segments: [SegmentHighlight]) throws -> ExportResult {
        let csv = generateCombinedCSV(workout: workout, segments: segments)
        guard let data = csv.data(using: .utf8) else {
            throw ExportError.encodingFailed("Could not encode CSV as UTF-8")
        }
        let filename = ExportFilenameBuilder.filename(for: workout, format: .combinedCSV)
        return ExportResult(format: .combinedCSV, filename: filename, data: data)
    }

    // MARK: - CSV Generation

    public func generateSplitsCSV(workout: RunWorkout) -> String {
        var lines: [String] = []

        // Header
        lines.append(CSVRow.joined([
            "Split", "Start_km", "End_km", "Distance_km", "Duration",
            "Pace_min_km", "Elevation_Gain_m", "Avg_HR_bpm"
        ]))

        // Data rows
        for split in workout.splits {
            let paceMin = split.paceSecondsPerKilometer / 60.0
            lines.append(CSVRow.joined([
                "\(split.splitIndex)",
                formatNumber(split.startDistanceMeters / 1000),
                formatNumber(split.endDistanceMeters / 1000),
                formatNumber(split.distanceMeters / 1000),
                split.formattedElapsed,
                formatNumber(paceMin),
                split.elevationGainMeters.map { formatNumber($0) } ?? "",
                split.averageHeartRateBPM.map { formatNumber($0) } ?? ""
            ]))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func generateSegmentsCSV(segments: [SegmentHighlight]) -> String {
        var lines: [String] = []

        // Header
        lines.append(CSVRow.joined([
            "Type", "Title", "Start_km", "End_km", "Distance_km",
            "Start_Time_s", "End_Time_s", "Duration",
            "Pace_min_km", "Elevation_Delta_m", "Avg_HR_bpm", "Description"
        ]))

        // Data rows
        for seg in segments {
            let paceMin = (seg.paceSecondsPerKilometer ?? 0) / 60.0
            lines.append(CSVRow.joined([
                seg.type.rawValue,
                seg.title,
                formatNumber(seg.startDistanceMeters / 1000),
                formatNumber(seg.endDistanceMeters / 1000),
                formatNumber(seg.distanceMeters / 1000),
                formatNumber(seg.startElapsedSeconds),
                formatNumber(seg.endElapsedSeconds),
                seg.formattedDuration,
                seg.paceSecondsPerKilometer != nil ? formatNumber(paceMin) : "",
                seg.elevationDeltaMeters.map { formatNumber($0) } ?? "",
                seg.averageHeartRate.map { formatNumber($0) } ?? "",
                seg.subtitle
            ]))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func generateCombinedCSV(workout: RunWorkout, segments: [SegmentHighlight]) -> String {
        var sections: [String] = []

        sections.append("# Splits")
        sections.append(generateSplitsCSV(workout: workout))
        sections.append("")
        sections.append("# Segment Highlights")
        sections.append(generateSegmentsCSV(segments: segments))

        return sections.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e10 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}

// MARK: - CSV Helpers

/// Safe CSV field escaping and joining.
public enum CSVRow {
    /// Escape a field for CSV (quote if it contains commas, quotes, or newlines).
    public static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    /// Join fields into a CSV row.
    public static func joined(_ fields: [String]) -> String {
        fields.map { escape($0) }.joined(separator: ",")
    }
}

// MARK: - Filename Builder

/// Builds safe filenames for exports.
public enum ExportFilenameBuilder {
    public static func filename(for workout: RunWorkout?, format: ExportFormat) -> String {
        let baseName: String
        if let workout = workout {
            baseName = sanitize(workout.displayName)
        } else {
            baseName = "runplay-export"
        }

        let timestamp = formatDateForFilename(Date())
        return "\(baseName)-\(timestamp).\(format.fileExtension)"
    }

    private static func sanitize(_ name: String) -> String {
        // Remove characters not safe for filenames
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_ "))
        let sanitized = name.unicodeScalars.map { char -> Character in
            allowed.contains(char) ? Character(char) : "-"
        }
        return String(sanitized)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(50)
            .lowercased()
    }

    private static func formatDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}
