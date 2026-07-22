import Foundation

// MARK: - Status

/// Structured reason a candidate is or is not importable.
public enum WorkoutArchiveCandidateStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case ready
    case duplicate
    case possibleDuplicate
    case unsupportedActivityType
    case unsupportedFormat
    case missingActivityFile
    case invalidMetadata
    case unsafeArchiveEntry
    case exceedsResourceLimit
    case parseFailed
    case noGPSRoute
    case providerConflict

    public var isImportableByDefault: Bool {
        switch self {
        case .ready, .possibleDuplicate:
            return true
        case .duplicate, .unsupportedActivityType, .unsupportedFormat,
             .missingActivityFile, .invalidMetadata, .unsafeArchiveEntry,
             .exceedsResourceLimit, .parseFailed, .noGPSRoute, .providerConflict:
            return false
        }
    }

    public var userFacingSummary: String {
        switch self {
        case .ready: return "Ready"
        case .duplicate: return "Already imported"
        case .possibleDuplicate: return "Possible duplicate"
        case .unsupportedActivityType: return "Unsupported activity type"
        case .unsupportedFormat: return "Unsupported format"
        case .missingActivityFile: return "Missing activity file"
        case .invalidMetadata: return "Invalid metadata"
        case .unsafeArchiveEntry: return "Unsafe archive entry"
        case .exceedsResourceLimit: return "Exceeds resource limit"
        case .parseFailed: return "Could not parse"
        case .noGPSRoute: return "No GPS route"
        case .providerConflict: return "Conflicts with existing workout"
        }
    }
}

// MARK: - Format

/// Activity file format detected inside an archive entry.
public enum WorkoutArchiveActivityFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case fit
    case gpx
    case tcx
    case fitGzip
    case gpxGzip
    case tcxGzip
    case unsupported

    public var fileExtension: String {
        switch self {
        case .fit: return "fit"
        case .gpx: return "gpx"
        case .tcx: return "tcx"
        case .fitGzip: return "fit"
        case .gpxGzip: return "gpx"
        case .tcxGzip: return "tcx"
        case .unsupported: return ""
        }
    }

    public var isGzipWrapped: Bool {
        switch self {
        case .fitGzip, .gpxGzip, .tcxGzip: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .fit: return "FIT"
        case .gpx: return "GPX"
        case .tcx: return "TCX"
        case .fitGzip: return "FIT.GZ"
        case .gpxGzip: return "GPX.GZ"
        case .tcxGzip: return "TCX.GZ"
        case .unsupported: return "Unsupported"
        }
    }

    /// Detect format from a normalized archive-relative path (lowercase).
    public static func detect(fromPath path: String) -> WorkoutArchiveActivityFormat {
        let lower = path.lowercased()
        if lower.hasSuffix(".fit.gz") { return .fitGzip }
        if lower.hasSuffix(".gpx.gz") { return .gpxGzip }
        if lower.hasSuffix(".tcx.gz") { return .tcxGzip }
        if lower.hasSuffix(".fit") { return .fit }
        if lower.hasSuffix(".gpx") { return .gpx }
        if lower.hasSuffix(".tcx") { return .tcx }
        return .unsupported
    }
}

// MARK: - Candidate

