import Foundation

/// Errors from the RFC 4180-style CSV parser.
public enum WorkoutArchiveCSVError: Error, LocalizedError, Equatable, Sendable {
    case oversizedField
    case oversizedRow
    case tooManyRows
    case malformedQuotation
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .oversizedField: return "CSV field exceeds size limit"
        case .oversizedRow: return "CSV row exceeds size limit"
        case .tooManyRows: return "CSV has too many rows"
        case .malformedQuotation: return "CSV has a malformed quoted field"
        case .cancelled: return "CSV parsing was cancelled"
        }
    }
}

/// One metadata row from a Strava activities CSV (column-order independent).
public struct StravaActivityMetadataRow: Hashable, Sendable {
    public var activityID: String?
    public var activityName: String?
    public var activityType: String?
    public var activityDate: Date?
    public var filename: String?
    public var distanceMeters: Double?
    public var elapsedTimeSeconds: Double?
    public var movingTimeSeconds: Double?
    /// Original row index in the CSV body (0-based).
    public var rowIndex: Int

    public init(
        activityID: String? = nil,
        activityName: String? = nil,
        activityType: String? = nil,
        activityDate: Date? = nil,
        filename: String? = nil,
        distanceMeters: Double? = nil,
        elapsedTimeSeconds: Double? = nil,
        movingTimeSeconds: Double? = nil,
        rowIndex: Int = 0
    ) {
        self.activityID = activityID
        self.activityName = activityName
        self.activityType = activityType
        self.activityDate = activityDate
        self.filename = filename
        self.distanceMeters = distanceMeters
        self.elapsedTimeSeconds = elapsedTimeSeconds
        self.movingTimeSeconds = movingTimeSeconds
        self.rowIndex = rowIndex
    }
}

/// Result of parsing a Strava activities metadata CSV.
public struct StravaActivityMetadataTable: Hashable, Sendable {
    public var rows: [StravaActivityMetadataRow]
    public var hasFilenameColumn: Bool
    public var recognizedHeaders: [String]
    public var unknownHeaders: [String]

    public init(
        rows: [StravaActivityMetadataRow] = [],
        hasFilenameColumn: Bool = false,
        recognizedHeaders: [String] = [],
        unknownHeaders: [String] = []
    ) {
        self.rows = rows
        self.hasFilenameColumn = hasFilenameColumn
        self.recognizedHeaders = recognizedHeaders
        self.unknownHeaders = unknownHeaders
    }
}

/// Streaming RFC 4180-style CSV parser with resource limits and cancellation.
public struct WorkoutArchiveCSVParser: Sendable {

    public let policy: WorkoutArchiveSecurityPolicy

    public init(policy: WorkoutArchiveSecurityPolicy = .default) {
        self.policy = policy
    }

