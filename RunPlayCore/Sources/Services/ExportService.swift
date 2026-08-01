import Foundation

/// Export formats supported by RunPlay Studio (core, platform-neutral).
public enum ExportFormat: String, CaseIterable, Sendable {
    case json = "JSON Summary"
    case splitsCSV = "Splits CSV"
    case recordedLapsCSV = "Recorded Laps CSV"
    case segmentsCSV = "Segments CSV"
    case combinedCSV = "Combined CSV"
    case png = "PNG Summary Card"

    public var fileExtension: String {
        switch self {
        case .json: return "json"
        case .splitsCSV, .recordedLapsCSV, .segmentsCSV, .combinedCSV: return "csv"
        case .png: return "png"
        }
    }

    public var utType: String {
        switch self {
        case .json: return "public.json"
        case .splitsCSV, .recordedLapsCSV, .segmentsCSV, .combinedCSV:
            return "public.comma-separated-values-text"
        case .png: return "public.png"
        }
    }
}

/// Errors that can occur during export.
public enum ExportError: Error, LocalizedError, Sendable {
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
public struct ExportResult: Sendable {
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
public struct ExportService: Sendable {

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

    /// Export calculated distance splits as CSV.
    public func exportSplitsCSV(workout: RunWorkout) throws -> ExportResult {
        let csv = generateSplitsCSV(workout: workout)
        guard let data = csv.data(using: .utf8) else {
            throw ExportError.encodingFailed("Could not encode CSV as UTF-8")
        }
        let filename = ExportFilenameBuilder.filename(for: workout, format: .splitsCSV)
        return ExportResult(format: .splitsCSV, filename: filename, data: data)
    }

    /// Export source-recorded laps as CSV. Distinct from calculated splits.
    public func exportRecordedLapsCSV(workout: RunWorkout) throws -> ExportResult {
        let csv = generateRecordedLapsCSV(workout: workout)
        guard let data = csv.data(using: .utf8) else {
            throw ExportError.encodingFailed("Could not encode CSV as UTF-8")
        }
        let filename = ExportFilenameBuilder.filename(
            for: workout,
            format: .recordedLapsCSV,
            suffix: "recorded-laps"
        )
        return ExportResult(format: .recordedLapsCSV, filename: filename, data: data)
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

    /// Export combined distance splits, recorded laps (when present), and segments as CSV.
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
            "Split", "Start_km", "End_km", "Distance_km",
            "Elapsed_Duration_s", "Active_Duration_s",
            "Moving_Duration_Estimated_s", "Stopped_Duration_Estimated_s",
            "Moving_Pace_Estimated_min_km",
            "Active_Pace_min_km", "Elapsed_Pace_min_km",
            "Corrected_Elevation_Gain_m", "Avg_HR_bpm"
        ]))