/// One activity discovered inside a bulk-export archive.
public struct WorkoutArchiveCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public var archiveRelativePath: String
    public var providerActivityID: String?
    public var activityName: String?
    public var activityType: String?
    public var activityDate: Date?
    public var format: WorkoutArchiveActivityFormat
    public var compressedBytes: Int64?
    public var declaredUncompressedBytes: Int64?
    public var status: WorkoutArchiveCandidateStatus
    public var statusDetail: String?
    public var isSelectedByDefault: Bool
    /// Content hash when known during scan (often nil until import reads bytes).
    public var contentSHA256: String?
    /// Archive-row order for deterministic import ordering.
    public var archiveOrder: Int

    public init(
        id: String,
        archiveRelativePath: String,
        providerActivityID: String? = nil,
        activityName: String? = nil,
        activityType: String? = nil,
        activityDate: Date? = nil,
        format: WorkoutArchiveActivityFormat = .unsupported,
        compressedBytes: Int64? = nil,
        declaredUncompressedBytes: Int64? = nil,
        status: WorkoutArchiveCandidateStatus = .ready,
        statusDetail: String? = nil,
        isSelectedByDefault: Bool = false,
        contentSHA256: String? = nil,
        archiveOrder: Int = 0
    ) {
        self.id = id
        self.archiveRelativePath = archiveRelativePath
        self.providerActivityID = providerActivityID
        self.activityName = activityName
        self.activityType = activityType
        self.activityDate = activityDate
        self.format = format
        self.compressedBytes = compressedBytes
        self.declaredUncompressedBytes = declaredUncompressedBytes
        self.status = status
        self.statusDetail = statusDetail
        self.isSelectedByDefault = isSelectedByDefault
        self.contentSHA256 = contentSHA256
        self.archiveOrder = archiveOrder
    }

    public var displayName: String {
        if let activityName, !activityName.isEmpty { return activityName }
        if !archiveRelativePath.isEmpty {
            return (archiveRelativePath as NSString).lastPathComponent
        }
        return providerActivityID ?? "Activity"
    }
}

// MARK: - Scan result

/// Diagnostics collected while scanning an archive.
public struct WorkoutArchiveScanDiagnostics: Hashable, Sendable {
    public var archiveName: String
    public var entryCount: Int
    public var ignoredEntryCount: Int
    public var unsafeEntryCount: Int
    public var metadataCSVFound: Bool
    public var metadataFilenameColumnPresent: Bool
    public var usedCaseInsensitivePathMatch: Bool
    public var ambiguousPathMatchCount: Int
    public var estimatedTotalSourceBytes: Int64
    public var warnings: [String]

    public init(
        archiveName: String = "",
        entryCount: Int = 0,
        ignoredEntryCount: Int = 0,
        unsafeEntryCount: Int = 0,
        metadataCSVFound: Bool = false,
        metadataFilenameColumnPresent: Bool = false,
        usedCaseInsensitivePathMatch: Bool = false,
        ambiguousPathMatchCount: Int = 0,
        estimatedTotalSourceBytes: Int64 = 0,
        warnings: [String] = []
    ) {
        self.archiveName = archiveName
        self.entryCount = entryCount
        self.ignoredEntryCount = ignoredEntryCount
        self.unsafeEntryCount = unsafeEntryCount
        self.metadataCSVFound = metadataCSVFound
        self.metadataFilenameColumnPresent = metadataFilenameColumnPresent
        self.usedCaseInsensitivePathMatch = usedCaseInsensitivePathMatch
        self.ambiguousPathMatchCount = ambiguousPathMatchCount
        self.estimatedTotalSourceBytes = estimatedTotalSourceBytes
        self.warnings = warnings
    }
}

/// Result of a lightweight archive scan before user selection.
public struct WorkoutArchiveScanResult: Hashable, Sendable {
    public var candidates: [WorkoutArchiveCandidate]
    public var diagnostics: WorkoutArchiveScanDiagnostics
    public var isRecognizedStravaExport: Bool
    public var rejectionMessage: String?

    public init(
        candidates: [WorkoutArchiveCandidate] = [],
        diagnostics: WorkoutArchiveScanDiagnostics = WorkoutArchiveScanDiagnostics(),
        isRecognizedStravaExport: Bool = false,
        rejectionMessage: String? = nil
    ) {
        self.candidates = candidates
        self.diagnostics = diagnostics
        self.isRecognizedStravaExport = isRecognizedStravaExport
        self.rejectionMessage = rejectionMessage
    }

    public var readyCount: Int {
        var count = 0
        for candidate in candidates {
            if candidate.status == .ready || candidate.status == .possibleDuplicate {
                count += 1
            }
        }
        return count
    }

    public var duplicateCount: Int {
        var count = 0
        for candidate in candidates {
            if candidate.status == .duplicate {
                count += 1
            }
        }
        return count
    }

    public var unsupportedActivityTypeCount: Int {
        var count = 0
        for candidate in candidates {
            if candidate.status == .unsupportedActivityType {
                count += 1
            }
        }
        return count
    }

