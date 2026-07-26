import Foundation

// MARK: - Status

/// Structured reason a discovered FIT session is or is not importable.
///
/// Free-form strings are never the only representation: `statusDetail` adds
/// context, but selection, reporting, and tests key off this enum.
public enum FITSessionCandidateStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case ready
    case duplicate
    case unsupportedSport
    case noGPSRoute
    case invalidBoundaries
    case ambiguousAttribution
    case exceedsResourceLimit
    case parseFailed

    /// Only `.ready` is ever selected by default.
    public var isImportableByDefault: Bool {
        self == .ready
    }

    public var userFacingSummary: String {
        switch self {
        case .ready: return "Ready"
        case .duplicate: return "Already imported"
        case .unsupportedSport: return "Unsupported sport"
        case .noGPSRoute: return "No GPS route"
        case .invalidBoundaries: return "Missing session boundaries"
        case .ambiguousAttribution: return "Ambiguous session data"
        case .exceedsResourceLimit: return "Exceeds resource limit"
        case .parseFailed: return "Could not parse"
        }
    }
}

// MARK: - Descriptor

/// One session discovered inside a FIT container.
///
/// Deliberately lightweight: it never retains records, route points, decoded
/// message containers, or UI types, so the review sheet can stay open without
/// pinning a parsed FIT file in memory.
public struct FITSessionDescriptor: Identifiable, Hashable, Sendable {
    /// Stable identity, equal to `providerActivityID`.
    public var id: String { providerActivityID }

    /// Zero-based ordinal in FIT source order. Display order follows this.
    public let sourceIndex: Int
    public let startDate: Date?
    public let endDate: Date?
    public let sport: FITSessionSportClassification
    /// Human-readable sport name, e.g. "Running".
    public let sportDescription: String
    public let subSportDescription: String?
    public let elapsedSeconds: Double?
    public let timerSeconds: Double?
    public let reportedDistanceMeters: Double?
    /// Records attributed to this session that carry usable GPS coordinates.
    public let gpsRecordCount: Int
    public let recordedLapCount: Int
    public let status: FITSessionCandidateStatus
    public let statusDetail: String?
    public let isSelectedByDefault: Bool
    /// Versioned content-derived identity — never a bare array index.
    public let providerActivityID: String
    /// Concise, user-facing name. Contains no fingerprints or FIT internals.
    public let displayName: String

    public init(
        sourceIndex: Int,
        startDate: Date? = nil,
        endDate: Date? = nil,
        sport: FITSessionSportClassification,
        sportDescription: String,
        subSportDescription: String? = nil,
        elapsedSeconds: Double? = nil,
        timerSeconds: Double? = nil,
        reportedDistanceMeters: Double? = nil,
        gpsRecordCount: Int = 0,
        recordedLapCount: Int = 0,
        status: FITSessionCandidateStatus,
        statusDetail: String? = nil,
        isSelectedByDefault: Bool = false,
        providerActivityID: String,
        displayName: String
    ) {
        self.sourceIndex = sourceIndex
        self.startDate = startDate
        self.endDate = endDate
        self.sport = sport
        self.sportDescription = sportDescription
        self.subSportDescription = subSportDescription
        self.elapsedSeconds = elapsedSeconds
        self.timerSeconds = timerSeconds
        self.reportedDistanceMeters = reportedDistanceMeters
        self.gpsRecordCount = gpsRecordCount
        self.recordedLapCount = recordedLapCount
        self.status = status
        self.statusDetail = statusDetail
        self.isSelectedByDefault = isSelectedByDefault
        self.providerActivityID = providerActivityID
        self.displayName = displayName
    }

    /// One-based ordinal for user-facing text.
    public var displayOrdinal: Int { sourceIndex + 1 }
}

// MARK: - Scan result

/// Where a scanned FIT container should be routed.
public enum FITSessionScanRouting: String, Codable, Hashable, Sendable {
    /// Zero or one session message: keep the existing single-workout path.
    case direct
    /// Two or more session messages: present the review sheet.
    case review
}

/// Result of scanning a FIT container before user selection.
public struct FITSessionScanResult: Hashable, Sendable {
    public var routing: FITSessionScanRouting
    public var fileName: String
    /// Lowercase hex SHA-256 of the whole original container.
    public var containerSHA256: String
    /// Session messages present in the container, before any limit clamping.
    public var totalSessionMessageCount: Int
    /// Descriptors in FIT source order.
    public var candidates: [FITSessionDescriptor]
    public var warnings: [String]

    public init(
        routing: FITSessionScanRouting = .direct,
        fileName: String = "",
        containerSHA256: String = "",
        totalSessionMessageCount: Int = 0,
        candidates: [FITSessionDescriptor] = [],
        warnings: [String] = []
    ) {
        self.routing = routing
        self.fileName = fileName
        self.containerSHA256 = containerSHA256
        self.totalSessionMessageCount = totalSessionMessageCount
        self.candidates = candidates
        self.warnings = warnings
    }

