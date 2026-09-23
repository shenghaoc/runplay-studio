import Foundation

/// Pure watch-folder scan and settle logic.
///
/// Everything here is deterministic and clock/filesystem-injectable so
/// RunPlayCore tests cover it on Linux with a temporary directory. The
/// coordinator owns tasks and lifetimes; this type only decides what is a
/// candidate, what already happened, and whether a file is still being
/// written.
///
/// `@unchecked Sendable` for the same reason as `FileWorkoutLibraryStore`:
/// `FileManager` is documented thread-safe but not `Sendable`.
public struct WatchFolderScanner: @unchecked Sendable {

    private let digest: any ContentDigesting
    private let policy: WatchFolderScanPolicy
    private let fileManager: FileManager

    public init(
        digest: any ContentDigesting,
        policy: WatchFolderScanPolicy = .default,
        fileManager: FileManager = .default
    ) {
        self.digest = digest
        self.policy = policy
        self.fileManager = fileManager
    }

    // MARK: - Directory scan

    /// One file discovered during a directory scan.
    public struct DiscoveredFile: Equatable, Sendable {
        public let url: URL
        public let byteSize: Int
        public let contentModificationDate: Date

        public init(url: URL, byteSize: Int, contentModificationDate: Date) {
            self.url = url
            self.byteSize = byteSize
            self.contentModificationDate = contentModificationDate
        }
    }

    /// Result of scanning one directory against one folder state.
    public struct ScanResult: Equatable, Sendable {
        /// Files eligible for import that are not in the ledger or the
        /// pending-review queue.
        public let candidates: [DiscoveredFile]
        /// Eligible files whose content hash is already ledgered.
        public let duplicates: [DiscoveredFile]
        /// Eligible files already queued for FIT review.
        public let pendingReview: [DiscoveredFile]
        /// Eligible files that could not be stat-ed (vanished mid-scan,
        /// permissions). Reported, never fatal.
        public let unreadable: [URL]

        public var isEmpty: Bool {
            candidates.isEmpty && duplicates.isEmpty
                && pendingReview.isEmpty && unreadable.isEmpty
        }
    }

    /// Whether `extension` (lowercased, dot-free) is import-eligible.
    public func isSupported(_ fileExtension: String) -> Bool {
        policy.supportedExtensions.contains(fileExtension.lowercased())
    }

    /// Whether `directoryURL` can currently be listed.
    ///
    /// Distinguishes "watched folder is gone right now" — volume ejected,
    /// directory deleted or moved, permission revoked — from "watched folder is
    /// empty", which `eligibleFiles` alone cannot tell apart because it reports
    /// an unreadable directory as zero files. Kept in Core so the Linux test
    /// suite covers the transition without macOS filesystem APIs.
    public func isDirectoryListable(_ directoryURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return fileManager.isReadableFile(atPath: directoryURL.path)
    }