    public var defaultSelectedCount: Int {
        var count = 0
        for candidate in candidates {
            if candidate.isSelectedByDefault {
                count += 1
            }
        }
        return count
    }
}

// MARK: - Selection & progress

/// User selection for a batch import.
public struct WorkoutBatchImportSelection: Hashable, Sendable {
    public var selectedCandidateIDs: [String]
    /// Snapshot of candidates from the scan (needed for paths and metadata).
    public var candidates: [WorkoutArchiveCandidate]

    public init(
        selectedCandidateIDs: [String] = [],
        candidates: [WorkoutArchiveCandidate] = []
    ) {
        self.selectedCandidateIDs = selectedCandidateIDs
        self.candidates = candidates
    }

    public var selectedCandidates: [WorkoutArchiveCandidate] {
        let idSet = Set(selectedCandidateIDs)
        return candidates
            .filter { idSet.contains($0.id) }
            .sorted { $0.archiveOrder < $1.archiveOrder }
    }
}

/// High-level phase of archive scan/import.
public enum WorkoutBatchImportPhase: String, Codable, Hashable, Sendable {
    case openingArchive
    case readingMetadata
    case scanningEntries
    case awaitingSelection
    case importing
    case staging
    case committing
    case completed
    case cancelled
    case failed
}

/// Structured progress for UI and tests.
public struct WorkoutBatchImportProgress: Hashable, Sendable {
    public var phase: WorkoutBatchImportPhase
    public var completedCount: Int
    public var totalCount: Int
    public var currentFilename: String?
    public var stagedCount: Int
    public var skippedCount: Int
    public var failedCount: Int

    public init(
        phase: WorkoutBatchImportPhase = .openingArchive,
        completedCount: Int = 0,
        totalCount: Int = 0,
        currentFilename: String? = nil,
        stagedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0
    ) {
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.currentFilename = currentFilename
        self.stagedCount = stagedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
    }
}

// MARK: - Item & report

/// Outcome for a single candidate during import.
public struct WorkoutBatchImportItemResult: Hashable, Sendable {
    public var candidateID: String
    public var archiveRelativePath: String
    public var activityName: String?
    public var status: WorkoutArchiveCandidateStatus
    public var detail: String?
    public var importedWorkoutID: UUID?

    public init(
        candidateID: String,
        archiveRelativePath: String,
        activityName: String? = nil,
        status: WorkoutArchiveCandidateStatus,
        detail: String? = nil,
        importedWorkoutID: UUID? = nil
    ) {
        self.candidateID = candidateID
        self.archiveRelativePath = archiveRelativePath
        self.activityName = activityName
        self.status = status
        self.detail = detail
        self.importedWorkoutID = importedWorkoutID
    }
}

/// Final structured report after a batch import attempt.
public struct WorkoutBatchImportReport: Hashable, Sendable {
    public var items: [WorkoutBatchImportItemResult]
    public var importedWorkoutIDs: [UUID]
    public var selectedWorkoutID: UUID?
    public var wasCancelled: Bool
    public var commitFailed: Bool
    public var errorMessage: String?

    public init(
        items: [WorkoutBatchImportItemResult] = [],
        importedWorkoutIDs: [UUID] = [],
        selectedWorkoutID: UUID? = nil,
        wasCancelled: Bool = false,
        commitFailed: Bool = false,
        errorMessage: String? = nil
    ) {
        self.items = items
        self.importedWorkoutIDs = importedWorkoutIDs
        self.selectedWorkoutID = selectedWorkoutID
        self.wasCancelled = wasCancelled
        self.commitFailed = commitFailed
        self.errorMessage = errorMessage
    }

    public var importedCount: Int { importedWorkoutIDs.count }

    public func count(for status: WorkoutArchiveCandidateStatus) -> Int {
        var count = 0
        for item in items {
            if item.status == status {
                count += 1
            }
        }
        return count
    }
}

// MARK: - Batch token

/// Opaque handle for a staged library batch transaction.
public struct WorkoutLibraryBatchToken: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}
