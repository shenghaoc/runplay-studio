import Foundation

/// One user-chosen watched directory.
///
/// The security-scoped bookmark is opaque bytes here. `RunPlayCore` never
/// resolves or interprets bookmark data — resolution requires the macOS
/// Platform layer, and keeping the payload opaque keeps Core buildable on
/// Linux with Foundation only. The persistence identity of a folder is its
/// `id`, not its path: paths move, ids do not.
public struct WatchFolderConfiguration: Codable, Equatable, Identifiable, Sendable {

    /// Stable identity for the watched folder.
    public let id: UUID

    /// The folder name as shown in settings and notifications.
    public var displayName: String

    /// Opaque security-scoped bookmark data. Core stores it; Platform
    /// resolves it.
    public var bookmarkData: Data

    /// Tag applied to workouts imported from this folder. Empty means no
    /// default tag.
    public var defaultTagName: String

    /// When true the folder is listed but never scanned or imported.
    public var isPaused: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        defaultTagName: String = "",
        isPaused: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.defaultTagName = defaultTagName
        self.isPaused = isPaused
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, bookmarkData, defaultTagName, isPaused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
        // Tolerant decode: fields added after v1 default instead of failing
        // the whole store load.
        self.defaultTagName = try container.decodeIfPresent(String.self, forKey: .defaultTagName) ?? ""
        self.isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
    }
}

/// What happened the last time the watcher processed one file.
public enum WatchFolderImportOutcome: String, Codable, Equatable, Sendable {
    /// Imported successfully as a workout.
    case imported
    /// Content hash already in the ledger — deliberately skipped.
    case skippedDuplicate
    /// Parsing or persistence failed; the failure is ledgered so the file is
    /// not retried on every scan.
    case failed
    /// A multi-session FIT container waiting for the user's review. Not
    /// ledgered until the review resolves.
    case awaitingReview
}

/// One persisted ledger entry: proof this content was already processed.
///
/// The key is the lowercase SHA-256 hex of the file content; the filename is
/// recorded for the recent-imports list and diagnostics only, never for
/// identity — the same content renamed is still a duplicate.
public struct WatchFolderLedgerEntry: Codable, Equatable, Sendable {

    /// Lowercase SHA-256 hex of the file content at import time.
    public let contentSHA256: String

    /// Filename at the time of processing (display only).
    public let fileName: String

    /// Final outcome for this content.
    public let outcome: WatchFolderImportOutcome

    /// When the outcome was recorded.
    public let processedAt: Date

    public init(
        contentSHA256: String,
        fileName: String,
        outcome: WatchFolderImportOutcome,
        processedAt: Date
    ) {
        self.contentSHA256 = contentSHA256
        self.fileName = fileName
        self.outcome = outcome
        self.processedAt = processedAt
    }
}

/// A user-visible per-file result row for the recent-imports panel.
public struct WatchFolderImportRecord: Codable, Equatable, Identifiable, Sendable {

    public enum Status: String, Codable, Equatable, Sendable {
        case imported
        case skippedDuplicate
        case failed
        case awaitingReview
    }

    public let id: UUID

    /// Folder the file was found in (configuration id).
    public let folderID: UUID

    /// Folder name at processing time (display only).
    public let folderName: String

    public let fileURL: URL

    public let fileName: String

    public let status: Status

    public let processedAt: Date

    /// Short human-readable failure detail for failed rows; empty otherwise.
    public let failureDetail: String

    public init(
        id: UUID = UUID(),
        folderID: UUID,
        folderName: String,
        fileURL: URL,
        fileName: String,
        status: Status,
        processedAt: Date,
        failureDetail: String = ""
    ) {
        self.id = id
        self.folderID = folderID
        self.folderName = folderName
        self.fileURL = fileURL
        self.fileName = fileName
        self.status = status
        self.processedAt = processedAt
        self.failureDetail = failureDetail
    }
}

/// Tunables for watch-folder scanning. All intervals are advisory input to
/// the coordinator; the scanner itself is pure and clock-injected.
public struct WatchFolderScanPolicy: Equatable, Sendable {

    /// Delay between authoritative filesystem polls.
    public var pollInterval: TimeInterval

    /// A file is considered settled when size and modification date are
    /// stable across two probes separated by at least this interval.
    public var settleInterval: TimeInterval

    /// Extensions eligible for import, lowercase, no dots.
    public var supportedExtensions: [String]

    /// Maximum bytes read per file for hashing and import.
    public var maxFileBytes: Int

    /// Maximum recent-import records retained for the panel.
    public var maxRecentRecords: Int

    /// Maximum ledger entries retained per folder.
    public var maxLedgerEntriesPerFolder: Int

    public init(
        pollInterval: TimeInterval = 5,
        settleInterval: TimeInterval = 2,
        supportedExtensions: [String] = ["gpx", "tcx", "fit", "json"],
        maxFileBytes: Int = WorkoutImportResourceLimits.maxSourceFileBytes,
        maxRecentRecords: Int = 50,
        maxLedgerEntriesPerFolder: Int = 10_000
    ) {
        self.pollInterval = pollInterval
        self.settleInterval = settleInterval
        self.supportedExtensions = supportedExtensions
        self.maxFileBytes = maxFileBytes
        self.maxRecentRecords = maxRecentRecords
        self.maxLedgerEntriesPerFolder = maxLedgerEntriesPerFolder
    }

    public static let `default` = WatchFolderScanPolicy()
}

/// Aggregated state persisted per watched folder: the dedupe ledger plus the
/// files queued for multi-session FIT review.
public struct WatchFolderState: Codable, Equatable, Sendable {

    public var folderID: UUID

    /// Content hashes already processed (imported, skipped, or failed).
    public var ledger: [WatchFolderLedgerEntry]

    /// Files whose content is waiting for the user's FIT review, keyed by
    /// content hash so renames dedupe naturally.
    public var pendingReview: [String: WatchFolderPendingReviewEntry]

    public init(
        folderID: UUID,
        ledger: [WatchFolderLedgerEntry] = [],
        pendingReview: [String: WatchFolderPendingReviewEntry] = [:]
    ) {
        self.folderID = folderID
        self.ledger = ledger
        self.pendingReview = pendingReview
    }
}

/// A file whose content is queued for the multi-session FIT review sheet.
public struct WatchFolderPendingReviewEntry: Codable, Equatable, Sendable {

    /// Absolute path of the file when it was queued (display and re-open
    /// hint only; identity is the ledger key, the content hash).
    public let filePath: String

    public let fileName: String

    public let queuedAt: Date

    public init(filePath: String, fileName: String, queuedAt: Date) {
        self.filePath = filePath
        self.fileName = fileName
        self.queuedAt = queuedAt
    }
}