    /// List eligible files directly inside `directoryURL`.
    ///
    /// Non-recursive: one watch folder maps to one directory, matching the
    /// single-folder picker and avoiding surprise imports from a `node_modules`
    /// tree or a synced Drive hierarchy. Hidden files and directories are
    /// skipped; only regular files whose extension could not be stat-ed count
    /// as unreadable.
    public func eligibleFiles(in directoryURL: URL) -> (files: [DiscoveredFile], unreadable: [URL]) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        ) else {
            return ([], [])
        }
        var files: [DiscoveredFile] = []
        var unreadable: [URL] = []
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let ext = url.pathExtension.lowercased()
            guard isSupported(ext) else { continue }
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
            ) else {
                unreadable.append(url)
                continue
            }
            // A directory that merely carries a supported extension is not a
            // file and not an error: skip it silently.
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                unreadable.append(url)
                continue
            }
            files.append(DiscoveredFile(
                url: url,
                byteSize: values.fileSize ?? 0,
                contentModificationDate: values.contentModificationDate ?? .distantPast
            ))
        }
        // Deterministic order for tests and stable panel rows.
        files.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        return (files, unreadable)
    }

    /// Classify a directory's eligible files against a folder state.
    ///
    /// `contentHashes` maps file URL to its content SHA-256 (computed by the
    /// caller, which owns the bounded read). Files whose hash is ledgered are
    /// duplicates; files whose hash is in pending review stay queued.
    public func classify(
        files: [DiscoveredFile],
        state: WatchFolderState,
        contentHashes: [URL: String]
    ) -> ScanResult {
        let ledgerHashes = Set(state.ledger.map(\.contentSHA256))
        var candidates: [DiscoveredFile] = []
        var duplicates: [DiscoveredFile] = []
        var pendingReview: [DiscoveredFile] = []
        for file in files {
            guard let hash = contentHashes[file.url] else {
                // No hash yet: the coordinator has not read this file.
                // Treat as a candidate; the pipeline hashes before import.
                candidates.append(file)
                continue
            }
            if ledgerHashes.contains(hash) {
                duplicates.append(file)
            } else if state.pendingReview[hash] != nil {
                pendingReview.append(file)
            } else {
                candidates.append(file)
            }
        }
        return ScanResult(
            candidates: candidates,
            duplicates: duplicates,
            pendingReview: pendingReview,
            unreadable: []
        )
    }

    // MARK: - Settle

    /// Settled-state tracking for one directory scan.
    ///
    /// A file is settled when its size and modification date are unchanged
    /// across two probes separated by at least the policy settle interval.
    /// Files that keep changing (a device or sync client still writing) are
    /// never imported, and once they stabilize they enter the next scan.
    public struct SettleTracker: Sendable {

        public struct Probe: Equatable, Sendable {
            public let byteSize: Int
            public let contentModificationDate: Date

            public init(byteSize: Int, contentModificationDate: Date) {
                self.byteSize = byteSize
                self.contentModificationDate = contentModificationDate
            }
        }

        private var previousProbes: [String: (probe: Probe, probedAt: Date)] = [:]

        private let settleInterval: TimeInterval

        public init(settleInterval: TimeInterval) {
            self.settleInterval = settleInterval
        }

        /// Record a probe for `key` and report whether the file is settled.
        ///
        /// Settled means: a previous probe exists, the size and modification
        /// date are identical, and the two probes are at least the settle
        /// interval apart. When the probes differ, the file is still being
        /// written and the new probe replaces the old.
        public mutating func update(
            key: String,
            byteSize: Int,
            contentModificationDate: Date,
            now: Date
        ) -> Bool {
            let probe = Probe(byteSize: byteSize, contentModificationDate: contentModificationDate)
            if let previous = previousProbes[key] {
                if previous.probe == probe,
                   now.timeIntervalSince(previous.probedAt) >= settleInterval {
                    return true
                }
                previousProbes[key] = (probe, now)
                return false
            }
            previousProbes[key] = (probe, now)
            return false
            // Entries for vanished files are pruned by `prune(keeping:)`.
        }

        /// Drop tracked entries whose key is no longer present in the
        /// directory, so the tracker does not grow without bound.
        public mutating func prune(keeping keys: Set<String>) {
            previousProbes = previousProbes.filter { keys.contains($0.key) }
        }
    }

    // MARK: - Content hashing

    /// Bounded content read and hash for one file.
    ///
    /// Returns nil when the file cannot be opened or read (vanished, locked,
    /// permissions) — that state is reported, never fatal. Re-throws the
    /// product resource-limit error when the file exceeds the maximum size
    /// so the caller records a definitive failure rather than retrying.
    public func contentHash(for url: URL) throws -> String? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return nil
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try readBounded(from: handle)
        } catch let error as WorkoutResourceLimitError {
            throw error
        } catch {
            return nil
        }
        return digest.sha256Hex(of: data)
    }

    /// Reuses the importer bounded-read semantics: read at most
    /// `maxFileBytes + 1` so an oversized file is proven, never guessed from
    /// metadata.
    private func readBounded(from handle: FileHandle) throws -> Data {
        let limit = policy.maxFileBytes
        let chunkSize = 1 << 20
        var data = Data()
        data.reserveCapacity(min(limit + 1, chunkSize))

        while data.count <= limit {
            let remaining = limit + 1 - data.count
            let chunk = try handle.read(upToCount: min(remaining, chunkSize))
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }

        guard data.count <= limit else {
            // Report the limit actually enforced, not a separate copy of the
            // product number: in production they are the same value, and a
            // narrowed policy must not claim a bound it did not apply.
            throw WorkoutResourceLimitError.sourceFileTooLarge(limitBytes: limit)
        }
        return data
    }
}