        // Data rows
        for split in workout.splits {
            lines.append(CSVRow.joined([
                "\(split.splitIndex)",
                formatNumber(split.startDistanceMeters / 1000),
                formatNumber(split.endDistanceMeters / 1000),
                formatNumber(split.distanceMeters / 1000),
                formatNumber(split.elapsedSeconds),
                formatNumber(split.activeSeconds),
                formatNumber(split.movingSeconds),
                formatNumber(split.stoppedSeconds),
                formatNumber(split.movingPaceSecondsPerKilometer / 60),
                formatNumber(split.paceSecondsPerKilometer / 60),
                formatNumber(split.elapsedPaceSecondsPerKilometer / 60),
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
            "Start_Elapsed_s", "End_Elapsed_s", "Active_Duration_s", "Elapsed_Duration_s",
            "Active_Pace_min_km", "Elevation_Metric", "Corrected_Elevation_Value_m",
            "Avg_HR_bpm", "Description"
        ]))

        // Data rows
        for seg in segments {
            let paceMin = (seg.paceSecondsPerKilometer ?? 0) / 60.0
            let semanticExport = SegmentExport(segment: seg)
            lines.append(CSVRow.joined([
                seg.type.rawValue,
                seg.title,
                formatNumber(seg.startDistanceMeters / 1000),
                formatNumber(seg.endDistanceMeters / 1000),
                formatNumber(seg.distanceMeters / 1000),
                formatNumber(seg.startElapsedSeconds),
                formatNumber(seg.endElapsedSeconds),
                formatNumber(seg.activeDurationSeconds),
                formatNumber(seg.elapsedDurationSeconds),
                seg.paceSecondsPerKilometer != nil ? formatNumber(paceMin) : "",
                semanticExport.elevationMetric ?? "",
                semanticExport.correctedElevationValueMeters.map { formatNumber($0) } ?? "",
                seg.averageHeartRate.map { formatNumber($0) } ?? "",
                seg.subtitle
            ]))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func generateRecordedLapsCSV(workout: RunWorkout) -> String {
        var lines: [String] = []

        lines.append(CSVRow.joined([
            "Lap", "Trigger",
            "Start_Elapsed_s", "End_Elapsed_s",
            "Start_km", "End_km", "Distance_km",
            "Elapsed_Duration_s", "Active_Duration_s",
            "Moving_Duration_Estimated_s", "Stopped_Duration_Estimated_s",
            "Paused_Duration_s",
            "Moving_Pace_Estimated_min_km",
            "Active_Pace_min_km", "Elapsed_Pace_min_km",
            "Corrected_Elevation_Gain_m", "Corrected_Elevation_Loss_m",
            "Avg_HR_bpm", "Max_HR_bpm", "Avg_Cadence",
            "Source_Reported_Distance_km",
            "Source_Reported_Elapsed_s",
            "Source_Reported_Timer_s"
        ]))

        for lap in workout.recordedLaps {
            let reported = lap.reportedMetrics
            lines.append(CSVRow.joined([
                "\(lap.lapIndex)",
                lap.trigger.exportToken,
                formatNumber(lap.startElapsedSeconds),
                formatNumber(lap.endElapsedSeconds),
                formatNumber(lap.startDistanceMeters / 1000),
                formatNumber(lap.endDistanceMeters / 1000),
                formatNumber(lap.distanceMeters / 1000),
                formatNumber(lap.elapsedSeconds),
                formatNumber(lap.activeSeconds),
                formatNumber(lap.movingSeconds),
                formatNumber(lap.stoppedSeconds),
                formatNumber(lap.pausedSeconds),
                formatNumber(lap.movingPaceSecondsPerKilometer / 60),
                formatNumber(lap.activePaceSecondsPerKilometer / 60),
                formatNumber(lap.elapsedPaceSecondsPerKilometer / 60),
                lap.elevationGainMeters.map { formatNumber($0) } ?? "",
                lap.elevationLossMeters.map { formatNumber($0) } ?? "",
                lap.averageHeartRateBPM.map { formatNumber($0) } ?? "",
                lap.maximumHeartRateBPM.map { formatNumber($0) } ?? "",
                lap.averageCadence.map { formatNumber($0) } ?? "",
                reported?.distanceMeters.map { formatNumber($0 / 1000) } ?? "",
                reported?.elapsedSeconds.map { formatNumber($0) } ?? "",
                reported?.timerSeconds.map { formatNumber($0) } ?? ""
            ]))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func generateCombinedCSV(workout: RunWorkout, segments: [SegmentHighlight]) -> String {
        var sections: [String] = []

        sections.append("# Distance Splits")
        sections.append(generateSplitsCSV(workout: workout))
        if !workout.recordedLaps.isEmpty {
            sections.append("")
            sections.append("# Recorded Laps")
            sections.append(generateRecordedLapsCSV(workout: workout))
        }
        sections.append("")
        sections.append("# Segment Highlights")
        sections.append(generateSegmentsCSV(segments: segments))

        return sections.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func formatNumber(_ value: Double) -> String {
        DisplayFormatter.formatNumber(value)
    }
}

// MARK: - CSV Helpers

/// Safe CSV field escaping and joining.
public enum CSVRow {
    /// Escape a field for CSV (quote if it contains commas, quotes, newlines, or carriage returns).
    /// Mitigates CSV Injection (OWASP A1.4) by prepending a single quote to non-numeric fields
    /// starting with `=, +, -, @`. Effective in Excel, Google Sheets, and LibreOffice Calc.
    /// NOTE: The single-quote prefix is not part of RFC 4180; behavior in other applications may vary.
    /// Non-whitespace characters that could start a spreadsheet formula (OWASP A1.4).
    private static let dangerousPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    public static func escape(_ field: String) -> String {
        var safeField = field

        // CSV Injection mitigation: check first non-whitespace character for dangerous prefixes.
        if let first = field.first {
            if dangerousPrefixes.contains(first) {
                // Fast path: first char is already a dangerous prefix, no trimming needed
                let normalized = field.replacingOccurrences(of: ",", with: ".")
                if Double(field) == nil && Double(normalized) == nil {
                    safeField = "'" + field
                }
            } else if first.isWhitespace {
                // Slow path: leading whitespace — trim to find the real first char.
                let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmedFirst = trimmed.first, dangerousPrefixes.contains(trimmedFirst) {
                    let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
                    if Double(trimmed) == nil && Double(normalized) == nil {
                        // Preserve the original field contents; only add the spreadsheet text marker.
                        safeField = "'" + field
                    }
                }
            }
        }

        if safeField.contains(",") || safeField.contains("\"") || safeField.contains("\n") || safeField.contains("\r") {
            let escaped = safeField.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return safeField
    }

    /// Join fields into a CSV row.
    public static func joined(_ fields: [String]) -> String {
        // ⚡ Bolt: Inline string construction avoids creating an intermediate O(N) array from .map
        var result = ""
        for (index, field) in fields.enumerated() {
            if index > 0 {
                result.append(",")
            }
            result.append(escape(field))
        }
        return result
    }
}

// MARK: - Filename Builder

/// Builds safe filenames for exports.
public enum ExportFilenameBuilder {
    public static func filename(
        for workout: RunWorkout?,
        format: ExportFormat,
        suffix: String? = nil
    ) -> String {
        let baseName: String
        if let workout = workout {
            baseName = sanitize(workout.displayName)
        } else {
            baseName = "runplay-export"
        }

        let timestamp = formatDateForFilename(Date())
        if let suffix, !suffix.isEmpty {
            return "\(baseName)-\(sanitize(suffix))-\(timestamp).\(format.fileExtension)"
        }
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

    // ⚡ Bolt: Cache date formatter to avoid expensive initialization
    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.autoupdatingCurrent
        return formatter
    }()

    private static func formatDateForFilename(_ date: Date) -> String {
        return filenameDateFormatter.string(from: date)
    }
}