    /// Parse raw CSV bytes into field rows (first row is the header).
    public func parseRows(
        from data: Data,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> [[String]] {
        if data.count > policy.maxMetadataCSVBytes {
            throw WorkoutArchiveCSVError.oversizedRow
        }

        // Strip optional UTF-8 BOM.
        let bytes: Data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = data.dropFirst(3)
        } else {
            bytes = data
        }

        guard let text = String(data: bytes, encoding: .utf8), !text.isEmpty else {
            throw WorkoutArchiveCSVError.malformedQuotation
        }

        var rows: [[String]] = []
        var currentField = ""
        var currentRow: [String] = []
        var inQuotes = false
        var rowByteEstimate = 0
        // Walk Unicode scalars so CRLF is never a single Character grapheme.
        let scalars = Array(text.unicodeScalars)
        var i = 0
        var scalarsSinceCancelCheck = 0

        func finishField() throws {
            if currentField.utf8.count > policy.maxCSVFieldBytes {
                throw WorkoutArchiveCSVError.oversizedField
            }
            currentRow.append(currentField)
            currentField = ""
        }

        func finishRow() throws {
            try finishField()
            // Trailing empty row after final newline.
            if currentRow.count == 1, currentRow[0].isEmpty, rows.isEmpty == false {
                currentRow = []
                rowByteEstimate = 0
                return
            }
            if rows.count >= policy.maxCSVRows {
                throw WorkoutArchiveCSVError.tooManyRows
            }
            rows.append(currentRow)
            currentRow = []
            rowByteEstimate = 0
        }

        while i < scalars.count {
            scalarsSinceCancelCheck += 1
            if scalarsSinceCancelCheck >= policy.cancellationCheckStride {
                scalarsSinceCancelCheck = 0
                if isCancelled() { throw WorkoutArchiveCSVError.cancelled }
            }

            let scalar = scalars[i]
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil

            if inQuotes {
                if scalar == "\"" {
                    if next == "\"" {
                        currentField.append("\"")
                        rowByteEstimate += 1
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    currentField.unicodeScalars.append(scalar)
                    rowByteEstimate += Self.utf8ByteCount(scalar)
                    if currentField.utf8.count > policy.maxCSVFieldBytes {
                        throw WorkoutArchiveCSVError.oversizedField
                    }
                    if rowByteEstimate > policy.maxCSVRowBytes {
                        throw WorkoutArchiveCSVError.oversizedRow
                    }
                    i += 1
                    continue
                }
            }

            switch scalar {
            case "\"":
                // Quote must start a field.
                if !currentField.isEmpty {
                    throw WorkoutArchiveCSVError.malformedQuotation
                }
                inQuotes = true
                i += 1
            case ",":
                try finishField()
                rowByteEstimate += 1
                if rowByteEstimate > policy.maxCSVRowBytes {
                    throw WorkoutArchiveCSVError.oversizedRow
                }
                i += 1
            case "\r":
                // CRLF or bare CR.
                if next == "\n" {
                    try finishRow()
                    i += 2
                } else {
                    try finishRow()
                    i += 1
                }
            case "\n":
                try finishRow()
                i += 1
            default:
                currentField.unicodeScalars.append(scalar)
                rowByteEstimate += Self.utf8ByteCount(scalar)
                if currentField.utf8.count > policy.maxCSVFieldBytes {
                    throw WorkoutArchiveCSVError.oversizedField
                }
                if rowByteEstimate > policy.maxCSVRowBytes {
                    throw WorkoutArchiveCSVError.oversizedRow
                }
                i += 1
            }
        }

        if inQuotes {
            throw WorkoutArchiveCSVError.malformedQuotation
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            try finishRow()
        }

        return rows
    }

    /// Parse a Strava activities.csv into structured metadata rows.
    public func parseStravaActivitiesCSV(
        from data: Data,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> StravaActivityMetadataTable {
        let rows = try parseRows(from: data, isCancelled: isCancelled)
        guard let headerRow = rows.first else {
            return StravaActivityMetadataTable()
        }

        let headers = headerRow.map { Self.normalizeHeader($0) }
        var columnMap: [StravaCSVColumn: Int] = [:]
        var recognized: [String] = []
        var unknown: [String] = []

        for (index, header) in headers.enumerated() {
            if let column = StravaCSVColumn.match(header) {
                // First match wins for aliases.
                if columnMap[column] == nil {
                    columnMap[column] = index
                    recognized.append(headerRow[index])
                }
            } else if !header.isEmpty {
                unknown.append(headerRow[index])
            }
        }

        var body: [StravaActivityMetadataRow] = []
        body.reserveCapacity(max(0, rows.count - 1))

        for (offset, row) in rows.dropFirst().enumerated() {
            if offset % policy.cancellationCheckStride == 0, isCancelled() {
                throw WorkoutArchiveCSVError.cancelled
            }
            func field(_ column: StravaCSVColumn) -> String? {
                guard let idx = columnMap[column], idx < row.count else { return nil }
                let value = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            let id = field(.activityID)
            let name = field(.activityName)
            let type = field(.activityType) ?? field(.sportType)
            let date = Self.parseDate(field(.activityDate))
            let filename = field(.filename)
            let distance = Self.parseDouble(field(.distance))
            let elapsed = Self.parseDouble(field(.elapsedTime))
            let moving = Self.parseDouble(field(.movingTime))

            // Skip completely empty rows.
            if id == nil, name == nil, type == nil, filename == nil, date == nil {
                continue
            }

            body.append(StravaActivityMetadataRow(
                activityID: id,
                activityName: name,
                activityType: type,
                activityDate: date,
                filename: filename,
                distanceMeters: distance,
                elapsedTimeSeconds: elapsed,
                movingTimeSeconds: moving,
                rowIndex: offset
            ))
        }

        return StravaActivityMetadataTable(
            rows: body,
            hasFilenameColumn: columnMap[.filename] != nil,
            recognizedHeaders: recognized,
            unknownHeaders: unknown
        )
    }

    // MARK: - Header / value helpers

    public static func normalizeHeader(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    /// Portable UTF-8 byte length for one Unicode scalar (1…4).
    private static func utf8ByteCount(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x1_0000: return 3
        default: return 4
        }
    }

    nonisolated(unsafe) private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoBasicFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateFormats = [
        "MMM d, yyyy, h:mm:ss a",
        "MMM dd, yyyy, h:mm:ss a",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
        "M/d/yyyy H:mm:ss",
        "M/d/yyyy h:mm:ss a",
    ]

    nonisolated(unsafe) private static let fallbackFormatters: [DateFormatter] = {
        dateFormats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = format
            return f
        }
    }()

    public static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        if let d = isoFractionalFormatter.date(from: raw) { return d }
        if let d = isoBasicFormatter.date(from: raw) { return d }

        for f in fallbackFormatters {
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    public static func parseDouble(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }
}

/// Known Strava activities.csv columns (aliases normalized).
enum StravaCSVColumn: Hashable, CaseIterable {
    case activityID
    case activityName
    case activityType
    case sportType
    case activityDate
    case filename
    case distance
    case elapsedTime
    case movingTime

    static func match(_ normalizedHeader: String) -> StravaCSVColumn? {
        switch normalizedHeader {
        case "activity id", "activityid", "id":
            return .activityID
        case "activity name", "activityname", "name", "title":
            return .activityName
        case "activity type", "activitytype", "type":
            return .activityType
        case "sport type", "sporttype", "sport":
            return .sportType
        case "activity date", "activitydate", "date", "start date", "start date local":
            return .activityDate
        case "filename", "file name", "file", "activity file", "activity filename":
            return .filename
        case "distance", "distance meters", "distance (m)":
            return .distance
        case "elapsed time", "elapsedtime", "elapsed time (s)", "timer time":
            return .elapsedTime
        case "moving time", "movingtime", "moving time (s)":
            return .movingTime
        default:
            return nil
        }
    }
}
