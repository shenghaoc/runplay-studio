import Foundation

/// File-backed persistence for watch-folder configuration and ledgers.
///
/// Layout on disk: `<library-root>/watch-folders.json`, beside the library
/// manifest and athlete profile. Writes are atomic, so a crash mid-write
/// never leaves a half-written ledger. A missing or undecodable file loads
/// as an empty configuration — a damaged store must never block the library
/// or the app (the athlete-profile precedent).
///
/// The persisted shape is a versioned envelope. Version 1 carries the folder
/// configurations plus per-folder ledger/pending-review state. Decode is
/// tolerant: unknown future versions load empty rather than throwing, and
/// entry-level optional fields default.
///
/// `@unchecked Sendable` for the same reason as `FileWorkoutLibraryStore`:
/// `FileManager` is documented thread-safe but not `Sendable`.
public struct FileWatchFolderStore: @unchecked Sendable {

    public enum LoadOutcome: Equatable, Sendable {
        /// A store file was present and decoded.
        case loaded(WatchFolderStoreSnapshot)
        /// No store file exists yet.
        case missing
        /// A file exists but could not be decoded; callers fall back to an
        /// empty configuration and may overwrite the file on the next save.
        case corrupt
    }

    /// Root object persisted to disk.
    public struct WatchFolderStoreSnapshot: Codable, Equatable, Sendable {
        public var version: Int
        public var folders: [WatchFolderConfiguration]
        public var states: [WatchFolderState]

        public init(
            version: Int = FileWatchFolderStore.currentVersion,
            folders: [WatchFolderConfiguration] = [],
            states: [WatchFolderState] = []
        ) {
            self.version = version
            self.folders = folders
            self.states = states
        }
    }

    /// The store schema version this build writes and understands.
    public static let currentVersion = 1

    private let storeURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.storeURL = rootURL.appendingPathComponent("watch-folders.json")
        self.fileManager = fileManager

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Load the configuration, distinguishing first run (missing) from a
    /// damaged file (corrupt) so callers can report or repair deliberately.
    public func load() -> LoadOutcome {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: storeURL) else {
            return .corrupt
        }
        guard let snapshot = try? decoder.decode(WatchFolderStoreSnapshot.self, from: data) else {
            return .corrupt
        }
        // Unknown future versions load empty rather than throwing: the file
        // may have been written by a newer build and must not wedge an older
        // one. Losing the ledger only costs re-detection of duplicates via
        // the in-memory existing-workout comparison; it never double-imports
        // because `addWorkout`/batch APIs dedupe by workout identity.
        guard snapshot.version <= Self.currentVersion else {
            return .corrupt
        }
        return .loaded(snapshot)
    }

    /// Load falling back to an empty snapshot for both missing and corrupt.
    public func loadOrEmpty() -> WatchFolderStoreSnapshot {
        switch load() {
        case .loaded(let snapshot): return snapshot
        case .missing, .corrupt: return WatchFolderStoreSnapshot()
        }
    }

    /// Persist the snapshot atomically, creating the root directory if needed.
    public func save(_ snapshot: WatchFolderStoreSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storeURL, options: .atomic)
    }
}