    public var readyCount: Int { candidates.count(where: { $0.status == .ready }) }
    public var duplicateCount: Int { candidates.count(where: { $0.status == .duplicate }) }
    public var unsupportedCount: Int {
        candidates.count(where: { $0.status == .unsupportedSport })
    }
    public var ambiguousCount: Int {
        candidates.count(where: { $0.status == .ambiguousAttribution })
    }
    public var defaultSelectedCount: Int { candidates.count(where: \.isSelectedByDefault) }

    public func count(for status: FITSessionCandidateStatus) -> Int {
        candidates.count(where: { $0.status == status })
    }
}

// MARK: - Selection

/// User selection for a multi-session FIT import.
public struct FITSessionImportSelection: Hashable, Sendable {
    public var selectedCandidateIDs: [String]
    /// Descriptor snapshot from the scan, needed for source indexes and names.
    public var candidates: [FITSessionDescriptor]

    public init(
        selectedCandidateIDs: [String] = [],
        candidates: [FITSessionDescriptor] = []
    ) {
        self.selectedCandidateIDs = selectedCandidateIDs
        self.candidates = candidates
    }

    /// Selected descriptors in FIT source order — the deterministic staging and
    /// reporting order. Selection order is never used.
    public var selectedCandidates: [FITSessionDescriptor] {
        let ids = Set(selectedCandidateIDs)
        return candidates
            .filter { ids.contains($0.providerActivityID) }
            .sorted { $0.sourceIndex < $1.sourceIndex }
    }
}

// MARK: - Report

/// Outcome for a single selected session.
///
/// `status` is the **candidate classification at process time** (duplicate,
/// no GPS, staged-as-ready, …). It is **not** by itself a commit outcome:
/// a staged `.ready` item is only “Imported” when the report’s
/// `commitFailed == false` and the workout ID appears in
/// `importedWorkoutIDs`. Use ``reportLabel(commitFailed:)`` for UI text.
public struct FITSessionImportItemResult: Hashable, Sendable {
    public var candidateID: String
    public var sourceIndex: Int
    public var sessionName: String
    /// Candidate / process classification — not the final commit outcome.
    public var status: FITSessionCandidateStatus
    public var detail: String?
    /// Set when the workout was staged successfully; commit may still fail.
    public var importedWorkoutID: UUID?

    public init(
        candidateID: String,
        sourceIndex: Int,
        sessionName: String,
        status: FITSessionCandidateStatus,
        detail: String? = nil,
        importedWorkoutID: UUID? = nil
    ) {
        self.candidateID = candidateID
        self.sourceIndex = sourceIndex
        self.sessionName = sessionName
        self.status = status
        self.detail = detail
        self.importedWorkoutID = importedWorkoutID
    }

    /// User-facing report row label. Never treat bare `.ready` as “Imported”.
    public func reportLabel(commitFailed: Bool) -> String {
        if status == .ready {
            return commitFailed ? "Not saved" : "Imported"
        }
        return status.userFacingSummary
    }
}

/// Final structured report after a multi-session FIT import attempt.
///
/// FIT-specific rather than `WorkoutBatchImportReport` so no user-facing field
/// is named `archiveRelativePath`. `importedWorkoutIDs` is only populated after
/// a successful commit: staging alone never counts as imported.
public struct FITSessionBatchImportReport: Hashable, Sendable {
    public var items: [FITSessionImportItemResult]
    public var importedWorkoutIDs: [UUID]
    public var selectedWorkoutID: UUID?
    public var wasCancelled: Bool
    public var commitFailed: Bool
    public var errorMessage: String?

    public init(
        items: [FITSessionImportItemResult] = [],
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

    public func count(for status: FITSessionCandidateStatus) -> Int {
        // Staged-but-not-committed items must not be reported as imported.
        // Only report-level `importedWorkoutIDs` / `!commitFailed` are authority
        // for "how many actually landed in the library".
        guard status == .ready else {
            return items.count(where: { $0.status == status })
        }
        return commitFailed ? 0 : importedWorkoutIDs.count
    }
}

// MARK: - Errors

/// Errors raised while opening or scanning a FIT container for sessions.
public enum FITSessionImportError: Error, LocalizedError, Equatable, Sendable {
    case notLocalFile
    case containerTooLarge
    case cannotReadFile(String)
    case tooManySessions(Int)
    case tooManySelectedSessions(Int)
    case batchConflict

    public var errorDescription: String? {
        switch self {
        case .notLocalFile:
            return "Only local files can be imported."
        case .containerTooLarge:
            return "This FIT file exceeds the maximum supported size."
        case .cannotReadFile(let detail):
            return "Could not read the FIT file. \(detail)"
        case .tooManySessions(let limit):
            return "This FIT file contains more than \(limit) sessions, which is more than RunPlay Studio can review safely."
        case .tooManySelectedSessions(let limit):
            return "Select at most \(limit) sessions to import at once."
        case .batchConflict:
            return "Another library change is already in progress."
        }
    }
}
